#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CIS Advocate Lookup
# ============================================================
# Calls Filing -> autocomplete_adv.php using a valid CIS session and CSRF token.
#
# Usage:
#   bash RUN_ADVOCATE_LOOKUP.sh 100
#   bash RUN_ADVOCATE_LOOKUP.sh --term P/1284/2014
#   bash RUN_ADVOCATE_LOOKUP.sh --raw 100
#   bash RUN_ADVOCATE_LOOKUP.sh                 # reads Data/advocate-lookup-input.json
#
# Optional existing-session mode, useful when reproducing a browser curl:
#   bash RUN_ADVOCATE_LOOKUP.sh --cookie 'PHPSESSID=...' --csrf 'sid:...,....' 100
#
# Default mode logs into CIS using Data/config.json, fetches civil_filingnew.php
# to extract __csrf_magic, then posts term=<term> to autocomplete_adv.php.
# Prints the CIS response to stdout. Does not create output artifacts.
# ============================================================

RAW=false
LOGOUT=true
TERM=""
COOKIE_HEADER="${CIS_COOKIE:-}"
CSRF_MAGIC="${CSRF_MAGIC:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --term)
      TERM="${2:-}"; shift 2 ;;
    --cookie|--cookie-header)
      COOKIE_HEADER="${2:-}"; shift 2 ;;
    --csrf|--csrf-magic)
      CSRF_MAGIC="${2:-}"; shift 2 ;;
    --raw)
      RAW=true; shift ;;
    --no-logout)
      LOGOUT=false; shift ;;
    --help|-h)
      sed -n '1,28p' "$0"
      exit 0 ;;
    --*)
      echo "ERROR: unknown option: $1" >&2
      exit 1 ;;
    *)
      if [[ -z "$TERM" ]]; then TERM="$1"; else echo "ERROR: unexpected argument: $1" >&2; exit 1; fi
      shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi
export PYTHON_BIN

if [[ -z "$TERM" && -f "$SCRIPT_DIR/Data/advocate-lookup-input.json" ]]; then
  TERM="$($PYTHON_BIN - "$SCRIPT_DIR/Data/advocate-lookup-input.json" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception as e:
    raise SystemExit(f'Could not read advocate lookup input JSON: {e}')
for key in ('term', 'barNumber', 'bar_number', 'query'):
    v=d.get(key)
    if v is not None and str(v).strip():
        print(str(v).strip())
        break
PY
)"
fi

if [[ -z "$TERM" ]]; then
  echo "ERROR: missing search term/bar registration number" >&2
  echo "Usage: bash RUN_ADVOCATE_LOOKUP.sh 100" >&2
  echo "   or add {\"term\": \"100\"} to Data/advocate-lookup-input.json" >&2
  exit 1
fi

# Load CIS_BASE_URL / COURT_CODE / CIS_USER / CIS_PASSWORD, with env overrides.
# shellcheck source=source/load_config.sh
source "$SCRIPT_DIR/source/load_config.sh" "$SCRIPT_DIR"

missing=()
for name in CIS_BASE_URL COURT_CODE CIS_USER CIS_PASSWORD; do
  if [[ -z "${!name:-}" ]]; then missing+=("$name"); fi
done
if (( ${#missing[@]} > 0 )); then
  echo "ERROR: missing required config value(s): ${missing[*]}" >&2
  echo "Edit Data/config.json directly or run ./open-editor.sh from the portable package." >&2
  exit 1
fi

BASE="${CIS_BASE_URL%/}"
ORIGIN="$($PYTHON_BIN - "$BASE" <<'PY'
from urllib.parse import urlparse
import sys
u=urlparse(sys.argv[1])
print(f'{u.scheme}://{u.netloc}')
PY
)"
REFERER="$BASE/filing/civil_filingnew.php?linkid=63&mode=0"

TMPDIR="$(mktemp -d)"
COOKIE="$TMPDIR/cookies.txt"
trap 'rm -rf "$TMPDIR"' EXIT

curl_cis() {
  local timeout_args=(--connect-timeout "${CIS_CONNECT_TIMEOUT:-10}" --max-time "${CIS_MAX_TIME:-60}")
  if [[ -n "$COOKIE_HEADER" ]]; then
    curl -sS --compressed -k "${timeout_args[@]}" -b "$COOKIE_HEADER" -c "$COOKIE" "$@"
  else
    curl -sS --compressed -k "${timeout_args[@]}" -b "$COOKIE" -c "$COOKIE" "$@"
  fi
}

echo "Advocate lookup: term=$TERM" >&2

echo "Advocate lookup: CIS URL=$BASE" >&2
if [[ -z "$COOKIE_HEADER" ]]; then
  echo "Advocate lookup: logging in..." >&2
  # shellcheck source=source/cis_bridge_common.sh
  source "$SCRIPT_DIR/source/cis_bridge_common.sh"
  login_cis
  echo "Advocate lookup: login OK" >&2
  if $LOGOUT; then
    trap 'logout_cis || true; rm -rf "$TMPDIR"' EXIT
  fi
else
  echo "Advocate lookup: using supplied cookie header" >&2
  printf '%s\n' "$COOKIE_HEADER" > "$TMPDIR/cookie-header.txt"
fi

if [[ -z "$CSRF_MAGIC" ]]; then
  echo "Advocate lookup: fetching filing form / CSRF token..." >&2
  FORM_HTML="$TMPDIR/civil_filingnew.html"
  curl_cis "$REFERER" > "$FORM_HTML"
  CSRF_MAGIC="$($PYTHON_BIN - "$FORM_HTML" <<'PY'
from html.parser import HTMLParser
import re, sys
html=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
class P(HTMLParser):
    def __init__(self): super().__init__(); self.val=''
    def handle_starttag(self, tag, attrs):
        if tag != 'input': return
        d=dict(attrs)
        if d.get('name') == '__csrf_magic': self.val = d.get('value','')
p=P(); p.feed(html)
if p.val:
    print(p.val); raise SystemExit(0)
patterns = [
    r'name=["\']__csrf_magic["\'][^>]*value=["\']([^"\']+)',
    r'value=["\']([^"\']+)["\'][^>]*name=["\']__csrf_magic["\']',
]
for pat in patterns:
    m=re.search(pat, html, re.I|re.S)
    if m:
        print(m.group(1)); raise SystemExit(0)
raise SystemExit('Could not find __csrf_magic in filing form. Is the CIS session logged in?')
PY
)"
fi

RAW_OUT="$TMPDIR/advocate-lookup-response.txt"

echo "Advocate lookup: querying autocomplete_adv.php..." >&2
curl_cis -X POST "$BASE/filing/autocomplete_adv.php" \
  -H 'Accept: application/json, text/javascript, */*; q=0.01' \
  -H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
  -H "Origin: $ORIGIN" \
  -H "Referer: $REFERER" \
  -H 'X-Requested-With: XMLHttpRequest' \
  --data-urlencode "__csrf_magic=$CSRF_MAGIC" \
  --data-urlencode "term=$TERM" \
  > "$RAW_OUT"

if $RAW; then
  cat "$RAW_OUT"
else
  "$PYTHON_BIN" - "$RAW_OUT" <<'PY'
import json, sys
path = sys.argv[1]
s=open(path, encoding='utf-8', errors='replace').read().strip()
if not s:
    print('(empty response)')
    raise SystemExit(0)
try:
    print(json.dumps(json.loads(s), ensure_ascii=False, indent=2))
except Exception:
    print(s)
PY
fi
