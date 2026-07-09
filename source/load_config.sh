#!/usr/bin/env bash
# Loads Data/config.json into environment variables for CIS bridges/verifiers.
# Sourced (not executed):  source source/load_config.sh
# Optional arg: path to the uploader root (defaults to the caller's SCRIPT_DIR/../).
#
# Reads Data/config.json and exports:
#   CIS_BASE_URL, COURT_CODE, CIS_USER, CIS_PASSWORD, UNLOCK_PASSWORD,
#   LOGIN_DATE, LANG_ID, CLOUD_FLAG, COURT_NO, SKIP_COURT_SELECTION
# UNLOCK_PASSWORD defaults to CIS_PASSWORD when empty.
# LOGIN_DATE defaults to today (dd-mm-YYYY) when empty.
#
# Already-set env vars WIN (so ad-hoc overrides are respected).

load_config() {
  local root="${1:-}"
  if [[ -z "$root" ]]; then
    # default: two levels up from this file's dir (source/ -> uploader root)
    local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    root="$(cd "$d/.." && pwd)"
  fi
  local cfg="$root/Data/config.json"
  if [[ ! -f "$cfg" ]]; then
    echo "load_config: missing $cfg" >&2
    return 1
  fi

  # Need python to read JSON.
  local py="${PYTHON_BIN:-}"
  if [[ -z "$py" ]]; then
    if command -v python3 >/dev/null 2>&1; then py=python3
    elif command -v python >/dev/null 2>&1; then py=python
    else echo "load_config: python not found" >&2; return 1; fi
  fi

  # Read each key; only export if not already set in the environment.
  _cfg_get() {
    "$py" - "$cfg" "$1" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
v=d.get(sys.argv[2],'')
print('' if v is None else v)
PY
  }

  [[ -z "${CIS_BASE_URL:-}" ]] && CIS_BASE_URL="$(_cfg_get CIS_BASE_URL)"
  [[ -z "${COURT_CODE:-}"    ]] && COURT_CODE="$(_cfg_get COURT_CODE)"
  [[ -z "${CIS_USER:-}"     ]] && CIS_USER="$(_cfg_get CIS_USER)"
  [[ -z "${CIS_PASSWORD:-}" ]] && CIS_PASSWORD="$(_cfg_get CIS_PASSWORD)"
  [[ -z "${UNLOCK_PASSWORD:-}" ]] && UNLOCK_PASSWORD="$(_cfg_get UNLOCK_PASSWORD)"
  [[ -z "${LOGIN_DATE:-}"   ]] && LOGIN_DATE="$(_cfg_get LOGIN_DATE)"
  [[ -z "${LANG_ID:-}"     ]] && LANG_ID="$(_cfg_get LANG_ID)"
  [[ -z "${CLOUD_FLAG:-}"  ]] && CLOUD_FLAG="$(_cfg_get CLOUD_FLAG)"
  [[ -z "${COURT_NO:-}"  ]] && COURT_NO="$(_cfg_get COURT_NO)"
  [[ -z "${SKIP_COURT_SELECTION:-}"  ]] && SKIP_COURT_SELECTION="$(_cfg_get SKIP_COURT_SELECTION)"

  # Defaults for empties
  [[ -z "$UNLOCK_PASSWORD" ]] && UNLOCK_PASSWORD="$CIS_PASSWORD"
  [[ -z "$LOGIN_DATE" ]] && LOGIN_DATE="$(date +%d-%m-%Y)"
  [[ -z "$LANG_ID" ]] && LANG_ID="0"
  [[ -z "$CLOUD_FLAG" ]] && CLOUD_FLAG="N"
  [[ -z "${SKIP_COURT_SELECTION:-}" ]] && SKIP_COURT_SELECTION="false"

  export CIS_BASE_URL COURT_CODE CIS_USER CIS_PASSWORD UNLOCK_PASSWORD LOGIN_DATE LANG_ID CLOUD_FLAG COURT_NO SKIP_COURT_SELECTION
}

# If executed directly, load and print for debugging.
# If sourced, load immediately so env vars are set for the caller.
if [[ "${BASH_SOURCE[0]}" == "${0:-}" ]]; then
  load_config "$@" && {
    echo "CIS_BASE_URL=$CIS_BASE_URL"
    echo "COURT_CODE=$COURT_CODE"
    echo "CIS_USER=$CIS_USER"
    echo "CIS_PASSWORD=***"
    echo "UNLOCK_PASSWORD=***"
    echo "LOGIN_DATE=$LOGIN_DATE"
    echo "LANG_ID=$LANG_ID"
    echo "CLOUD_FLAG=$CLOUD_FLAG"
    echo "COURT_NO=$COURT_NO"
    echo "SKIP_COURT_SELECTION=$SKIP_COURT_SELECTION"
  }
else
  load_config "$@"
fi