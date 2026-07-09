#!/usr/bin/env bash
set -euo pipefail

# Case-registration CIS bridge.
#
# HAR-backed final registration flow (walkthro-23062026/168.144.70.80.har):
#   GET  registration/registration.php?linkid=74&mode=1&cino=<CNR>
#   POST registration/registrationajax.php x=appellateCourt
#   POST registration/registrationajax.php x=showdetails&filingno=<CNR>&mode_of_filing=2
#   POST registration/registrationajax.php <serialized frm>&flag=Register&ftab_status=P~R~E~A~F
#
# The browser also saves intermediate tabs with flag=Pet/Res/Extra/Act/Policestn.
# For bridge mode we post the final Register payload directly, using showdetails + input
# JSON to populate the same serialized form fields.
#
# Expected readable input JSON (array):
#   [
#     {
#       "external_filing_id": "APP-123",
#       "cis_cnr": "HRPK020007022026",
#       "cis_filing_no_numeric": "205500000232026",
#       "case_type_code": "55",
#       "ci_cri": "3",
#       "registration_date": "26-06-2026",
#       "listing_date": "26-06-2026",
#       "purpose_code": "6",
#       "complainant_name": "...",
#       "accused_name": "...",
#       "cause_of_action": "Complaint under Section 138...",
#       "jurisdiction_value": "100000",
#       "amount": "100000.00",
#       "acts": [{"act_name":"Negotiable Instruments Act", "hidden_act_code":"18810260099001 ", "act_code":"732", "section_code":"138"}]
#     }
#   ]
#
# CIS-form field names (fpet_name, fres_name, fdt_regis, etc.) are still accepted
# for backward compatibility, but new callers should prefer the readable names.

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

REGISTRATION_LINKID="${REGISTRATION_LINKID:-74}"
REGISTRATION_MODE="${REGISTRATION_MODE:-1}"
DEFAULT_PURPOSE_CODE="${DEFAULT_PURPOSE_CODE:-6}"

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

register_one() {
  local item_json="$1"
  local page="$TMPDIR/reg_page.html" base_post="$TMPDIR/base_post.txt" appellate_resp="$TMPDIR/appellate.json" show_resp="$TMPDIR/showdetails.json" submit_body="$TMPDIR/submit_body.txt" submit_resp="$TMPDIR/submit.json" result_json="$TMPDIR/result.json"
  local cnr external_id mode_of_filing
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
  mode_of_filing="$($PYTHON_BIN - "$item_json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8')); print(d.get('mode_of_filing') or '2')
PY
)"
  [[ -n "$cnr" ]] || { echo "ERROR: cis_cnr missing" >&2; return 1; }

  curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/registration/registration.php?linkid=$REGISTRATION_LINKID&mode=$REGISTRATION_MODE&cino=$cnr" > "$page"
  "$PYTHON_BIN" - "$page" "$base_post" <<'PY'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode
html=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
class FP(HTMLParser):
    def __init__(self): super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]; self.sel=None; self.selval=''
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if tag=='form' and attrs.get('id')=='frm': self.in_form=True
        if not self.in_form: return
        if tag=='input':
            n=attrs.get('name'); typ=(attrs.get('type') or '').lower()
            if not n or typ in ('button','submit','reset','file','image'): return
            if typ in ('radio','checkbox') and 'checked' not in attrs: return
            self.items.append((n, attrs.get('value','')))
        elif tag=='select': self.sel=attrs.get('name'); self.selval=''
        elif tag=='option' and self.sel and 'selected' in attrs: self.selval=attrs.get('value','')
        elif tag=='textarea': self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, d):
        if self.in_textarea: self.ta+=d
    def handle_endtag(self, tag):
        if tag=='select' and self.sel: self.items.append((self.sel,self.selval)); self.sel=None; self.selval=''
        elif tag=='textarea' and self.in_textarea: self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False
p=FP(); p.feed(html)
d={}
for k,v in p.items: d[k]=v
open(sys.argv[2],'w',encoding='utf-8').write(urlencode(list(d.items())))
PY

  # HAR calls this before showdetails. Its values are also included in showdetails on most CIS builds,
  # but keep the call so server/session behaviour matches the UI.
  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/registrationajax.php" \
    --data-urlencode "x=appellateCourt" > "$appellate_resp" || true

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/registrationajax.php" \
    --data-urlencode "x=showdetails" --data-urlencode "filingno=$cnr" --data-urlencode "mode_of_filing=$mode_of_filing" > "$show_resp"

  "$PYTHON_BIN" - "$base_post" "$item_json" "$show_resp" "$appellate_resp" "$submit_body" "$LOGIN_DATE" "$DEFAULT_PURPOSE_CODE" <<'PY'
import datetime, json, os, re, sys
from urllib.parse import parse_qsl, urlencode, unquote_plus
base_post, item_f, show_f, appellate_f, out_f, login_date, default_purpose = sys.argv[1:8]
base=dict(parse_qsl(open(base_post, encoding='utf-8').read(), keep_blank_values=True))
item=json.load(open(item_f, encoding='utf-8'))
def parse_json(path):
    raw=open(path, encoding='utf-8', errors='ignore').read(); m=re.search(r'\{.*\}', raw, re.S)
    if not m: return {}
    try: return json.loads(m.group(0))
    except Exception: return {}
show=parse_json(show_f); appellate=parse_json(appellate_f)
# Optional exact-replay mode for HAR/debug use. This is deliberately not the
# normal API contract because the browser serialize() body is deployment-specific,
# mostly blanks, and contains duplicate keys/order that JSON objects cannot safely
# represent. If exact_replay=true is present, post it exactly as supplied.
if item.get('cis_form_urlencoded') and item.get('exact_replay'):
    open(out_f, 'w', encoding='utf-8').write(str(item['cis_form_urlencoded']))
    raise SystemExit(0)
def clean_default(default):
    return None if default is None else str(default)

def item_val(*keys, default=''):
    for k in keys:
        if k in item and item.get(k) not in (None, ''):
            return str(item.get(k))
    return clean_default(default)

def show_val(*keys, default=''):
    for k in keys:
        if k in show and show.get(k) not in (None, ''):
            return str(show.get(k))
    return clean_default(default)

def val(key, *alts, default=''):
    # Prefer explicit input aliases over showdetails defaults, then fall back to
    # showdetails. This lets readable JSON intentionally override CIS defaults.
    keys=(key,)+alts
    got=item_val(*keys, default=None)
    if got is not None:
        return got
    got=show_val(*keys, default=None)
    if got is not None:
        return got
    return str(default)

cnr=item_val('cis_cnr', 'ffiling_no', default='')
reg_dt=item_val('registration_date', 'registration_dt', 'fdt_regis', default=login_date)
list_dt=item_val('listing_date', 'listing_dt', 'flisting_date', default=show_val('date_next_list', default=reg_dt))
purpose=str(item_val('purpose_code', 'fpurpose_code', default=show_val('purpose_next', default=default_purpose)))
year=str(item_val('registration_year', 'freg_year', default=show_val('reg_year', default=(reg_dt.split('-')[-1] if '-' in reg_dt else datetime.date.today().year))))
case_type=str(item_val('case_type_code', 'cis_case_type_code', 'fmm_case_type', default=show_val('filcase_type', 'case_type', default='55')))
ci_cri=str(item_val('ci_cri', 'fci_cri', default=show_val('ci_cri', default='3')))
mode_of_filing=str(item_val('mode_of_filing', default=appellate.get('mode_of_filing') or '2'))
now=item_val('server_time', 'filing_time', 'ftime_of_filing', default=datetime.datetime.now().strftime('%H:%M:%S'))

# Merge fields that registration.js copies from showdetails into #frm. Values are
# HAR-aligned for the final Register post (entry 246): ftab_status=P~R~E~A~F,
# fpolice_private=2, fpurpose_code=6, flag=Register.
d=base.copy()
d.update({
 'fupdateservertime': now,
 'cino_fromobjection': str(item.get('cino_fromobjection') or ''),
 'formaction': '1',
 'fci_cri': ci_cri,
 'macp': val('macp', default='N'),
 'filingno': str(item_val('cis_filing_no_numeric', 'filingno', default=show.get('filing_no') or '')),
 'ffilcase_type': case_type,
 'ffiling_no_type': case_type,
 'mode_of_filing': mode_of_filing,
 'hide_partyname': str(item.get('hide_partyname') or appellate.get('hide_partyname') or show.get('hide_partyname') or 'N'),
 'app_court_type': str(item.get('app_court_type') or appellate.get('app_court_type') or show.get('app_court_type') or 'N'),
 'ftab_status': str(item.get('ftab_status') or show.get('tab_status') or 'P~R~E~A~F'),
 'role': str(item.get('role') or '1'),
 'sessiondate': login_date,
 'cino': str(item.get('cino') or ''),
 'prevcino': str(item.get('prevcino') or ''),
 'fadvcode_comp1': val('fadvcode_comp1','complainant_advocate_code','pet_adv_cd', default='0'),
 'fadvcode_comp2': val('fadvcode_comp2','accused_advocate_code','respondent_advocate_code','res_adv_cd', default='0'),
 'fmatter_type': val('fmatter_type','matter_type', default='0'),
 'orgname_fromcourt': str(item.get('orgname_fromcourt') or ''),
 'lorgname_fromcourt': str(item.get('lorgname_fromcourt') or ''),
 'ffiling_no': cnr,
 'freg_no_comp': str(item.get('freg_no_comp') or 'NaN'),
 'fpet_salutation': val('fpet_salutation','complainant_salutation','pet_salutation', default='1'),
 'fpet_name': val('fpet_name','complainant_name','pet_name'),
 'flpet_name': val('flpet_name','complainant_local_name','lpet_name','complainant_name'),
 'fpetadd': val('fpetadd','complainant_address','petadd'),
 'flpetadd': val('flpetadd','complainant_local_address','lpetadd','complainant_address'),
 'fpet_add2': val('fpet_add2','complainant_address_line2','petadd2'),
 'fpet_age': val('fpet_age','complainant_age','pet_age'),
 'fpet_sex': val('fpet_sex','complainant_gender_code','pet_sex', default='1').strip() or '1',
 'fpet_father_flag': val('fpet_father_flag','complainant_father_flag','pet_father_flag', default='1'),
 'fpet_father_name': val('fpet_father_name','complainant_father_name','pet_father_name'),
 'fpet_inperson': val('fpet_inperson','complainant_inperson','pet_inperson', default='Y'),
 'fadv_type1': val('fadv_type1','complainant_advocate_type', default='R'),
 'fadv_name1': val('fadv_name1','complainant_advocate_name','pet_adv'),
 'fbarcode1': val('fbarcode1','complainant_advocate_barcode','petbar_code'),
 'fpet_email': val('fpet_email','complainant_email','pet_email'),
 'fpet_mobile': val('fpet_mobile','complainant_mobile','pet_mobile'),
 'fpet_pincode': val('fpet_pincode','complainant_pincode','pet_pincode'),
 'fpet_nationality': val('fpet_nationality','complainant_nationality','pet_nationality'),
 'fstate_code_pet_off': val('fstate_code_pet_off','complainant_state_code','state_code_pet_off', default='6'),
 'fdist_code_pet_off': val('fdist_code_pet_off','complainant_district_code','dist_code_pet_off'),
 'ftaluka_code_pet_off': val('ftaluka_code_pet_off','complainant_taluka_code','taluka_code_pet_off'),
 'fres_salutation': val('fres_salutation','accused_salutation','respondent_salutation','res_salutation', default='1'),
 'fres_name': val('fres_name','accused_name','respondent_name','res_name'),
 'flres_name': val('flres_name','accused_local_name','respondent_local_name','lres_name','accused_name','respondent_name'),
 'fresadd': val('fresadd','accused_address','respondent_address','resadd'),
 'flresadd': val('flresadd','accused_local_address','respondent_local_address','lresadd','accused_address','respondent_address'),
 'fres_add2': val('fres_add2','accused_address_line2','respondent_address_line2','resadd2'),
 'fres_age': val('fres_age','accused_age','respondent_age','res_age'),
 'fres_sex': val('fres_sex','accused_gender_code','respondent_gender_code','res_sex', default='1').strip() or '1',
 'fres_father_flag': val('fres_father_flag','accused_father_flag','respondent_father_flag','res_father_flag', default='1'),
 'fres_father_name': val('fres_father_name','accused_father_name','respondent_father_name','res_father_name'),
 'fadv_type2': val('fadv_type2','accused_advocate_type','respondent_advocate_type', default='R'),
 'fadv_name2': val('fadv_name2','accused_advocate_name','respondent_advocate_name','res_adv'),
 'fbarcode2': val('fbarcode2','accused_advocate_barcode','respondent_advocate_barcode','resbar_code'),
 'fres_email': val('fres_email','accused_email','respondent_email','res_email'),
 'fres_mobile': val('fres_mobile','accused_mobile','respondent_mobile','res_mobile'),
 'fres_pincode': val('fres_pincode','accused_pincode','respondent_pincode','res_pincode'),
 'fres_nationality': val('fres_nationality','accused_nationality','respondent_nationality','res_nationality'),
 'fstate_code_res_off': val('fstate_code_res_off','accused_state_code','respondent_state_code','state_code_res_off', default='6'),
 'fdist_code_res_off': val('fdist_code_res_off','accused_district_code','respondent_district_code','dist_code_res_off'),
 'ftaluka_code_res_off': val('ftaluka_code_res_off','accused_taluka_code','respondent_taluka_code','taluka_code_res_off'),
 'fstate_id3': val('fstate_id3','case_state_code', default='6'),
 'fdist_code3': val('fdist_code3','case_district_code','case_dist_code', default='1'),
 'ftaluka_code3': val('ftaluka_code3','case_taluka_code', default='2'),
 'filing_type': val('filing_type', default='2'),
 'fpolice_private': val('fpolice_private','police_private', default='2'),
 'fpolicestation_state_id': val('fpolicestation_state_id','police_state_code', default='6'),
 'fdist_code_police': val('fdist_code_police','police_district_code','case_district_code','case_dist_code', default='1'),
 'fpolice_st_code': val('fpolice_st_code','police_station_code','police_st_code'),
 'ffir_no': val('ffir_no','fir_no'),
 'ffir_year': val('ffir_year','fir_year'),
 'ffir_date': val('ffir_date','fir_date'),
 'fdt_of_offense': val('fdt_of_offense','offense_date','dishonour_date'),
 'foffense_date': val('foffense_date','offense_date','dishonour_date'),
 'fcauseofaction_cri': val('fcauseofaction_cri','cause_of_action','causeofaction'),
 'flcauseofaction_cri': val('flcauseofaction_cri','local_cause_of_action','cause_of_action','lcauseofaction','causeofaction'),
 'fcauseofaction_ci': val('fcauseofaction_ci','cause_of_action','causeofaction'),
 'frelief_offense': val('frelief_offense','relief','relief_offense'),
 'fjuri_value': val('fjuri_value','jurisdiction_value','juri_value','cheque_amount','amount', default=''),
 'famount': val('famount','amount','cheque_amount', default='50.00'),
 'fdate_of_filing': val('fdate_of_filing','filing_date','date_of_filing', default=reg_dt),
 'ftime_of_filing': val('ftime_of_filing','filing_time','time_of_filing', default=now),
 'radiotype': str(item.get('radiotype') or '2'),
 'searchcaveat': str(item.get('searchcaveat') or '1'),
 'caveatorname': val('caveatorname','accused_name','respondent_name','res_name'),
 'caveateename': val('caveateename','complainant_name','pet_name'),
 'rcaveator': str(item.get('rcaveator') or '1'),
 'filing_type1': str(item.get('filing_type1') or '2'),
 'fcase_type_reg': case_type,
 'freg_no': str(item.get('freg_no') or 'NaN'),
 'freg_year': year,
 'fdt_regis': reg_dt,
 'freasonregisdate': str(item.get('freasonregisdate') or ''),
 'flisting_date': list_dt,
 'fpurpose_code': purpose,
 'fsubpurpose_code': str(item.get('fsubpurpose_code') or ''),
 # Police-station/MVC component fields observed in HAR final Register post.
 'fitem_no': str(item.get('fitem_no') or '1'),
 'fstate_id': val('fstate_id','case_state_code', default='6'),
 'fdist_code': val('fdist_code','case_district_code','case_dist_code', default='1'),
 'ftaluka_code': val('ftaluka_code','case_taluka_code', default='2'),
 'injurytype': val('injurytype','injury_type', default='4'),
 'ftype': val('ftype', default='2'),
 'fstate_code_dvtComp': val('fstate_code_dvtComp','case_state_code', default='6'),
 'ftaluka_code_extra_off': val('ftaluka_code_extra_off','case_taluka_code', default='2'),
 'ftaluka_code_extra_alt': val('ftaluka_code_extra_alt','case_taluka_code', default='2'),
})
def is_org_party(prefix, org_key, form_org_key):
    party_type = str(item_val(f'{prefix}_party_type', default='')).strip().lower()
    return party_type in {'organization', 'organisation', 'org', 'company'} or item_val(org_key, form_org_key, default='') not in ('', None)

if is_org_party('complainant', 'complainant_org_id', 'fpetorg_type'):
    complainant_org_id = item_val('complainant_org_id', 'fpetorg_type', default='')
    d.update({
        'fpetorg_check': '1',
        'fpetorg_type': complainant_org_id,
        'hidden_fpetorg_type': item_val('hidden_fpetorg_type', default=complainant_org_id),
        'fpet_extracount': item_val('complainant_extra_count', 'fpet_extracount', default=''),
    })

if is_org_party('accused', 'accused_org_id', 'fresorg_type'):
    accused_org_id = item_val('accused_org_id', 'fresorg_type', default='')
    d.update({
        'fresorg_check': '1',
        'fresorg_type': accused_org_id,
        'hidden_fresorg_type': item_val('hidden_fresorg_type', default=accused_org_id),
        'fres_extracount': item_val('accused_extra_count', 'fres_extracount', default=''),
    })

# Advocate values are sometimes supplied URL-encoded from HAR/input JSON
# (e.g. Bhagat+Jit+Singh, P%2F785%2F1988). Decode once; urlencode(pairs)
# below re-encodes them in the CIS POST body as Bhagat+Jit+Singh / P%2F...
for _adv_key in ('fadv_name1', 'fbarcode1', 'fadv_name2', 'fbarcode2', 'fadv_name3', 'fbarcode3'):
    if d.get(_adv_key):
        d[_adv_key] = unquote_plus(str(d[_adv_key])).strip()
# Act/section arrays. Field names in HAR request params appear URL-encoded by the
# browser export, but the actual HTTP body is normal form encoding of fdispactcode[].
pairs=[(k,v) for k,v in d.items() if k not in {'fdispactcode[]','fhiddactcode[]','factcode[]','factsection_code[]'}]
acts=item.get('acts') or []
if acts and isinstance(acts, list) and isinstance(acts[0], dict):
    default_act = {
        'act_display': 'Negotiable Instruments Act-732',
        'hidden_act_code': '18810260099001',
        'act_code': '732',
        'section_code': '138',
    }
    norm_acts=[default_act]
    seen={(default_act['hidden_act_code'], default_act['act_code'], default_act['section_code'].rstrip(','))}
    for a in acts:
        row={
            'act_display': a.get('act_display') or a.get('act_name') or a.get('name') or '',
            'hidden_act_code': a.get('hidden_act_code') or a.get('hiddactcode') or a.get('national_code') or '',
            'act_code': a.get('act_code') or a.get('code') or a.get('actvalue') or '',
            'section_code': a.get('section_code') or a.get('section') or a.get('secvalue') or '',
        }
        key=(row['hidden_act_code'], row['act_code'], str(row['section_code']).rstrip(','))
        if key not in seen:
            seen.add(key)
            norm_acts.append(row)
    act_names=[a['act_display'] for a in norm_acts]
    hids=[a['hidden_act_code'] for a in norm_acts]
    actcodes=[a['act_code'] for a in norm_acts]
    sections=[a['section_code'] for a in norm_acts]
else:
    act_names=item.get('fdispactcode') or item.get('fdispactcodes') or item.get('act_names') or ['Negotiable Instruments Act']
    hids=item.get('fhiddactcode') or item.get('hidden_act_codes') or ['18810260099001 ']
    actcodes=item.get('factcode') or item.get('act_codes') or ['732']
    sections=item.get('factsection_code') or item.get('section_codes') or ['138']
for valx in act_names: pairs.append(('fdispactcode[]', str(valx)))
for valx in hids: pairs.append(('fhiddactcode[]', str(valx)))
for valx in actcodes: pairs.append(('factcode[]', str(valx)))
for valx in sections: pairs.append(('factsection_code[]', str(valx).rstrip(',')))
pairs += [('flag','Register'), ('submitdata',str(item.get('submitdata') or 'undefined')), ('globallinkid',str(item.get('globallinkid') or show.get('globallinkid') or 'undefined')), ('fdist_code_mvc',str(item.get('fdist_code_mvc') or 'undefined'))]
open(out_f,'w',encoding='utf-8').write(urlencode(pairs, doseq=True))
PY

  curl -sS -b "$COOKIE" -c "$COOKIE" -X POST "$BASE/registration/registrationajax.php" --data-binary "@$submit_body" > "$submit_resp"

  "$PYTHON_BIN" - "$item_json" "$external_id" "$cnr" "$show_resp" "$submit_resp" "$result_json" <<'PY'
import json, re, sys
item=json.load(open(sys.argv[1], encoding='utf-8'))
external_id, cnr, show_f, submit_f, out_f = sys.argv[2:7]
def parse(path):
    s=open(path, encoding='utf-8', errors='ignore').read(); m=re.search(r'\{.*\}', s, re.S)
    if m:
        try: return json.loads(m.group(0))
        except Exception: pass
    return {'_raw': s[:1000]}
show=parse(show_f); submit=parse(submit_f)
success = submit.get('success') in ('Yes','Y',True)
out={
 'external_id': external_id or item.get('external_id') or item.get('external_filing_id'),
 'cis_cnr': cnr,
 'status': 'success' if success else 'failed',
 'registered_case_number': submit.get('case_number') or submit.get('reg_no') or None,
 'registered_case_label': (re.search(r'Case No\.:-([^<]+)', str(submit.get('msg2',''))) or [None, None])[1],
 'showdetails_response': show,
 'submit_response': submit,
}
if not success: out['error']=submit.get('msg2') or submit.get('msg1') or 'registrationajax did not return success=Yes'
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
[[ "$COUNT" == "0" ]] && { echo "No registration records."; exit 0; }
login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "registration"
for i in $(seq 0 $((COUNT-1))); do
  ITEM_JSON="$TMPDIR/item_$i.json"; RESULT_JSON="$TMPDIR/result_$i.json"
  "$PYTHON_BIN" - "$PENDING_JSON" "$i" "$ITEM_JSON" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8')); json.dump(d[int(sys.argv[2])], open(sys.argv[3],'w',encoding='utf-8'), ensure_ascii=False)
PY
  echo "Registering case [$((i+1))/$COUNT] ..." >&2
  set +e
  ( set -e; register_one "$ITEM_JSON" ) > "$RESULT_JSON"
  REGISTER_RC=$?
  set -e
  if [[ "$REGISTER_RC" -eq 0 ]]; then $FILE_MODE || post_callback "$RESULT_JSON"; else
    rm -f "$RESULT_JSON"
    ERR="$TMPDIR/error_$i.json"
    "$PYTHON_BIN" - "$ITEM_JSON" "$ERR" <<'PY'
import json, sys
r=json.load(open(sys.argv[1], encoding='utf-8'))
json.dump({'external_id':r.get('external_id') or r.get('external_filing_id'),'cis_cnr':r.get('cis_cnr'),'status':'failed','error':'CIS registration failed; see bridge logs'}, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False)
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
