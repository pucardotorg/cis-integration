#!/usr/bin/env python3
"""
Lightweight JSON viewer/editor for the uploader Data/ folder.

Stdlib only (http.server). Serves one embedded HTML page + a tiny JSON API:
  GET  /                      -> the editor page
  GET  /api/files             -> [{name, size}] for Data/*.json
  GET  /api/file?name=...     -> raw text of one file
  POST /api/file?name=...     -> save/create (body=raw text; validates JSON first)
  POST /api/delete?name=...   -> delete one file

Run launcher API (allow-listed scripts only):
  GET  /api/run-targets       -> buttons the UI may trigger
  POST /api/run?target=...    -> start a run in the background
  GET  /api/jobs              -> recent run jobs + log tails
  GET  /api/job?id=...        -> one run job + log tail
  GET  /api/run-log?id=...    -> full text log for one job
  POST /api/stop?id=...       -> terminate a running job

`name` is basename-sanitized so only the Data/ folder is reachable.
Run targets are allow-listed, never shell-interpolated, and execute from the uploader root.
Bind 127.0.0.1 only (court-side, no external exposure).

Usage:  python3 tools/data_editor.py [--port 8766] [--data Data]
Launch: bash RUN_DATA_EDITOR.sh
"""
import argparse
import datetime as _dt
import json
import os
import re
import signal
import subprocess
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # uploader/
DEFAULT_DATA = os.path.join(ROOT, "Data")
RUN_LOG_DIR = os.path.join(ROOT, "output", "editor-runs")
OUTPUT_ROOT = os.path.join(ROOT, "output")

DATA_DIR = DEFAULT_DATA

# Files that get a badge in the UI.
BADGES = {
    "pipeline.json": "manifest",
    "config.json": "config",
}

# Allow-listed run commands. These are the only commands the web UI/API can start.
# Each target also declares the Data/*.json files that operators usually edit before running it.
RUN_TARGETS = {
    "pipeline_validate": {
        "label": "Validate pipeline",
        "description": "Checks enabled stage inputs without CIS login or writes.",
        "command": ["bash", "RUN_PIPELINE.sh", "--validate"],
        "kind": "check",
        "cis_writes": False,
        "allow_input": False,
        "files": ["pipeline.json", "config.json"],
    },
    "pipeline": {
        "label": "Run full pipeline",
        "description": "Runs enabled stages from Data/pipeline.json.",
        "command": ["bash", "RUN_PIPELINE.sh"],
        "kind": "pipeline",
        "cis_writes": True,
        "allow_input": False,
        "files": ["pipeline.json"],
    },
    "advocate_lookup": {
        "label": "0. Lookup advocate",
        "description": "Read-only CIS advocate autocomplete lookup using Data/advocate-lookup-input.json; prints response in the run log.",
        "command": ["bash", "RUN_ADVOCATE_LOOKUP.sh"],
        "kind": "check",
        "cis_writes": False,
        "allow_input": False,
        "files": ["advocate-lookup-input.json", "config.json"],
    },
    "filing": {
        "label": "1. Run filing",
        "description": "Runs pipeline stage 'filing' using Data/pipeline.json.",
        "command": ["bash", "RUN_STAGE.sh", "filing"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["cis-daily-filings-2026-06-26.json"],
    },
    "allocation": {
        "label": "2. Run allocation",
        "description": "Runs pipeline stage 'allocation' using Data/allocation-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "allocation"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["allocation-input.json"],
    },
    "select_court": {
        "label": "3. Run court mapping",
        "description": "Runs pipeline stage 'select_court' using Data/select-court-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "select_court"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["select-court-input.json"],
    },
    "case_objection": {
        "label": "4. Run objection",
        "description": "Runs pipeline stage 'case_objection' using Data/case-objection-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "case_objection"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["case-objection-input.json"],
    },
    "registration": {
        "label": "5. Run case registration",
        "description": "Runs pipeline stage 'registration' using Data/registration-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "registration"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["registration-input.json", "registration-input.prefetched.json"],
    },
    "prefetch": {
        "label": "5a. Prefetch registration/proceeding drafts",
        "description": "Read-only CIS prefetch using simplified Data/prefetch-input.json (id/cnr/filing/stages); selects COURT_NO first; writes Data/*-input.prefetched.json and an audit output.",
        "command": ["bash", "fetch_stage_inputs.sh"],
        "kind": "check",
        "cis_writes": False,
        "allow_input": False,
        "files": ["prefetch-input.json", "registration-input.prefetched.json", "case-proceeding-input.prefetched.json"],
    },
    "case_proceeding_normalize_next_hearing": {
        "label": "6a. Prepare proceeding: next hearing",
        "description": "Normalizes Data/case-proceeding-next-hearing-input.json into Data/case-proceeding-input.json. No CIS login or writes.",
        "command": ["bash", "RUN_NORMALIZE_CASE_PROCEEDING.sh", "next_hearing"],
        "kind": "check",
        "cis_writes": False,
        "allow_input": False,
        "files": ["case-proceeding-types.json", "case-proceeding-next-hearing-input.json", "case-proceeding-input.json"],
    },
    "case_proceeding_normalize_disposal": {
        "label": "6b. Prepare proceeding: disposal",
        "description": "Normalizes Data/case-proceeding-disposal-input.json into Data/case-proceeding-input.json. No CIS login or writes.",
        "command": ["bash", "RUN_NORMALIZE_CASE_PROCEEDING.sh", "disposal"],
        "kind": "check",
        "cis_writes": False,
        "allow_input": False,
        "files": ["case-proceeding-types.json", "case-proceeding-disposal-input.json", "case-proceeding-input.json"],
    },
    "case_proceeding": {
        "label": "6c. Run case proceeding",
        "description": "Runs pipeline stage 'case_proceeding' using normalized Data/case-proceeding-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "case_proceeding"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["case-proceeding-input.json", "case-proceeding-input.prefetched.json", "case-proceeding-next-hearing-input.json", "case-proceeding-disposal-input.json"],
    },
    "bulk_order_upload": {
        "label": "7. Upload order/process PDF",
        "description": "Auto-builds Data/bulk-order-upload-input.json from the registration stage (case_no=registered_case_number) merged with Data/bulk-order-upload-drafts.json (file_path/document_type/order_no/order_date), then uploads via proceedings/bulkupload.php. Edit the drafts file to point at your order PDF.",
        "command": ["bash", "RUN_STAGE.sh", "bulk_order_upload"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["bulk-order-upload-drafts.json", "bulk-order-upload-input.json"],
    },
    "process_prefetch": {
        "label": "8. Prefetch + save process-generation input",
        "description": "Read-only process prefetch using Data/process-prefetch-input.json; saves editable Data/process-generation-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "process_prefetch"],
        "kind": "check",
        "cis_writes": False,
        "allow_input": False,
        "files": ["process-prefetch-input.json", "process-generation-input.json"],
    },
    "process_generation": {
        "label": "9. Run process generation",
        "description": "Runs pipeline stage 'process_generation' using Data/process-generation-input.json and downloads draft PDFs.",
        "command": ["bash", "RUN_STAGE.sh", "process_generation"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["process-generation-input.json"],
    },
    "process_upload": {
        "label": "10. Upload process",
        "description": "Final stage: uploads generated/signed process PDF using Data/process-upload-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "process_upload"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["process-upload-input.json"],
    },
    "publish_process": {
        "label": "11. Publish process (optional)",
        "description": "Runs optional pipeline stage 'publish_process' using Data/publish-process-input.json.",
        "command": ["bash", "RUN_STAGE.sh", "publish_process"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["publish-process-input.json"],
    },
    "delete_process_draft": {
        "label": "12. Delete generated process draft",
        "description": "Deletes the generated draft process/notices using Data/publish-process-input.json (HAR: publish-process-delete.har).",
        "command": ["bash", "RUN_STAGE.sh", "publish_process"],
        "kind": "stage",
        "cis_writes": True,
        "allow_input": False,
        "files": ["publish-process-input.json"],
        "env": {"PUBLISH_PROCESS_FORCE_ACTION": "delete_draft"},
    },
}

JOBS = {}
JOB_PROCS = {}
JOBS_LOCK = threading.Lock()

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>uploader — Data/ JSON editor</title>
<style>
  :root { --bg:#f7f8fa; --panel:#fff; --line:#e3e6ea; --accent:#2563eb; --ok:#16a34a; --err:#dc2626; --muted:#6b7280; --warn:#ea580c; --ink:#111827; }
  * { box-sizing: border-box; }
  body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:#111; }
  header { background:var(--panel); border-bottom:1px solid var(--line); padding:10px 16px; display:flex; gap:12px; align-items:center; flex-wrap:wrap; position:sticky; top:0; z-index:2; }
  header h1 { font-size:16px; margin:0; }
  header .path { color:var(--muted); font-family:monospace; font-size:12px; }
  header .spacer { flex:1; }
  header input[type=text] { padding:6px 10px; border:1px solid var(--line); border-radius:6px; width:220px; }
  button { cursor:pointer; border:1px solid var(--line); background:var(--panel); padding:6px 12px; border-radius:6px; font-size:13px; }
  button.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
  button.danger { color:var(--err); border-color:var(--err); }
  button.warn { background:var(--warn); color:#fff; border-color:var(--warn); }
  button:disabled { opacity:.5; cursor:default; }
  main { padding:12px 16px 60px; max-width:1180px; margin:0 auto; }
  .panel { background:var(--panel); border:1px solid var(--line); border-radius:8px; margin-bottom:12px; padding:12px; }
  .panel h2 { font-size:14px; margin:0; display:flex; gap:8px; align-items:center; }
  .panel .top { display:flex; align-items:center; gap:10px; margin-bottom:10px; flex-wrap:wrap; }
  .hint { color:var(--muted); font-size:12px; }
  .runbuttons { display:flex; flex-wrap:wrap; gap:8px; margin:8px 0; }
  .runbuttons button.check { border-color:var(--ok); color:var(--ok); }
  .runbuttons button.pipeline { background:var(--accent); border-color:var(--accent); color:white; }
  .runbuttons button.stage { border-color:#a5b4fc; color:#3730a3; }
  .workflow { display:grid; grid-template-columns:1fr; gap:12px; }
  .action-card { border:1px solid var(--line); border-radius:10px; background:#fbfcff; overflow:hidden; }
  .action-card.check { background:#fbfffc; }
  .action-card.pipeline { background:#f8fbff; border-color:#bfdbfe; }
  .action-card.collapsed .action-body { display:none; }
  .action-card.collapsed .action-head { border-bottom:0; }
  .action-head { display:flex; gap:10px; align-items:flex-start; padding:12px; border-bottom:1px solid var(--line); flex-wrap:wrap; }
  .action-toggle { width:30px; padding:6px 0; text-align:center; }
  .action-title { font-weight:700; font-size:14px; }
  .action-desc { color:var(--muted); font-size:12px; margin-top:2px; max-width:720px; }
  .action-main { flex:1; min-width:260px; }
  .action-files { padding:10px 12px 12px; }
  .action-files .file { margin-bottom:8px; }
  .action-files .file:last-child { margin-bottom:0; }
  .action-job { padding:0 12px 12px; }
  .action-job .job { margin-top:0; border-top:1px dashed var(--line); }
  .tag { font-size:11px; border-radius:99px; padding:2px 7px; border:1px solid var(--line); color:var(--muted); background:#fff; white-space:nowrap; }
  .tag.warn { color:#9a3412; border-color:#fed7aa; background:#fff7ed; }
  .missing-file { padding:8px 10px; border:1px dashed var(--line); border-radius:8px; color:var(--muted); font-family:monospace; background:#fff; margin-bottom:8px; }
  .section-title { display:flex; align-items:center; gap:8px; margin:2px 0 10px; }
  .section-title h2 { margin:0; font-size:14px; }
  .job { border-top:1px solid var(--line); padding-top:10px; margin-top:10px; }
  .jobhead { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
  .outhead { display:flex; align-items:center; gap:8px; flex-wrap:wrap; cursor:pointer; user-select:none; }
  .outbody { margin:8px 0 0 18px; display:none; }
  .job.open .outbody { display:block; }
  .outfiles { width:100%; border-collapse:collapse; margin-top:6px; }
  .outfiles td { border-top:1px solid var(--line); padding:6px 4px; vertical-align:top; }
  .outfiles .fname { font-family:monospace; }
  .viewer { background:#0f172a; color:#d1d5db; border-radius:6px; padding:10px; max-height:420px; overflow:auto; white-space:pre-wrap; font:12px/1.45 ui-monospace,Menlo,Consolas,monospace; margin-top:8px; }
  select { padding:6px 10px; border:1px solid var(--line); border-radius:6px; background:var(--panel); }
  .pill { font-size:11px; border-radius:99px; padding:2px 7px; border:1px solid var(--line); font-family:monospace; }
  .pill.running { color:#1d4ed8; background:#dbeafe; border-color:#bfdbfe; }
  .pill.succeeded { color:#166534; background:#dcfce7; border-color:#bbf7d0; }
  .pill.failed { color:#991b1b; background:#fee2e2; border-color:#fecaca; }
  .log { margin-top:8px; background:#0f172a; color:#d1d5db; border-radius:6px; padding:10px; max-height:280px; overflow:auto; white-space:pre-wrap; font:12px/1.45 ui-monospace,Menlo,Consolas,monospace; }
  .file { background:var(--panel); border:1px solid var(--line); border-radius:8px; margin-bottom:10px; }
  .file > .head { display:flex; align-items:center; gap:10px; padding:8px 12px; cursor:pointer; user-select:none; }
  .file > .head .chev { width:12px; color:var(--muted); transition:transform .15s; }
  .file.collapsed .chev { transform:rotate(-90deg); }
  .file .name { font-weight:600; font-family:monospace; }
  .file .badge { font-size:10px; text-transform:uppercase; letter-spacing:.5px; padding:1px 6px; border-radius:10px; background:#eef2ff; color:#4338ca; }
  .file .badge.config { background:#fef3c7; color:#92400e; }
  .file .meta { color:var(--muted); font-size:12px; margin-left:auto; }
  .file .body { padding:0 12px 12px; display:flex; flex-direction:column; gap:8px; }
  .file.collapsed .body { display:none; }
  textarea { width:100%; min-height:280px; font:12px/1.5 ui-monospace,Menlo,Consolas,monospace; border:1px solid var(--line); border-radius:6px; padding:10px; resize:vertical; tab-size:2; }
  .row { display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
  .status { font-size:12px; font-family:monospace; }
  .status.ok { color:var(--ok); } .status.err { color:var(--err); } .status.info { color:var(--muted); }
  .empty { color:var(--muted); padding:24px; text-align:center; }
  .newrow { display:flex; gap:8px; align-items:center; margin-bottom:12px; }
  .newrow input { padding:6px 10px; border:1px solid var(--line); border-radius:6px; }
</style></head><body>
<header>
  <h1>📁 V3 Data/ editor</h1>
  <span class="path" id="datapath"></span>
  <span class="spacer"></span>
  <input id="filter" type="text" placeholder="filter actions/files…">
  <button id="refresh">↻ refresh</button>
  <button class="primary" id="new">＋ New file</button>
</header>
<main>
  <section class="panel" id="runpanel">
    <div class="top">
      <h2>▶ Workflow</h2>
      <span class="hint">Each action is paired with the JSON file(s) normally edited before running it. Save changes before starting a run.</span>
      <span class="spacer"></span>
      <button id="expandworkflow">Expand all</button>
      <button id="collapseworkflow">Collapse all</button>
      <button id="refreshjobs">↻ jobs</button>
      <span class="status info" id="runmsg"></span>
    </div>
    <div class="workflow" id="workflow"></div>
  </section>

  <section class="panel" id="outputpanel">
    <div class="top">
      <h2>📤 Outputs</h2>
      <span class="hint">Read-only result files grouped by output date. Latest run expands by default.</span>
      <span class="spacer"></span>
      <label class="hint" for="outputdate">Date:</label>
      <select id="outputdate"></select>
      <button id="refreshoutputs">↻ outputs</button>
      <button id="expandlatest">Expand latest only</button>
      <button id="expandall">Expand all</button>
      <button id="collapseall">Collapse all</button>
      <span class="status info" id="outputmsg"></span>
    </div>
    <div id="outputs"></div>
  </section>

  <section class="panel" id="otherpanel">
    <div class="top">
      <h2>🗂 Other JSON files</h2>
      <span class="hint">Files not directly attached to a workflow action.</span>
      <span class="spacer"></span>
      <span class="status info" id="othercount"></span>
    </div>
    <div class="newrow" id="newrow" style="display:none">
      <input id="newname" type="text" placeholder="new-file.json" style="width:260px">
      <button class="primary" id="newcreate">Create</button>
      <button id="newcancel">Cancel</button>
      <span class="status info" id="newmsg"></span>
    </div>
    <div id="list"></div>
  </section>
</main>
<script>
const api = '/api';
let allFiles = [];
let filesLoaded = false;
let runTargets = [];
let recentJobs = [];
let pollTimer = null;
let outputDates = [];
let outputRuns = [];
let outputMode = 'latest';

const $ = s => document.querySelector(s);
const list = $('#list');
const workflow = $('#workflow');
const datapath = $('#datapath');

async function jget(u){ const r=await fetch(u); if(!r.ok) throw new Error(await r.text()); return r.json(); }
async function textget(u){ const r=await fetch(u); if(!r.ok) throw new Error(await r.text()); return r.text(); }
async function post(u, body, ct='text/plain;charset=utf-8'){
  const r=await fetch(u,{method:'POST',headers:{'Content-Type':ct},body});
  if(!r.ok) throw new Error(await r.text()); return r.text();
}
async function jpost(u, obj){
  const r=await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(obj||{})});
  if(!r.ok) throw new Error(await r.text()); return r.json();
}

function esc(s){ return String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function setRunMsg(msg, cls='info'){ const el=$('#runmsg'); el.textContent=msg; el.className='status '+cls; }

function row(f){
  const badge = BADGES(f.name);
  const el = document.createElement('div');
  el.className='file collapsed'; el.dataset.name=f.name;
  el.innerHTML = `
    <div class="head"><span class="chev">▼</span>
      <span class="name">${esc(f.name)}</span>${badge}
      <span class="meta">${f.size} B</span>
    </div>
    <div class="body">
      <textarea spellcheck="false" data-orig=""></textarea>
      <div class="row">
        <button class="primary" data-act="save" disabled>Save</button>
        <button data-act="revert" disabled>Revert</button>
        <button data-act="format">Format</button>
        <button class="danger" data-act="delete">Delete</button>
        <span class="status info" data-role="status"></span>
      </div>
    </div>`;
  const head=el.querySelector('.head'),
        ta=el.querySelector('textarea'), save=el.querySelector('[data-act=save]'),
        revert=el.querySelector('[data-act=revert]'), fmt=el.querySelector('[data-act=format]'),
        del=el.querySelector('[data-act=delete]'), st=el.querySelector('[data-role=status]');
  let dirty=false;
  function setstatus(msg,cls){ st.textContent=msg; st.className='status '+(cls||'info'); }
  function setdirty(v){ dirty=v; ta.dataset.dirty = v ? '1' : '0'; save.disabled=!dirty; revert.disabled=!dirty; }
  head.onclick=async ()=>{
    const open = !el.classList.contains('collapsed');
    el.classList.toggle('collapsed');
    if(!open && !ta.dataset.loaded){ // expanding and not yet loaded
      setstatus('loading…','info');
      try{
        const txt=await textget(`${api}/file?name=${encodeURIComponent(f.name)}`);
        ta.value=txt; ta.dataset.orig=txt; ta.dataset.loaded='1'; setdirty(false); setstatus('loaded','info');
      }catch(e){ setstatus('load failed: '+e.message,'err'); }
    }
  };
  ta.addEventListener('input',()=>{ setdirty(ta.value!==ta.dataset.orig); setstatus(dirty?'unsaved':'','info'); });
  fmt.onclick=()=>{ try{ ta.value=JSON.stringify(JSON.parse(ta.value), null, 2); setstatus('formatted','ok'); setdirty(ta.value!==ta.dataset.orig); }catch(e){ setstatus('invalid JSON: '+e.message,'err'); } };
  revert.onclick=()=>{ ta.value=ta.dataset.orig; setdirty(false); setstatus('reverted','info'); };
  save.onclick=async ()=>{
    try{ JSON.parse(ta.value); }catch(e){ setstatus('refuse save: invalid JSON: '+e.message,'err'); return; }
    setstatus('saving…','info');
    try{ await post(`${api}/file?name=${encodeURIComponent(f.name)}`, ta.value); ta.dataset.orig=ta.value; setdirty(false); setstatus('saved','ok'); await refreshMeta(el,f.name); }
    catch(e){ setstatus('save failed: '+e.message,'err'); }
  };
  del.onclick=async ()=>{
    if(!confirm(`Delete ${f.name}? This cannot be undone.`)) return;
    try{ await post(`${api}/delete?name=${encodeURIComponent(f.name)}`,''); el.remove(); allFiles=allFiles.filter(x=>x.name!==f.name); applyFilter(); }
    catch(e){ setstatus('delete failed: '+e.message,'err'); }
  };
  return el;
}
function BADGES(n){ const b=BADGES_MAP[n]; return b?` <span class="badge ${b}">${b}</span>`:''; }
let BADGES_MAP = {};

async function refreshMeta(el,name){
  try{ const files=await jget(`${api}/files`); const f=files.find(x=>x.name===name); if(f) el.querySelector('.meta').textContent=f.size+' B'; }catch(e){}
}
async function refreshFileIndex(){
  const files = await jget(`${api}/files`);
  files.sort((a,b)=>a.name.localeCompare(b.name));
  allFiles = files;
  const byName = new Map(files.map(f=>[f.name, f]));
  document.querySelectorAll('.file[data-name]').forEach(el=>{
    const f = byName.get(el.dataset.name);
    if(f) el.querySelector('.meta').textContent = f.size + ' B';
  });
}
async function refreshLoadedEditors(names){
  try{ await refreshFileIndex(); }catch(e){ return; }
  const wanted = names && names.length ? new Set(names) : null;
  const editors = Array.from(document.querySelectorAll('.file[data-name]')).filter(el=>!wanted || wanted.has(el.dataset.name));
  for(const el of editors){
    const ta = el.querySelector('textarea');
    if(!ta || !ta.dataset.loaded || ta.dataset.dirty === '1') continue;
    const st = el.querySelector('[data-role=status]');
    try{
      const txt = await textget(`${api}/file?name=${encodeURIComponent(el.dataset.name)}`);
      if(txt !== ta.dataset.orig){
        ta.value = txt;
        ta.dataset.orig = txt;
        if(st){ st.textContent = 'reloaded after run'; st.className = 'status ok'; }
      }
    }catch(e){
      if(st){ st.textContent = 'reload failed: '+e.message; st.className = 'status err'; }
    }
  }
}
function filesForTargets(targetKeys){
  const out = new Set();
  for(const key of targetKeys){
    const t = runTargets.find(x=>x.key === key);
    for(const n of (t?.files || [])) out.add(n);
  }
  return Array.from(out);
}

function fileMeta(name){ return allFiles.find(f=>f.name===name); }
function associatedFileNames(){
  const names = new Set();
  for(const t of runTargets) for(const n of (t.files||[])) names.add(n);
  return names;
}
function targetMatches(t, q){
  if(!q) return true;
  const hay = [t.label, t.description, t.key, ...(t.files||[])].join(' ').toLowerCase();
  return hay.includes(q);
}
function renderMissingFile(name){
  const el = document.createElement('div');
  el.className = 'missing-file';
  el.textContent = `${name} — not found in Data/`;
  return el;
}
function renderWorkflow(){
  if(!workflow) return;
  const q=$('#filter').value.toLowerCase().trim();
  workflow.innerHTML='';
  const targets = runTargets.filter(t=>targetMatches(t,q));
  if(!targets.length){ workflow.innerHTML='<div class="empty">No actions match.</div>'; return; }
  for(const t of targets){
    const card = document.createElement('div');
    card.className = `action-card collapsed ${esc(t.kind || '')}`;
    card.dataset.target = t.key;
    const writeTag = t.cis_writes ? '<span class="tag warn">CIS write</span>' : '<span class="tag">read-only/check</span>';
    card.innerHTML = `
      <div class="action-head">
        <button class="action-toggle" data-action-toggle title="Expand/collapse this stage">▶</button>
        <div class="action-main">
          <div class="action-title">${esc(t.label)}</div>
          <div class="action-desc">${esc(t.description || '')}</div>
        </div>
        ${writeTag}
        <button class="${t.kind === 'pipeline' ? 'primary' : (t.cis_writes ? 'warn' : '')}" data-run="${esc(t.key)}">Run</button>
      </div>
      <div class="action-body">
        <div class="action-files"></div>
        <div class="action-job" data-job-for="${esc(t.key)}"></div>
      </div>`;
    const filesBox = card.querySelector('.action-files');
    const names = t.files || [];
    if(!names.length) filesBox.innerHTML = '<div class="hint">No JSON files mapped to this action.</div>';
    for(const name of names){
      const f = fileMeta(name);
      filesBox.appendChild(f ? row(f) : renderMissingFile(name));
    }
    card.querySelector('[data-action-toggle]').onclick = (ev) => { ev.stopPropagation(); toggleActionCard(card); };
    card.querySelector('[data-run]').onclick = () => startRun(t.key);
    workflow.appendChild(card);
  }
  renderActionJobs();
  const running = recentJobs.some(j=>j.status === 'running');
  document.querySelectorAll('[data-run]').forEach(b=>b.disabled = running);
}
function toggleActionCard(card, forceCollapsed){
  const collapsed = forceCollapsed === undefined ? !card.classList.contains('collapsed') : forceCollapsed;
  card.classList.toggle('collapsed', collapsed);
  const btn = card.querySelector('[data-action-toggle]');
  if(btn) btn.textContent = collapsed ? '▶' : '▼';
}
function setWorkflowCollapsed(collapsed){
  document.querySelectorAll('.action-card').forEach(card=>toggleActionCard(card, collapsed));
}
function renderOtherFiles(){
  const q=$('#filter').value.toLowerCase().trim();
  const mapped = associatedFileNames();
  const filtered = allFiles.filter(f=>!mapped.has(f.name)).filter(f=>!q || f.name.toLowerCase().includes(q));
  $('#othercount').textContent = filtered.length ? `${filtered.length} file(s)` : '';
  list.innerHTML='';
  if(!filtered.length){ list.innerHTML='<div class="empty">No other files match.</div>'; return; }
  for(const f of filtered) list.appendChild(row(f));
}
function applyFilter(){
  renderWorkflow();
  renderOtherFiles();
}

async function load(){
  try{
    const meta=await jget(`${api}/meta`); datapath.textContent=(meta.version ? meta.version + ' — ' : '') + meta.data_dir; BADGES_MAP=meta.badges||{};
    allFiles=await jget(`${api}/files`);
    allFiles.sort((a,b)=>a.name.localeCompare(b.name));
    filesLoaded = true;
    applyFilter();
  }catch(e){ list.innerHTML=`<div class="empty">Error: ${esc(e.message)}</div>`; }
}

async function loadRunTargets(){
  try{
    const data = await jget(`${api}/run-targets`);
    runTargets = data.targets || [];
    renderWorkflow();
    renderOtherFiles();
  }catch(e){ setRunMsg('run targets failed: '+e.message, 'err'); }
}

async function startRun(key){
  const t = runTargets.find(x=>x.key===key);
  if(!t) return;
  if(t.cis_writes && !confirm(`${t.label} will log in and submit to CIS. Continue?`)) return;
  if(!t.cis_writes && !confirm(`${t.label}?`)) return;
  setRunMsg('starting…','info');
  try{
    const job = await jpost(`${api}/run?target=${encodeURIComponent(key)}`, {});
    setRunMsg(`started ${job.id}`,'ok');
    await loadJobs();
  }catch(e){ setRunMsg('start failed: '+e.message,'err'); }
}

function jobMarkup(j, open=true){
  const cls = j.status === 'running' ? 'running' : (j.returncode === 0 ? 'succeeded' : 'failed');
  const rc = j.returncode === null || j.returncode === undefined ? '' : ` rc=${j.returncode}`;
  const ended = j.ended_at ? ` ended ${esc(j.ended_at)}` : '';
  const stop = j.status === 'running' ? `<button class="danger" data-stop="${esc(j.id)}">Stop</button>` : '';
  return `<div class="job ${open ? 'open' : ''}">
    <div class="outhead" data-job-toggle>
      <span class="chev">${open ? '▼' : '▶'}</span>
      <strong>${esc(j.label || j.target)}</strong>
      <span class="pill ${cls}">${esc(j.status)}${rc}</span>
      <span class="hint">${esc(j.started_at || '')}${ended}</span>
      <span class="hint">log: ${esc(j.log_rel || '')}</span>
      <button data-reload="${esc(j.id)}">Refresh</button>${stop}
    </div>
    <div class="outbody"><pre class="log">${esc(j.log_tail || '')}</pre></div>
  </div>`;
}

function wireJobControls(root){
  root.querySelectorAll('[data-stop]').forEach(b=>b.onclick=(ev)=>{ ev.stopPropagation(); stopJob(b.dataset.stop); });
  root.querySelectorAll('[data-reload]').forEach(b=>b.onclick=(ev)=>{ ev.stopPropagation(); loadJobs(); });
  root.querySelectorAll('[data-job-toggle]').forEach(h=>h.onclick=()=>{
    const card=h.closest('.job'); card.classList.toggle('open'); h.querySelector('.chev').textContent=card.classList.contains('open')?'▼':'▶';
  });
}

function renderActionJobs(){
  document.querySelectorAll('[data-job-for]').forEach(box=>{
    const key = box.dataset.jobFor;
    const latest = recentJobs.find(j=>j.target === key);
    if(!latest){ box.innerHTML = '<div class="hint">No run from this editor yet.</div>'; return; }
    box.innerHTML = jobMarkup(latest, latest.status === 'running');
    wireJobControls(box);
  });
}

async function loadJobs(){
  try{
    const previous = new Map(recentJobs.map(j=>[j.id, j.status]));
    const data = await jget(`${api}/jobs`);
    recentJobs = data.jobs || [];
    const completedTargets = recentJobs
      .filter(j=>previous.get(j.id) === 'running' && j.status !== 'running')
      .map(j=>j.target);
    if(completedTargets.length) await refreshLoadedEditors(filesForTargets(completedTargets));
    renderActionJobs();
    const running = recentJobs.some(j=>j.status === 'running');
    document.querySelectorAll('[data-run]').forEach(b=>b.disabled = running);
    if(pollTimer) clearTimeout(pollTimer);
    if(running) pollTimer = setTimeout(loadJobs, 2000);
  }catch(e){ setRunMsg('jobs failed: '+e.message,'err'); }
}

async function stopJob(id){
  if(!confirm('Stop this running job?')) return;
  try{ await post(`${api}/stop?id=${encodeURIComponent(id)}`, ''); await loadJobs(); }
  catch(e){ setRunMsg('stop failed: '+e.message,'err'); }
}

function setOutputMsg(msg, cls='info'){ const el=$('#outputmsg'); el.textContent=msg; el.className='status '+cls; }
function outputSummary(run){
  const s = run.summary || {};
  if(s.total !== undefined) return `${s.success||0}/${s.total||0} ok`;
  return `${run.files?.length||0} file(s)`;
}
function outputStatus(run){
  const s = run.summary || {};
  if(s.failed > 0) return 'failed';
  if(s.total > 0) return 'succeeded';
  return 'running';
}

async function loadOutputDates(){
  try{
    const data = await jget(`${api}/output-dates`);
    outputDates = data.dates || [];
    const sel = $('#outputdate');
    const prev = sel.value;
    sel.innerHTML = outputDates.map(d=>`<option value="${esc(d.date)}">${esc(d.date)} (${d.file_count})</option>`).join('');
    if(prev && outputDates.some(d=>d.date===prev)) sel.value = prev;
    if(!sel.value && outputDates.length) sel.value = outputDates[0].date;
    if(outputDates.length) await loadOutputs();
    else $('#outputs').innerHTML = '<div class="hint">No output folders found yet.</div>';
  }catch(e){ setOutputMsg('output dates failed: '+e.message,'err'); }
}

async function loadOutputs(){
  const date = $('#outputdate').value;
  if(!date){ $('#outputs').innerHTML = '<div class="hint">Select a date.</div>'; return; }
  try{
    const data = await jget(`${api}/output-runs?date=${encodeURIComponent(date)}`);
    outputRuns = data.runs || [];
    renderOutputs();
    setOutputMsg(`loaded ${outputRuns.length} run(s)`,'ok');
  }catch(e){ setOutputMsg('outputs failed: '+e.message,'err'); }
}

function shouldOpenOutput(idx){
  if(outputMode === 'all') return true;
  if(outputMode === 'none') return false;
  return idx === 0;
}

function renderOutputs(){
  const el = $('#outputs');
  if(!outputRuns.length){ el.innerHTML = '<div class="hint">No outputs for this date.</div>'; return; }
  el.innerHTML = outputRuns.map((r,idx)=>{
    const open = shouldOpenOutput(idx);
    const cls = outputStatus(r);
    const files = (r.files||[]).map(f=>`<tr>
      <td class="fname">${esc(f.name)}</td>
      <td class="hint">${esc(f.size)} B</td>
      <td><button data-view-output="${esc(f.name)}">View JSON</button></td>
    </tr>`).join('');
    return `<div class="job ${open ? 'open' : ''}" data-run-id="${esc(r.run_id)}">
      <div class="outhead" data-output-toggle>
        <span class="chev">${open ? '▼' : '▶'}</span>
        <strong>${esc(r.run_id)}</strong>
        <span class="pill ${cls}">${esc(r.kind || 'run')}</span>
        <span class="hint">${esc(outputSummary(r))}</span>
        <span class="hint">${esc(r.started_at || '')}</span>
      </div>
      <div class="outbody">
        <table class="outfiles"><tbody>${files}</tbody></table>
        <pre class="viewer" style="display:none"></pre>
      </div>
    </div>`;
  }).join('');
  el.querySelectorAll('[data-output-toggle]').forEach(h=>h.onclick=()=>{
    const card=h.closest('.job'); card.classList.toggle('open'); h.querySelector('.chev').textContent=card.classList.contains('open')?'▼':'▶';
  });
  el.querySelectorAll('[data-view-output]').forEach(b=>b.onclick=(ev)=>{
    ev.stopPropagation(); viewOutputFile(b.dataset.viewOutput, b.closest('.job').querySelector('.viewer'));
  });
}

async function viewOutputFile(name, viewer){
  const date = $('#outputdate').value;
  try{
    const txt = await textget(`${api}/output-file?date=${encodeURIComponent(date)}&name=${encodeURIComponent(name)}`);
    let out = txt;
    try{ out = JSON.stringify(JSON.parse(txt), null, 2); }catch(e){}
    viewer.textContent = out;
    viewer.style.display = 'block';
  }catch(e){ viewer.textContent='load failed: '+e.message; viewer.style.display='block'; }
}

$('#refresh').onclick=load;
$('#expandworkflow').onclick=()=>setWorkflowCollapsed(false);
$('#collapseworkflow').onclick=()=>setWorkflowCollapsed(true);
$('#refreshjobs').onclick=loadJobs;
$('#refreshoutputs').onclick=loadOutputDates;
$('#outputdate').onchange=loadOutputs;
$('#expandlatest').onclick=()=>{ outputMode='latest'; localStorage.setItem('outputs.mode', outputMode); renderOutputs(); };
$('#expandall').onclick=()=>{ outputMode='all'; localStorage.setItem('outputs.mode', outputMode); renderOutputs(); };
$('#collapseall').onclick=()=>{ outputMode='none'; localStorage.setItem('outputs.mode', outputMode); renderOutputs(); };
$('#filter').addEventListener('input',applyFilter);
$('#new').onclick=()=>{ $('#newrow').style.display='flex'; $('#newname').value=''; $('#newname').focus(); $('#newmsg').textContent=''; };
$('#newcancel').onclick=()=>{ $('#newrow').style.display='none'; };
$('#newcreate').onclick=async ()=>{
  let name=$('#newname').value.trim();
  if(!name){ $('#newmsg').textContent='enter a name'; return; }
  if(!name.toLowerCase().endsWith('.json')) name+='.json';
  if(/[^A-Za-z0-9._-]/.test(name)){ $('#newmsg').textContent='only letters, digits, . _ - allowed'; return; }
  try{
    await post(`${api}/file?name=${encodeURIComponent(name)}`, '[]');
    $('#newmsg').textContent='created'; $('#newrow').style.display='none';
    await load();
    const el=list.querySelector(`.file[data-name="${CSS.escape(name)}"]`);
    if(el) el.querySelector('.head').click();
  }catch(e){ $('#newmsg').textContent='failed: '+e.message; }
};

outputMode = localStorage.getItem('outputs.mode') || 'latest';
loadRunTargets();
load();
loadJobs();
loadOutputDates();
</script>
</body></html>"""


def _now():
    return _dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def _basename(name):
    """Return a safe basename or raise ValueError."""
    if not name:
        raise ValueError("missing name")
    name = urllib.parse.unquote(name)
    name = os.path.basename(name.replace("\\", "/"))
    if name in (".", "..", "") or os.sep in name or "/" in name:
        raise ValueError("invalid name")
    if not name.lower().endswith(".json"):
        raise ValueError("only .json files are editable")
    return name


def _safe_optional_input(value):
    """Validate an optional relative JSON input path for standalone run scripts."""
    if value is None:
        return ""
    value = str(value).strip().replace("\\", "/")
    if not value:
        return ""
    if value.startswith("/") or value.startswith("~"):
        raise ValueError("input path must be relative to the uploader folder")
    parts = [p for p in value.split("/") if p]
    if any(p in (".", "..") for p in parts):
        raise ValueError("input path cannot contain . or ..")
    if not value.lower().endswith(".json"):
        raise ValueError("input path must point to a .json file")
    if not (value.startswith("Data/") or value.startswith("output/")):
        raise ValueError("input path must be under Data/ or output/")
    abspath = os.path.abspath(os.path.join(ROOT, value))
    root_abs = os.path.abspath(ROOT)
    if os.path.commonpath([root_abs, abspath]) != root_abs:
        raise ValueError("input path escapes uploader folder")
    if not os.path.isfile(abspath):
        raise ValueError("input file not found: " + value)
    return value


def _safe_output_date(value):
    value = str(value or "").strip()
    if not re.fullmatch(r"\d{8}", value):
        raise ValueError("date must be DDMMYYYY")
    return value


def _safe_output_name(value):
    name = urllib.parse.unquote(str(value or ""))
    name = os.path.basename(name.replace("\\", "/"))
    if not name or name in (".", "..") or "/" in name or "\\" in name:
        raise ValueError("invalid output filename")
    return name


def _json_summary(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
    except Exception:
        return None
    if isinstance(data, list):
        total = len(data)
        success = sum(1 for r in data if isinstance(r, dict) and r.get("status") == "success")
        return {"total": total, "success": success, "failed": total - success}
    if isinstance(data, dict) and isinstance(data.get("stages"), list):
        total = success = failed = 0
        for st in data.get("stages") or []:
            out = st.get("output") if isinstance(st, dict) else None
            if isinstance(out, dict):
                total += int(out.get("total") or 0)
                success += int(out.get("success") or 0)
                failed += int(out.get("failed") or 0)
        return {"total": total, "success": success, "failed": failed}
    if isinstance(data, dict) and data.get("status"):
        return {"total": 1, "success": 1 if data.get("status") == "success" else 0, "failed": 0 if data.get("status") == "success" else 1}
    return None


def _infer_kind(filename):
    n = filename.lower()
    if "pipeline-summary" in n:
        return "pipeline"
    if "registration" in n:
        return "registration"
    if "case-objection" in n:
        return "case_objection"
    if "select-court" in n:
        return "select_court"
    if "allocation" in n:
        return "allocation"
    if "cis-results" in n:
        return "filing"
    return "run"


def _list_output_dates():
    rows = []
    if not os.path.isdir(OUTPUT_ROOT):
        return rows
    for name in os.listdir(OUTPUT_ROOT):
        p = os.path.join(OUTPUT_ROOT, name)
        if not os.path.isdir(p) or not re.fullmatch(r"\d{8}", name):
            continue
        files = [os.path.join(p, f) for f in os.listdir(p) if os.path.isfile(os.path.join(p, f))]
        latest = max((os.path.getmtime(f) for f in files), default=os.path.getmtime(p))
        rows.append({"date": name, "file_count": len(files), "latest_mtime": latest})
    rows.sort(key=lambda r: r["latest_mtime"], reverse=True)
    return rows


def _list_output_runs(date_s):
    date_s = _safe_output_date(date_s)
    day_dir = os.path.abspath(os.path.join(OUTPUT_ROOT, date_s))
    output_abs = os.path.abspath(OUTPUT_ROOT)
    if os.path.commonpath([output_abs, day_dir]) != output_abs or not os.path.isdir(day_dir):
        return []

    files = []
    for n in os.listdir(day_dir):
        p = os.path.join(day_dir, n)
        if os.path.isfile(p):
            files.append({"name": n, "path": p, "size": os.path.getsize(p), "mtime": os.path.getmtime(p)})

    manifests = {}
    for f in files:
        if f["name"].endswith("-run-manifest.json"):
            try:
                with open(f["path"], encoding="utf-8", errors="replace") as fh:
                    m = json.load(fh)
                rid = str(m.get("run_id") or f["name"].removesuffix("-run-manifest.json"))
                manifests[rid] = m
            except Exception:
                pass

    groups = {}
    for f in files:
        name = f["name"]
        rid = None
        for mrid in manifests:
            if name.startswith(mrid + "-"):
                rid = mrid
                break
        if not rid:
            m = re.match(r"^(\d{6}(?:-[A-Za-z0-9]+)?)-", name)
            rid = m.group(1) if m else os.path.splitext(name)[0]
        groups.setdefault(rid, []).append(f)

    runs = []
    for rid, gfiles in groups.items():
        gfiles.sort(key=lambda x: x["name"])
        manifest = manifests.get(rid, {})
        kind = manifest.get("kind") or _infer_kind(" ".join(f["name"] for f in gfiles))
        summary = None
        if isinstance(manifest.get("summary"), dict):
            # Pipeline manifest embeds detailed stage summary; expose aggregate counts.
            tmp = os.path.join(day_dir, rid + "-pipeline-summary.json")
            summary = _json_summary(tmp) if os.path.isfile(tmp) else None
        if summary is None:
            preferred = [f for f in gfiles if f["name"].endswith("results.json") or f["name"].endswith("pipeline-summary.json")]
            for f in preferred or gfiles:
                summary = _json_summary(f["path"])
                if summary:
                    break
        if summary is None:
            summary = {"total": 0, "success": 0, "failed": 0}
        latest = max(f["mtime"] for f in gfiles)
        started = manifest.get("started_at") or _dt.datetime.fromtimestamp(latest).astimezone().replace(microsecond=0).isoformat()
        runs.append({
            "run_id": rid,
            "kind": kind,
            "started_at": started,
            "summary": summary,
            "files": [{"name": f["name"], "size": f["size"], "type": "json" if f["name"].lower().endswith(".json") else "file"} for f in gfiles],
            "latest_mtime": latest,
        })
    runs.sort(key=lambda r: r["latest_mtime"], reverse=True)
    return runs


def _tail(path, max_bytes=16000):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes), os.SEEK_SET)
            data = f.read().decode("utf-8", errors="replace")
        if size > max_bytes:
            data = "... (log truncated to last %d bytes) ...\n" % max_bytes + data
        return data
    except FileNotFoundError:
        return ""
    except Exception as e:
        return "<could not read log: %s>" % e


def _public_target(key, target):
    return {
        "key": key,
        "label": target["label"],
        "description": target.get("description", ""),
        "kind": target.get("kind", ""),
        "cis_writes": bool(target.get("cis_writes")),
        "allow_input": bool(target.get("allow_input")),
        "files": list(target.get("files", [])),
    }


def _job_public(job, include_tail=True):
    out = {k: v for k, v in job.items() if k != "log_path"}
    out["log_rel"] = os.path.relpath(job["log_path"], ROOT).replace("\\", "/")
    if include_tail:
        out["log_tail"] = _tail(job["log_path"])
    return out


def _watch_job(job_id, proc, log_fh):
    try:
        rc = proc.wait()
    finally:
        try:
            log_fh.close()
        except Exception:
            pass
    with JOBS_LOCK:
        job = JOBS.get(job_id)
        if job:
            job["returncode"] = rc
            job["status"] = "succeeded" if rc == 0 else "failed"
            job["ended_at"] = _now()
            job["ended_ts"] = time.time()
        JOB_PROCS.pop(job_id, None)


def _start_run(target_key, payload):
    target = RUN_TARGETS.get(target_key)
    if not target:
        raise ValueError("unknown run target: " + target_key)

    with JOBS_LOCK:
        running = [j for j in JOBS.values() if j.get("status") == "running"]
    if running:
        raise RuntimeError("another run is already running; wait for it to finish or stop it")

    cmd = list(target["command"])
    if target.get("allow_input"):
        input_arg = _safe_optional_input((payload or {}).get("input", ""))
        if input_arg:
            cmd.append(input_arg)

    missing = [c for c in cmd if c.endswith(".sh") and not os.path.isfile(os.path.join(ROOT, c))]
    if missing:
        raise RuntimeError("missing run script: " + ", ".join(missing))

    os.makedirs(RUN_LOG_DIR, exist_ok=True)
    job_id = _dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    log_path = os.path.join(RUN_LOG_DIR, f"{job_id}-{target_key}.log")
    log_fh = open(log_path, "w", encoding="utf-8", buffering=1)
    log_fh.write("$ " + " ".join(cmd) + "\n")
    if target.get("env"):
        log_fh.write("env: " + json.dumps(target.get("env"), sort_keys=True) + "\n")
    log_fh.write("cwd: " + ROOT + "\n")
    log_fh.write("started: " + _now() + "\n\n")

    env = os.environ.copy()
    env.setdefault("PYTHONUNBUFFERED", "1")
    for k, v in (target.get("env") or {}).items():
        env[str(k)] = str(v)
    popen_kwargs = {}
    if os.name == "nt":
        popen_kwargs["creationflags"] = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        popen_kwargs["preexec_fn"] = os.setsid

    try:
        proc = subprocess.Popen(
            cmd,
            cwd=ROOT,
            stdout=log_fh,
            stderr=subprocess.STDOUT,
            env=env,
            text=True,
            **popen_kwargs,
        )
    except Exception:
        log_fh.close()
        raise

    job = {
        "id": job_id,
        "target": target_key,
        "label": target["label"],
        "command": cmd,
        "status": "running",
        "pid": proc.pid,
        "returncode": None,
        "started_at": _now(),
        "started_ts": time.time(),
        "ended_at": None,
        "ended_ts": None,
        "log_path": log_path,
    }
    with JOBS_LOCK:
        JOBS[job_id] = job
        JOB_PROCS[job_id] = proc
    t = threading.Thread(target=_watch_job, args=(job_id, proc, log_fh), daemon=True)
    t.start()
    return _job_public(job, include_tail=False)


def _stop_job(job_id):
    with JOBS_LOCK:
        proc = JOB_PROCS.get(job_id)
        job = JOBS.get(job_id)
    if not job:
        raise ValueError("unknown job id")
    if not proc or job.get("status") != "running":
        return job
    try:
        if os.name == "nt":
            proc.terminate()
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except ProcessLookupError:
        pass
    return job


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # quiet

    def _send(self, code, body=b"", ctype="application/json", headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _err(self, code, msg):
        self._send(code, json.dumps({"error": msg}, ensure_ascii=False), "application/json; charset=utf-8")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        path = parsed.path
        if path == "/" or path == "/index.html":
            self._send(200, PAGE, "text/html; charset=utf-8")
            return
        if path == "/api/meta":
            self._json(200, {"data_dir": os.path.abspath(DATA_DIR), "root_dir": os.path.abspath(ROOT), "version": "V3", "badges": BADGES})
            return
        if path == "/api/files":
            files = []
            try:
                for n in sorted(os.listdir(DATA_DIR)):
                    p = os.path.join(DATA_DIR, n)
                    if os.path.isfile(p) and n.lower().endswith(".json"):
                        files.append({"name": n, "size": os.path.getsize(p)})
            except FileNotFoundError:
                pass
            self._json(200, files)
            return
        if path == "/api/file":
            try:
                name = _basename(qs.get("name", [""])[0])
            except ValueError as e:
                return self._err(400, str(e))
            p = os.path.join(DATA_DIR, name)
            if not os.path.isfile(p):
                return self._err(404, "not found: " + name)
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
            self._send(200, txt, "text/plain; charset=utf-8")
            return
        if path == "/api/run-targets":
            self._json(200, {"targets": [_public_target(k, v) for k, v in RUN_TARGETS.items()]})
            return
        if path == "/api/jobs":
            with JOBS_LOCK:
                rows = sorted(JOBS.values(), key=lambda j: j.get("started_ts", 0), reverse=True)
                rows = [_job_public(j, include_tail=True) for j in rows]
            self._json(200, {"jobs": rows})
            return
        if path == "/api/job":
            job_id = qs.get("id", [""])[0]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job:
                return self._err(404, "unknown job id")
            self._json(200, _job_public(job, include_tail=True))
            return
        if path == "/api/run-log":
            job_id = qs.get("id", [""])[0]
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job:
                return self._err(404, "unknown job id")
            self._send(200, _tail(job["log_path"], max_bytes=10_000_000), "text/plain; charset=utf-8")
            return
        if path == "/api/output-dates":
            self._json(200, {"dates": _list_output_dates()})
            return
        if path == "/api/output-runs":
            try:
                date_s = _safe_output_date(qs.get("date", [""])[0])
                self._json(200, {"date": date_s, "runs": _list_output_runs(date_s)})
            except ValueError as e:
                return self._err(400, str(e))
            return
        if path == "/api/output-file":
            try:
                date_s = _safe_output_date(qs.get("date", [""])[0])
                name = _safe_output_name(qs.get("name", [""])[0])
            except ValueError as e:
                return self._err(400, str(e))
            day_dir = os.path.abspath(os.path.join(OUTPUT_ROOT, date_s))
            p = os.path.abspath(os.path.join(day_dir, name))
            if os.path.commonpath([os.path.abspath(OUTPUT_ROOT), p]) != os.path.abspath(OUTPUT_ROOT) or os.path.dirname(p) != day_dir:
                return self._err(400, "invalid output path")
            if not os.path.isfile(p):
                return self._err(404, "not found: " + name)
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
            self._send(200, txt, "text/plain; charset=utf-8")
            return
        self._err(404, "not found")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        text = raw.decode("utf-8", errors="replace")

        if path == "/api/run":
            target = qs.get("target", [""])[0]
            try:
                payload = json.loads(text) if text.strip() else {}
                job = _start_run(target, payload)
            except ValueError as e:
                return self._err(400, str(e))
            except RuntimeError as e:
                return self._err(409, str(e))
            except Exception as e:
                return self._err(500, "could not start run: " + str(e))
            self._json(200, job)
            return

        if path == "/api/stop":
            job_id = qs.get("id", [""])[0]
            try:
                job = _stop_job(job_id)
            except ValueError as e:
                return self._err(404, str(e))
            except Exception as e:
                return self._err(500, "could not stop job: " + str(e))
            self._json(200, _job_public(job, include_tail=True))
            return

        if path not in ("/api/file", "/api/delete"):
            return self._err(404, "not found")

        try:
            name = _basename(qs.get("name", [""])[0])
        except ValueError as e:
            return self._err(400, str(e))

        if path == "/api/file":
            # validate JSON before writing
            try:
                json.loads(text) if text.strip() else None
                if not text.strip():
                    return self._err(400, "refuse empty file")
            except json.JSONDecodeError as e:
                return self._err(400, "invalid JSON: " + str(e))
            p = os.path.join(DATA_DIR, name)
            with open(p, "w", encoding="utf-8") as f:
                f.write(text)
            self._json(200, {"ok": True, "name": name, "size": os.path.getsize(p)})
            return

        if path == "/api/delete":
            p = os.path.join(DATA_DIR, name)
            if not os.path.isfile(p):
                return self._err(404, "not found: " + name)
            os.remove(p)
            self._json(200, {"ok": True, "name": name})
            return

    def do_HEAD(self):
        self.do_GET()


def main():
    global DATA_DIR
    ap = argparse.ArgumentParser(description="uploader Data/ JSON editor + run launcher")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--data", default=DEFAULT_DATA, help="data folder (default: uploader/Data)")
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    DATA_DIR = os.path.abspath(args.data)
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(RUN_LOG_DIR, exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"data_editor: serving {DATA_DIR} at {url}  (Ctrl+C to stop)")
    print("data_editor: run launcher enabled (allow-listed local scripts only)")
    if not args.no_browser:
        try:
            import webbrowser
            webbrowser.open(url)
        except Exception:
            pass
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")


if __name__ == "__main__":
    main()
