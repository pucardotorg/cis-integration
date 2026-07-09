#!/usr/bin/env bash
set -euo pipefail

# Select-court CIS bridge.
#
# Purpose:
#   Set the active proceeding court/session by replaying the UI flow captured in HAR:
#     GET  proceedings/select_court.php?linkid=182&difflinkid=182&mode=0
#     POST proceedings/select_courtajax.php x=fetch_bench&radio_flag=active
#     POST proceedings/select_courtajax.php formaction=1&count1=&checkorder=&fno_judges=&fcourt_no=<court>
#     POST proceedings/select_courtajax.php x=fetch_bench&radio_flag=active  (verify)
#
# Input record:
#   { "external_id": "court-41", "court_no": "41", "radio_flag": "active" }
#
# File mode: INPUT_JSON + OUTPUT_JSON. API mode: MODERN_PULL_URL + MODERN_CALLBACK_URL.

CIS_BASE_URL="${CIS_BASE_URL:-http://127.0.0.1/swecourtis}"
COURT_CODE="${COURT_CODE:-HRPK02}"
CIS_USER="${CIS_USER:-supuser}"
CIS_PASSWORD="${CIS_PASSWORD:-ecourt123}"
UNLOCK_PASSWORD="${UNLOCK_PASSWORD:-$CIS_PASSWORD}"
LOGIN_DATE="${LOGIN_DATE:-$(date +%d-%m-%Y)}"
LANG_ID="${LANG_ID:-0}"
CLOUD_FLAG="${CLOUD_FLAG:-N}"

MODERN_PULL_URL="${MODERN_PULL_URL:-}"
MODERN_CALLBACK_URL="${MODERN_CALLBACK_URL:-}"
MODERN_API_KEY="${MODERN_API_KEY:-}"
INPUT_JSON="${INPUT_JSON:-}"
OUTPUT_JSON="${OUTPUT_JSON:-}"

SELECT_COURT_LINKID="${SELECT_COURT_LINKID:-182}"
SELECT_COURT_DIFFLINKID="${SELECT_COURT_DIFFLINKID:-182}"
SELECT_COURT_MODE="${SELECT_COURT_MODE:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need curl; need openssl
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi

if [[ -n "${INPUT_JSON:-}" ]]; then
  [[ -f "$INPUT_JSON" ]] || { echo "INPUT_JSON file not found: $INPUT_JSON" >&2; exit 1; }
elif [[ -z "$MODERN_PULL_URL" || -z "$MODERN_CALLBACK_URL" ]]; then
  echo "Set INPUT_JSON (file mode) or MODERN_PULL_URL + MODERN_CALLBACK_URL (API mode)" >&2; exit 1
fi

BASE="${CIS_BASE_URL%/}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
COOKIE="$TMPDIR/cookie.txt"
# shellcheck source=cis_court_selection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_court_selection.sh"

api_headers=()
if [[ -n "$MODERN_API_KEY" ]]; then api_headers=(-H "Authorization: Bearer $MODERN_API_KEY"); fi
FILE_MODE=false
if [[ -n "${INPUT_JSON:-}" ]]; then FILE_MODE=true; fi

post_callback() {
  local json_file="$1"
  curl -sS -X POST "${api_headers[@]}" -H "Content-Type: application/json" --data-binary "@$json_file" "$MODERN_CALLBACK_URL" >/dev/null
}

encrypt_password() { printf '%s' "$1" | openssl enc -aes-256-cbc -salt -md md5 -a -A -pass pass:myPassword 2>/dev/null; }

loginuser_cis() {
  local enc_password="$1" out="$TMPDIR/loginuser.json"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" \
    --data-urlencode "databasetype=$COURT_CODE" \
    --data-urlencode "username=$CIS_USER" \
    --data-urlencode "pass_word=$enc_password" \
    --data-urlencode "logindate=$LOGIN_DATE" \
    --data-urlencode "lang_id=$LANG_ID" \
    --data-urlencode "hidd_otp=" \
    --data-urlencode "x=loginuser" \
    --data-urlencode "cloud_flag=$CLOUD_FLAG" > "$out"
  "$PYTHON_BIN" - "$out" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m: raise SystemExit('CIS login failed: no JSON: '+s[:300])
d=json.loads(m.group(0))
open(sys.argv[1]+'.parsed','w',encoding='utf-8').write(json.dumps(d, ensure_ascii=False))
print(d.get('output',''))
PY
}

unlock_cis_user() {
  local enc_unlock; enc_unlock="$(encrypt_password "$UNLOCK_PASSWORD")"
  local form_html="$TMPDIR/unlock_form.html" post_data="$TMPDIR/unlock_post.txt" resp="$TMPDIR/unlock_resp.json"
  curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/index_unlock.php" > "$form_html" 2>/dev/null || true
  "$PYTHON_BIN" - "$form_html" "$post_data" "$CIS_USER" "$enc_unlock" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode
form_html, post_data, user, enc = sys.argv[1:5]
html=open(form_html, encoding='utf-8', errors='ignore').read()
class FP(HTMLParser):
    def __init__(self): super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if tag=='form' and attrs.get('id')=='frm_unlock': self.in_form=True
        if not self.in_form: return
        if tag=='input':
            name=attrs.get('name')
            if not name: return
            typ=(attrs.get('type') or '').lower()
            if typ in ('button','submit','reset','file','image'): return
            if typ in ('radio','checkbox') and 'checked' not in attrs: return
            self.items.append((name, attrs.get('value','')))
        elif tag=='textarea': self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, d):
        if self.in_textarea: self.ta+=d
    def handle_endtag(self, tag):
        if tag=='textarea' and self.in_textarea: self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False
p=FP(); p.feed(html)
items=[(k,v) for k,v in p.items if k not in {'unlock_username','unlock_pass_word','unlock_confirmpass_word'}]
items += [('unlock_username',user),('unlock_pass_word',enc),('unlock_confirmpass_word',enc),('x','checkunlock_fromindex')]
open(post_data,'w',encoding='utf-8').write(urlencode(items))
PY
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" --data-binary "@$post_data" > "$resp"
  "$PYTHON_BIN" - "$resp" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m: raise SystemExit('CIS unlock failed: no JSON: '+s[:300])
d=json.loads(m.group(0))
if d.get('msgnn','')!='Unlocked Successfully': raise SystemExit(f'CIS unlock failed: {d}')
PY
  echo "CIS user unlocked." >&2
}

login_cis() {
  local enc_password; enc_password="$(encrypt_password "$CIS_PASSWORD")"
  local sessstore="$(date +%s)"
  curl -sS -c "$COOKIE" "$BASE/" >/dev/null
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" \
    --data-urlencode "x=fetchdata" --data-urlencode "est_code=$COURT_CODE" >/dev/null
  local out; out="$(loginuser_cis "$enc_password")"
  if [[ "$out" == "UserLogged" ]]; then echo "CIS: user already logged in. Attempting unlock..." >&2; unlock_cis_user; out="$(loginuser_cis "$enc_password")"; fi
  if [[ "$out" != "yes" ]]; then
    "$PYTHON_BIN" - "$TMPDIR/loginuser.json.parsed" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8', errors='ignore'))
raise SystemExit(f"CIS login failed (output={d.get('output')}): {d}")
PY
  fi
  curl -sS -L -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/o_index1.php?sessstore=$sessstore" \
    --data-urlencode "databasetype=$COURT_CODE" --data-urlencode "username=$CIS_USER" \
    --data-urlencode "pass_word=$enc_password" --data-urlencode "logindate=$LOGIN_DATE" \
    --data-urlencode "lang_id=$LANG_ID" --data-urlencode "hidd_otp=" >/dev/null
}

logout_cis() { curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/logout.php" >/dev/null 2>&1 || true; }

select_court() {
  local item_json="$1"
  local court radio external_id page fetch_before submit_resp fetch_after result_json
  page="$TMPDIR/select_page.html"; fetch_before="$TMPDIR/fetch_before.json"; submit_resp="$TMPDIR/submit.json"; fetch_after="$TMPDIR/fetch_after.json"; result_json="$TMPDIR/result.json"
  court="$($PYTHON_BIN - "$item_json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
import os
print(os.environ.get('COURT_NO') or d.get('court_no') or d.get('fcourt_no') or d.get('target_court_no') or d.get('allocated_court_no') or '')
PY
)"
  radio="$($PYTHON_BIN - "$item_json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('radio_flag') or 'active')
PY
)"
  external_id="$($PYTHON_BIN - "$item_json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('external_id') or d.get('external_filing_id') or '')
PY
)"
  if [[ -n "${SKIP_COURT_SELECTION:-}" ]] && cis_truthy "${SKIP_COURT_SELECTION:-}"; then
    echo "[select_court] Court selection skipped by config; court_no=${court:-<empty>}" >&2
    "$PYTHON_BIN" - "$item_json" "$external_id" "$court" "$result_json" <<'PY'
import json, sys
item=json.load(open(sys.argv[1], encoding='utf-8'))
external_id, court, out_f = sys.argv[2:5]
json.dump({'external_id': external_id or item.get('external_id') or item.get('external_filing_id') or f'court-{court}', 'court_no': court, 'status': 'skipped', 'court_selection_status': 'skipped'}, open(out_f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
    cat "$result_json"
    return 0
  fi

  cis_select_court_if_enabled "$BASE" "$COOKIE" "$court" "false" "select_court" "$radio"

  "$PYTHON_BIN" - "$item_json" "$external_id" "$court" "$result_json" <<'PY'
import json, sys
item=json.load(open(sys.argv[1], encoding='utf-8'))
external_id, court, out_f = sys.argv[2:5]
json.dump({'external_id': external_id or item.get('external_id') or item.get('external_filing_id') or f'court-{court}', 'court_no': court, 'status': 'success', 'court_selection_status': 'success'}, open(out_f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  cat "$result_json"
  return 0

  [[ -n "$court" ]] || { echo "ERROR: court_no missing" >&2; return 1; }

  curl -sS -b "$COOKIE" -c "$COOKIE" \
    "$BASE/proceedings/select_court.php?linkid=$SELECT_COURT_LINKID&difflinkid=$SELECT_COURT_DIFFLINKID&mode=$SELECT_COURT_MODE" > "$page"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/proceedings/select_courtajax.php" \
    -H "X-Requested-With: XMLHttpRequest" \
    --data-urlencode "x=fetch_bench" --data-urlencode "radio_flag=$radio" > "$fetch_before"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/proceedings/select_courtajax.php" \
    -H "X-Requested-With: XMLHttpRequest" \
    --data-urlencode "formaction=1" --data-urlencode "count1=" --data-urlencode "checkorder=" \
    --data-urlencode "fno_judges=" --data-urlencode "fcourt_no=$court" > "$submit_resp"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/proceedings/select_courtajax.php" \
    -H "X-Requested-With: XMLHttpRequest" \
    --data-urlencode "x=fetch_bench" --data-urlencode "radio_flag=$radio" > "$fetch_after"

  "$PYTHON_BIN" - "$item_json" "$external_id" "$court" "$submit_resp" "$fetch_after" "$result_json" <<'PY'
import json, re, sys
item=json.load(open(sys.argv[1], encoding='utf-8'))
external_id, court, submit_f, fetch_f, out_f = sys.argv[2:7]
def parse(path):
    s=open(path, encoding='utf-8', errors='ignore').read()
    m=re.search(r'\{.*\}', s, re.S)
    if m:
        try: return json.loads(m.group(0))
        except Exception: pass
    return {'_raw': s[:1000]}
submit=parse(submit_f)
fetch=parse(fetch_f)
raw=json.dumps(submit, ensure_ascii=False).lower()
# CIS variants often return msg/msg1 plus court_judge_name/topjocode/notifycourts.
success = not any(x in raw for x in ['syntax error','error','failed'])
out={
  'external_id': external_id or item.get('external_id') or f'court-{court}',
  'court_no': str(court),
  'status': 'success' if success else 'failed',
  'submit_response': submit,
  'fetch_after_response': fetch,
}
if not success:
    out['error']='select_courtajax submit response looked like an error'
open(out_f,'w',encoding='utf-8').write(json.dumps(out, ensure_ascii=False, indent=2))
PY
  cat "$result_json"
}

PENDING_JSON="$TMPDIR/pending.json"
if $FILE_MODE; then cp "$INPUT_JSON" "$PENDING_JSON"; else curl -sS "${api_headers[@]}" "$MODERN_PULL_URL" > "$PENDING_JSON"; fi

COUNT="$($PYTHON_BIN - "$PENDING_JSON" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
if not isinstance(d, list): raise SystemExit('Input must be a JSON array')
print(len(d))
PY
)"

if [[ "$COUNT" == "0" ]]; then echo "No select-court records."; exit 0; fi

login_cis
for i in $(seq 0 $((COUNT-1))); do
  ITEM_JSON="$TMPDIR/item_$i.json"; RESULT_JSON="$TMPDIR/result_$i.json"
  "$PYTHON_BIN" - "$PENDING_JSON" "$i" "$ITEM_JSON" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
json.dump(d[int(sys.argv[2])], open(sys.argv[3],'w',encoding='utf-8'), ensure_ascii=False)
PY
  echo "Selecting court [$((i+1))/$COUNT] ..." >&2
  set +e
  ( set -e; select_court "$ITEM_JSON" ) > "$RESULT_JSON"
  SELECT_COURT_RC=$?
  set -e
  if [[ "$SELECT_COURT_RC" -eq 0 ]]; then $FILE_MODE || post_callback "$RESULT_JSON"; else
    rm -f "$RESULT_JSON"
    ERR="$TMPDIR/error_$i.json"
    "$PYTHON_BIN" - "$ITEM_JSON" "$ERR" <<'PY'
import json, sys
r=json.load(open(sys.argv[1], encoding='utf-8'))
json.dump({'external_id':r.get('external_id') or r.get('external_filing_id'),'court_no':r.get('court_no'),'status':'failed','error':'CIS select-court failed; see bridge logs'}, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False)
PY
    $FILE_MODE || post_callback "$ERR"
  fi
done
logout_cis
echo "CIS logout complete." >&2

if $FILE_MODE && [[ -n "${OUTPUT_JSON:-}" ]]; then
  "$PYTHON_BIN" - "$TMPDIR" "$OUTPUT_JSON" <<'PY'
import json, os, glob, sys
results=[]
def load_safe(f):
    try:
        if os.path.getsize(f)==0: return {'status':'failed','error':f'empty result file {os.path.basename(f)}'}
        return json.load(open(f, encoding='utf-8'))
    except Exception as e:
        return {'status':'failed','error':f'unreadable result file {os.path.basename(f)}: {e}'}
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'result_*.json'))): results.append(load_safe(f))
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'error_*.json'))): results.append(load_safe(f))
json.dump(results, open(sys.argv[2], 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"Wrote {len(results)} results to {sys.argv[2]}")
PY
fi
