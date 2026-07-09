#!/usr/bin/env bash
set -euo pipefail

# Bulk, READ-ONLY allocation verifier.
#
# Two modes (no writes to CIS, no rollback — safe on the whole batch):
#   --preflight  : validate every CNR + target_court_no BEFORE submitting.
#                  Per CNR: showdetails (found? casetype? pet/res? already allocated?)
#                  + fetchcourttable (is target_court_no in the available court list?).
#   --postcheck  : confirm every CNR is no longer pending (= allocated) AFTER a run.
#
# Writes verification-report.json + prints a summary.
#
# Usage:
#   verify_allocation_cis_bridge.sh --preflight  <input_or_output_json>  [report.json]
#   verify_allocation_cis_bridge.sh --postcheck  <output_json>          [report.json]
#
# Env: CIS_BASE_URL, COURT_CODE, CIS_USER, CIS_PASSWORD, UNLOCK_PASSWORD (same as bridge)

MODE=""
INPUT_FILE=""
REPORT_FILE="verification-report.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight|--postcheck) MODE="${1#--}"; shift;;
    -h|--help)
      sed -n '2,16p' "$0"; exit 0;;
    *) if [[ -z "$INPUT_FILE" ]]; then INPUT_FILE="$1"; else REPORT_FILE="$1"; fi; shift;;
  esac
done

if [[ -z "$MODE" || -z "$INPUT_FILE" ]]; then
  echo "Usage: $0 --preflight|--postcheck <input_or_output_json> [report.json]" >&2; exit 1; fi
if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Input file not found: $INPUT_FILE" >&2; exit 1; fi

CIS_BASE_URL="${CIS_BASE_URL:-http://127.0.0.1/swecourtis}"
COURT_CODE="${COURT_CODE:-HRPK02}"
CIS_USER="${CIS_USER:-supuser}"
CIS_PASSWORD="${CIS_PASSWORD:-ecourt123}"
UNLOCK_PASSWORD="${UNLOCK_PASSWORD:-$CIS_PASSWORD}"
LOGIN_DATE="${LOGIN_DATE:-$(date +%d-%m-%Y)}"
LANG_ID="${LANG_ID:-0}"
CLOUD_FLAG="${CLOUD_FLAG:-N}"
ALLOCATION_LINKID="${ALLOCATION_LINKID:-93}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need curl; need openssl
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3;
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python;
  else echo "Missing python3/python" >&2; exit 1; fi
fi

BASE="${CIS_BASE_URL%/}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
COOKIE="$TMPDIR/cookie.txt"

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
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m: raise SystemExit('login: no JSON: '+s[:300])
d=json.loads(m.group(0)); open(sys.argv[1]+'.parsed','w',encoding='utf-8').write(json.dumps(d,ensure_ascii=False))
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
form_html, post_data, user, enc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
html=open(form_html, encoding='utf-8', errors='ignore').read()
class FormParser(HTMLParser):
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
    def handle_endtag(self, t):
        if t=='textarea' and self.in_textarea: self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif t=='form' and self.in_form: self.in_form=False
p=FormParser(); p.feed(html)
override={'unlock_username','unlock_pass_word','unlock_confirmpass_word'}
items=[(k,v) for k,v in p.items if k not in override]+[('unlock_username',user),('unlock_pass_word',enc),('unlock_confirmpass_word',enc),('x','checkunlock_fromindex')]
open(post_data,'w',encoding='utf-8').write(urlencode(items))
PY
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/loginajax1.php" --data-binary "@$post_data" > "$resp"
  "$PYTHON_BIN" - "$resp" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m: raise SystemExit('unlock: no JSON: '+s[:300])
d=json.loads(m.group(0))
if d.get('msgnn','')!='Unlocked Successfully': raise SystemExit(f'unlock failed: {d}')
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
  if [[ "$out" == "UserLogged" ]]; then unlock_cis_user; out="$(loginuser_cis "$enc_password")"; fi
  if [[ "$out" != "yes" ]]; then
    "$PYTHON_BIN" - "$TMPDIR/loginuser.json.parsed" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8', errors='ignore'))
raise SystemExit(f"login failed (output={d.get('output')}): {d}")
PY
  fi
  curl -sS -L -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/o_index1.php?sessstore=$sessstore" \
    --data-urlencode "databasetype=$COURT_CODE" --data-urlencode "username=$CIS_USER" \
    --data-urlencode "pass_word=$enc_password" --data-urlencode "logindate=$LOGIN_DATE" \
    --data-urlencode "lang_id=$LANG_ID" --data-urlencode "hidd_otp=" >/dev/null
}

# showdetails for one CNR -> JSON {numrow,casetypevalue,pet_name,res_name,case_no,...}
showdetails_for() {
  local cino="$1" out="$2"
  local page="$TMPDIR/page.html" base="$TMPDIR/base.txt" body="$TMPDIR/body.txt" resp="$TMPDIR/show.json"
  curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/registration/bulk_allocation.php?linkid=$ALLOCATION_LINKID&mode=0" > "$page"
  "$PYTHON_BIN" - "$page" "$base" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode
page, base = sys.argv[1], sys.argv[2]
html=open(page, encoding='utf-8', errors='ignore').read()
class FP(HTMLParser):
    def __init__(self): super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]
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
        elif tag=='textarea': self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, d):
        if self.in_textarea: self.ta+=d
    def handle_endtag(self, t):
        if t=='textarea' and self.in_textarea: self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif t=='form' and self.in_form: self.in_form=False
p=FP(); p.feed(html)
d={}; 
for k,v in p.items: d[k]=v
open(base,'w',encoding='utf-8').write(urlencode(list(d.items())))
PY
  local adt; adt="$(date +%d-%m-%Y)"
  "$PYTHON_BIN" - "$base" "$body" "$cino" "$adt" <<'PY'
import sys
from urllib.parse import parse_qsl, urlencode
base, body, cino, adt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d=dict(parse_qsl(open(base,encoding='utf-8').read(), keep_blank_values=True))
d.update({'todaysdate':adt,'radiotype':'5','formaction':'1','uniquecino':cino,'case_no1':'','behaviour':'','numrow':'','cino_fromreg':'','radiotypeval_fromreg':'','fmm_case_type':'','fmm_case_no':'','fmm_case_year':'','freg_no':cino,'pet_name':'','res_name':'','next_date':'','allocation_dt':adt,'fcourt_no':'','police_st_code':'','x':'showdetails','cino':cino})
open(body,'w',encoding='utf-8').write(urlencode(d, doseq=True))
PY
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/bulk_allocationajax.php" --data-binary "@$body" > "$resp"
  "$PYTHON_BIN" - "$resp" "$out" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
if not m: open(sys.argv[2],'w').write(json.dumps({'numrow':0,'_raw':s[:500]})); sys.exit()
d=json.loads(m.group(0))
open(sys.argv[2],'w',encoding='utf-8').write(json.dumps({
  'numrow':d.get('numrow',0),'casetypevalue':d.get('casetypevalue',''),'pet_name':d.get('pet_name',''),'res_name':d.get('res_name',''),'case_no':d.get('case_no','')
}, ensure_ascii=False))
PY
}

courts_for() {
  local ct="$1" out="$2"
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/bulk_allocationajax.php" \
    --data-urlencode "x=fetchcourttable" --data-urlencode "casetypevalue=$ct" --data-urlencode "formaction=1" > "$TMPDIR/court.json"
  "$PYTHON_BIN" - "$TMPDIR/court.json" "$out" <<'PY'
import json, re, sys
s=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', s, re.S)
table=json.loads(m.group(0)).get('court_table','') if m else ''
courts=sorted({vm.group(1) for tag in re.findall(r'<input[^>]*>', table, re.I) if re.search(r'name\s*=\s*["\']?court_no', tag, re.I) for vm in [re.search(r'value\s*=\s*["\']?(\d+)', tag, re.I)] if vm}, key=lambda x:int(x))
open(sys.argv[2],'w',encoding='utf-8').write(json.dumps(courts))
PY
}

login_cis

REPORT="$TMPDIR/report.jsonl"
: > "$REPORT"

"$PYTHON_BIN" - "$INPUT_FILE" > "$TMPDIR/manifest.json" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1], encoding='utf-8'))))
PY

i=0
while IFS= read -r line; do
  i=$((i+1))
  rec="$line"
  echo "$rec" > "$TMPDIR/rec.json"
  cino="$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('cis_cnr',''))" "$TMPDIR/rec.json")"
  target="$("$PYTHON_BIN" -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('target_court_no') or '')" "$TMPDIR/rec.json")"
  ext="$("$PYTHON_BIN" -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(d.get('external_id') or d.get('external_filing_id') or '')" "$TMPDIR/rec.json")"
  show="$TMPDIR/show_$i.json"
  showdetails_for "$cino" "$show"
  numrow="$("$PYTHON_BIN" -c "import json;print(json.load(open('$show',encoding='utf-8')).get('numrow',0))" 2>/dev/null || echo 0)"
  ct="$("$PYTHON_BIN" -c "import json;print(json.load(open('$show',encoding='utf-8')).get('casetypevalue',''))" 2>/dev/null || echo "")"
  pet="$("$PYTHON_BIN" -c "import json,html;print(html.unescape(json.load(open('$show',encoding='utf-8')).get('pet_name','')))" 2>/dev/null || echo "")"
  res="$("$PYTHON_BIN" -c "import json,html;print(html.unescape(json.load(open('$show',encoding='utf-8')).get('res_name','')))" 2>/dev/null || echo "")"

  if [[ "$MODE" == "preflight" ]]; then
    if [[ "$numrow" == "0" || -z "$numrow" ]]; then
      row="{\"external_id\":\"$ext\",\"cis_cnr\":\"$cino\",\"status\":\"error\",\"reason\":\"case not found or already allocated (numrow=0)\"}"
      echo "$row" >> "$REPORT"; echo "  [$i] $cino ERROR not-found/already-allocated"; continue; fi
    courts="$TMPDIR/courts_$i.json"
    courts_for "$ct" "$courts"
    avail="$("$PYTHON_BIN" -c "import json;print(','.join(json.load(open('$courts',encoding='utf-8'))))")"
    if [[ -z "$target" ]]; then
      row="{\"external_id\":\"$ext\",\"cis_cnr\":\"$cino\",\"status\":\"error\",\"reason\":\"missing target_court_no\",\"casetype\":\"$ct\",\"available_courts\":\"$avail\"}"
      echo "$row" >> "$REPORT"; echo "  [$i] $cino ERROR missing target_court_no"; continue; fi
    if grep -q "\"$target\"" "$courts"; then
      row="{\"external_id\":\"$ext\",\"cis_cnr\":\"$cino\",\"status\":\"ok\",\"casetype\":\"$ct\",\"pet_name\":\"$pet\",\"res_name\":\"$res\",\"target_court_no\":\"$target\",\"available_courts\":\"$avail\"}"
      echo "$row" >> "$REPORT"; echo "  [$i] $cino OK casetype=$ct court=$target"; else
      row="{\"external_id\":\"$ext\",\"cis_cnr\":\"$cino\",\"status\":\"error\",\"reason\":\"target_court_no $target not in available courts\",\"casetype\":\"$ct\",\"available_courts\":\"$avail\"}"
      echo "$row" >> "$REPORT"; echo "  [$i] $cino ERROR court $target not available (have: $avail)"; fi
  else  # postcheck
    if [[ "$numrow" == "0" || -z "$numrow" ]]; then
      row="{\"external_id\":\"$ext\",\"cis_cnr\":\"$cino\",\"status\":\"ok\",\"reason\":\"case no longer pending (allocated)\"}"
      echo "$row" >> "$REPORT"; echo "  [$i] $cino OK allocated"; else
      row="{\"external_id\":\"$ext\",\"cis_cnr\":\"$cino\",\"status\":\"mismatch\",\"reason\":\"case still pending (numrow=$numrow); not allocated\"}"
      echo "$row" >> "$REPORT"; echo "  [$i] $cino MISMATCH still pending"; fi
  fi
done < <("$PYTHON_BIN" -c "
import json,sys
for r in json.load(open('$TMPDIR/manifest.json',encoding='utf-8')):
    print(json.dumps(r,ensure_ascii=False))
")

curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/logout.php" >/dev/null 2>&1 || true

# Assemble report + summary
"$PYTHON_BIN" - "$REPORT" "$REPORT_FILE" "$MODE" <<'PY'
import json, sys
rows=[json.loads(l) for l in open(sys.argv[1], encoding='utf-8') if l.strip()]
ok=sum(1 for r in rows if r['status']=='ok')
err=sum(1 for r in rows if r['status']=='error')
mis=sum(1 for r in rows if r['status']=='mismatch')
out={'mode':sys.argv[3] if len(sys.argv)>3 else 'verify','total':len(rows),'ok':ok,'error':err,'mismatch':mis,'rows':rows}
json.dump(out, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False, indent=2)
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
echo ""
echo "Verification report written: $REPORT_FILE"
