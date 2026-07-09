# Data/ JSON editor

A lightweight, browser-based viewer/editor for the `Data/` folder — view, edit, create,
and delete the JSON files the pipeline consumes (inputs, samples, the manifest, and
`config.json`). It can also trigger the allow-listed local run scripts from the same page.
Stdlib Python only (no Flask/npm/build step).

```text
uploader/V3/RUN_DATA_EDITOR.sh        # launcher
uploader/V3/tools/data_editor.py      # the tool (backend + embedded HTML)
```

## Run

```bash
cd uploader/V3
bash RUN_DATA_EDITOR.sh            # opens http://127.0.0.1:8765 in your browser
# options:
bash RUN_DATA_EDITOR.sh --port 9000 --no-browser
```

Binds **`127.0.0.1`** only (court-side, no external exposure). Ctrl+C to stop. Python is
the only requirement (already a hard dependency of the bridges).

## What it edits

Only files in `Data/*.json`. `config.json` (CIS connection) and `pipeline.json` (stage
manifest) are **badged** in the UI so they're not mistaken for throwaway inputs. The tool
cannot reach `source/` or `output/` — `name` is basename-sanitized and path traversal is
rejected.

## Features

- **File list** with sizes + a **filter** box.
- **Collapsible sections**, one per file, with the **filename as the header**.
- **Editable textarea** per file; **Save / Revert / Format / Delete** buttons.
- **JSON validation on save** — parses before writing; refuses to save invalid JSON and
  shows the error. **Format** pretty-prints (does not auto-mutate on load).
- **New file** button — prompts for a `.json` name (only `A-Za-z0-9._-`), creates an
  empty `[]` file and expands it ready to edit.
- **Delete** with a per-file confirm.
- Auto-refreshes the list on save/delete (catches renames/new files).
- **Runs panel** with buttons for:
  - pipeline validation (`bash RUN_PIPELINE.sh --validate`)
  - full pipeline (`bash RUN_PIPELINE.sh`)
  - individual stages via `bash RUN_STAGE.sh <stage>`; stage input/output/bridge paths
    come from `Data/pipeline.json`, including process/order stages:
    `bulk_order_upload`, `process_prefetch`, `process_generation`,
    `publish_process`, and the forced delete-draft variant.
- **Outputs panel** groups read-only result files by `output/DDMMYYYY/`, with latest run
  expanded by default and controls to expand/collapse previous runs.
- Run output is streamed to log files under `output/editor-runs/` and shown as a tail in
  the browser. Only one run can execute at a time; a running job can be stopped.
- Process flow buttons:
  1. **Prefetch + save process-generation input** reads `Data/process-prefetch-input.json`
     and saves editable recipients/addresses to `Data/process-generation-input.json`.
  2. **Run process generation** reads `Data/process-generation-input.json`, generates
     process drafts, and writes results/draft PDFs under `output/DDMMYYYY/`.
  3. **Publish process** reads `Data/publish-process-input.json` and publishes generated
     notices/processes.
  4. **Delete generated process draft** uses the same input but forces
     `action=delete_draft`, posting the HAR-backed `x=deletenotice` call.

## CIS connection config

`Data/config.json` is the single source of truth for the pipeline's CIS connection
and active proceedings court (`CIS_BASE_URL`, `COURT_CODE`, `CIS_USER`,
`CIS_PASSWORD`, `UNLOCK_PASSWORD`, `LOGIN_DATE`, `LANG_ID`, `CLOUD_FLAG`,
`COURT_NO`, `SKIP_COURT_SELECTION`). Edit it here in the editor — the run scripts
load it via `source/load_config.sh` (no per-script hardcoded values anymore). Empty
`UNLOCK_PASSWORD` defaults to `CIS_PASSWORD`; empty `LOGIN_DATE` defaults to today.
Each CIS stage selects `COURT_NO` in its own login/session unless
`SKIP_COURT_SELECTION=true`.

## Notes

- `output/` is **not** editable here — it's runtime-generated and not versioned.
  The editor can view output JSON files read-only; it cannot edit `output/`.
- Run buttons are intentionally allow-listed server-side. The browser cannot submit an
  arbitrary shell command.
- The server is a single Python file with no dependencies; safe to run on the court server.