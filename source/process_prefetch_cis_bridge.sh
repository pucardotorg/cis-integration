#!/usr/bin/env bash
set -euo pipefail

# Prefetch accused/addressees and their main/alternate addresses for process generation.
# Output is an editable process-generation-input.json. User selects recipients/addresses
# before running process_generation_cis_bridge.sh.

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
PROCESS_NOTICE_LINKID="${PROCESS_NOTICE_LINKID:-266}"
PROCESS_NOTICE_MODE="${PROCESS_NOTICE_MODE:-0}"

if [[ -z "$INPUT_JSON" || ! -f "$INPUT_JSON" ]]; then echo "INPUT_JSON file not found: ${INPUT_JSON:-}" >&2; exit 1; fi
if [[ -z "$OUTPUT_JSON" ]]; then echo "OUTPUT_JSON is required" >&2; exit 1; fi

BASE="${CIS_BASE_URL%/}"
TMPDIR="$(mktemp -d)"
COOKIE="$TMPDIR/cookie.txt"
cleanup(){ if [[ -n "${DEBUG_PROCESS_PREFETCH:-}" ]]; then dbg="$(dirname "$OUTPUT_JSON")/../debug/process-prefetch-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dbg"; cp -f "$TMPDIR"/* "$dbg"/ 2>/dev/null || true; echo "Debug files: $dbg" >&2; fi; rm -rf "$TMPDIR"; }
trap cleanup EXIT
# shellcheck source=cis_bridge_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_bridge_common.sh"
# shellcheck source=cis_court_selection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_court_selection.sh"

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "process_prefetch"
curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/proceedings/notice_generation.php?linkid=$PROCESS_NOTICE_LINKID&mode=$PROCESS_NOTICE_MODE" > "$TMPDIR/page.html"

mkdir -p "$(dirname "$OUTPUT_JSON")"
"$PYTHON_BIN" - "$INPUT_JSON" "$OUTPUT_JSON" "$COOKIE" "$BASE" "$LOGIN_DATE" <<'PY'
import html, json, os, re, subprocess, sys
from html.parser import HTMLParser

input_json, output_json, cookie, base, login_date = sys.argv[1:6]
records=json.load(open(input_json, encoding='utf-8'))
if not isinstance(records, list): raise SystemExit('INPUT_JSON must be an array')
base=base.rstrip('/')

def curl_post(path, fields):
    args=['curl','-sS','-b',cookie,'-c',cookie,'-X','POST', base+path]
    for k,v in fields:
        args += ['--data-urlencode', f'{k}={v}']
    p=subprocess.run(args, text=True, capture_output=True)
    if p.returncode != 0:
        return {'_curl_error': p.stderr, '_raw': p.stdout}
    s=p.stdout
    m=re.search(r'\{.*\}', s, re.S)
    if not m:
        return {'_raw': s[:2000]}
    try: return json.loads(m.group(0))
    except Exception: return {'_raw': s[:2000]}

def item_val(item,*keys,default=''):
    for k in keys:
        v=item.get(k)
        if v not in (None,''): return str(v)
    return str(default or '')

class OptionParser(HTMLParser):
    def __init__(self): super().__init__(); self.opts=[]; self.cur=None; self.text=''
    def handle_starttag(self, tag, attrs):
        if tag=='option':
            d=dict(attrs); self.cur={'value':d.get('value',''), 'id':d.get('id','')}; self.text=''
    def handle_data(self, data):
        if self.cur is not None: self.text += data
    def handle_endtag(self, tag):
        if tag=='option' and self.cur is not None:
            self.cur['label']=' '.join(html.unescape(self.text).split())
            self.opts.append(self.cur); self.cur=None

def parse_options(fragment):
    p=OptionParser(); p.feed(fragment or ''); return p.opts

def party_from_value(value, label=''):
    parts=(value or '').split('~')
    return {
        'selected': True,
        'party_name': parts[0] if len(parts)>0 else label,
        'party_no': parts[1] if len(parts)>1 else '',
        'party_type': parts[2] if len(parts)>2 else '',
        'pet_res_wit_value': value,
        'label': label,
    }

def addr_from_result(addr_type, r):
    def s(k, default=''):
        v=r.get(k, default)
        if v in (None, 0, '0'): return ''
        return str(v)
    address=s('address')
    return {
        'selected': bool(address),
        'address_type': addr_type,
        'address_type_label': 'Main' if addr_type=='M' else 'Alternate',
        'address': address,
        'father_name': s('father_name'),
        'relation_flag': s('relation_flag').strip(),
        'age': s('rec_age'),
        'mobile': s('mobile'),
        'email': s('email'),
        'state_code': s('state_code_pet', s('state_id')),
        'district_code': s('dist_code_pet', s('dist_code')),
        'taluka_code': s('taluka_code_pet', s('taluka_code')),
        'town_code': s('town_code_pet', s('town_code')),
        'ward_code': s('ward_code_pet', s('ward_code')),
        'village_code': s('village_code_pet', s('village_code')),
        'village1_code': s('village1_code_pet', s('village1_code')),
        'village2_code': s('village2_code_pet', s('village2_code')),
        'police_station_code': s('police_st_code'),
        'police_station_census': s('police_st_census'),
        'pincode': s('pincode'),
        'raw_fetchpartydetails': r,
    }

def changed_next_date_from_case_details(case_details):
    """CIS UI auto-fills changed_next_date from fetchcasedetails.htmlstr4."""
    htmlstr=html.unescape(str(case_details.get('htmlstr4') or ''))
    m=re.search(r"<input[^>]*(?:name|id)=['\"]changed_next_date['\"][^>]*>", htmlstr, re.I)
    if m:
        v=re.search(r"\bvalue\s*=\s*['\"]?([^'\"\s>]+)", m.group(0), re.I)
        if v:
            return v.group(1).strip()
    m=re.search(r"Next\s*Date\s*:\s*([0-9]{2}-[0-9]{2}-[0-9]{4})", htmlstr, re.I)
    return m.group(1).strip() if m else ''

out=[]
for idx,item in enumerate(records, start=1):
    if not isinstance(item, dict): continue
    external_id=item_val(item,'external_id','external_filing_id',default=f'process-prefetch-{idx}')
    cino=item_val(item,'cis_cnr','cino')
    if not cino:
        out.append({'external_id': external_id, 'status':'failed', 'error':'cis_cnr missing'})
        continue
    case_radio=item_val(item,'case_radio','ftype_of_filing',default='3')
    notice_id=item_val(item,'notice_id',default='200001')
    casestatus=item_val(item,'casestatus',default='P')
    case_type=item_val(item,'case_type_code','fmm_case_type',default='55')
    notice_code=item_val(item,'notice_code', default='200001~0~0~1~2,3,4~E200001 -English, L200001-Marathi~B~3~N~')
    notice_name=item_val(item,'notice_name', default='Summons to an accused person [Sec. 61] -200001')

    case_details=curl_post('/proceedings/notice_generation_ajax.php', [('x','fetchcasedetails'),('cino',cino)])
    if case_details.get('case_type') not in (None,''):
        case_type=str(case_details.get('case_type'))
    casestatus=str(case_details.get('casestatus') or casestatus)
    load_notice=curl_post('/proceedings/notice_generation_ajax.php', [('x','loadnoticesummons'),('typeofprocess',case_radio),('bnss_chk','0')])
    fetch_parties=curl_post('/proceedings/notice_generation_ajax.php', [
        ('x','fetchPetitioner'),('cino',cino),('flag',case_radio),('notice_id',notice_id),('action',''),
        ('casestatus',casestatus),('casetype',case_type),('findividual_or_bulk','B'),('strflag',''),('faddressee_different','N')])
    opts=parse_options(fetch_parties.get('htmlstr',''))
    parties=[]
    for opt in opts:
        val=opt.get('value','')
        if not val or '~' not in val: continue
        if val.startswith('comp') and item_val(item,'include_complainant',default='N').upper()!='Y':
            continue
        # Default summons target is accused/respondent parties: MR/R entries.
        p=party_from_value(val,opt.get('label',''))
        if p['party_type'] not in ('MR','R','JR') and item_val(item,'include_all_party_types',default='N').upper()!='Y':
            continue
        addresses=[]
        seen=set()
        for at in ('M','A'):
            adr=curl_post('/proceedings/notice_generation_ajax.php', [
                ('x','fetchpartydetails'),('cino',cino),('party_no',p['party_no']),('party_type',p['party_type']),
                ('addr_type',at),('action',''),('process_no',''),('civil_criminal',case_radio),('casestatus',casestatus),('flag','')])
            ao=addr_from_result(at, adr)
            key=(ao.get('address'), ao.get('state_code'), ao.get('district_code'), ao.get('mobile'))
            if ao.get('address') and key not in seen:
                seen.add(key); addresses.append(ao)
            elif at=='M' and not addresses:
                addresses.append(ao)
        p['addresses']=addresses
        parties.append(p)

    fir_no=item_val(item,'fir_no',default=str(case_details.get('fir_no') or ''))
    fir_year=item_val(item,'fir_year',default=str(case_details.get('fir_year') or ''))
    if fir_year in ('0',''): fir_year=item_val(item,'process_year',default=login_date[-4:])
    police_station=item_val(item,'police_station_code',default=str(case_details.get('police_st_census') or case_details.get('police_st_code') or ''))
    out.append({
        'external_id': external_id,
        'status': 'prefetched',
        'cis_cnr': cino,
        'case_type_code': case_type,
        'case_radio': case_radio,
        'casestatus': casestatus,
        'notice_id': notice_id,
        'notice_code': notice_code,
        'notice_name': notice_name,
        # Match CIS UI behavior: selecting the case auto-fills this from fetchcasedetails;
        # input value remains an override when the user wants to edit it.
        'changed_next_date': item_val(item,'changed_next_date','next_hearing_date',default=changed_next_date_from_case_details(case_details)),
        'footnote': item_val(item,'footnote',default='if house is closed, paste the summon'),
        'case': {
            'police_private': item_val(item,'police_private',default=str(case_details.get('police_private') or '2')),
            'offense_date': item_val(item,'offense_date','dt_of_offense',default=str(case_details.get('offense_date') or '')),
            'causeofaction_ci': item_val(item,'causeofaction_ci','causeofaction',default=str(case_details.get('causeofaction') or '')),
            'amount': item_val(item,'amount',default=str(case_details.get('amount') or '')),
        },
        'fir': {
            'state_code': item_val(item,'fir_state_code','police_state_code',default=str(case_details.get('police_state_census') or '6')),
            'district_code': item_val(item,'fir_district_code','police_district_code',default=str(case_details.get('police_dist_census') or '069')).zfill(3),
            'police_station_code': police_station,
            'fir_no': fir_no,
            'fir_year': fir_year,
        },
        'acts': item.get('acts') or [{'act_name':'Negotiable Instruments Act','hidden_act_code':'18810260099001 ','act_code':'732','section':'138,'}],
        'recipients': parties,
        '_prefetch': {'case_details': case_details, 'loadnoticesummons': load_notice, 'fetchPetitioner': fetch_parties},
    })

json.dump(out, open(output_json,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'Wrote {len(out)} prefetched records to {output_json}')
PY

logout_cis
echo "CIS logout complete." >&2
