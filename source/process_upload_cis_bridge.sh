#!/usr/bin/env bash
set -euo pipefail

# Final process-upload CIS bridge.
#
# HAR-backed flow (walkthro-23062026/process-upload.har + proceedings/process_upload.js):
#   GET  proceedings/process_upload.php?linkid=656&mode=0
#   POST proceedings/process_upload_ajax.php x=fetchcasedetails
#   POST proceedings/process_upload_ajax.php x=loadnoticesummons
#   POST proceedings/process_upload_ajax.php x=fetchPetitioner
#   POST proceedings/process_upload_ajax.php x=fetchpartydetails
#   POST proceedings/process_upload_ajax.php multipart x=submitData, fmyfile=@PDF
#
# Minimal input record:
#   {
#     "external_id": "trial9-process-upload",
#     "cis_cnr": "HRPK020007182026",
#     "notice_id": "200001",
#     "party_type": "2",
#     "address_type": "M",
#     "file_path": "D:/path/to/process.pdf"
#   }
# Optional disambiguators when party_type returns multiple rows:
#   party_value / res_pet_wit_table, party_name, party_no, party_kind

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
PROCESS_UPLOAD_LINKID="${PROCESS_UPLOAD_LINKID:-656}"
PROCESS_UPLOAD_MODE="${PROCESS_UPLOAD_MODE:-0}"
DEFAULT_PROCESS_UPLOAD_CASE_RADIO="${DEFAULT_PROCESS_UPLOAD_CASE_RADIO:-3}"
DEFAULT_PROCESS_UPLOAD_CASE_TYPE="${DEFAULT_PROCESS_UPLOAD_CASE_TYPE:-55}"
DEFAULT_PROCESS_UPLOAD_CASE_STATUS="${DEFAULT_PROCESS_UPLOAD_CASE_STATUS:-P}"

if [[ -z "$INPUT_JSON" || ! -f "$INPUT_JSON" ]]; then echo "INPUT_JSON file not found: ${INPUT_JSON:-}" >&2; exit 1; fi
if [[ -z "$OUTPUT_JSON" ]]; then echo "OUTPUT_JSON is required" >&2; exit 1; fi

BASE="${CIS_BASE_URL%/}"
TMPDIR="$(mktemp -d)"
COOKIE="$TMPDIR/cookie.txt"
cleanup(){ if [[ -n "${DEBUG_PROCESS_UPLOAD:-}" ]]; then dbg="$(dirname "$OUTPUT_JSON")/../debug/process-upload-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dbg"; cp -f "$TMPDIR"/* "$dbg"/ 2>/dev/null || true; echo "Debug files: $dbg" >&2; fi; rm -rf "$TMPDIR"; }
trap cleanup EXIT
# shellcheck source=cis_bridge_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_bridge_common.sh"
# shellcheck source=cis_court_selection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_court_selection.sh"

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "process_upload"
curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/proceedings/process_upload.php?linkid=$PROCESS_UPLOAD_LINKID&mode=$PROCESS_UPLOAD_MODE" > "$TMPDIR/page.html"

mkdir -p "$(dirname "$OUTPUT_JSON")"
"$PYTHON_BIN" - "$INPUT_JSON" "$OUTPUT_JSON" "$COOKIE" "$BASE" "$LOGIN_DATE" \
  "$DEFAULT_PROCESS_UPLOAD_CASE_RADIO" "$DEFAULT_PROCESS_UPLOAD_CASE_TYPE" "$DEFAULT_PROCESS_UPLOAD_CASE_STATUS" <<'PY'
import html, json, os, re, subprocess, sys
from html.parser import HTMLParser
from pathlib import Path

(input_json, output_json, cookie, base, login_date, default_case_radio, default_case_type, default_case_status) = sys.argv[1:9]
records=json.load(open(input_json, encoding='utf-8'))
if not isinstance(records, list):
    raise SystemExit('INPUT_JSON must be a JSON array')
base=base.rstrip('/')
results=[]

class OptionParser(HTMLParser):
    def __init__(self):
        super().__init__(); self.opts=[]; self.cur=None; self.text=''
    def handle_starttag(self, tag, attrs):
        if tag.lower() == 'option':
            d=dict(attrs); self.cur={'value':d.get('value',''), 'id':d.get('id','')}; self.text=''
    def handle_data(self, data):
        if self.cur is not None: self.text += data
    def handle_endtag(self, tag):
        if tag.lower() == 'option' and self.cur is not None:
            self.cur['label']=' '.join(html.unescape(self.text).split())
            self.opts.append(self.cur); self.cur=None

def parse_options(fragment):
    p=OptionParser(); p.feed(fragment or ''); return p.opts

def item_val(item,*keys,default=''):
    for k in keys:
        v=item.get(k)
        if v not in (None,''):
            return str(v)
    return str(default or '')

def clean(v):
    if v in (None, 0, '0'):
        return ''
    return str(v)

def clean_name(v):
    s = clean(v)
    s = re.sub(r'[^A-Za-z0-9\s]', ' ', s)
    return ' '.join(s.split())

def validate_path(path_s):
    if not path_s:
        return ''
    expanded=os.path.expandvars(path_s)
    app_root=Path(os.environ.get('UPLOADER_APP_DIR') or os.getcwd())
    candidates=[Path(path_s), Path(expanded)]
    if not Path(expanded).is_absolute():
        candidates.append(app_root / expanded)
    # tolerate /d/foo style when running native Windows Python
    m=re.match(r'^/([A-Za-z])/(.*)$', path_s.replace('\\','/'))
    if m:
        candidates.append(Path(f'{m.group(1)}:/{m.group(2)}'))
    for p in candidates:
        try:
            if p.exists():
                return str(p)
        except Exception:
            pass
    return ''

def run_curl(args):
    p=subprocess.run(['curl','-sS','-b',cookie,'-c',cookie] + args, text=True, capture_output=True)
    return p.returncode, p.stdout, p.stderr

def parse_jsonish(s):
    s=s or ''
    try:
        return json.loads(s)
    except Exception:
        pass
    m=re.search(r'\{.*\}', s, re.S)
    if not m:
        return {'_raw': s[:3000]}
    try:
        return json.loads(m.group(0))
    except Exception:
        return {'_raw': s[:3000]}

def curl_post(path, fields):
    args=['-X','POST', base+path, '-H', 'X-Requested-With: XMLHttpRequest']
    for k,v in fields:
        args += ['--data-urlencode', f'{k}={v}']
    rc,out,err=run_curl(args)
    parsed=parse_jsonish(out)
    if rc != 0:
        parsed['_curl_error']=err
    return parsed

def select_notice(load_resp, notice_id):
    opts=parse_options(load_resp.get('selectBox','') if isinstance(load_resp, dict) else '')
    candidates=[]
    for opt in opts:
        val=opt.get('value','')
        if not val or '~' not in val:
            continue
        if val.split('~',1)[0] == notice_id:
            candidates.append(opt)
    if candidates:
        opt=candidates[0]
        return opt.get('value',''), opt.get('label',''), opts
    return '', '', opts

def option_parts(value):
    parts=(value or '').split('~')
    return {
        'party_name': parts[0] if len(parts) > 0 else '',
        'party_no': parts[1] if len(parts) > 1 else '',
        'party_kind': parts[2] if len(parts) > 2 else '',
    }

def select_party(fetch_resp, item):
    direct=item_val(item,'party_value','res_pet_wit_table','pet_res_wit_value')
    opts=[o for o in parse_options(fetch_resp.get('htmlstr','') if isinstance(fetch_resp, dict) else '') if '~' in (o.get('value') or '')]
    if direct:
        matches=[o for o in opts if o.get('value') == direct]
        if matches:
            return matches[0], {'method':'direct', 'candidates':opts}
        return None, {'method':'direct', 'error':'direct party value not found', 'candidates':opts}

    party_name=item_val(item,'party_name','recipient_name').strip().lower()
    party_no=item_val(item,'party_no')
    party_kind=item_val(item,'party_kind','party_suffix').strip().upper()
    scored=[]
    for opt in opts:
        parts=option_parts(opt.get('value',''))
        score=0
        if party_name and (party_name == parts['party_name'].strip().lower() or party_name in opt.get('label','').lower()): score += 4
        if party_no and party_no == parts['party_no']: score += 3
        if party_kind and party_kind == parts['party_kind'].upper(): score += 2
        scored.append((score,opt))
    scored.sort(key=lambda x:x[0], reverse=True)
    if scored and scored[0][0] > 0 and (len(scored) == 1 or scored[0][0] > scored[1][0]):
        return scored[0][1], {'method':'hints', 'candidates':opts, 'selected_score':scored[0][0]}
    if len(opts) == 1:
        return opts[0], {'method':'single_candidate', 'candidates':opts}
    return None, {'method':'ambiguous' if opts else 'none', 'error':'party selection is ambiguous; add party_value, party_name, party_no or party_kind', 'candidates':opts}

def build_submit_fields(item, cino, case_radio, case_type, casestatus, notice_code, notice_name, selected_party, party_details):
    party_type=item_val(item,'party_type',default='2')
    address_type=item_val(item,'address_type','addr_type',default='M').upper()
    # Match process_upload.har final multipart closely. Optional location labels/codes are blank
    # unless the deployment returns usable non-zero values.
    fields=[
        ('formaction',''), ('case_no[]',''), ('cino',cino), ('casestatus',casestatus),
        ('rec_adv', clean(party_details.get('rec_adv'))), ('rec_adv_cd', clean(party_details.get('rec_adv_cd')) or '0'),
        ('rec_age', clean(party_details.get('rec_age'))), ('rec_address',''), ('lname',''), ('ename',''), ('laddress',''), ('lfather_name',''), ('lrec_address',''), ('ltown_name',''), ('lward_name',''),
        ('action',''), ('frec_no',''), ('fyear',''), ('archieve',''), ('labelcounter',''), ('datecounter',''), ('otherpartyno',''), ('fmmregdate',''), ('footnotecounter',''), ('hideshowtabs',''), ('filename',''), ('actloaded','0'),
        ('fcivil_criminal',''), ('matter_type','0'), ('filcase_type',case_type), ('recv_party_type',''), ('recv_party_no',''), ('recno_year_str',''), ('oldpartytype_no_str',''), ('process_no',''),
        ('findividual_or_bulk',''), ('fselected_party_type',''), ('faddressee',''), ('faddressee_different',''), ('hiddenstatusstring_s',''), ('oldpartytype_no_str_s',''), ('recv_party_type_s',''), ('recv_party_no_s',''),
        ('hide_plead_guilty','Y'), ('hide_interlocutory_application','Y'), ('app_court_type','N'),
        ('case_radio',case_radio), ('fcase_no',f'{case_type}~{cino}~{casestatus}'), ('fnoticecode',notice_code),
        ('party_type',party_type), ('res_pet_wit_table',selected_party), ('otherparty',''), ('frecv_father_flag', clean(party_details.get('relation_flag')).strip()), ('fro', clean_name(party_details.get('father_name'))), ('ffir_police_st_code1',''),
        ('fcol_state_code_pet',''), ('faddress', clean(party_details.get('address'))), ('fcol_dist_code_pet',''), ('rdo_address','1' if address_type == 'M' else '2'),
        ('ffir_state_code_pet',''), ('ffir_dist_code_pet',''), ('fdist_code_pet', clean(party_details.get('dist_code_pet'))), ('ffir_taluka_code_pet',''),
        ('ftown_code_pet', clean(party_details.get('town_code_pet'))), ('fward_code_pet', clean(party_details.get('ward_code_pet'))), ('ftaluka_code_pet', clean(party_details.get('taluka_code_pet'))), ('fvillage_code_pet', clean(party_details.get('village_code_pet'))),
        ('fpolice_st_code1', clean(party_details.get('police_st_census'))), ('fpincode', clean(party_details.get('pincode'))), ('fmob_no', clean(party_details.get('mobile'))), ('fremark', clean(party_details.get('remark'))), ('femail', clean(party_details.get('email'))),
        ('x','submitData'), ('fnoticecode_name', notice_name), ('fstate_name',''), ('fpolicestn_name','')
    ]
    return fields

for idx,item in enumerate(records, start=1):
    if not isinstance(item, dict):
        results.append({'status':'failed','error':f'record {idx} is not an object'})
        continue

    external_id=item_val(item,'external_id','external_filing_id',default=f'process-upload-{idx}')
    cino=item_val(item,'cis_cnr','cino')
    notice_id=item_val(item,'notice_id',default='200001')
    party_type=item_val(item,'party_type',default='2')
    address_type=item_val(item,'address_type','addr_type',default='M').upper()
    file_path=item_val(item,'file_path','pdf_path','path')
    case_radio=item_val(item,'case_radio','ftype_of_filing',default=default_case_radio)
    case_type=item_val(item,'case_type_code','casetype',default=default_case_type)
    casestatus=item_val(item,'casestatus',default=default_case_status)
    resolved_file=validate_path(file_path)
    base_result={'external_id':external_id,'cis_cnr':cino,'notice_id':notice_id,'party_type':party_type,'address_type':address_type,'file_path':file_path}

    missing=[]
    for label,value in [('cis_cnr',cino),('notice_id',notice_id),('party_type',party_type),('address_type',address_type),('file_path',file_path)]:
        if not value: missing.append(label)
    if file_path and not resolved_file:
        missing.append('file_path_exists')
    if missing:
        results.append({**base_result,'status':'failed','error':'missing/invalid required field(s): '+', '.join(missing)})
        continue

    fetch_case=curl_post('/proceedings/process_upload_ajax.php', [
        ('x','fetchcasedetails'),('cino',cino),('fcase_no',f'{case_type}~{cino}~{casestatus}'),('civ_cri',case_radio)
    ])
    if fetch_case.get('ffiling_no_type') not in (None,''):
        case_type=str(fetch_case.get('ffiling_no_type'))
    if fetch_case.get('casestatus') not in (None,''):
        casestatus=str(fetch_case.get('casestatus'))

    load_notice=curl_post('/proceedings/process_upload_ajax.php', [('x','loadnoticesummons'),('typeofprocess',case_radio)])
    notice_code, notice_name, notice_options = select_notice(load_notice, notice_id)
    if not notice_code:
        results.append({**base_result,'status':'failed','error':f'notice_id {notice_id} not found for case_radio {case_radio}', 'fetch_case_response':fetch_case, 'loadnoticesummons_response':load_notice, 'notice_candidates':notice_options})
        continue

    show_type=curl_post('/proceedings/process_upload_ajax.php', [('x','show_type'),('process_typeNo',notice_id),('civ_crimm',case_radio)])
    fetch_parties=curl_post('/proceedings/process_upload_ajax.php', [
        ('x','fetchPetitioner'),('cino',cino),('flag',party_type),('notice_id',notice_id),('action',''),
        ('casestatus',casestatus),('casetype',case_type),('findividual_or_bulk',''),('strflag','')
    ])
    selected_opt, party_discovery = select_party(fetch_parties, item)
    if not selected_opt:
        results.append({**base_result,'status':'failed','error':'could not select unique process recipient', 'fetch_case_response':fetch_case, 'loadnoticesummons_response':load_notice, 'fetchPetitioner_response':fetch_parties, 'party_discovery':party_discovery})
        continue
    party_value=selected_opt.get('value','')

    party_details=curl_post('/proceedings/process_upload_ajax.php', [
        ('x','fetchpartydetails'),('cino',cino),('flag',party_type),('partystr',party_value),('addr_type',address_type)
    ])
    if party_details.get('errorFlag') not in (None,'','0',0):
        results.append({**base_result,'status':'failed','error':'fetchpartydetails returned errorFlag', 'selected_party':party_value, 'fetchpartydetails_response':party_details})
        continue

    fields=build_submit_fields(item, cino, case_radio, case_type, casestatus, notice_code, notice_name, party_value, party_details)
    args=['-X','POST', f'{base}/proceedings/process_upload_ajax.php', '-H', 'X-Requested-With: XMLHttpRequest']
    for k,v in fields:
        args += ['-F', f'{k}={v}']
    args += ['-F', f'fmyfile=@{resolved_file};type=application/pdf']
    rc,out,err=run_curl(args)
    submit=parse_jsonish(out)
    if rc != 0:
        submit['_curl_error']=err
    ok = rc == 0 and 'Process Uploaded Successfully' in str(submit.get('msg2',''))
    result={**base_result,
        'status':'success' if ok else 'failed',
        'case_radio':case_radio,
        'case_type_code':case_type,
        'casestatus':casestatus,
        'notice_code':notice_code,
        'notice_name':notice_name,
        'selected_party':party_value,
        'selected_party_label':selected_opt.get('label',''),
        'submit_response':submit,
        'fetch_case_response':fetch_case,
        'loadnoticesummons_response':load_notice,
        'show_type_response':show_type,
        'fetchPetitioner_response':fetch_parties,
        'party_discovery':party_discovery,
        'fetchpartydetails_response':party_details,
    }
    if not ok:
        result['error']='process upload did not return Process Uploaded Successfully'
        result['raw_submit_response']=(out or '')[:3000]
        if err: result['curl_stderr']=err
    results.append(result)

json.dump(results, open(output_json, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'Wrote {len(results)} results to {output_json}')
PY

logout_cis
echo "CIS logout complete." >&2
