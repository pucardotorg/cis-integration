#!/usr/bin/env bash
set -euo pipefail

# Case-objection / scrutiny CIS bridge.
#
# HAR-backed flow:
#   GET  registration/case_objection.php?linkid=71&mode=0
#   POST registration/case_objectionajax.php x=showdetails&ffiling_no=<CNR>&opt=undefined
#   POST registration/case_objectionajax.php formaction=1&fobj_flag=<Y/N>&...serialized form...
#   POST registration/case_objectionajax.php x=caseObjectionComponent
#
# Input record:
#   {
#     "external_id": "APP-123",
#     "cis_cnr": "HRPK030093392026",
#     "fobj_sel": "N",                 # N = no objection / ready for registration, Y = objection raised
#     "fobj_flag": "Y",                # HAR posts Y when finalized/ready
#     "scrutiny_date": "23-06-2026",
#     "fobjection": "optional text"
#   }

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

CASE_OBJECTION_LINKID="${CASE_OBJECTION_LINKID:-71}"
CASE_OBJECTION_MODE="${CASE_OBJECTION_MODE:-0}"

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

post_callback() { curl -sS -X POST "${api_headers[@]}" -H "Content-Type: application/json" --data-binary "@$1" "$MODERN_CALLBACK_URL" >/dev/null; }
encrypt_password() { printf '%s' "$1" | openssl enc -aes-256-cbc -salt -md md5 -a -A -pass pass:myPassword 2>/dev/null; }

loginuser_cis() {
  local enc_password="$1" out="$TMPDIR/loginuser.json"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" \
    --data-urlencode "databasetype=$COURT_CODE" --data-urlencode "username=$CIS_USER" \
    --data-urlencode "pass_word=$enc_password" --data-urlencode "logindate=$LOGIN_DATE" \
    --data-urlencode "lang_id=$LANG_ID" --data-urlencode "hidd_otp=" \
    --data-urlencode "x=loginuser" --data-urlencode "cloud_flag=$CLOUD_FLAG" > "$out"
  "$PYTHON_BIN" - "$out" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read(); m=re.search(r'\{.*\}', s, re.S)
if not m: raise SystemExit('CIS login failed: no JSON: '+s[:300])
d=json.loads(m.group(0)); open(sys.argv[1]+'.parsed','w',encoding='utf-8').write(json.dumps(d,ensure_ascii=False)); print(d.get('output',''))
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
html=open(sys.argv[1], encoding='utf-8', errors='ignore').read(); user=sys.argv[3]; enc=sys.argv[4]
class FP(HTMLParser):
    def __init__(self): super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if tag=='form' and attrs.get('id')=='frm_unlock': self.in_form=True
        if not self.in_form: return
        if tag=='input':
            n=attrs.get('name'); typ=(attrs.get('type') or '').lower()
            if n and typ not in ('button','submit','reset','file','image') and not (typ in ('radio','checkbox') and 'checked' not in attrs): self.items.append((n, attrs.get('value','')))
        elif tag=='textarea': self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, d):
        if self.in_textarea: self.ta+=d
    def handle_endtag(self, tag):
        if tag=='textarea' and self.in_textarea: self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False
p=FP(); p.feed(html)
items=[(k,v) for k,v in p.items if k not in {'unlock_username','unlock_pass_word','unlock_confirmpass_word'}]
items += [('unlock_username',user),('unlock_pass_word',enc),('unlock_confirmpass_word',enc),('x','checkunlock_fromindex')]
open(sys.argv[2],'w',encoding='utf-8').write(urlencode(items))
PY
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" --data-binary "@$post_data" > "$resp"
  "$PYTHON_BIN" - "$resp" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read(); m=re.search(r'\{.*\}', s, re.S)
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
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" --data-urlencode "x=fetchdata" --data-urlencode "est_code=$COURT_CODE" >/dev/null
  local out; out="$(loginuser_cis "$enc_password")"
  if [[ "$out" == "UserLogged" ]]; then echo "CIS: user already logged in. Attempting unlock..." >&2; unlock_cis_user; out="$(loginuser_cis "$enc_password")"; fi
  if [[ "$out" != "yes" ]]; then "$PYTHON_BIN" - "$TMPDIR/loginuser.json.parsed" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8', errors='ignore')); raise SystemExit(f"CIS login failed (output={d.get('output')}): {d}")
PY
  fi
  curl -sS -L -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/o_index1.php?sessstore=$sessstore" \
    --data-urlencode "databasetype=$COURT_CODE" --data-urlencode "username=$CIS_USER" \
    --data-urlencode "pass_word=$enc_password" --data-urlencode "logindate=$LOGIN_DATE" \
    --data-urlencode "lang_id=$LANG_ID" --data-urlencode "hidd_otp=" >/dev/null
}
logout_cis() { curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/logout.php" >/dev/null 2>&1 || true; }

case_objection_one() {
  local item_json="$1"
  local page="$TMPDIR/case_objection_page.html" show_resp="$TMPDIR/showdetails.json" submit_body="$TMPDIR/submit_body.txt" submit_resp="$TMPDIR/submit.json" comp_resp="$TMPDIR/component.html" result_json="$TMPDIR/result.json"
  local cnr external_id
  cnr="$($PYTHON_BIN - "$item_json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8')); print(d.get('cis_cnr') or d.get('ffiling_no') or '')
PY
)"
  external_id="$($PYTHON_BIN - "$item_json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8')); print(d.get('external_id') or d.get('external_filing_id') or '')
PY
)"
  [[ -n "$cnr" ]] || { echo "ERROR: cis_cnr missing" >&2; return 1; }

  curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/registration/case_objection.php?linkid=$CASE_OBJECTION_LINKID&mode=$CASE_OBJECTION_MODE" > "$page"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/case_objectionajax.php" \
    --data-urlencode "x=showdetails" --data-urlencode "ffiling_no=$cnr" --data-urlencode "opt=undefined" > "$show_resp"

  "$PYTHON_BIN" - "$item_json" "$show_resp" "$submit_body" "$CASE_OBJECTION_LINKID" <<'PY'
import json, re, sys
from urllib.parse import urlencode
item=json.load(open(sys.argv[1], encoding='utf-8'))
raw=open(sys.argv[2], encoding='utf-8', errors='ignore').read()
linkid=sys.argv[4]
m=re.search(r'\{.*\}', raw, re.S)
show={}
if m:
    try: show=json.loads(m.group(0))
    except Exception: show={}
cnr=item.get('cis_cnr') or item.get('ffiling_no') or ''
fobj_sel=str(item.get('fobj_sel') or ('Y' if (item.get('fobjection') or item.get('objection_text')) else 'N'))
fobj_flag=str(item.get('fobj_flag') or 'Y')
scrutiny=item.get('scrutiny_date') or item.get('fobjreturn_dt') or ''
# The HAR has both leading fobj_flag and serialized fobj_flag; keep both by list of tuples.
pairs=[
 ('formaction','1'), ('fobj_flag',fobj_flag),
 ('cino_fromfiling',''), ('fci_cri',str(item.get('fci_cri') or show.get('ci_cri') or '3')),
 ('filing_number',str(item.get('filing_number') or show.get('filing_no') or '')),
 ('cino',cnr), ('tbl',str(show.get('tbl') or 'objection_history')),
 ('date_of_filing',str(show.get('date_of_filing') or item.get('date_of_filing') or '')),
 ('filcase_type',str(show.get('filcase_type') or item.get('fmm_case_type') or '')),
 ('linkid',str(show.get('linkid') or linkid)),
 ('caseobj_case_type',''), ('caseobj_filing_num',''), ('caseobj_filing_year',''), ('label_checkslip','Check Slip'), ('efilno',''),
 ('radiotype',str(item.get('radiotype') or '2')), ('filing_case_type',''), ('filing_num',''), ('filing_year',''),
 ('ffiling_no',cnr), ('ffiling_no',cnr),
 ('fobj_sel',fobj_sel), ('scrutiny_date',scrutiny),
 ('fobjection',str(item.get('fobjection') or item.get('objection_text') or '')),
 ('flobjection',str(item.get('flobjection') or item.get('local_objection_text') or '')),
 ('fobjreturn_dt',str(item.get('fobjreturn_dt') or scrutiny)),
 ('fobj_redate',str(item.get('fobj_redate') or '')),
 ('fobjreceipt_dt',str(item.get('fobjreceipt_dt') or '')),
 ('fobjdescription',str(item.get('fobjdescription') or '')),
 ('fobj_flag',fobj_flag), ('submitdata',str(item.get('submitdata') or 'undefined')),
]
open(sys.argv[3],'w',encoding='utf-8').write(urlencode(pairs))
PY

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/case_objectionajax.php" --data-binary "@$submit_body" > "$submit_resp"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/case_objectionajax.php" --data-urlencode "x=caseObjectionComponent" > "$comp_resp" || true

  "$PYTHON_BIN" - "$item_json" "$external_id" "$cnr" "$show_resp" "$submit_resp" "$comp_resp" "$result_json" <<'PY'
import json, re, sys
item=json.load(open(sys.argv[1], encoding='utf-8'))
external_id, cnr, show_f, submit_f, comp_f, out_f = sys.argv[2:8]
def parse(path):
    s=open(path, encoding='utf-8', errors='ignore').read()
    m=re.search(r'\{.*\}', s, re.S)
    if m:
        try: return json.loads(m.group(0))
        except Exception: pass
    return {'_raw': s[:1000]}
show=parse(show_f); submit=parse(submit_f)
raw=json.dumps(submit, ensure_ascii=False).lower()
# CIS response commonly uses success='Y'. If absent but no obvious error, mark success cautiously.
success = submit.get('success') in ('Y','Yes',True) or not any(x in raw for x in ['syntax error','failed','error'])
out={
 'external_id': external_id or item.get('external_id') or item.get('external_filing_id'),
 'cis_cnr': cnr,
 'status': 'success' if success else 'failed',
 'fobj_sel': item.get('fobj_sel') or ('Y' if item.get('fobjection') else 'N'),
 # Preserve complainant advocate values captured at filing; registration
 # showdetails does not reliably return these fields.
 'advocate_name': item.get('advocate_name'),
 'advocate_bar_number': item.get('advocate_bar_number'),
 'advocate_code': item.get('advocate_code'),
 'advocate_type': item.get('advocate_type'),
 'complainant_advocate_name': item.get('complainant_advocate_name') or item.get('advocate_name'),
 'complainant_advocate_barcode': item.get('complainant_advocate_barcode') or item.get('advocate_bar_number'),
 'complainant_advocate_code': item.get('complainant_advocate_code') or item.get('advocate_code'),
 'complainant_advocate_type': item.get('complainant_advocate_type') or item.get('advocate_type'),
 'complainant_party_type': item.get('complainant_party_type'),
 'complainant_org_id': item.get('complainant_org_id'),
 'complainant_extra_count': item.get('complainant_extra_count'),
 'accused_party_type': item.get('accused_party_type'),
 'accused_org_id': item.get('accused_org_id'),
 'accused_extra_count': item.get('accused_extra_count'),
 'acts': item.get('acts'),
 'showdetails_response': show,
 'submit_response': submit,
}
if not success: out['error']='case_objectionajax submit response looked like an error'
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
[[ "$COUNT" == "0" ]] && { echo "No case-objection records."; exit 0; }

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "case_objection"
for i in $(seq 0 $((COUNT-1))); do
  ITEM_JSON="$TMPDIR/item_$i.json"; RESULT_JSON="$TMPDIR/result_$i.json"
  "$PYTHON_BIN" - "$PENDING_JSON" "$i" "$ITEM_JSON" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8')); json.dump(d[int(sys.argv[2])], open(sys.argv[3],'w',encoding='utf-8'), ensure_ascii=False)
PY
  echo "Submitting case objection [$((i+1))/$COUNT] ..." >&2
  set +e
  ( set -e; case_objection_one "$ITEM_JSON" ) > "$RESULT_JSON"
  CASE_OBJECTION_RC=$?
  set -e
  if [[ "$CASE_OBJECTION_RC" -eq 0 ]]; then $FILE_MODE || post_callback "$RESULT_JSON"; else
    rm -f "$RESULT_JSON"
    ERR="$TMPDIR/error_$i.json"
    "$PYTHON_BIN" - "$ITEM_JSON" "$ERR" <<'PY'
import json, sys
r=json.load(open(sys.argv[1], encoding='utf-8'))
json.dump({'external_id':r.get('external_id') or r.get('external_filing_id'),'cis_cnr':r.get('cis_cnr'),'status':'failed','error':'CIS case-objection failed; see bridge logs'}, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False)
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
    except Exception as e: return {'status':'failed','error':f'unreadable result file {os.path.basename(f)}: {e}'}
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'result_*.json'))): results.append(load_safe(f))
for f in sorted(glob.glob(os.path.join(sys.argv[1], 'error_*.json'))): results.append(load_safe(f))
json.dump(results, open(sys.argv[2], 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"Wrote {len(results)} results to {sys.argv[2]}")
PY
fi
