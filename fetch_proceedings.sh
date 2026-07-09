#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible single-CNR wrapper around the reusable read-only prefetcher.
#
# Usage:
#   bash fetch_proceedings.sh <CNR> [output.json]
#
# Safe: delegates to source/prefetch_case_data.py with --stages case_proceeding,
# which logs in, calls only case_proceeding x=fetchdata, transforms to our JSON,
# writes the requested output, and logs out.

CNR="${1:-}"
OUTPUT_FILE="${2:-Data/case-proceeding-input.json}"

if [[ -z "$CNR" || "$CNR" == "--help" || "$CNR" == "-h" ]]; then
  cat <<'EOF'
Usage:
  bash fetch_proceedings.sh <CNR> [output.json]

Example:
  bash fetch_proceedings.sh HRPK020007042026

Default write:
  Data/case-proceeding-input.json

This is read-only: it logs into CIS, loads case_proceeding page, calls x=fetchdata,
transforms the response to the editable case_proceeding JSON shape, and logs out.
EOF
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi
command -v openssl >/dev/null 2>&1 || { echo "Missing command: openssl" >&2; exit 1; }

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

INPUT_FILE="$TMPDIR/input.json"
RESULT_FILE="$TMPDIR/prefetch-result.json"
UNUSED_REGISTRATION_OUT="$TMPDIR/registration-unused.json"

"$PYTHON_BIN" - "$CNR" "$INPUT_FILE" <<'PY'
import json, sys
cnr, out = sys.argv[1:3]
json.dump([{
  'external_id': 'PROC-' + cnr,
  'cis_cnr': cnr,
  'target_stages': ['case_proceeding'],
}], open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY

mkdir -p "$(dirname "$OUTPUT_FILE")"
export PYTHONPATH="$SCRIPT_DIR/source${PYTHONPATH:+:$PYTHONPATH}"

"$PYTHON_BIN" "$SCRIPT_DIR/source/prefetch_case_data.py" \
  "$INPUT_FILE" \
  --root "$SCRIPT_DIR" \
  --stages case_proceeding \
  --registration-out "$UNUSED_REGISTRATION_OUT" \
  --case-proceeding-out "$OUTPUT_FILE" \
  --result-out "$RESULT_FILE"

"$PYTHON_BIN" - "$RESULT_FILE" "$OUTPUT_FILE" <<'PY'
import json, sys
result=json.load(open(sys.argv[1], encoding='utf-8'))
out=sys.argv[2]
records=result.get('records') or []
first=records[0] if records else {}
stage=first.get('case_proceeding') or {}
summary={
  'wrote': out,
  'cis_cnr': first.get('cis_cnr'),
  'status': first.get('status'),
  'case_proceeding': stage.get('status'),
}
if stage.get('error'):
    summary['error']=stage['error']
print(json.dumps(summary, ensure_ascii=False))
PY

echo "" >&2
echo "Wrote: $SCRIPT_DIR/$OUTPUT_FILE" >&2
echo "Edit JSON fields: next_hearing_date, business_remarks, purpose_code if needed." >&2
echo "Then run: bash RUN_STAGE.sh case_proceeding" >&2
