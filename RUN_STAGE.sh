#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GENERIC CIS STAGE RUNNER
# ============================================================
# Reads Data/pipeline.json and runs one selected stage using that stage's:
#   input_file, output_file, bridge_script
#
# Usage:
#   bash RUN_STAGE.sh                 # interactive stage selection
#   bash RUN_STAGE.sh --list          # list stages from pipeline.json
#   bash RUN_STAGE.sh allocation      # run one stage
#   bash RUN_STAGE.sh allocation --dry-run
#
# Transforms are intentionally not run here. Full transform chaining remains in
# RUN_PIPELINE.sh. Per-step inputs live in Data/ and are referenced by
# Data/pipeline.json.
# ============================================================

DRY_RUN=false
LIST_ONLY=false
STAGE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=true ;;
    --list|-l) LIST_ONLY=true ;;
    --help|-h)
      sed -n '1,24p' "$0"
      exit 0
      ;;
    *)
      if [[ -z "$STAGE" ]]; then STAGE="$arg";
      else echo "ERROR: unexpected argument: $arg" >&2; exit 1; fi
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/Data/pipeline.json"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need curl
need openssl
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi

if [[ ! -f "$MANIFEST" ]]; then echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; fi

stage_count() {
  "$PYTHON_BIN" - "$MANIFEST" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding='utf-8'))['stages']))
PY
}

list_stages() {
  "$PYTHON_BIN" - "$MANIFEST" <<'PY'
import json, sys
m=json.load(open(sys.argv[1], encoding='utf-8'))
for i,s in enumerate(m.get('stages', []), 1):
    desc=(s.get('description') or '').strip()
    if len(desc) > 76: desc = desc[:73] + '...'
    print(f"{i:2d}) {s.get('name',''):<15} {s.get('input_file',''):<42} {desc}")
PY
}

stage_field() {
  "$PYTHON_BIN" - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
manifest, stage, field = sys.argv[1:4]
m=json.load(open(manifest, encoding='utf-8'))
for s in m.get('stages', []):
    if s.get('name') == stage:
        v=s.get(field, '')
        print('' if v is None else v)
        sys.exit(0)
raise SystemExit('stage not found: ' + stage)
PY
}

stage_name_at() {
  "$PYTHON_BIN" - "$MANIFEST" "$1" <<'PY'
import json, sys
m=json.load(open(sys.argv[1], encoding='utf-8'))
idx=int(sys.argv[2]) - 1
stages=m.get('stages', [])
if idx < 0 or idx >= len(stages):
    raise SystemExit('invalid selection')
print(stages[idx].get('name',''))
PY
}

stage_exists() {
  "$PYTHON_BIN" - "$MANIFEST" "$1" <<'PY' >/dev/null 2>&1
import json, sys
m=json.load(open(sys.argv[1], encoding='utf-8'))
name=sys.argv[2]
raise SystemExit(0 if any(s.get('name') == name for s in m.get('stages', [])) else 1)
PY
}

run_output_path() {
  "$PYTHON_BIN" - "$1" "$STAGE" "$OUTPUT_DAY_DIR" "$RUN_ID" <<'PY'
import os, sys
p, stage, output_day_dir, run_id = sys.argv[1:5]
# Match RUN_PIPELINE.sh: output/... gets a dated run artifact; Data/... remains
# a canonical editable step input/output file. Use POSIX separators because these
# paths are consumed by Git Bash and later joined with SCRIPT_DIR.
if p.startswith('output/'):
    print(f"{output_day_dir}/{run_id}-{os.path.basename(p)}")
else:
    print(p.replace('\\\\', '/'))
PY
}

if $LIST_ONLY; then
  echo "Available stages from Data/pipeline.json:"
  echo ""
  list_stages
  exit 0
fi

if [[ -z "$STAGE" ]]; then
  echo "Available stages from Data/pipeline.json:"
  echo ""
  list_stages
  echo ""
  read -r -p "Select stage number: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then echo "ERROR: enter a stage number" >&2; exit 1; fi
  STAGE="$(stage_name_at "$choice")"
fi

if ! stage_exists "$STAGE"; then
  echo "ERROR: unknown stage: $STAGE" >&2
  echo "Run 'bash RUN_STAGE.sh --list' to see valid stages." >&2
  exit 1
fi

INPUT_FILE="$(stage_field "$STAGE" input_file)"
OUTPUT_TEMPLATE="$(stage_field "$STAGE" output_file)"
BRIDGE="$(stage_field "$STAGE" bridge_script)"
DESCRIPTION="$(stage_field "$STAGE" description)"

if [[ -z "$INPUT_FILE" ]]; then echo "ERROR: stage '$STAGE' has no input_file in Data/pipeline.json" >&2; exit 1; fi
if [[ -z "$OUTPUT_TEMPLATE" ]]; then echo "ERROR: stage '$STAGE' has no output_file in Data/pipeline.json" >&2; exit 1; fi
if [[ -z "$BRIDGE" ]]; then echo "ERROR: stage '$STAGE' has no bridge_script in Data/pipeline.json" >&2; exit 1; fi

# shellcheck source=source/output_paths.sh
source "$SCRIPT_DIR/source/output_paths.sh"
OUTPUT_FILE="$(run_output_path "$OUTPUT_TEMPLATE")"
INPUT_JSON="$SCRIPT_DIR/$INPUT_FILE"
OUTPUT_JSON="$SCRIPT_DIR/$OUTPUT_FILE"
BRIDGE_SCRIPT="$SCRIPT_DIR/$BRIDGE"
NORMALIZED_FROM=""

# Optional convenience for typed case-proceeding inputs. Operators can keep
# separate Data/case-proceeding-next-hearing-input.json and
# Data/case-proceeding-disposal-input.json files, then run:
#   CASE_PROCEEDING_SOURCE_JSON=Data/case-proceeding-disposal-input.json bash RUN_STAGE.sh case_proceeding
if [[ "$STAGE" == "case_proceeding" && -n "${CASE_PROCEEDING_SOURCE_JSON:-}" ]]; then
  SRC="$CASE_PROCEEDING_SOURCE_JSON"
  if [[ ! "$SRC" = /* && ! "$SRC" =~ ^[A-Za-z]: ]]; then SRC="$SCRIPT_DIR/$SRC"; fi
  NORM_TARGET="$INPUT_JSON"
  if $DRY_RUN; then NORM_TARGET="$(mktemp)"; fi
  "$PYTHON_BIN" "$SCRIPT_DIR/source/normalize_case_proceeding_input.py" "$SRC" "$NORM_TARGET" \
    --types "$SCRIPT_DIR/Data/case-proceeding-types.json"
  if $DRY_RUN; then INPUT_JSON="$NORM_TARGET"; fi
  NORMALIZED_FROM="$SRC"
fi

if [[ ! -f "$INPUT_JSON" ]]; then echo "ERROR: Input JSON not found: $INPUT_JSON" >&2; exit 1; fi
if [[ ! -f "$BRIDGE_SCRIPT" ]]; then echo "ERROR: Missing bridge script: $BRIDGE_SCRIPT" >&2; exit 1; fi
mkdir -p "$(dirname "$OUTPUT_JSON")"

# Load CIS connection config from Data/config.json (exports env vars).
# shellcheck source=source/load_config.sh
source "$SCRIPT_DIR/source/load_config.sh" "$SCRIPT_DIR" || { echo "ERROR: load_config failed" >&2; exit 1; }

cat <<EOF
Starting CIS stage: $STAGE
Description: $DESCRIPTION
CIS URL: $CIS_BASE_URL
Court code: $COURT_CODE
Court no: ${COURT_NO:-}
Skip court selection: ${SKIP_COURT_SELECTION:-false}
Input: $INPUT_JSON
${NORMALIZED_FROM:+Normalized from: $NORMALIZED_FROM
}Output: $OUTPUT_JSON
Bridge: $BRIDGE_SCRIPT
Run ID: $RUN_ID
EOF

echo ""

if $DRY_RUN; then
  echo "Dry run only. No CIS calls made."
  exit 0
fi

export CIS_BASE_URL COURT_CODE CIS_USER CIS_PASSWORD UNLOCK_PASSWORD LOGIN_DATE LANG_ID CLOUD_FLAG COURT_NO SKIP_COURT_SELECTION
export INPUT_JSON OUTPUT_JSON
export UPLOADER_APP_DIR="$SCRIPT_DIR"

bash "$BRIDGE_SCRIPT"
write_run_manifest "$STAGE" "$INPUT_FILE" "$OUTPUT_FILE"

echo ""
echo "Done. Stage results:"
echo "$OUTPUT_JSON"
