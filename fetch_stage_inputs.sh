#!/usr/bin/env bash
set -euo pipefail

# Read-only multi-stage prefetch.
#
# Contract:
#   login -> extract read-only CIS data -> transform to uploader JSON -> save -> logout
#
# Usage:
#   bash fetch_stage_inputs.sh [Data/prefetch-input.json] [--stages registration,case_proceeding] [--write-data] [--include-raw]
#
# Simplified input is accepted, e.g.:
#   [{"id":"trial10","cnr":"HRPK...","stages":"proceeding"}]
# or:
#   ["HRPK..."]
#
# Court selection is performed after login and before all prefetch reads unless
# SKIP_COURT_SELECTION=true.
#
# Default outputs:
#   Data/registration-input.prefetched.json
#   Data/case-proceeding-input.prefetched.json
#   output/DDMMYYYY/<RUN_ID>-cis-prefetch-results.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INPUT_JSON="Data/prefetch-input.json"
ARGS=()
WRITE_DATA=false
if [[ "${1:-}" != "" && "${1:-}" != --* ]]; then
  INPUT_JSON="$1"
  shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      sed -n '1,26p' "$0"
      exit 0
      ;;
    --write-data)
      WRITE_DATA=true
      ARGS+=("$1")
      ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need openssl
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi

if [[ ! -f "$INPUT_JSON" ]]; then
  echo "ERROR: input JSON not found: $INPUT_JSON" >&2
  exit 1
fi

# Load CIS connection config from Data/config.json (env overrides still win).
# shellcheck source=source/load_config.sh
source "$SCRIPT_DIR/source/load_config.sh" "$SCRIPT_DIR" || { echo "ERROR: load_config failed" >&2; exit 1; }
# shellcheck source=source/output_paths.sh
source "$SCRIPT_DIR/source/output_paths.sh"

RESULT_REL="$(output_artifact cis-prefetch-results.json)"
RESULT_ABS="$SCRIPT_DIR/$RESULT_REL"
if $WRITE_DATA; then
  REG_OUT_REL="Data/registration-input.json"
  PROC_OUT_REL="Data/case-proceeding-input.json"
  ID_OUT_REL="Data/case-identity-input.json"
else
  REG_OUT_REL="Data/registration-input.prefetched.json"
  PROC_OUT_REL="Data/case-proceeding-input.prefetched.json"
  ID_OUT_REL="Data/case-identity-input.prefetched.json"
fi

export CIS_BASE_URL COURT_CODE CIS_USER CIS_PASSWORD UNLOCK_PASSWORD LOGIN_DATE LANG_ID CLOUD_FLAG COURT_NO SKIP_COURT_SELECTION
export PYTHONPATH="$SCRIPT_DIR/source${PYTHONPATH:+:$PYTHONPATH}"

cat <<EOF
Starting CIS prefetch
CIS URL: $CIS_BASE_URL
Court code: $COURT_CODE
Court no: ${COURT_NO:-}
Skip court selection: ${SKIP_COURT_SELECTION:-false}
Input: $SCRIPT_DIR/$INPUT_JSON
Registration draft: $SCRIPT_DIR/$REG_OUT_REL
Case proceeding draft: $SCRIPT_DIR/$PROC_OUT_REL
Case identity draft: $SCRIPT_DIR/$ID_OUT_REL
Audit output: $RESULT_ABS
Run ID: $RUN_ID
EOF

echo ""
PREFETCH_RESULT_JSON="$RESULT_ABS" "$PYTHON_BIN" "$SCRIPT_DIR/source/prefetch_case_data.py" \
  "$INPUT_JSON" \
  --root "$SCRIPT_DIR" \
  --result-out "$RESULT_ABS" \
  "${ARGS[@]}"

write_run_manifest "prefetch" "$INPUT_JSON" "$RESULT_REL" "$REG_OUT_REL" "$PROC_OUT_REL" "$ID_OUT_REL"

echo ""
echo "Done. Prefetch outputs:"
echo "$SCRIPT_DIR/$REG_OUT_REL"
echo "$SCRIPT_DIR/$PROC_OUT_REL"
echo "$SCRIPT_DIR/$ID_OUT_REL"
echo "$RESULT_ABS"
