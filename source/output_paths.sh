#!/usr/bin/env bash
# Shared output-path helper for V3 run scripts.
#
# Creates date-bucketed output paths:
#   output/DDMMYYYY/HHMMSS-rand-name.json
#
# Caller must set SCRIPT_DIR to the uploader/V3 directory before sourcing.
# Optional env overrides:
#   OUTPUT_DATE=29062026
#   RUN_ID=115304-a7f1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  echo "output_paths.sh: SCRIPT_DIR must be set before sourcing" >&2
  return 1 2>/dev/null || exit 1
fi

OUTPUT_DATE="${OUTPUT_DATE:-$(date +%d%m%Y)}"
if [[ -z "${RUN_ID:-}" ]]; then
  _output_rand="$(openssl rand -hex 2 2>/dev/null || printf '%04x' "$$")"
  RUN_ID="$(date +%H%M%S)-${_output_rand}"
  unset _output_rand
fi

OUTPUT_DAY_DIR="output/$OUTPUT_DATE"
OUTPUT_DAY_DIR_ABS="$SCRIPT_DIR/$OUTPUT_DAY_DIR"
mkdir -p "$OUTPUT_DAY_DIR_ABS"

output_file() {
  local name="${1##*/}"
  printf '%s/%s-%s\n' "$OUTPUT_DAY_DIR" "$RUN_ID" "$name"
}

output_file_abs() {
  local rel
  rel="$(output_file "$1")"
  printf '%s/%s\n' "$SCRIPT_DIR" "$rel"
}

output_artifact() {
  # For pipeline/stage-specific artifacts where the filename is already fully
  # constructed and should only get the shared RUN_ID prefix.
  local name="${1##*/}"
  printf '%s/%s-%s\n' "$OUTPUT_DAY_DIR" "$RUN_ID" "$name"
}

output_manifest_rel() {
  printf '%s/%s-run-manifest.json\n' "$OUTPUT_DAY_DIR" "$RUN_ID"
}

output_manifest_abs() {
  printf '%s/%s\n' "$SCRIPT_DIR" "$(output_manifest_rel)"
}

write_run_manifest() {
  local kind="$1"
  local input_rel="$2"
  shift 2
  local manifest py
  manifest="$(output_manifest_abs)"
  mkdir -p "$(dirname "$manifest")"
  py="${PYTHON_BIN:-}"
  if [[ -z "$py" ]]; then
    if command -v python3 >/dev/null 2>&1; then py=python3
    elif command -v python >/dev/null 2>&1; then py=python
    else echo "output_paths.sh: python not found" >&2; return 1; fi
  fi
  "$py" - "$manifest" "$RUN_ID" "$OUTPUT_DATE" "$kind" "$input_rel" "$@" <<'PY'
import datetime as dt, json, os, sys
manifest, run_id, date_s, kind, input_rel, *outputs = sys.argv[1:]
out = {
    'run_id': run_id,
    'date': date_s,
    'started_at': dt.datetime.now().astimezone().replace(microsecond=0).isoformat(),
    'kind': kind,
    'input': input_rel,
    'outputs': [o.replace('\\', '/') for o in outputs],
}
with open(manifest, 'w', encoding='utf-8') as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
PY
}

export OUTPUT_DATE RUN_ID OUTPUT_DAY_DIR OUTPUT_DAY_DIR_ABS
