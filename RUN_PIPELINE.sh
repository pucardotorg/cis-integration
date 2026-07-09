#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CIS PIPELINE ORCHESTRATOR
# ============================================================
# Runs an ordered list of CIS "use cases" (stages) defined in pipeline.json.
# Each stage: optional transform (from a prior stage output) -> optional
# preflight (read-only gate) -> bridge script -> optional postcheck ->
# collect summary. Prints + writes a summary at the end.
#
# Stages today: filing -> allocation. To add a future use case
# (registration, notice, proceedings...), append a stage to pipeline.json.
# ============================================================

# ---- Config: all CIS connection values live in Data/config.json ----
# Edit them there (or via the Data/ editor: bash RUN_DATA_EDITOR.sh).
# Per-run overrides are still honored by setting these env vars before running.
ABORT_ON_PREFLIGHT_ERROR="${ABORT_ON_PREFLIGHT_ERROR:-yes}"
PIPELINE_MANIFEST="Data/pipeline.json"
# ---------------------------------------------------------------------

# Usage: bash RUN_PIPELINE.sh           # run the pipeline
#        bash RUN_PIPELINE.sh --validate  # check each stage's input JSON is present (no CIS)
VALIDATE_ONLY=false
if [[ "${1:-}" == "--validate" || "${1:-}" == "-v" ]]; then VALIDATE_ONLY=true; shift; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/$PIPELINE_MANIFEST"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need curl; need openssl
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3;
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python;
  else echo "Missing python3/python" >&2; exit 1; fi
fi

if [[ ! -f "$MANIFEST" ]]; then echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; fi

# Load CIS connection config from Data/config.json (exports the env vars).
# shellcheck source=source/load_config.sh
source "$SCRIPT_DIR/source/load_config.sh" "$SCRIPT_DIR" || { echo "ERROR: load_config failed" >&2; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Per-run output bucket: output/DDMMYYYY/. Every artifact this run produces gets
# the same RUN_ID prefix so related files stay grouped without nested run dirs.
# shellcheck source=source/output_paths.sh
source "$SCRIPT_DIR/source/output_paths.sh"
RUN_DIR="$OUTPUT_DAY_DIR"
RUN_DIR_ABS="$OUTPUT_DAY_DIR_ABS"
SUMMARY_REL="$(output_artifact pipeline-summary.json)"
SUMMARY_JSON="$SCRIPT_DIR/$SUMMARY_REL"
RUN_MANIFEST_REL="$(output_manifest_rel)"
RUN_MANIFEST_JSON="$SCRIPT_DIR/$RUN_MANIFEST_REL"

# Resolve a stage's output file path by name (absolute), relative to the uploader root.
# Manifest output_file fields like "output/cis-results.json" are rewritten to
# "output/DDMMYYYY/<RUN_ID>-<stage>-cis-results.json" so each run is isolated.
output_of() {
  "$PYTHON_BIN" - "$MANIFEST" "$RUN_DIR" "$RUN_ID" "$1" <<'PY'
import json, sys, os
m=json.load(open(sys.argv[1], encoding='utf-8'))
run_dir=sys.argv[2]; run_id=sys.argv[3]; name=sys.argv[4]
for s in m['stages']:
    if s['name']==name:
        p=s['output_file']
        base=os.path.basename(p)
        if p.startswith('output/'):
            print(os.path.join(run_dir, f'{run_id}-{name}-{base}'))
        else:
            print(p)
        sys.exit()
sys.exit('stage not found: '+name)
PY
}

# Rewrite a manifest path field (input_file/output_file) for the current run.
# output/... paths become output/DDMMYYYY/<RUN_ID>-<stage>-<basename>; non-output
# paths are left as-is (rooted at SCRIPT_DIR by callers).
run_path() {
  "$PYTHON_BIN" - "$1" "$RUN_DIR" "$RUN_ID" "$2" <<'PY'
import sys, os
p=sys.argv[1]; run_dir=sys.argv[2]; run_id=sys.argv[3]; stage=sys.argv[4]
if p.startswith('output/'):
    print(os.path.join(run_dir, f'{run_id}-{stage}-{os.path.basename(p)}'))
else:
    print(p)
PY
}

# Count results in an output JSON array file.
count_results() {
  local f="$1"
  [[ -f "$f" ]] || { echo '{"total":0,"success":0,"failed":0}'; return; }
  "$PYTHON_BIN" - "$f" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print('{"total":0,"success":0,"failed":0}'); sys.exit()
if not isinstance(d, list):
    print('{"total":0,"success":0,"failed":0}'); sys.exit()
ok=sum(1 for r in d if r.get('status')=='success')
print(json.dumps({'total':len(d),'success':ok,'failed':len(d)-ok}))
PY
}

stage_count() {
  "$PYTHON_BIN" - "$MANIFEST" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding='utf-8'))['stages']))
PY
}

stage_field() {
  "$PYTHON_BIN" - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
st=d['stages'][int(sys.argv[2])]
v=st.get(sys.argv[3], '')
print('' if v is None else v)
PY
}

json_get() {
  "$PYTHON_BIN" - "$1" "$2" "${3:-0}" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1], encoding='utf-8'))
    print(d.get(sys.argv[2], sys.argv[3]))
except Exception:
    print(sys.argv[3])
PY
}

STAGE_COUNT="$(stage_count)"

# ---- Validate-only mode: check each stage's input JSON is present & well-formed. ----
if $VALIDATE_ONLY; then
  echo "Validating pipeline inputs (no CIS calls)..."
  echo ""
  ALL_OK=true
  for idx in $(seq 0 $((STAGE_COUNT-1))); do
    STAGE="$(stage_field "$idx" name)"
    RUN="$(stage_field "$idx" run)"
    INPUT_FILE="$(stage_field "$idx" input_file)"
    TRANSFORM_FROM="$(stage_field "$idx" transform_from)"
    if [[ "$RUN" != "True" ]]; then
      printf "  %-14s SKIPPED (run=false)\n" "$STAGE"; continue; fi
    if [[ -n "$TRANSFORM_FROM" ]]; then
      printf "  %-14s PEND  input '%s' generated at runtime from '%s'\n" "$STAGE" "$INPUT_FILE" "$TRANSFORM_FROM"; continue; fi
    INPUT_PATH="$SCRIPT_DIR/$INPUT_FILE"
    if [[ -f "$INPUT_PATH" ]]; then
      N=$("$PYTHON_BIN" -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(len(d) if isinstance(d,list) else 'NOT-ARRAY')" "$INPUT_PATH" 2>/dev/null || echo invalid)
      printf "  %-14s OK   input '%s' present (%s records)\n" "$STAGE" "$INPUT_FILE" "$N"
    else
      printf "  %-14s MISS  input '%s' NOT FOUND\n" "$STAGE" "$INPUT_FILE"; ALL_OK=false; fi
  done
  echo ""
  if $ALL_OK; then echo "Validation: all stage inputs present. Ready to run."; exit 0;
  else echo "Validation: one or more stage inputs missing. Provide them before running." >&2; exit 1; fi
fi

echo "Pipeline: $STAGE_COUNT stage(s)."
echo ""

# summary accumulator (jsonl of per-stage summaries)
: > "$TMPDIR/summary.jsonl"

for idx in $(seq 0 $((STAGE_COUNT-1))); do
  STAGE="$(stage_field "$idx" name)"
  RUN="$(stage_field "$idx" run)"
  if [[ "$RUN" != "True" ]]; then
    echo "==> Stage [$idx] '$STAGE': skipped (run=false)"; echo ""
    echo "{\"stage\":\"$STAGE\",\"skipped\":true}" >> "$TMPDIR/summary.jsonl"
    continue; fi

  INPUT_FILE="$(stage_field "$idx" input_file)"
  OUTPUT_FILE="$(stage_field "$idx" output_file)"
  BRIDGE="$(stage_field "$idx" bridge_script)"
  PREFLIGHT="$(stage_field "$idx" preflight_script)"
  POSTCHECK="$(stage_field "$idx" postcheck_script)"
  TRANSFORM_FROM="$(stage_field "$idx" transform_from)"
  TRANSFORM_SCRIPT="$(stage_field "$idx" transform_script)"

  echo "==> Stage [$idx] '$STAGE'"
  # rewrite output/ paths into the date bucket with this run's prefix; keep Data/ etc. as-is
  INPUT_REL=$(run_path "$INPUT_FILE" "$STAGE")
  OUTPUT_REL=$(run_path "$OUTPUT_FILE" "$STAGE")
  INPUT_PATH="$SCRIPT_DIR/$INPUT_REL"
  OUTPUT_PATH="$SCRIPT_DIR/$OUTPUT_REL"
  mkdir -p "$(dirname "$OUTPUT_PATH")" "$(dirname "$INPUT_PATH")"

  # 1. Transform (build this stage input from a prior stage output)
  if [[ -n "$TRANSFORM_FROM" && -n "$TRANSFORM_SCRIPT" ]]; then
    SRC_OUT="$(output_of "$TRANSFORM_FROM")"
    if [[ ! -f "$SRC_OUT" ]]; then
      echo "   ERROR: transform_from '$TRANSFORM_FROM' output not found ($SRC_OUT). Did that stage run?" >&2
      echo "{\"stage\":\"$STAGE\",\"status\":\"blocked\",\"reason\":\"missing upstream output $TRANSFORM_FROM\"}" >> "$TMPDIR/summary.jsonl"
      echo ""; continue; fi
    echo "   transform: $TRANSFORM_SCRIPT  ($SRC_OUT -> $INPUT_PATH)"
    "$PYTHON_BIN" "$SCRIPT_DIR/$TRANSFORM_SCRIPT" "$SRC_OUT" "$INPUT_PATH" "$TMPDIR/transform_$STAGE.json" || {
      echo "   ERROR: transform failed" >&2
      echo "{\"stage\":\"$STAGE\",\"status\":\"transform_failed\"}" >> "$TMPDIR/summary.jsonl"; echo ""; continue; }
  fi

  if [[ ! -f "$INPUT_PATH" ]]; then
    echo "   ERROR: input not found: $INPUT_PATH" >&2
    echo "{\"stage\":\"$STAGE\",\"status\":\"blocked\",\"reason\":\"missing input\"}" >> "$TMPDIR/summary.jsonl"; echo ""; continue; fi

  IN_COUNT=$("$PYTHON_BIN" -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(len(d) if isinstance(d,list) else 0)" "$INPUT_PATH")
  echo "   input: $INPUT_PATH ($IN_COUNT record(s))"

  # 2. Preflight (read-only gate)
  PREFLIGHT_REPORT="$RUN_DIR_ABS/${RUN_ID}-${STAGE}-preflight-report.json"
  if [[ -n "$PREFLIGHT" ]]; then
    echo "   preflight: $PREFLIGHT --preflight"
    if UPLOADER_APP_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/$PREFLIGHT" --preflight "$INPUT_PATH" "$PREFLIGHT_REPORT" >&2; then
      : ; fi
    PF_ERR="$(json_get "$PREFLIGHT_REPORT" error 0)"
    echo "   preflight: ok=$(json_get "$PREFLIGHT_REPORT" ok 0) error=$PF_ERR"
    if [[ "$ABORT_ON_PREFLIGHT_ERROR" == "yes" && "$PF_ERR" != "0" ]]; then
      echo "   ABORT: $PF_ERR preflight error(s) for stage '$STAGE'. Fix input and re-run." >&2
      echo "{\"stage\":\"$STAGE\",\"status\":\"preflight_aborted\",\"preflight_error\":$PF_ERR}" >> "$TMPDIR/summary.jsonl"; echo ""; continue; fi
  fi

  # 3. Bridge
  if [[ -n "$BRIDGE" ]]; then
    echo "   bridge: $BRIDGE"
    INPUT_JSON="$INPUT_PATH" OUTPUT_JSON="$OUTPUT_PATH" UPLOADER_APP_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/$BRIDGE" >&2 || {
      echo "   ERROR: bridge failed for stage '$STAGE'" >&2
      echo "{\"stage\":\"$STAGE\",\"status\":\"bridge_failed\"}" >> "$TMPDIR/summary.jsonl"; echo ""; continue; }
  fi

  OUT_CNT=$(count_results "$OUTPUT_PATH")
  echo "   output: $OUTPUT_PATH ($OUT_CNT)"

  # 4. Postcheck
  POSTCHECK_REPORT="$RUN_DIR_ABS/${RUN_ID}-${STAGE}-postcheck-report.json"
  if [[ -n "$POSTCHECK" ]]; then
    echo "   postcheck: $POSTCHECK --postcheck"
    UPLOADER_APP_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/$POSTCHECK" --postcheck "$OUTPUT_PATH" "$POSTCHECK_REPORT" >&2 || true
    echo "   postcheck: ok=$(json_get "$POSTCHECK_REPORT" ok 0) mismatch=$(json_get "$POSTCHECK_REPORT" mismatch 0)"
  fi

  echo ""

  "$PYTHON_BIN" - "$STAGE" "$INPUT_PATH" "$OUTPUT_PATH" "$PREFLIGHT_REPORT" "$POSTCHECK_REPORT" "$TMPDIR/summary.jsonl" <<'PY'
import json, sys, os
stage, inp, outp, pf, pc, sfile = sys.argv[1:7]
def load(p):
    try: return json.load(open(p, encoding='utf-8'))
    except: return {}
def cnt(p):
    try:
        d=json.load(open(p, encoding='utf-8'))
        if isinstance(d,list): return {'total':len(d),'success':sum(1 for r in d if r.get('status')=='success'),'failed':sum(1 for r in d if r.get('status')!='success')}
    except: pass
    return {'total':0,'success':0,'failed':0}
s={'stage':stage,'input':cnt(inp),'output':cnt(outp),'preflight':load(pf),'postcheck':load(pc)}
with open(sfile,'a',encoding='utf-8') as f: f.write(json.dumps(s,ensure_ascii=False)+'\n')
PY
done

# Final summary + run manifest
"$PYTHON_BIN" - "$TMPDIR/summary.jsonl" "$SUMMARY_JSON" "$RUN_MANIFEST_JSON" "$RUN_ID" "$OUTPUT_DATE" "$SUMMARY_REL" <<'PY'
import datetime as dt, glob, json, os, sys
summary_lines, summary_json, manifest_json, run_id, date_s, summary_rel = sys.argv[1:7]
rows=[json.loads(l) for l in open(summary_lines, encoding='utf-8') if l.strip()]
out={'run_id': run_id, 'date': date_s, 'stages':rows}
json.dump(out, open(summary_json,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
print(json.dumps(out, ensure_ascii=False, indent=2))
run_dir=os.path.dirname(summary_json)
outputs=[]
for p in sorted(glob.glob(os.path.join(run_dir, run_id + '-*'))):
    if os.path.abspath(p) == os.path.abspath(manifest_json):
        continue
    outputs.append(os.path.relpath(p, os.path.dirname(os.path.dirname(run_dir))).replace('\\','/'))
if summary_rel.replace('\\','/') not in outputs:
    outputs.append(summary_rel.replace('\\','/'))
manifest={
  'run_id': run_id,
  'date': date_s,
  'started_at': dt.datetime.now().astimezone().replace(microsecond=0).isoformat(),
  'kind': 'pipeline',
  'input': 'Data/pipeline.json',
  'outputs': outputs,
  'summary': out,
}
json.dump(manifest, open(manifest_json,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY

echo ""
echo "============================================================"
echo "PIPELINE SUMMARY"
echo "============================================================"
"$PYTHON_BIN" - "$TMPDIR/summary.jsonl" <<'PY'
import json, sys
for l in open(sys.argv[1], encoding='utf-8'):
    if not l.strip(): continue
    r=json.loads(l)
    if r.get('skipped'):
        print(f"  {r['stage']:14s} SKIPPED"); continue
    if r.get('status'):
        print(f"  {r['stage']:14s} {r['status'].upper()}"); continue
    i=r.get('input',{}); o=r.get('output',{}); pf=r.get('preflight',{}); pc=r.get('postcheck',{})
    print(f"  {r['stage']:14s} in={i.get('total',0)} out_ok={o.get('success',0)}/{o.get('total',0)} fail={o.get('failed',0)} | preflight ok={pf.get('ok',0)}/err={pf.get('error',0)} | postcheck ok={pc.get('ok',0)}/mismatch={pc.get('mismatch',0)}")
PY
echo ""
echo "Summary JSON: $SUMMARY_JSON"
echo "Run manifest: $RUN_MANIFEST_JSON"
echo "Run folder:   $RUN_DIR_ABS"
