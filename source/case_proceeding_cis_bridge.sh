#!/usr/bin/env bash
set -euo pipefail

# Case-proceeding CIS bridge.
#
# HAR-backed flow (walkthro-23062026/case-proceeding.har + case_proceeding.js):
#   POST proceedings/select_courtajax.php     fcourt_no=$COURT_NO from Data/config.json (same session)
#   GET  proceedings/case_proceeding.php?linkid=261&mode=0
#   POST proceedings/case_proceedingajax.php  <serialized frm>&x=fetchdata&cino=<CNR>
#   POST proceedings/case_proceedingajax.php  <serialized frm + readable overrides>&x=submitdata
#
# Input record (readable names):
#   {
#     "external_id": "PROC-001",
#     "cis_cnr": "HRPK020007042026",
#     "proceeding_date": "29-06-2026",
#     "purpose_code": "6",
#     "subpurpose_code": "",
#     "next_hearing_date": "30-06-2026",
#     "business_remarks": "next hearing date is 30.06.2026",
#     "dormant_flag": "S",
#     "case_type_flag": "3",
#     "case_type_code": "55",
#     "counsel_present": ["MP"],
#     "dispose_flag": false,
#     "dor_sinedie": false,
#     "through_vc": false
#   }
#
# Disposal records are also supported after normalisation from typed inputs:
#   {
#     "type": "disposal",
#     "dispose_flag": true,
#     "decision_date": "03-07-2026",
#     "disposal_radio_type": "2",
#     "disposal_type": "25",
#     "dormant_flag": "D",
#     "next_hearing_date": ""
#   }

CIS_BASE_URL="${CIS_BASE_URL:-http://127.0.0.1/swecourtis}"
COURT_CODE="${COURT_CODE:-HRPK02}"
CIS_USER="${CIS_USER:-supuser}"
CIS_PASSWORD="${CIS_PASSWORD:-ecourt123}"
UNLOCK_PASSWORD="${UNLOCK_PASSWORD:-$CIS_PASSWORD}"
LOGIN_DATE="${LOGIN_DATE:-$(date +%d-%m-%Y)}"
LANG_ID="${LANG_ID:-0}"
CLOUD_FLAG="${CLOUD_FLAG:-N}"

INPUT_JSON="${INPUT_JSON:-}"
OUTPUT_JSON="${OUTPUT_JSON:-}"

CASE_PROCEEDING_LINKID="${CASE_PROCEEDING_LINKID:-261}"
CASE_PROCEEDING_MODE="${CASE_PROCEEDING_MODE:-0}"
SELECT_COURT_LINKID="${SELECT_COURT_LINKID:-182}"
SELECT_COURT_DIFFLINKID="${SELECT_COURT_DIFFLINKID:-182}"
SELECT_COURT_MODE="${SELECT_COURT_MODE:-0}"
DEFAULT_CASE_TYPE="${DEFAULT_CASE_TYPE:-55}"
DEFAULT_CASE_TYPE_FLAG="${DEFAULT_CASE_TYPE_FLAG:-3}"
DEFAULT_PURPOSE_CODE="${DEFAULT_PURPOSE_CODE:-6}"
DEFAULT_DORMANT_FLAG="${DEFAULT_DORMANT_FLAG:-S}"
DEFAULT_COUNSEL_PRESENT="${DEFAULT_COUNSEL_PRESENT:-MP}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need curl
need openssl
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi

if [[ -z "$INPUT_JSON" || ! -f "$INPUT_JSON" ]]; then
  echo "INPUT_JSON file not found: ${INPUT_JSON:-}" >&2
  exit 1
fi
if [[ -z "$OUTPUT_JSON" ]]; then
  echo "OUTPUT_JSON is required" >&2
  exit 1
fi

BASE="${CIS_BASE_URL%/}"
TMPDIR="$(mktemp -d)"
COOKIE="$TMPDIR/cookie.txt"
# shellcheck source=cis_court_selection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_court_selection.sh"
cleanup() {
  if [[ -n "${DEBUG_CASE_PROCEEDING:-}" ]]; then
    local dbg
    dbg="$(dirname "$OUTPUT_JSON")/../debug/case-proceeding-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$dbg"
    cp -f "$TMPDIR"/* "$dbg"/ 2>/dev/null || true
    echo "Debug files: $dbg" >&2
  fi
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

encrypt_password() {
  printf '%s' "$1" | openssl enc -aes-256-cbc -salt -md md5 -a -A -pass pass:myPassword 2>/dev/null
}

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
if not m:
    raise SystemExit('CIS login failed: no JSON in loginuser response: '+s[:300])
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
            name=attrs.get('name'); typ=(attrs.get('type') or '').lower()
            if name and typ not in ('button','submit','reset','file','image') and not (typ in ('radio','checkbox') and 'checked' not in attrs):
                self.items.append((name, attrs.get('value','')))
        elif tag=='textarea': self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, data):
        if self.in_textarea: self.ta += data
    def handle_endtag(self, tag):
        if tag=='textarea' and self.in_textarea:
            self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
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
if d.get('msgnn','') != 'Unlocked Successfully':
    raise SystemExit(f'CIS unlock failed: {d}')
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

logout_cis() { curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/logout.php" >/dev/null 2>&1 || true; }

rec_count() {
  "$PYTHON_BIN" - "$1" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
if not isinstance(d, list): raise SystemExit('INPUT_JSON must be a JSON array')
print(len(d))
PY
}

item_at() {
  "$PYTHON_BIN" - "$1" "$2" "$3" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
json.dump(d[int(sys.argv[2])], open(sys.argv[3],'w',encoding='utf-8'), ensure_ascii=False)
PY
}

parse_form() {
  local html="$1" out="$2"
  "$PYTHON_BIN" - "$html" "$out" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode
html=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
class FP(HTMLParser):
    def __init__(self):
        super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]; self.sel=None; self.selval=''
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if tag=='form' and attrs.get('id')=='frm': self.in_form=True
        if not self.in_form: return
        if tag=='input':
            n=attrs.get('name')
            if not n: return
            typ=(attrs.get('type') or '').lower()
            if typ in ('button','submit','reset','file','image'): return
            if typ in ('radio','checkbox') and 'checked' not in attrs: return
            self.items.append((n, attrs.get('value','')))
        elif tag=='select': self.sel=attrs.get('name'); self.selval=''
        elif tag=='option' and self.sel and 'selected' in attrs: self.selval=attrs.get('value','')
        elif tag=='textarea': self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, data):
        if self.in_textarea: self.ta += data
    def handle_endtag(self, tag):
        if tag=='select' and self.sel:
            self.items.append((self.sel,self.selval)); self.sel=None; self.selval=''
        elif tag=='textarea' and self.in_textarea:
            self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False
p=FP(); p.feed(html)
open(sys.argv[2],'w',encoding='utf-8').write(urlencode(p.items, doseq=True))
PY
}

case_proceeding_one() {
  local item_json="$1" idx="$2"
  local page="$TMPDIR/page_$idx.html" base_post="$TMPDIR/base_post_$idx.txt"
  local fetch_body="$TMPDIR/fetch_body_$idx.txt" fetch_resp="$TMPDIR/fetch_response_$idx.json"
  local submit_body="$TMPDIR/submit_body_$idx.txt" submit_resp="$TMPDIR/submit_response_$idx.json"
  local select_json="$TMPDIR/stage_court_selection.json" result_json="$TMPDIR/result.json"

  local cnr
  cnr="$("$PYTHON_BIN" - "$item_json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('cis_cnr') or d.get('cino') or '')
PY
)"
  [[ -n "$cnr" ]] || { echo "ERROR: cis_cnr missing" >&2; return 1; }

  curl -sS -b "$COOKIE" -c "$COOKIE" \
    "$BASE/proceedings/case_proceeding.php?linkid=$CASE_PROCEEDING_LINKID&mode=$CASE_PROCEEDING_MODE" > "$page"
  parse_form "$page" "$base_post"

  "$PYTHON_BIN" - "$base_post" "$fetch_body" "$item_json" "$cnr" "$DEFAULT_CASE_TYPE" "$DEFAULT_CASE_TYPE_FLAG" <<'PY'
import json, sys
from urllib.parse import parse_qsl, urlencode
base_post, out, item_f, cnr, default_case_type, default_case_radio = sys.argv[1:7]
item=json.load(open(item_f, encoding='utf-8'))
pairs=parse_qsl(open(base_post, encoding='utf-8').read(), keep_blank_values=True)
d=dict(pairs)
case_type=str(item.get('case_type_code') or item.get('fmm_case_type') or default_case_type)
case_radio=str(item.get('case_type_flag') or item.get('civ_cri') or default_case_radio)
d.update({'case_radio': case_radio, 'fcase_no': f'{case_type}~{cnr}~P', 'fcino': cnr, 'x': 'fetchdata', 'cino': cnr})
open(out,'w',encoding='utf-8').write(urlencode(d, doseq=True))
PY

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/proceedings/case_proceedingajax.php" \
    -H "X-Requested-With: XMLHttpRequest" --data-binary "@$fetch_body" > "$fetch_resp"

  "$PYTHON_BIN" - "$base_post" "$item_json" "$fetch_resp" "$submit_body" "$cnr" "$LOGIN_DATE" \
    "$DEFAULT_CASE_TYPE" "$DEFAULT_CASE_TYPE_FLAG" "$DEFAULT_PURPOSE_CODE" "$DEFAULT_DORMANT_FLAG" "$DEFAULT_COUNSEL_PRESENT" <<'PY'
import datetime as dt, json, re, sys
from urllib.parse import parse_qsl, urlencode
(base_post, item_f, fetch_f, out_f, cnr, login_date, default_case_type, default_case_radio, default_purpose, default_dormant, default_counsel) = sys.argv[1:12]
item=json.load(open(item_f, encoding='utf-8'))
raw=open(fetch_f, encoding='utf-8', errors='ignore').read()
m=re.search(r'\{.*\}', raw, re.S)
if not m:
    raise SystemExit('fetchdata: no JSON: '+raw[:500])
fetch=json.loads(m.group(0))
if fetch.get('errcnr'):
    raise SystemExit('fetchdata returned errcnr: '+str(fetch.get('errcnr')))

def item_val(*keys, default=''):
    for k in keys:
        v=item.get(k)
        if v not in (None, ''):
            return v
    fetched=item.get('_fetched') if isinstance(item.get('_fetched'), dict) else {}
    for k in keys:
        v=fetched.get(k)
        if v not in (None, ''):
            return v
    return default

def fval(*keys, default=''):
    for k in keys:
        v=fetch.get(k)
        if v not in (None, ''):
            return v
    return default

def b(v):
    if isinstance(v, bool): return 'true' if v else 'false'
    return 'true' if str(v).lower() in ('1','true','yes','y','on') else 'false'

def date_val(v, default=''):
    v=str(v or default or '')
    if re.match(r'^\d{2}-\d{2}-\d{4}$', v): return v
    mo=re.match(r'^(\d{4})-(\d{2})-(\d{2})$', v)
    if mo: return f'{mo.group(3)}-{mo.group(2)}-{mo.group(1)}'
    return v

base=parse_qsl(open(base_post,encoding='utf-8').read(), keep_blank_values=True)
override_keys={
 'case_no','fcino','called_count','formaction','ia_no','ia_year','current_date','pending_ia','previous_iahearing','todays_date_flag','prev_purpose','prev_subpurpose',
 'date_of_filing','filing_no','dt_regis','eng_pet_name','eng_res_name','dangling_ia_case_type','allprtyhdn','hiddennoofpages','label_fpet_name','label_fres_name','editflg','hpartyno','htype','hpartyid','fadvcode_comp1','hidPurposePrevFlag','hidTotDelayCnt','date_last_list','hidAuditValid','displayDelayReasonFlag','case_radio','fcase_no','proceeding','exibits','fbusiness','fexibit_text','fdispose','fdormantnext_date','fdormant','fadjcode','fpurpose_code','fsubpurpose_code','fnext_date','ftimeslot_id','fdt_decision','radio_disp_type','fdisp_type','funits','fdt_iafiling','fdt_iaserved','fdt_iahearing','ia_subpurpose','ia_exibits','fia_exibit_text','fia_business','fdt_iaordered','fdisposal_type','fiaunit','globallinkid','hid_roll','cino','case_no1','fpartyno','noofpages','selectAllpresents','x','checkval','civ_cri','dor_sinedie','thro_vc','flagprty','open_tab',
 'fpartyname','fname_salutation','fname','fpet_sex','ffather_flag','ffather_name','fage','fcaste','fadv_name1','fbarcode1','femail','fmobile','foccupation','faddress','fpincode','fphone','fnationality','ffax','fstate_code_off','fdist_code_off','ftown_code_off','fward_code_off','ftaluka_code_off','fvillage_code_off','fvillage1_code_off','fvillage2_code_off'
}
# array-ish keys filtered by prefix below
pairs=[(k,v) for k,v in base if k not in override_keys and not any(k.startswith(p) for p in ('witness[','extrawitness[','witnessfor[','examination[','status313[','appearance_party_no[','selProcessIss[','fissue_date[','fapp_madv_MP[','fapp_adv_cdMP[','present['))]
case_type=str(item_val('case_type_code','fmm_case_type', default=fval('filcase_type','case_type', default=default_case_type)))
case_radio=str(item_val('case_type_flag','civ_cri', default=default_case_radio))
dispose_enabled=(b(item_val('dispose_flag','checkval', default=False)) == 'true')
proceeding_date=date_val(item_val('proceeding_date','current_date', default=login_date or dt.date.today().strftime('%d-%m-%Y')))
next_date='' if dispose_enabled else date_val(item_val('next_hearing_date','next_date','fnext_date', default=''))
current_purpose=str(item_val('current_listing_purpose_code','previous_purpose_code','prev_purpose', default=fval('purpose_next', default='0')))
current_subpurpose=str(item_val('current_listing_subpurpose_code','previous_subpurpose_code','prev_subpurpose', default=fval('purpose_prev', default='0')))
purpose=str(item_val('next_listing_purpose_code','purpose_code','fpurpose_code', default='')).strip()
if not purpose:
    raise SystemExit('case proceeding requires user-filled next_listing_purpose_code/purpose_code/fpurpose_code')
subpurpose=str(item_val('next_listing_subpurpose_code','subpurpose_code','fsubpurpose_code', default=''))
if not subpurpose:
    # User-facing next subpurpose is optional. It is based on the selected next purpose.
    subpurpose=''
decision_date=date_val(item_val('decision_date','fdt_decision', default=''))
disposal_type=str(item_val('disposal_type','fdisp_type', default=''))
disposal_radio_type=str(item_val('disposal_radio_type','radio_disp_type', default='2' if dispose_enabled else ''))
dormant_flag=str(item_val('dormant_flag','fdormant', default='D' if dispose_enabled else default_dormant))
if dispose_enabled:
    missing=[]
    if not decision_date: missing.append('decision_date')
    if not disposal_type: missing.append('disposal_type')
    if missing:
        raise SystemExit('disposal case proceeding requires: '+', '.join(missing))

known=[
 ('case_no', str(fval('case_no', default=''))),
 ('fcino', cnr),
 ('called_count', str(item_val('called_count', default='0'))),
 ('formaction', '1'),
 ('ia_no',''), ('ia_year',''),
 ('current_date', proceeding_date),
 ('pending_ia', str(fval('pending_ia', default='N'))),
 ('previous_iahearing',''), ('todays_date_flag',''),
 ('prev_purpose', current_purpose),
 ('prev_subpurpose', current_subpurpose),
 ('date_of_filing', str(fval('date_of_filing', default=''))),
 ('filing_no', str(fval('filing_no', default=''))),
 ('dt_regis', str(fval('dt_regis', default=''))),
 ('eng_pet_name', str(fval('eng_pet_name','pet_name', default=''))),
 ('eng_res_name', str(fval('eng_res_name','res_name', default=''))),
 ('dangling_ia_case_type',''), ('allprtyhdn',''), ('hiddennoofpages',''), ('label_fpet_name',''), ('label_fres_name',''), ('editflg',''), ('hpartyno',''), ('htype',''), ('hpartyid',''), ('fadvcode_comp1',''),
 ('hidPurposePrevFlag', str(fval('purpose_flag','hidPurposePrevFlag', default='0'))),
 ('hidTotDelayCnt', str(fval('delayCnt','hidTotDelayCnt', default=''))),
 ('date_last_list', str(fval('date_last_list', default=''))),
 ('hidAuditValid', str(item_val('hid_audit_valid','hidAuditValid', default='0'))),
 ('displayDelayReasonFlag', str(fval('displayDelayReasonFlag', default='HIDE'))),
 ('case_radio', case_radio),
 ('fcase_no', f'{case_type}~{cnr}~P'),
 ('proceeding', str(item_val('proceeding', default=''))),
 ('exibits', str(item_val('exhibits','exibits', default=''))),
 ('fbusiness', str(item_val('business_remarks','fbusiness', default=''))),
 ('fexibit_text', str(item_val('exhibit_text','fexibit_text', default=''))),
]
if dispose_enabled:
    known.append(('fdispose','on'))
known.extend([
 ('fdormantnext_date', str(item_val('dormant_next_date','fdormantnext_date', default=''))),
 ('fdormant', dormant_flag),
 ('fadjcode', str(item_val('adjournment_code','fadjcode', default=''))),
 ('fpurpose_code', purpose),
 ('fsubpurpose_code', subpurpose),
 ('fnext_date', next_date),
 ('ftimeslot_id', str(item_val('timeslot_id','ftimeslot_id', default=''))),
 ('fdt_decision', decision_date),
])
if dispose_enabled:
    known.append(('radio_disp_type', disposal_radio_type))
known.extend([
 ('fdisp_type', disposal_type),
 ('funits', str(item_val('units','funits', default=''))),
 ('fdt_iafiling',''), ('fdt_iaserved',''), ('fdt_iahearing',''), ('ia_subpurpose',''), ('ia_exibits',''), ('fia_exibit_text',''), ('fia_business',''), ('fdt_iaordered',''), ('fdisposal_type',''), ('fiaunit',''),
 # HAR had a duplicate empty formaction later in the serialized form. Keep this to mirror browser serialize.
 ('formaction',''),
 ('globallinkid', str(item_val('global_link_id','globallinkid', default='261'))),
 ('hid_roll', str(item_val('role','hid_roll', default='1'))),
 ('cino',''), ('case_no1',''), ('fpartyno',''),
])
pairs.extend(known)

witnesses=item.get('witnesses')
if not isinstance(witnesses, list) or not witnesses:
    witnesses=[{}]
for idx,w in enumerate(witnesses, start=1):
    if not isinstance(w, dict): w={}
    pairs.extend([
      (f'witness[{idx}]', str(w.get('present') or '1') + '~~~'),
      (f'extrawitness[{idx}]', str(w.get('extra') or '')),
      (f'witnessfor[{idx}]', str(w.get('for') or w.get('witness_for') or '1')),
      (f'examination[{idx}]', str(w.get('examination') or '')),
      ('noofpages', str(w.get('no_of_pages') or '')),
    ])

appearance_rows=item.get('appearance_rows')
if not isinstance(appearance_rows, list) or not appearance_rows:
    legacy=[w for w in witnesses if isinstance(w, dict) and any(k in w for k in ('appearance_party_no','process_issue','selProcessIss','issue_date','fissue_date','advocate_name','advocate_code'))]
    appearance_rows=legacy or [{}]
for idx,row in enumerate(appearance_rows, start=1):
    if not isinstance(row, dict): row={}
    name_idx=str(row.get('row') or row.get('index') or idx)
    pairs.extend([
      (f'appearance_party_no[{name_idx}]', str(row.get('appearance_party_no') or row.get('party_no') or '0')),
      (f'selProcessIss[{name_idx}]', str(row.get('process_issue') or row.get('selProcessIss') or '')),
      (f'fissue_date[{name_idx}]', str(row.get('issue_date') or row.get('fissue_date') or '')),
      (f'fapp_madv_MP[{name_idx}]', str(row.get('advocate_name') or row.get('fapp_madv_MP') or '')),
      (f'fapp_adv_cdMP[{name_idx}]', str(row.get('advocate_code') or row.get('fapp_adv_cdMP') or '0')),
    ])

status313_rows=item.get('status313_rows')
if not isinstance(status313_rows, list) or not status313_rows:
    if isinstance(item.get('appearance_rows'), list) and item.get('appearance_rows'):
        status313_rows=[{'row': (r.get('row') if isinstance(r, dict) else i), 'status_313': (r.get('status_313') if isinstance(r, dict) else '')} for i,r in enumerate(item.get('appearance_rows'), start=1)]
    else:
        status313_rows=[{'row': idx, 'status_313': (w.get('status_313') if isinstance(w, dict) else '')} for idx,w in enumerate(witnesses, start=1)]
for idx,row in enumerate(status313_rows, start=1):
    if not isinstance(row, dict): row={}
    name_idx=str(row.get('row') or row.get('index') or idx)
    pairs.append((f'status313[{name_idx}]', str(row.get('status_313') or row.get('status313') or '1')))

pairs.extend([
 ('fpartyname',''), ('fname_salutation',''), ('fname',''), ('fpet_sex', str(item_val('petitioner_gender_code','fpet_sex', default='1'))), ('ffather_flag',''), ('ffather_name',''), ('fage',''), ('fcaste',''), ('fadv_name1',''), ('fbarcode1',''), ('femail',''), ('fmobile',''), ('foccupation',''), ('faddress',''), ('fpincode',''), ('fphone',''), ('fnationality',''), ('ffax',''), ('fstate_code_off',''), ('fdist_code_off',''), ('ftown_code_off',''), ('fward_code_off',''), ('ftaluka_code_off',''), ('fvillage_code_off',''), ('fvillage1_code_off',''), ('fvillage2_code_off','')
])

present=item.get('counsel_present', default_counsel)
if isinstance(present, str):
    present=[present] if present else []
if present:
    if b(item_val('select_all_present','selectAllpresents', default=False)) == 'true':
        pairs.append(('selectAllpresents','on'))
    for p in present:
        pairs.append(('present[]', str(p)))

pairs.extend([
 ('x','submitdata'),
 ('checkval', 'true' if dispose_enabled else 'false'),
 ('civ_cri', case_radio),
 ('dor_sinedie', b(item_val('dor_sinedie', default=False))),
 ('thro_vc', b(item_val('through_vc','thro_vc', default=False))),
 ('flagprty', str(item_val('flag_party','flagprty', default=''))),
 ('open_tab', str(item_val('open_tab', default=''))),
])
open(out_f,'w',encoding='utf-8').write(urlencode(pairs, doseq=True))
PY

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/proceedings/case_proceedingajax.php" \
    -H "X-Requested-With: XMLHttpRequest" --data-binary "@$submit_body" > "$submit_resp"

  "$PYTHON_BIN" - "$item_json" "$cnr" "$fetch_resp" "$submit_resp" "$select_json" "$result_json" <<'PY'
import json, re, sys
item=json.load(open(sys.argv[1], encoding='utf-8'))
cnr, fetch_f, submit_f, select_f, out_f = sys.argv[2:7]
def parse(path):
    s=open(path, encoding='utf-8', errors='ignore').read()
    m=re.search(r'\{.*\}', s, re.S)
    if m:
        try: return json.loads(m.group(0))
        except Exception: pass
    return {'_raw': s[:1000]}
fetch=parse(fetch_f); submit=parse(submit_f)
try:
    court_selection=json.load(open(select_f, encoding='utf-8'))
except Exception:
    court_selection={}
def truthy(v):
    if isinstance(v, bool): return v
    return str(v).strip().lower() in ('1','true','yes','y','on')
msg=str(submit.get('msg2') or submit.get('msg') or '')
disposed=truthy(item.get('dispose_flag')) or item.get('type') == 'disposal'
success=('Case Proceeding successful' in msg) or ('Case Disposed successfully' in msg)
out={
  'external_id': item.get('external_id') or item.get('external_filing_id') or ('PROC-'+cnr),
  'cis_cnr': cnr,
  'court_no': str(item.get('court_no') or item.get('fcourt_no') or item.get('target_court_no') or item.get('allocated_court_no') or court_selection.get('court_no') or ''),
  'court_selection_status': court_selection.get('court_selection_status') or court_selection.get('status'),
  'status': 'success' if success else 'failed',
  'disposed': disposed,
  'proceeding_date': item.get('proceeding_date'),
  'next_hearing_date': item.get('next_hearing_date'),
  'decision_date': item.get('decision_date') or item.get('fdt_decision'),
  'next_listing_purpose_code': item.get('next_listing_purpose_code') or item.get('purpose_code') or item.get('fpurpose_code'),
  'disposal_type': item.get('disposal_type') or item.get('fdisp_type'),
  'fetched_case_no': fetch.get('case_no'),
  'submit_response': submit,
}
if not success:
    out['error']='case_proceedingajax submit did not return a success message'
open(out_f,'w',encoding='utf-8').write(json.dumps(out, ensure_ascii=False, indent=2))
PY

  cat "$result_json"
}

PENDING_JSON="$TMPDIR/pending.json"
cp "$INPUT_JSON" "$PENDING_JSON"
COUNT="$(rec_count "$PENDING_JSON")"

if [[ "$COUNT" == "0" ]]; then
  echo "No case-proceeding records."
  exit 0
fi

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "case_proceeding"
"$PYTHON_BIN" - "$TMPDIR/stage_court_selection.json" "${COURT_NO:-}" "${CIS_COURT_SELECTION_STATUS:-}" <<'PY'
import json, sys
out={'court_no': sys.argv[2], 'court_selection_status': sys.argv[3]}
json.dump(out, open(sys.argv[1], 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
for i in $(seq 0 $((COUNT-1))); do
  ITEM_JSON="$TMPDIR/item_$i.json"
  RESULT_JSON="$TMPDIR/result_$i.json"
  item_at "$PENDING_JSON" "$i" "$ITEM_JSON"
  echo "Processing case proceeding [$((i+1))/$COUNT] ..." >&2
  set +e
  ( set -e; case_proceeding_one "$ITEM_JSON" "$i" ) > "$RESULT_JSON"
  RC=$?
  set -e
  if [[ "$RC" -ne 0 ]]; then
    rm -f "$RESULT_JSON"
    ERR="$TMPDIR/error_$i.json"
    "$PYTHON_BIN" - "$ITEM_JSON" "$ERR" <<'PY'
import json, sys
r=json.load(open(sys.argv[1], encoding='utf-8'))
json.dump({'external_id':r.get('external_id') or r.get('external_filing_id'),'cis_cnr':r.get('cis_cnr'),'status':'failed','error':'CIS case-proceeding failed; see bridge logs'}, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False)
PY
  fi
done
logout_cis
echo "CIS logout complete." >&2

mkdir -p "$(dirname "$OUTPUT_JSON")"
"$PYTHON_BIN" - "$TMPDIR" "$OUTPUT_JSON" <<'PY'
import json, os, glob, sys
results=[]
def load_safe(f):
    try:
        if os.path.getsize(f)==0: return {'status':'failed','error':f'empty result file {os.path.basename(f)}'}
        return json.load(open(f, encoding='utf-8'))
    except Exception as e:
        return {'status':'failed','error':f'unreadable result file {os.path.basename(f)}: {e}'}
for f in sorted(glob.glob(os.path.join(sys.argv[1],'result_*.json'))): results.append(load_safe(f))
for f in sorted(glob.glob(os.path.join(sys.argv[1],'error_*.json'))): results.append(load_safe(f))
json.dump(results, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False, indent=2)
print(f"Wrote {len(results)} results to {sys.argv[2]}")
PY
