#!/usr/bin/env bash
set -euo pipefail

# Generate criminal/civil process drafts from preselected recipients/addresses and download PDFs.
# First supported path: criminal NACT summons to accused (notice_id=200001), HAR-backed.

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
cleanup(){ if [[ -n "${DEBUG_PROCESS_GENERATION:-}" ]]; then dbg="$(dirname "$OUTPUT_JSON")/../debug/process-generation-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dbg"; cp -f "$TMPDIR"/* "$dbg"/ 2>/dev/null || true; echo "Debug files: $dbg" >&2; fi; rm -rf "$TMPDIR"; }
trap cleanup EXIT
# shellcheck source=cis_bridge_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_bridge_common.sh"
# shellcheck source=cis_court_selection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_court_selection.sh"

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "process_generation"
curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/proceedings/notice_generation.php?linkid=$PROCESS_NOTICE_LINKID&mode=$PROCESS_NOTICE_MODE" > "$TMPDIR/page.html"

mkdir -p "$(dirname "$OUTPUT_JSON")"
"$PYTHON_BIN" - "$INPUT_JSON" "$OUTPUT_JSON" "$COOKIE" "$BASE" "$LOGIN_DATE" <<'PY'
import json, os, re, subprocess, sys
from pathlib import Path
from urllib.parse import urlsplit

input_json, output_json, cookie, base, login_date = sys.argv[1:6]
records=json.load(open(input_json, encoding='utf-8'))
if not isinstance(records, list): raise SystemExit('INPUT_JSON must be an array')
base=base.rstrip('/')
origin=f'{urlsplit(base).scheme}://{urlsplit(base).netloc}'
out_dir=Path(output_json).resolve().parent
pdf_dir=out_dir / 'process-drafts'
pdf_dir.mkdir(parents=True, exist_ok=True)

def curl_post(path, fields):
    args=['curl','-sS','-b',cookie,'-c',cookie,'-X','POST', base+path]
    for k,v in fields:
        args += ['--data-urlencode', f'{k}={v}']
    p=subprocess.run(args, text=True, capture_output=True)
    s=p.stdout
    if p.returncode != 0:
        return {'_curl_error': p.stderr, '_raw': s}
    m=re.search(r'\{.*\}', s, re.S)
    if not m:
        return {'_raw': s[:3000]}
    try: return json.loads(m.group(0))
    except Exception: return {'_raw': s[:3000]}

def curl_download(url, dest):
    p=subprocess.run(['curl','-sS','-L','-b',cookie,'-c',cookie,url,'-o',str(dest)], text=True, capture_output=True)
    if p.returncode != 0:
        return False, p.stderr
    try:
        data=dest.read_bytes()[:4]
        if data != b'%PDF':
            return False, 'downloaded file does not start with %PDF'
    except Exception as e:
        return False, str(e)
    return True, ''

def item_val(item,*keys,default=''):
    for k in keys:
        v=item.get(k)
        if v not in (None,''): return str(v)
    return str(default or '')

def first_act(item):
    acts=item.get('acts') or []
    if acts and isinstance(acts, list) and isinstance(acts[0], dict): return acts[0]
    return {'act_name':'Negotiable Instruments Act','hidden_act_code':'18810260099001 ','act_code':'732','section':'138,'}

def split_rec_year(s):
    p=(s or '').split('#',1)
    return (p[0], p[1]) if len(p)==2 else ('','')

def parse_addedparty(htmlstr):
    m=re.search(r"value=['\"]([^'\"]+)['\"]", htmlstr or '')
    return m.group(1) if m else ''

def draft_path_from_view(view):
    m=re.search(r"data=['\"]([^'\"]+\.pdf)['\"]", view or '')
    return m.group(1) if m else ''

def selected_tasks(record):
    tasks=[]
    for rec in record.get('recipients') or []:
        if rec.get('selected') is False: continue
        for addr in rec.get('addresses') or []:
            if addr.get('selected'):
                tasks.append((rec, addr))
    return tasks

def build_fields(record, rec, addr, flag, state):
    cino=item_val(record,'cis_cnr','cino')
    case_radio=item_val(record,'case_radio',default='3')
    case_type=item_val(record,'case_type_code',default='55')
    casestatus=item_val(record,'casestatus',default='P')
    notice_code=item_val(record,'notice_code',default='200001~0~0~1~2,3,4~E200001 -English, L200001-Marathi~B~3~N~')
    notice_id=item_val(record,'notice_id',default=notice_code.split('~')[0] if notice_code else '200001')
    notice_name=item_val(record,'notice_name',default='Summons to an accused person [Sec. 61] -200001')
    case_info=record.get('case') or (record.get('_prefetch') or {}).get('case_details') or {}
    police_private=item_val(record,'police_private',default=str(case_info.get('police_private') or '2'))
    offense_date=item_val(record,'offense_date','dt_of_offense',default=str(case_info.get('offense_date') or ''))
    causeofaction_ci=item_val(record,'causeofaction_ci','causeofaction',default=str(case_info.get('causeofaction_ci') or case_info.get('causeofaction') or ''))
    amount=item_val(record,'amount',default=str(case_info.get('amount') or ''))
    parts=notice_code.split('~')
    filename=parts[5] if len(parts)>5 else 'E200001 -English, L200001-Marathi'
    hideshowtabs=parts[4] if len(parts)>4 else '2,3,4'
    findividual=parts[6] if len(parts)>6 else 'B'
    faddressee=parts[7] if len(parts)>7 else '3'
    faddressee_diff=parts[8] if len(parts)>8 else 'N'
    fir=record.get('fir') or {}
    act=first_act(record)
    recno_year=state.get('recno_year_str','')
    rec_no, year=split_rec_year(recno_year)
    addedparty=state.get('addedparty','')
    ptype=rec.get('party_type','')
    pno=rec.get('party_no','')
    pet_res=rec.get('pet_res_wit_value') or f"{rec.get('party_name','')}~{pno}~{ptype}"
    if not rec_no:
        rec_no=item_val(record,'rec_no',default='')
    if not year:
        year=item_val(record,'process_year',default=login_date[-4:])
    fields=[
      ('formaction','1'), ('case_no[]',''), ('cino',cino), ('casestatus',casestatus),
      ('rec_adv', addr.get('rec_adv','')), ('rec_adv_cd', addr.get('rec_adv_cd','0') or '0'),
      ('rec_age', addr.get('age','')), ('sparty_age_new', addr.get('age','')),
      ('rec_address',''), ('lname',''), ('ename',''), ('laddress',''), ('lfather_name',''), ('lrec_address',''), ('ltown_name',''), ('lward_name',''),
      ('action',''), ('frec_no', rec_no), ('fyear', year), ('archieve',''), ('labelcounter', parts[1] if len(parts)>1 else '0'), ('datecounter', parts[2] if len(parts)>2 else '0'),
      ('otherpartyno',''), ('fmmregdate',''), ('footnotecounter','1'), ('hideshowtabs',hideshowtabs), ('filename',filename), ('actloaded','0'),
      ('fcivil_criminal',case_radio), ('matter_type','0'), ('filcase_type',case_type), ('recv_party_type', ptype if flag!='GenerateProcess' else ''), ('recv_party_no', pno if flag!='GenerateProcess' else ''),
      ('recno_year_str',recno_year), ('oldpartytype_no_str', state.get('partytype_no_str','')), ('process_no', str(state.get('process_no',''))),
      ('findividual_or_bulk',findividual), ('fselected_party_type',''), ('faddressee',faddressee), ('faddressee_different',faddressee_diff),
      ('recno_year_str_old',''), ('oldpartytype_no_str_s',''), ('recv_party_type_s',''), ('recv_party_no_s',''),
      ('sessionstateforps','6'), ('sessiondistrictforps','1'), ('hide_plead_guilty','Y'), ('hide_interlocutory_application','Y'), ('onlyodt',''),
      ('copied_cino',''), ('copied_casestatus',''), ('copied_draft_date',''), ('copied_process_no',''), ('copied_case_type',''), ('copied_case_radio',''), ('app_court_type','N'),
      ('case_radio',case_radio), ('fcase_no',f'{case_type}~{cino}~{casestatus}'), ('fnoticecode',notice_code),
      ('fcriminal_state_id', fir.get('state_code','6')), ('fcriminal_dist_code', fir.get('district_code','069')), ('fcriminal_police_station', fir.get('police_station_code','')),
      ('fcriminal_fir_no', fir.get('fir_no','')), ('fcriminal_fir_year', fir.get('fir_year','')), ('changed_next_date', item_val(record,'changed_next_date','next_hearing_date',default='')),
      ('fees_type','on'), ('party_type', item_val(record,'party_type',default='3')), ('pet_res_wit[]', pet_res), ('otherparty',''), ('footnote', item_val(record,'footnote',default='')),
    ]
    if flag != 'GenerateProcess':
        fields.append(('addedparty', addedparty))
    fields += [
      ('fro', addr.get('father_name','')), ('ffir_police_st_code1', addr.get('police_station_code','')), ('fcol_state_code_pet',''),
      ('faddress', addr.get('address','')), ('fcol_dist_code_pet',''), ('rdo_address','on'),
      ('ffir_state_code_pet',''), ('fstate_code_pet', addr.get('state_code','')), ('ffir_dist_code_pet',''), ('fdist_code_pet', addr.get('district_code','')),
      ('ffir_taluka_code_pet',''), ('ftaluka_code_pet', addr.get('taluka_code','')), ('ftown_code_pet', addr.get('town_code','')), ('fward_code_pet', addr.get('ward_code','')),
      ('fvillage_code_pet', addr.get('village_code','')), ('fvillage1_code_pet', addr.get('village1_code','')), ('fvillage2_code_pet', addr.get('village2_code','')),
      ('fpincode', addr.get('pincode','')), ('fmob_no', addr.get('mobile','')), ('femail', addr.get('email','')), ('frecv_father_flag', addr.get('relation_flag','')), ('fremark', addr.get('remark','')),
      ('filing_type','2'), ('fcase_type',case_type), ('fcase_ref_no',''), ('fl_case_no',''), ('fl_case_year',''), ('fcinno',''), ('flower_judge_name',''),
      ('flcdate_decision',''), ('fcc_applied_date',''), ('fcc_received_date',''),
      ('fdispactcode[]', act.get('act_name','Negotiable Instruments Act')), ('fhiddactcode[]', act.get('hidden_act_code','18810260099001 ')),
      ('factcode[]', act.get('act_code','732')), ('factsection_code[]', act.get('section','138,')),
      ('fcauseofaction_ci', causeofaction_ci), ('foffense_date', offense_date), ('fprayercode',''), ('frelief_offense',''), ('fjuri_value',''), ('famount', amount),
      ('fpolice_private', police_private), ('fpolicestation_state_id', fir.get('state_code','6')), ('fdist_code_police', fir.get('district_code','069')), ('fpolice_st_code', fir.get('police_station_code','')),
      ('fdt_of_offense', offense_date), ('fdt_chargesheet',''), ('ffir_no', fir.get('fir_no','')), ('ffir_year', fir.get('fir_year','')), ('fcauseofaction_cri',''),
      ('radiotype','2'), ('fmm_case_type1',''), ('fmm_case_no1',''), ('fmm_case_year1',''), ('fmain_mcase_no',''), ('fmmcinno',''), ('fmmcinno_old',''), ('fmain_petname',''), ('fmain_resname',''), ('label1',''),
      ('cino', cino), ('feestype','2'), ('receipt_no',''), ('receipt_year',''), ('receipt_fee',''), ('receipt_dates',''),
      ('fnoticecode_s', notice_id), ('addresstype', '1' if addr.get('address_type','M')=='M' else '2'), ('fpolice_station', item_val(addr,'police_station_name','police_station_label',default='')), ('fnoticecode_name', notice_name),
      ('fstate_name', item_val(addr,'state_name',default='')), ('fdist_name', item_val(addr,'district_name',default='')), ('ftaluka_name', item_val(addr,'taluka_name',default='')), ('fvillage_name', item_val(addr,'village_name',default='')), ('ftown_name', item_val(addr,'town_name',default='')), ('fward_name', item_val(addr,'ward_name',default='')), ('fhobli_name',''), ('fhamlet_name',''),
      ('flag',flag), ('fmm_case_type_name',''), ('police_st_code_name', item_val(addr,'police_station_name','police_station_label',default='')), ('addresstype_s',''), ('criminal_police_st_code_name', item_val(addr,'police_station_name','police_station_label',default='')), ('check_proc_ins_com','N')
    ]
    return fields

results=[]
for ridx,record in enumerate(records, start=1):
    if not isinstance(record, dict): continue
    ext=item_val(record,'external_id','external_filing_id',default=f'process-generation-{ridx}')
    tasks=selected_tasks(record)
    if not tasks:
        results.append({'external_id':ext,'cis_cnr':item_val(record,'cis_cnr','cino'),'status':'failed','error':'no selected recipient/address'})
        continue
    for tix,(rec,addr) in enumerate(tasks, start=1):
        state={}
        cino=item_val(record,'cis_cnr','cino')
        base_result={'external_id': ext, 'task_index': tix, 'cis_cnr': cino, 'recipient': {'party_name':rec.get('party_name'), 'party_no':rec.get('party_no'), 'party_type':rec.get('party_type'), 'address_type':addr.get('address_type'), 'address':addr.get('address')}}
        notice_code=item_val(record,'notice_code',default='200001~0~0~1~2,3,4~E200001 -English, L200001-Marathi~B~3~N~')
        notice_id=item_val(record,'notice_id',default=notice_code.split('~')[0] if notice_code else '200001')
        filename=(notice_code.split('~')[5] if len(notice_code.split('~'))>5 else 'E200001 -English, L200001-Marathi')
        show_type=curl_post('/proceedings/notice_generation_ajax.php', [('x','show_type'),('process_typeNo',notice_id),('civ_crimm',item_val(record,'case_radio',default='3'))])
        check_odt=curl_post('/proceedings/notice_generation_ajax.php', [('x','checkforodt'),('filename',filename),('civil_criminal',item_val(record,'case_radio',default='3')),('process_id',notice_id)])
        gp=curl_post('/proceedings/notice_generation_ajax.php', build_fields(record, rec, addr, 'GenerateProcess', state))
        if gp.get('msg')!='success':
            results.append({**base_result,'status':'failed','error':'GenerateProcess failed','show_type_response':show_type,'check_odt_response':check_odt,'generate_process_response':gp}); continue
        state['process_no']=str(gp.get('process_no',''))
        state['recno_year_str']=str(gp.get('recno_year_str',''))
        state['partytype_no_str']=str(gp.get('partytype_no_str',''))
        state['addedparty']=parse_addedparty(gp.get('htmlstr',''))
        issued=curl_post('/proceedings/notice_generation_ajax.php', [('x','show_issuedProcess'),('cino',cino),('notice_id',notice_id)])
        fetched_party=curl_post('/proceedings/notice_generation_ajax.php', [('x','fetchpartydetails'),('cino',cino),('party_no',rec.get('party_no','')),('party_type',rec.get('party_type','')),('addr_type',addr.get('address_type','M')),('action',''),('process_no',state.get('process_no','')),('civil_criminal',item_val(record,'case_radio',default='3')),('casestatus',item_val(record,'casestatus',default='P')),('flag','')])
        pd=curl_post('/proceedings/notice_generation_ajax.php', build_fields(record, rec, addr, 'PartyDetailClick', state))
        if pd.get('msg')!='success':
            results.append({**base_result,'status':'failed','error':'PartyDetailClick failed','show_type_response':show_type,'check_odt_response':check_odt,'generate_process_response':gp,'issued_process_response':issued,'fetch_party_response':fetched_party,'party_detail_response':pd}); continue
        display=curl_post('/proceedings/notice_generation_ajax.php', [('x','displaydetails'),('cino',cino),('recno_year_str',state.get('recno_year_str','')),('action',''),('processtype',item_val(record,'case_radio',default='3')),('faddressee_different',(notice_code.split('~')[8] if len(notice_code.split('~'))>8 else 'N'))])
        act_resp=curl_post('/proceedings/notice_generation_ajax.php', build_fields(record, rec, addr, 'Act', state))
        if act_resp.get('msg')!='success':
            results.append({**base_result,'status':'failed','error':'Act save failed','generate_process_response':gp,'party_detail_response':pd,'displaydetails_response':display,'act_response':act_resp}); continue
        case_resp=curl_post('/proceedings/notice_generation_ajax.php', build_fields(record, rec, addr, 'CaseInfo', state))
        if case_resp.get('msg')!='success':
            results.append({**base_result,'status':'failed','error':'CaseInfo save failed','generate_process_response':gp,'party_detail_response':pd,'displaydetails_response':display,'act_response':act_resp,'case_info_response':case_resp}); continue
        gd=curl_post('/proceedings/notice_generation_ajax.php', build_fields(record, rec, addr, 'GenerateDraft', state))
        ok = gd.get('msg')=='success' and int(str(gd.get('generated_notice_count') or '0')) > 0
        draft_path=draft_path_from_view(gd.get('view',''))
        draft_url=(origin + draft_path) if draft_path.startswith('/') else draft_path
        rec_no, year=split_rec_year(state.get('recno_year_str',''))
        local_path=''
        download_ok=False
        download_error=''
        if draft_url:
            safe_ext=re.sub(r'[^A-Za-z0-9_.-]+','_',ext)
            dest=pdf_dir / f'{safe_ext}-{tix}-{rec_no or "rec"}-{year or "year"}.pdf'
            download_ok, download_error = curl_download(draft_url, dest)
            if download_ok:
                local_path=str(dest)
        result={**base_result,
            'status':'success' if ok and (not draft_url or download_ok) else 'failed',
            'notice_id': item_val(record,'notice_id',default='200001'),
            'notice_name': item_val(record,'notice_name',default='Summons to an accused person [Sec. 61] -200001'),
            'process_no': state.get('process_no'),
            'recno_year_str': state.get('recno_year_str'),
            'rec_no': rec_no,
            'process_year': year,
            'partytype_no_str': state.get('partytype_no_str'),
            'addedparty': state.get('addedparty'),
            'draft_pdf_path': draft_path,
            'draft_pdf_url': draft_url,
            'draft_pdf_local_path': local_path,
            'download_ok': download_ok,
            'show_type_response': show_type,
            'check_odt_response': check_odt,
            'generate_process_response': gp,
            'issued_process_response': issued,
            'fetch_party_response': fetched_party,
            'party_detail_response': pd,
            'displaydetails_response': display,
            'act_response': act_resp,
            'case_info_response': case_resp,
            'generate_draft_response': gd,
            'publish_discovery_hint': {'cis_cnr': cino, 'from_date': login_date, 'to_date': login_date, 'ftype_of_filing': item_val(record,'case_radio',default='3')}
        }
        if result['status']!='success':
            result['error']='GenerateDraft failed or draft PDF download failed'
            if download_error: result['download_error']=download_error
        results.append(result)

json.dump(results, open(output_json,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'Wrote {len(results)} process generation results to {output_json}')
PY

logout_cis
echo "CIS logout complete." >&2
