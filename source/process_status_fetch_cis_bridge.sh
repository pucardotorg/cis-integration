#!/usr/bin/env bash
set -euo pipefail

# Read-only process status fetch for a date range.
# HAR-backed flow: proceedings/process_status.php -> proceedings/process_statusajax.php

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
PROCESS_STATUS_LINKID="${PROCESS_STATUS_LINKID:-652}"
PROCESS_STATUS_MODE="${PROCESS_STATUS_MODE:-0}"

if [[ -z "$INPUT_JSON" || ! -f "$INPUT_JSON" ]]; then echo "INPUT_JSON file not found: ${INPUT_JSON:-}" >&2; exit 1; fi
if [[ -z "$OUTPUT_JSON" ]]; then echo "OUTPUT_JSON is required" >&2; exit 1; fi

BASE="${CIS_BASE_URL%/}"
TMPDIR="$(mktemp -d)"
COOKIE="$TMPDIR/cookie.txt"
cleanup(){ if [[ -n "${DEBUG_PROCESS_STATUS:-}" ]]; then dbg="$(dirname "$OUTPUT_JSON")/../debug/process-status-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dbg"; cp -f "$TMPDIR"/* "$dbg"/ 2>/dev/null || true; echo "Debug files: $dbg" >&2; fi; rm -rf "$TMPDIR"; }
trap cleanup EXIT
# shellcheck source=cis_bridge_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_bridge_common.sh"
# shellcheck source=cis_court_selection.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cis_court_selection.sh"

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "process_status_fetch"
curl -sS -b "$COOKIE" -c "$COOKIE" "$BASE/proceedings/process_status.php?linkid=$PROCESS_STATUS_LINKID&mode=$PROCESS_STATUS_MODE" > "$TMPDIR/page.html"

mkdir -p "$(dirname "$OUTPUT_JSON")"
"$PYTHON_BIN" - "$INPUT_JSON" "$OUTPUT_JSON" "$COOKIE" "$BASE" "$LOGIN_DATE" <<'PY'
import html, json, re, subprocess, sys
from html.parser import HTMLParser

input_json, output_json, cookie, base, login_date = sys.argv[1:6]
records = json.load(open(input_json, encoding='utf-8'))
if not isinstance(records, list):
    raise SystemExit('INPUT_JSON must be a JSON array')
base = base.rstrip('/')

class Stripper(HTMLParser):
    def __init__(self):
        super().__init__(); self.parts=[]
    def handle_data(self, data):
        if data: self.parts.append(data)

def textify(value):
    s = html.unescape(str(value or ''))
    p = Stripper(); p.feed(s)
    return ' '.join(' '.join(p.parts).split())

def item_val(item, *keys, default=''):
    for k in keys:
        v = item.get(k)
        if v not in (None, ''):
            return str(v)
    return str(default or '')

def parse_jsonish(s):
    try:
        return json.loads(s)
    except Exception:
        pass
    m = re.search(r'\{.*\}', s or '', re.S)
    if not m:
        return {'_raw': (s or '')[:3000]}
    try:
        return json.loads(m.group(0))
    except Exception:
        return {'_raw': (s or '')[:3000]}

def curl_table(fields):
    args = ['curl', '-sS', '-b', cookie, '-c', cookie, '-X', 'POST', f'{base}/proceedings/process_statusajax.php', '-H', 'X-Requested-With: XMLHttpRequest']
    for k, v in fields:
        args += ['--data-urlencode', f'{k}={v}']
    p = subprocess.run(args, text=True, capture_output=True)
    parsed = parse_jsonish(p.stdout)
    if p.returncode != 0:
        parsed['_curl_error'] = p.stderr
    return parsed

def table_fields(item, start, length, echo):
    fields = [('', ''), ('sEcho', echo), ('iColumns', '16'), ('sColumns', ',,,,,,,,,,,,,,,,'), ('iDisplayStart', str(start)), ('iDisplayLength', str(length))]
    for i in range(16):
        fields += [(f'mDataProp_{i}', str(i)), (f'sSearch_{i}', ''), (f'bRegex_{i}', 'false'), (f'bSearchable_{i}', 'true'), (f'bSortable_{i}', 'true')]
    fields += [
        ('sSearch', ''), ('bRegex', 'false'),
        ('iSortCol_0', item_val(item, 'sort_column', default='3')),
        ('sSortDir_0', item_val(item, 'sort_direction', default='desc')),
        ('iSortingCols', '1'),
        ('case', 'chargsheet_count'),
        ('ffrom_date', item_val(item, 'from_date', 'ffrom_date', default=login_date)),
        ('fto_date', item_val(item, 'to_date', 'fto_date', default=login_date)),
        ('radval', item_val(item, 'status_filter', 'radval', default='4')),
        ('cv_crm', item_val(item, 'case_radio', 'cv_crm', default='2')),
        ('fcourt_no', item_val(item, 'court_no', 'fcourt_no')),
        ('type_of_process', item_val(item, 'type_of_process', 'process_type')),
        # Keep this N: Y asks CIS/NSTEP to refresh/consume status, not just read.
        ('webservice_flg', 'N'),
    ]
    return fields

def extract_row(row):
    raw = {str(k): row.get(str(k), '') for k in range(17)}
    col1, col2 = str(raw['1']), str(raw['2'])
    cnr = ''
    m = re.search(r"showProcessList\(['\"]([^'\"]+)['\"]\)", col1)
    if m: cnr = m.group(1)
    process_id = ''
    m = re.search(r"cctns_processes\(['\"]([^'\"]+)['\"]", col2) or re.search(r'<b>\s*([^<]+?)\s*</b>', col2, re.I)
    if m: process_id = html.unescape(m.group(1)).strip()
    next_date = ''
    m = re.search(r'Next\s*Date\s*:\s*([0-9]{2}-[0-9]{2}-[0-9]{4})', textify(col2), re.I)
    if m: next_date = m.group(1)
    process_title = re.sub(r'^' + re.escape(process_id) + r'\s*', '', textify(col2)).strip() if process_id else textify(col2)
    process_title = re.sub(r'\s*Next\s*Date\s*:\s*[0-9]{2}-[0-9]{2}-[0-9]{4}.*$', '', process_title, flags=re.I).strip()
    return {
        'sr_no': textify(raw['0']),
        'case_number': textify(col1),
        'cis_cnr': cnr,
        'process_id': process_id,
        'process_title': process_title,
        'next_date': next_date,
        'type_of_process': textify(raw['3']),
        'receiver_name_address': textify(raw['4']),
        'date_of_publishing': textify(raw['5']),
        'process_manager': textify(raw['6']),
        'date_of_allocation': textify(raw['7']),
        'date_of_service': textify(raw['8']),
        'status_of_service': textify(raw['9']),
        'reason': textify(raw['10']),
        'nstep_status': textify(raw['11']),
        'view_details': textify(raw['12']),
        'email_service_status': textify(raw['13']),
        'email_sent_date': textify(raw['14']),
        'authentication_datetime': textify(raw['15']),
        'authentication_ip': textify(raw['16']),
    }

results = []
for idx, item in enumerate(records, start=1):
    if not isinstance(item, dict):
        results.append({'status': 'failed', 'error': f'record {idx} is not an object'})
        continue
    ext = item_val(item, 'external_id', default=f'process-status-{idx}')
    page_size = max(1, int(item_val(item, 'page_size', default='1000')))
    start = 0; echo = 1; rows = []; total = None; error = ''
    while True:
        resp = curl_table(table_fields(item, start, page_size, str(echo)))
        if resp.get('_curl_error') or 'aaData' not in resp:
            error = resp.get('_curl_error') or resp.get('_raw') or 'process_statusajax did not return aaData'
            break
        batch = resp.get('aaData') or []
        if total is None:
            try: total = int(resp.get('iTotalDisplayRecords', resp.get('iTotalRecords', 0)) or 0)
            except Exception: total = 0
        rows.extend(extract_row(r) for r in batch if isinstance(r, dict))
        if not batch or len(rows) >= total:
            break
        start += len(batch); echo += 1
    result = {
        'external_id': ext,
        'status': 'failed' if error else 'success',
        'from_date': item_val(item, 'from_date', 'ffrom_date', default=login_date),
        'to_date': item_val(item, 'to_date', 'fto_date', default=login_date),
        'case_radio': item_val(item, 'case_radio', 'cv_crm', default='2'),
        'status_filter': item_val(item, 'status_filter', 'radval', default='4'),
        'court_no': item_val(item, 'court_no', 'fcourt_no'),
        'type_of_process': item_val(item, 'type_of_process', 'process_type'),
        'total_records': total or 0,
        'fetched_records': len(rows),
        'rows': rows,
    }
    if error:
        result['error'] = error
    results.append(result)

json.dump(results, open(output_json, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'Wrote {len(results)} process status result(s) to {output_json}')
PY

logout_cis
echo "CIS logout complete." >&2
