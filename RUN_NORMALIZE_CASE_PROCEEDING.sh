#!/usr/bin/env bash
set -euo pipefail

# Normalize a typed case-proceeding input into Data/case-proceeding-input.json.
# Usage:
#   bash RUN_NORMALIZE_CASE_PROCEEDING.sh next_hearing
#   bash RUN_NORMALIZE_CASE_PROCEEDING.sh disposal
#   bash RUN_NORMALIZE_CASE_PROCEEDING.sh Data/my-typed-case-proceeding.json [Data/case-proceeding-input.json]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND="${1:-}"
OUT_REL="${2:-Data/case-proceeding-input.json}"

if [[ -z "$KIND" || "$KIND" == "--help" || "$KIND" == "-h" ]]; then
  sed -n '1,12p' "$0"
  exit 0
fi

case "$KIND" in
  next|next-hearing|next_hearing)
    IN_REL="Data/case-proceeding-next-hearing-input.json"
    ;;
  dispose|disposed|disposal)
    IN_REL="Data/case-proceeding-disposal-input.json"
    ;;
  *)
    IN_REL="$KIND"
    ;;
esac

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi

if [[ "$IN_REL" = /* || "$IN_REL" =~ ^[A-Za-z]: ]]; then IN_PATH="$IN_REL"; else IN_PATH="$SCRIPT_DIR/$IN_REL"; fi
if [[ "$OUT_REL" = /* || "$OUT_REL" =~ ^[A-Za-z]: ]]; then OUT_PATH="$OUT_REL"; else OUT_PATH="$SCRIPT_DIR/$OUT_REL"; fi

"$PYTHON_BIN" "$SCRIPT_DIR/source/normalize_case_proceeding_input.py" "$IN_PATH" "$OUT_PATH" \
  --types "$SCRIPT_DIR/Data/case-proceeding-types.json"
