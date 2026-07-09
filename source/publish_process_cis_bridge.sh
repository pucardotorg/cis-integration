#!/usr/bin/env bash
set -euo pipefail

# Publish generated process/notices via proceedings/publish_notice_ajax.php.
# HAR-backed flows (walkthro-23062026/publish-process*.har + publish_notice.js):
#   GET  proceedings/publish_notice.php?linkid=638&mode=0
#   POST proceedings/publish_notice_ajax.php x=publishnotice&myval=<...>&ftype_of_filing=3&esigned=N
#   POST proceedings/publish_notice_ajax.php x=deletenotice&bunchprocessno=<CNR>~<process_no>&case_category=3&draft_date=DD-MM-YYYY
# Optional discovery:
#   POST proceedings/publish_notice_ajax.php x=publish_table&typeofprocess=3&ffrom_date=...&fto_date=...
# and extract publishNotice('<myval>','N') / deleteNotice('<bunchprocessno>','<draft_date>') from aaData.

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
PUBLISH_NOTICE_LINKID="${PUBLISH_NOTICE_LINKID:-638}"
PUBLISH_NOTICE_MODE="${PUBLISH_NOTICE_MODE:-0}"
# Per-record `action` wins unless PUBLISH_PROCESS_FORCE_ACTION is set.
# Supported actions: publish (default), delete_draft.
PUBLISH_PROCESS_DEFAULT_ACTION="${PUBLISH_PROCESS_DEFAULT_ACTION:-publish}"
PUBLISH_PROCESS_FORCE_ACTION="${PUBLISH_PROCESS_FORCE_ACTION:-}"

if [[ -z "$INPUT_JSON" || ! -f "$INPUT_JSON" ]]; then echo "INPUT_JSON file not found: ${INPUT_JSON:-}" >&2; exit 1; fi
if [[ -z "$OUTPUT_JSON" ]]; then echo "OUTPUT_JSON is required" >&2; exit 1; fi

BASE="${CIS_BASE_URL%/}"
TMPDIR="$(mktemp -d)"
COOKIE="$TMPDIR/cookie.txt"
cleanup(){ if [[ -n "${DEBUG_PUBLISH_PROCESS:-}" ]]; then dbg="$(dirname "$OUTPUT_JSON")/../debug/publish-process-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dbg"; cp -f "$TMPDIR"/* "$dbg"/ 2>/dev/null || true; echo "Debug files: $dbg" >&2; fi; rm -rf "$TMPDIR"; }
trap cleanup EXIT
# shellcheck source=cis_bridge_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_bridge_common.sh"
# shellcheck source=cis_court_selection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_court_selection.sh"

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "publish_process"
curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/proceedings/publish_notice.php?linkid=$PUBLISH_NOTICE_LINKID&mode=$PUBLISH_NOTICE_MODE" > "$TMPDIR/page.html"

mkdir -p "$(dirname "$OUTPUT_JSON")"
"$PYTHON_BIN" - "$INPUT_JSON" "$OUTPUT_JSON" "$COOKIE" "$BASE" "$LOGIN_DATE" "$PUBLISH_PROCESS_DEFAULT_ACTION" "$PUBLISH_PROCESS_FORCE_ACTION" <<'PY'
import json, re, subprocess, sys
from html import unescape

input_json, output_json, cookie, base, login_date, default_action, force_action = sys.argv[1:8]
records=json.load(open(input_json, encoding='utf-8'))
if not isinstance(records, list): raise SystemExit('INPUT_JSON must be an array')
base=base.rstrip('/')

def item_val(item,*keys,default=''):
    for k in keys:
        v=item.get(k)
        if v not in (None,''): return str(v)
    return str(default or '')

def curl_post(fields):
    args=['curl','-sS','-b',cookie,'-c',cookie,'-X','POST', f'{base}/proceedings/publish_notice_ajax.php', '-H', 'X-Requested-With: XMLHttpRequest']
    for k,v in fields:
        args += ['--data-urlencode', f'{k}={v}']
    p=subprocess.run(args, text=True, capture_output=True)
    if p.returncode != 0:
        return {'_curl_error': p.stderr, '_raw': p.stdout}
    s=p.stdout
    m=re.search(r'\{.*\}', s, re.S)
    if not m:
        # eSign=Y can return a JSON array. Keep raw for unsupported mode/debug.
        return {'_raw': s[:5000]}
    try: return json.loads(m.group(0))
    except Exception: return {'_raw': s[:5000]}

def publish_table(typeofprocess, from_date, to_date, processtype='', searches=None):
    searches=searches or {}
    fields=[('', ''), ('sEcho','1'), ('iColumns','8'), ('sColumns',',,,,,,,'), ('iDisplayStart','0'), ('iDisplayLength','100')]
    for i in range(8):
        fields += [(f'mDataProp_{i}', str(i)), (f'sSearch_{i}', ''), (f'bRegex_{i}', 'false'), (f'bSearchable_{i}', 'true'), (f'bSortable_{i}', 'true')]
    fields += [('sSearch',''), ('bRegex','false'), ('iSortCol_0','0'), ('sSortDir_0','asc'), ('iSortingCols','1'),
               ('x','publish_table'), ('typeofprocess', typeofprocess), ('ffrom_date', from_date), ('fto_date', to_date), ('processtype', processtype)]
    for i in range(1,8):
        fields.append((f'search_{i}', str(searches.get(str(i), searches.get(i, 'undefined' if i==7 else '')))))
    fields.append(('column_cnt','8'))
    for i in range(1,8):
        fields.append((f'search_{i}', str(searches.get(str(i), searches.get(i, 'undefined' if i==7 else '')))))
    fields.append(('column_cnt','8'))
    return curl_post(fields)

def flatten_text(x):
    if isinstance(x, str): return x
    if isinstance(x, list): return ' '.join(flatten_text(v) for v in x)
    if isinstance(x, dict): return ' '.join(flatten_text(v) for v in x.values())
    return str(x)

def extract_candidates(table):
    text=unescape(flatten_text(table or {}))
    vals=[]
    seen=set()
    for m in re.finditer(r"publishNotice\(\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]*)['\"]", text):
        myval=m.group(1)
        esigned=(m.group(2) or 'N').upper()
        key=(myval, esigned)
        if key in seen:
            continue
        seen.add(key)
        vals.append({'myval': myval, 'esigned': esigned, 'source': m.group(0)[:500]})
    return vals

def extract_delete_candidates(table):
    text=unescape(flatten_text(table or {}))
    vals=[]
    seen=set()
    for m in re.finditer(r"deleteNotice\(\s*['\"]([^'\"]+)['\"]\s*,\s*['\"]([^'\"]+)['\"]", text):
        key=(m.group(1), m.group(2))
        if key in seen:
            continue
        seen.add(key)
        vals.append({'bunchprocessno': m.group(1), 'draft_date': m.group(2), 'source': m.group(0)[:500]})
    return vals

def build_myval(item, table=None):
    direct=item_val(item,'myval')
    if direct: return direct, {'method':'direct'}
    cino=item_val(item,'cis_cnr','cino')
    pno=item_val(item,'publish_process_no','process_publish_no','publish_no')
    sr=item_val(item,'sr_no','serial_no','publish_sr_no')
    yr=item_val(item,'process_year','year','publish_year')
    if cino and pno and sr and yr:
        return f'{cino}~{pno}~{sr}~{yr}', {'method':'components'}
    if table:
        candidates=extract_candidates(table)
        cands=[c for c in candidates if not cino or cino in c['myval']]
        desired_esigned=item_val(item,'esigned',default='N').upper()
        esigned_cands=[c for c in cands if not desired_esigned or c.get('esigned','N').upper() == desired_esigned]
        if esigned_cands:
            cands=esigned_cands
        # If all remaining controls point to the same publish payload, it is safe to select it
        # even when multiple buttons/sources expose that same myval.
        distinct_myvals=sorted({c['myval'] for c in cands})
        if len(distinct_myvals) == 1:
            return distinct_myvals[0], {'method':'publish_table', 'candidates': candidates, 'selected': cands[0]}
        # If input carries a known process/rec/year, prefer candidates containing those tokens.
        hints=[item_val(item,'process_no'), item_val(item,'rec_no'), item_val(item,'process_year','year')]
        scored=[]
        for c in cands:
            score=sum(1 for h in hints if h and h in c['myval'])
            scored.append((score,c))
        scored.sort(key=lambda x:x[0], reverse=True)
        if scored and (len(scored)==1 or scored[0][0] > scored[1][0]):
            return scored[0][1]['myval'], {'method':'publish_table', 'candidates': candidates, 'selected': scored[0][1]}
        if len(cands)==1:
            return cands[0]['myval'], {'method':'publish_table', 'candidates': candidates, 'selected': cands[0]}
        return '', {'method':'publish_table', 'candidates': candidates, 'error':'no unique candidate'}
    return '', {'method':'none', 'error':'missing myval or components'}

def visible_delete_candidates(table, cino=''):
    raw=extract_delete_candidates(table) if table else []
    candidates=[]
    seen=set()
    for c in raw:
        key=(c.get('bunchprocessno',''), c.get('draft_date',''))
        if key in seen: continue
        seen.add(key)
        candidates.append(c)
    cands=[c for c in candidates if not cino or cino in c['bunchprocessno']]
    return candidates, cands

def build_bunchprocessno(item, table=None):
    direct=item_val(item,'bunchprocessno','bunch_process_no','delete_bunchprocessno','draft_bunchprocessno')
    cino=item_val(item,'cis_cnr','cino')
    pno=item_val(item,'process_no','draft_process_no','publish_process_no','process_publish_no','publish_no')
    desired=direct or (f'{cino}~{pno}' if cino and pno else '')
    desired_method='direct' if direct else ('components' if desired else '')
    input_draft_date=item_val(item,'draft_date','delete_draft_date',default='')

    if table:
        candidates, cands=visible_delete_candidates(table, cino)
        if desired:
            matches=[c for c in cands if c['bunchprocessno'] == desired]
            if matches:
                sel=matches[0]
                return desired, input_draft_date or sel['draft_date'], {'method':f'{desired_method}_verified', 'candidates': candidates, 'selected': sel}
            if len(cands)==1:
                sel=cands[0]
                return sel['bunchprocessno'], input_draft_date or sel['draft_date'], {'method':'publish_table_override', 'input_bunchprocessno': desired, 'candidates': candidates, 'selected': sel, 'warning':'input target was not visible in publish_table; using the only visible draft for this CNR'}
            return '', '', {'method':desired_method, 'input_bunchprocessno': desired, 'candidates': candidates, 'error':'input target is not visible in publish_table'}
        hints=[pno, item_val(item,'rec_no'), item_val(item,'process_year','year')]
        scored=[]
        for c in cands:
            score=sum(1 for h in hints if h and h in c['bunchprocessno'])
            scored.append((score,c))
        scored.sort(key=lambda x:x[0], reverse=True)
        if scored and (len(scored)==1 or scored[0][0] > scored[1][0]):
            sel=scored[0][1]
            return sel['bunchprocessno'], input_draft_date or sel['draft_date'], {'method':'publish_table', 'candidates': candidates, 'selected': sel}
        if len(cands)==1:
            return cands[0]['bunchprocessno'], input_draft_date or cands[0]['draft_date'], {'method':'publish_table', 'candidates': candidates, 'selected': cands[0]}
        return '', '', {'method':'publish_table', 'candidates': candidates, 'error':'no unique candidate'}

    if desired: return desired, input_draft_date, {'method':desired_method}
    return '', '', {'method':'none', 'error':'missing bunchprocessno or cis_cnr/process_no'}

truthy=lambda v: str(v).lower() in ('1','true','yes','y')

def normalise_action(item):
    action=(force_action or item_val(item,'action','publish_action',default=default_action or 'publish')).strip().lower().replace('-', '_')
    if not force_action and (truthy(item.get('delete_draft', 'false')) or truthy(item.get('remove_generated_draft', 'false'))):
        action='delete_draft'
    if action in ('delete','remove','remove_draft','delete_generated_draft'):
        action='delete_draft'
    return action

results=[]
for idx,item in enumerate(records, start=1):
    if not isinstance(item, dict):
        results.append({'status':'failed','error':f'record {idx} is not an object'}); continue
    external_id=item_val(item,'external_id','external_filing_id',default=f'publish-process-{idx}')
    cino=item_val(item,'cis_cnr','cino')
    ftype=item_val(item,'ftype_of_filing','case_radio','typeofprocess',default='3')
    esigned=item_val(item,'esigned',default='N').upper()
    from_date=item_val(item,'from_date','ffrom_date',default=item_val(item,'process_date','generation_date',default=login_date))
    to_date=item_val(item,'to_date','fto_date',default=from_date or login_date)
    processtype=item_val(item,'process_type','processtype',default='')
    postcheck=truthy(item.get('postcheck', 'true'))
    action=normalise_action(item)
    base_result={'external_id':external_id,'cis_cnr':cino,'action':action,'ftype_of_filing':ftype,'esigned':esigned,'from_date':from_date,'to_date':to_date}

    if action not in ('publish','delete_draft'):
        results.append({**base_result,'status':'failed','error':f'unsupported action: {action}'}); continue

    table_before=None
    needs_table = postcheck or (action == 'publish' and not item_val(item,'myval')) or (action == 'delete_draft' and not item_val(item,'bunchprocessno','bunch_process_no','delete_bunchprocessno','draft_bunchprocessno') and not (cino and item_val(item,'process_no','draft_process_no','publish_process_no','process_publish_no','publish_no')))
    if needs_table:
        table_before=publish_table(ftype, from_date, to_date, processtype)

    if action == 'delete_draft':
        bunchprocessno, discovered_draft_date, discovery = build_bunchprocessno(item, table_before)
        draft_date=item_val(item,'draft_date','delete_draft_date',default=discovered_draft_date or from_date or login_date)
        if not bunchprocessno:
            results.append({**base_result,'status':'failed','error':'could not determine draft bunchprocessno', 'discovery': discovery, 'table_before': table_before})
            continue
        submit=curl_post([('x','deletenotice'),('bunchprocessno',bunchprocessno),('case_category',ftype),('draft_date',draft_date)])
        ok = 'Deleted Successfully' in str(submit.get('msg2','')) or submit.get('success') in ('Y','Yes',True)
        table_after=publish_table(ftype, from_date, to_date, processtype) if postcheck else None
        postcheck_remaining=[]
        if table_after:
            _, after_cands=visible_delete_candidates(table_after, cino)
            postcheck_remaining=[c for c in after_cands if c['bunchprocessno'] == bunchprocessno]
            if postcheck_remaining:
                ok=False
        result={**base_result,
            'status':'success' if ok else 'failed',
            'bunchprocessno':bunchprocessno,
            'draft_date':draft_date,
            'submit_response':submit,
            'discovery':discovery,
            'postcheck_remaining':postcheck_remaining,
            'table_before':table_before,
            'table_after':table_after,
        }
        if not ok:
            if postcheck_remaining:
                result['error']='deletenotice returned success but draft is still visible in publish_table'
            else:
                result['error']='deletenotice did not return Deleted Successfully'
        results.append(result)
        continue

    if esigned == 'Y':
        results.append({**base_result,'status':'failed','error':'eSigned publish requires browser/DSC flow; bridge supports esigned=N only'})
        continue

    myval, discovery=build_myval(item, table_before)
    if not myval:
        results.append({**base_result,'status':'failed','error':'could not determine publish myval', 'discovery': discovery, 'table_before': table_before})
        continue

    submit=curl_post([('x','publishnotice'),('myval',myval),('ftype_of_filing',ftype),('esigned',esigned)])
    ok = submit.get('success') in ('Y','Yes',True) or 'Published successfully' in str(submit.get('msg2',''))
    table_after=publish_table(ftype, from_date, to_date, processtype) if postcheck else None
    result={**base_result,
        'status':'success' if ok else 'failed',
        'myval':myval,
        'submit_response':submit,
        'discovery':discovery,
        'table_before':table_before,
        'table_after':table_after,
    }
    if not ok:
        result['error']='publish_notice_ajax did not return success=Y'
    results.append(result)

json.dump(results, open(output_json,'w',encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'Wrote {len(results)} publish-process results to {output_json}')
PY

logout_cis
echo "CIS logout complete." >&2
