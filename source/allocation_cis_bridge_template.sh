#!/usr/bin/env bash
set -euo pipefail

# Case-allocation CIS bridge template
#
# Purpose:
#   1. Pull pending allocations (CNR + target court) from modern app API or file.
#   2. Login to old CIS (auto-unlocks if "User Already Logged In").
#   3. For each CNR: load bulk_allocation page, showdetails, fetchcourttable,
#      behaviourfetch, then submit formaction=8 to allocate to target_court_no.
#   4. Verify allocation by re-running showdetails (case no longer pending).
#   5. POST result back to modern app callback (API mode) or write output JSON (file mode).
#
# Required commands: curl, openssl, python3/python
#
# Environment:
#   CIS_BASE_URL="http://<cis-host>/swecourtis"
#   COURT_CODE="HRPK02"
#   CIS_USER="<cis-user>"
#   CIS_PASSWORD="<cis-password>"
#   UNLOCK_PASSWORD="<unlock-password>"   # defaults to CIS_PASSWORD
#
#   (File mode) INPUT_JSON + OUTPUT_JSON
#   (API mode)  MODERN_PULL_URL + MODERN_CALLBACK_URL + MODERN_API_KEY
#
# Input record:
#   {
#     "external_id": "APP-123",
#     "cis_cnr": "HRPK030093392026",
#     "fmm_case_type": "55",          # optional, default 55 (NACT)
#     "target_court_no": "41",        # REQUIRED
#     "allocation_dt": "23-06-2026"   # optional, default today
#   }
#
# Allocation flow (radiotype=5, by CNR):
#   GET  registration/bulk_allocation.php?linkid=93&mode=0
#   POST bulk_allocationajax.php  x=showdetails&cino=<CNR>            (validate + fetch pet/res/casetype)
#   POST bulk_allocationajax.php  x=fetchcourttable&casetypevalue=..  (available courts)
#   POST bulk_allocationajax.php  x=behaviourfetch                     (behaviour flag)
#   POST bulk_allocationajax.php  ...&formaction=8                    (THE ALLOCATION)
#   POST bulk_allocationajax.php  x=showdetails&cino=<CNR>            (post-check: numrow==0 => allocated)

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

# Allocation constants
ALLOCATION_LINKID="${ALLOCATION_LINKID:-93}"
RADIOTYPE="${RADIOTYPE:-5}"                 # 5 = by CNR / registration number
FORMACTION_ALLOCATE="${FORMACTION_ALLOCATE:-8}"
DEFAULT_CASE_TYPE="${DEFAULT_CASE_TYPE:-55}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need curl
need openssl
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3;
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python;
  else echo "Missing python3/python" >&2; exit 1; fi
fi

if [[ -n "${INPUT_JSON:-}" ]]; then
  if [[ ! -f "$INPUT_JSON" ]]; then echo "INPUT_JSON file not found: $INPUT_JSON" >&2; exit 1; fi
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
  curl -sS -X POST "${api_headers[@]}" -H "Content-Type: application/json" \
    --data-binary "@$json_file" "$MODERN_CALLBACK_URL" >/dev/null
}

encrypt_password() {
  printf '%s' "$1" | openssl enc -aes-256-cbc -salt -md md5 -a -A -pass pass:myPassword 2>/dev/null
}

loginuser_cis() {
  local enc_password="$1"
  local out="$TMPDIR/loginuser.json"
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
if not m:
    raise SystemExit('CIS login failed: no JSON in loginuser response: '+s[:300])
d=json.loads(m.group(0))
open(sys.argv[1]+'.parsed','w',encoding='utf-8').write(json.dumps(d, ensure_ascii=False))
print(d.get('output',''))
PY
}

unlock_cis_user() {
  local enc_unlock; enc_unlock="$(encrypt_password "$UNLOCK_PASSWORD")"
  local form_html="$TMPDIR/unlock_form.html"
  local post_data="$TMPDIR/unlock_post.txt"
  local resp="$TMPDIR/unlock_resp.json"

  curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/index_unlock.php" > "$form_html" 2>/dev/null || true

  "$PYTHON_BIN" - "$form_html" "$post_data" "$CIS_USER" "$enc_unlock" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode
form_html, post_data, user, enc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
html=open(form_html, encoding='utf-8', errors='ignore').read()
class FormParser(HTMLParser):
    def __init__(self):
        super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]
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
        elif tag=='textarea':
            self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, data):
        if self.in_textarea: self.ta += data
    def handle_endtag(self, tag):
        if tag=='textarea' and self.in_textarea:
            self.items.append((self.in_textarea, self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False
p=FormParser(); p.feed(html)
override={'unlock_username','unlock_pass_word','unlock_confirmpass_word'}
items=[(k,v) for k,v in p.items if k not in override]
items += [('unlock_username',user),('unlock_pass_word',enc),('unlock_confirmpass_word',enc),('x','checkunlock_fromindex')]
open(post_data,'w',encoding='utf-8').write(urlencode(items))
PY

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" \
    --data-binary "@$post_data" > "$resp"

  "$PYTHON_BIN" - "$resp" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m:
    raise SystemExit('CIS unlock failed: no JSON: '+s[:300])
d=json.loads(m.group(0))
if d.get('msgnn','') != 'Unlocked Successfully':
    raise SystemExit(f'CIS unlock failed: {d}')
PY
  echo "CIS user unlocked successfully." >&2
}

login_cis() {
  local enc_password; enc_password="$(encrypt_password "$CIS_PASSWORD")"
  local sessstore="$(date +%s)"

  curl -sS -c "$COOKIE" "$BASE/" >/dev/null
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" \
    --data-urlencode "x=fetchdata" --data-urlencode "est_code=$COURT_CODE" >/dev/null

  local out; out="$(loginuser_cis "$enc_password")"
  if [[ "$out" == "UserLogged" ]]; then
    echo "CIS: user already logged in. Attempting unlock..." >&2
    unlock_cis_user
    out="$(loginuser_cis "$enc_password")"
  fi
  if [[ "$out" != "yes" ]]; then
    "$PYTHON_BIN" - "$TMPDIR/loginuser.json.parsed" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8', errors='ignore'))
raise SystemExit(f"CIS login failed (output={d.get('output')}): {d}")
PY
  fi

  curl -sS -L -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/o_index1.php?sessstore=$sessstore" \
    --data-urlencode "databasetype=$COURT_CODE" \
    --data-urlencode "username=$CIS_USER" \
    --data-urlencode "pass_word=$enc_password" \
    --data-urlencode "logindate=$LOGIN_DATE" \
    --data-urlencode "lang_id=$LANG_ID" \
    --data-urlencode "hidd_otp=" >/dev/null
}

logout_cis() {
  curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/logout.php" >/dev/null 2>&1 || true
}

# Fetch a field from the item JSON.
rec_field() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import json, sys, datetime
d=json.load(open(sys.argv[1], encoding='utf-8'))
key=sys.argv[2]
if key=='allocation_dt':
    print(d.get(key) or datetime.date.today().strftime('%d-%m-%Y'))
elif key=='fmm_case_type':
    print(d.get(key) or '55')
else:
    v=d.get(key)
    print('' if v is None else v)
PY
}

# Fetch a field from a JSON file. The path is passed as argv (not embedded in
# Python source) so this works with native Windows Python under Git Bash/MSYS,
# where argv paths are converted but string literals like '/tmp/...' are not.
json_field() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d=json.load(fh)
v=d.get(sys.argv[2], '')
print('' if v is None else v)
PY
}

json_field_unescape() {
  "$PYTHON_BIN" - "$1" "$2" <<'PY'
import html, json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    d=json.load(fh)
v=d.get(sys.argv[2], '')
print(html.unescape('' if v is None else str(v)))
PY
}

allocate_case_to_cis() {
  local item_json="$1"
  local alloc_page="$TMPDIR/alloc_page.html"
  local base_post="$TMPDIR/base_post.txt"
  local show_body="$TMPDIR/show_body.txt"
  local show_resp="$TMPDIR/showdetails.json"
  local court_resp="$TMPDIR/courttable.json"
  local behave_resp="$TMPDIR/behaviour.json"
  local submit_body="$TMPDIR/submit_body.txt"
  local submit_resp="$TMPDIR/submit.json"
  local postshow_resp="$TMPDIR/postshow.json"

  local cis_cnr fmm_case_type target_court allocation_dt next_date purpose_code
  cis_cnr="$(rec_field "$item_json" cis_cnr)"
  fmm_case_type="$(rec_field "$item_json" fmm_case_type)"
  target_court="$(rec_field "$item_json" target_court_no)"
  allocation_dt="$(rec_field "$item_json" allocation_dt)"
  next_date="$(rec_field "$item_json" next_date)"
  purpose_code="$(rec_field "$item_json" purpose_code)"
  if [[ -z "$purpose_code" ]]; then purpose_code="$(rec_field "$item_json" fpurpose_code)"; fi
  if [[ -z "$purpose_code" ]]; then purpose_code="6"; fi
  if [[ -z "$next_date" ]]; then next_date="$allocation_dt"; fi

  if [[ -z "$cis_cnr" ]]; then
    echo "ERROR: cis_cnr missing in record" >&2; return 1; fi
  if [[ -z "$target_court" ]]; then
    echo "ERROR: target_court_no missing (required) for $cis_cnr" >&2; return 1; fi

  # 1. Load allocation page, parse base #frm fields (preserve hidden tokens).
  curl -sS -b "$COOKIE" -c "$COOKIE" \
    "$BASE/registration/bulk_allocation.php?linkid=$ALLOCATION_LINKID&mode=0" > "$alloc_page"

  "$PYTHON_BIN" - "$alloc_page" "$base_post" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode
alloc_page, base_post = sys.argv[1], sys.argv[2]
html=open(alloc_page, encoding='utf-8', errors='ignore').read()
class FormParser(HTMLParser):
    def __init__(self):
        super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if tag=='form' and attrs.get('id')=='frm': self.in_form=True
        if not self.in_form: return
        if tag=='input':
            name=attrs.get('name')
            if not name: return
            typ=(attrs.get('type') or '').lower()
            if typ in ('button','submit','reset','file','image'): return
            if typ in ('radio','checkbox') and 'checked' not in attrs: return
            self.items.append((name, attrs.get('value','')))
        elif tag=='textarea':
            self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, data):
        if self.in_textarea: self.ta += data
    def handle_endtag(self, tag):
        if tag=='textarea' and self.in_textarea:
            self.items.append((self.in_textarea, self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False
p=FormParser(); p.feed(html)
base={}
for k,v in p.items:
    base[k]=v
open(base_post,'w',encoding='utf-8').write(urlencode(list(base.items())))
PY

  # 2. showdetails — validate case is pending allocation; fetch pet/res/casetype/case_no.
  "$PYTHON_BIN" - "$base_post" "$show_body" "$cis_cnr" "$fmm_case_type" "$allocation_dt" "$next_date" "$purpose_code" <<'PY'
import sys
from urllib.parse import parse_qsl, urlencode
base_post, show_body, cino, ct, adt, ndt, purpose = sys.argv[1:8]
d=dict(parse_qsl(open(base_post,encoding='utf-8').read(), keep_blank_values=True))
d.update({
  'todaysdate': adt, 'radiotype': '5', 'formaction': '1',
  'case_no[]': '', 'court_case_flag': '', 'uniquecino': cino, 'case_no1': '',
  'behaviour': '', 'numrow': '', 'cino_fromreg': '', 'radiotypeval_fromreg': '',
  'fmm_case_type': ct, 'fmm_case_no': '', 'fmm_case_year': '', 'freg_no': cino,
  'pet_name': '', 'res_name': '', 'fpurpose_code': purpose, 'next_date': ndt, 'allocation_dt': adt,
  'fcourt_no': '', 'police_st_code': '',
  'x': 'showdetails', 'cino': cino,
})
open(show_body,'w',encoding='utf-8').write(urlencode(d, doseq=True))
PY

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/bulk_allocationajax.php" \
    --data-binary "@$show_body" > "$show_resp"

  local show_fields="$TMPDIR/show_fields.json"
  "$PYTHON_BIN" - "$show_resp" "$show_fields" "$cis_cnr" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m:
    raise SystemExit(f'showdetails: no JSON: {s[:300]}')
d=json.loads(m.group(0))
fields={
  'numrow': d.get('numrow',0),
  'casetypevalue': d.get('casetypevalue',''),
  'pet_name': d.get('pet_name',''),
  'res_name': d.get('res_name',''),
  'case_no': d.get('case_no',''),
  'date_next_list': d.get('date_next_list',''),
  'uniquecino': d.get('uniquecino1') or sys.argv[3],
}
open(sys.argv[2],'w',encoding='utf-8').write(json.dumps(fields, ensure_ascii=False))
print(json.dumps(fields, ensure_ascii=False), file=sys.stderr)
PY
  local numrow casetypevalue pet_name res_name case_no uniquecino
  numrow="$(json_field "$show_fields" numrow)"
  casetypevalue="$(json_field "$show_fields" casetypevalue)"
  pet_name="$(json_field_unescape "$show_fields" pet_name)"
  res_name="$(json_field_unescape "$show_fields" res_name)"
  case_no="$(json_field "$show_fields" case_no)"
  uniquecino="$(json_field "$show_fields" uniquecino)"

  if [[ "$numrow" == "0" || -z "$numrow" ]]; then
    echo "ERROR: case $cis_cnr not found or already allocated (numrow=0)" >&2; return 1; fi
  if [[ -z "$casetypevalue" ]]; then
    casetypevalue="$fmm_case_type"; fi

  # 3. fetchcourttable — list available courts for this casetype; validate target.
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/bulk_allocationajax.php" \
    --data-urlencode "x=fetchcourttable" \
    --data-urlencode "casetypevalue=$casetypevalue" \
    --data-urlencode "formaction=1" > "$court_resp"

  local courts_json="$TMPDIR/courts.json"
  "$PYTHON_BIN" - "$court_resp" "$courts_json" "$target_court" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m:
    raise SystemExit(f'fetchcourttable: no JSON: {s[:300]}')
d=json.loads(m.group(0))
table=d.get('court_table','') or ''
courts=set()
# match <input ... name="court_no" ... value="N" ...> in either attribute order
for tag in re.findall(r'<input[^>]*>', table, re.I):
    if re.search(r'name\s*=\s*["\']?court_no', tag, re.I):
        vm=re.search(r'value\s*=\s*["\']?(\d+)', tag, re.I)
        if vm: courts.add(vm.group(1))
courts=sorted(courts, key=lambda x:int(x))
target=sys.argv[3]
result={'courts':courts, 'target':target, 'valid': (target in courts)}
open(sys.argv[2],'w',encoding='utf-8').write(json.dumps(result, ensure_ascii=False))
print(json.dumps(result, ensure_ascii=False), file=sys.stderr)
PY
  local target_valid
  target_valid="$(json_field "$courts_json" valid)"
  if [[ "$target_valid" != "True" ]]; then
    echo "ERROR: target_court_no=$target_court not in available courts for casetype $casetypevalue ($cis_cnr)" >&2; return 1; fi

  # 4. behaviourfetch
  local behaviour="yes"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/bulk_allocationajax.php" \
    --data-urlencode "x=behaviourfetch" > "$behave_resp" 2>/dev/null || true
  behaviour="$("$PYTHON_BIN" - "$behave_resp" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
print(json.loads(m.group(0)).get('behaviour','yes') if m else 'yes')
PY
)"

  # 5. submit allocation (formaction=8).
  "$PYTHON_BIN" - "$base_post" "$submit_body" "$cis_cnr" "$fmm_case_type" "$allocation_dt" "$next_date" "$purpose_code" \
    "$pet_name" "$res_name" "$case_no" "$uniquecino" "$target_court" "$behaviour" "$courts_json" <<'PY'
import json, sys
from urllib.parse import parse_qsl, urlencode
(base_post, submit_body, cino, ct, adt, ndt, purpose, pet, res, case_no, ucino, target, behaviour, courts_json) = sys.argv[1:15]
d=dict(parse_qsl(open(base_post,encoding='utf-8').read(), keep_blank_values=True))
courts=json.load(open(courts_json,encoding='utf-8'))['courts']
d.update({
  'todaysdate': adt, 'radiotype': '5', 'formaction': '8',
  'court_case_flag': '', 'uniquecino': ucino, 'case_no1': case_no,
  'behaviour': behaviour, 'numrow': '', 'cino_fromreg': '', 'radiotypeval_fromreg': '',
  'fmm_case_type': ct, 'fmm_case_no': '', 'fmm_case_year': '', 'freg_no': cino,
  'pet_name': pet, 'res_name': res, 'fpurpose_code': purpose, 'next_date': ndt, 'allocation_dt': adt,
  'court_no': target, 'fcourt_no': '', 'police_st_code': '',
})
# empty notify-court fields, one per available court (matches UI serialize)
for c in courts:
    d.setdefault('fnotify_court'+c, '')
open(submit_body,'w',encoding='utf-8').write(urlencode(d, doseq=True))
PY

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/bulk_allocationajax.php" \
    --data-binary "@$submit_body" > "$submit_resp"

  # 6. post-check: showdetails again — numrow==0 means case left the pending pool (allocated).
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/bulk_allocationajax.php" \
    --data-binary "@$show_body" > "$postshow_resp"
  # show_body still has x=showdetails; reuse it.

  local result_json="$TMPDIR/result.json"
  "$PYTHON_BIN" - "$item_json" "$cis_cnr" "$target_court" "$submit_resp" "$postshow_resp" "$result_json" <<'PY'
import json, re, sys
record=json.load(open(sys.argv[1], encoding='utf-8'))
cino, target, submit_f, postshow_f, out_f = sys.argv[2:7]
def first_json(path):
    s=open(path, encoding='utf-8', errors='ignore').read()
    m=re.search(r'\{.*\}', s, re.S)
    return json.loads(m.group(0)) if m else {'_raw': s[:500]}
submit=first_json(submit_f)
postshow=first_json(postshow_f)
post_numrow=str(postshow.get('numrow',''))
allocated = (post_numrow=='0')
out={
  'external_id': record.get('external_id') or record.get('external_filing_id'),
  'cis_cnr': cino,
  'status': 'success' if allocated else 'failed',
  'allocated_court_no': target if allocated else None,
  'postcheck_numrow': post_numrow,
  'submit_response': submit,
  'postcheck_response': postshow,
}
if not allocated:
    out['error']='post-check showdetails still returns case (numrow!=0); allocation may not have taken. Inspect submit_response.'
open(out_f,'w',encoding='utf-8').write(json.dumps(out, ensure_ascii=False, indent=2))
PY

  cat "$result_json"
}

# Pull pending allocations from modern app (API mode) or local file (file mode).
PENDING_JSON="$TMPDIR/pending.json"
if $FILE_MODE; then
  cp "$INPUT_JSON" "$PENDING_JSON"
else
  curl -sS "${api_headers[@]}" "$MODERN_PULL_URL" > "$PENDING_JSON"
fi

COUNT=$("$PYTHON_BIN" - "$PENDING_JSON" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
if not isinstance(d, list):
    raise SystemExit('Pull API/input must return a JSON array')
print(len(d))
PY
)

if [[ "$COUNT" == "0" ]]; then
  echo "No pending allocations."
  exit 0
fi

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "allocation"

for i in $(seq 0 $((COUNT-1))); do
  ITEM_JSON="$TMPDIR/item_$i.json"
  RESULT_JSON="$TMPDIR/result_$i.json"
  "$PYTHON_BIN" - "$PENDING_JSON" "$i" "$ITEM_JSON" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
json.dump(d[int(sys.argv[2])], open(sys.argv[3],'w',encoding='utf-8'), ensure_ascii=False)
PY

  echo "Allocating [$((i+1))/$COUNT] ..."
  set +e
  ( set -e; allocate_case_to_cis "$ITEM_JSON" ) > "$RESULT_JSON"
  ALLOC_RC=$?
  set -e
  if [[ "$ALLOC_RC" -eq 0 ]]; then
    $FILE_MODE || post_callback "$RESULT_JSON"
  else
    rm -f "$RESULT_JSON"
    ERR="$TMPDIR/error_$i.json"
    "$PYTHON_BIN" - "$ITEM_JSON" "$ERR" <<'PY'
import json, sys
record=json.load(open(sys.argv[1], encoding='utf-8'))
out={
  'external_id': record.get('external_id') or record.get('external_filing_id'),
  'cis_cnr': record.get('cis_cnr'),
  'status': 'failed',
  'error': 'CIS allocation failed; see bridge logs on court machine'
}
json.dump(out, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False)
PY
    $FILE_MODE || post_callback "$ERR"
  fi
done

logout_cis
echo "CIS logout complete." >&2

# File mode: collect all results into a single output JSON.
if $FILE_MODE && [[ -n "${OUTPUT_JSON:-}" ]]; then
  "$PYTHON_BIN" - "$TMPDIR" "$OUTPUT_JSON" <<'PY'
import json, os, glob, sys
results=[]
def load_safe(f):
    try:
        if os.path.getsize(f)==0:
            return {'status':'failed','error':f'empty result file {os.path.basename(f)}'}
        with open(f, encoding='utf-8') as fh: return json.load(fh)
    except Exception as e:
        return {'status':'failed','error':f'unreadable result file {os.path.basename(f)}: {e}'}
for f in sorted(glob.glob(os.path.join(sys.argv[1],'result_*.json'))):
    results.append(load_safe(f))
for f in sorted(glob.glob(os.path.join(sys.argv[1],'error_*.json'))):
    results.append(load_safe(f))
with open(sys.argv[2],'w',encoding='utf-8') as fh:
    json.dump(results, fh, ensure_ascii=False, indent=2)
print(f"Wrote {len(results)} results to {sys.argv[2]}")
PY
fi
