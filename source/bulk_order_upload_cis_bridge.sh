#!/usr/bin/env bash
set -euo pipefail

# Bulk order/judgment PDF upload CIS bridge.
#
# HAR-backed flow (walkthro-23062026/bulk-order-upload.har + proceedings/bulkorder.js):
#   POST proceedings/select_courtajax.php  fcourt_no=$COURT_NO from Data/config.json (same session)
#   GET  proceedings/bulkorder.php?linkid=567&mode=0
#   POST proceedings/bulkupload.php        multipart/form-data, one active fmyfile_N
#   POST proceedings/bulkorder_ajax.php    x=showordercount&cino=<CNR> for verification
#
# Input record (readable names):
#   {
#     "external_id": "trial7-order-1",
#     "cis_cnr": "HRPK020007012026",
#     "case_no": "205500000012026",
#     "pet_name": "ABC TRADERS",
#     "order_date": "30-06-2026",
#     "order_no": "1",                    # optional; defaults to max_ord_no + 1
#     "document_type": "8~3",             # 8~3=Copy of order, 6~1=Copy of Judgment
#     "file_path": "D:/path/to/order.pdf"
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

BULK_ORDER_LINKID="${BULK_ORDER_LINKID:-567}"
BULK_ORDER_MODE="${BULK_ORDER_MODE:-0}"
SELECT_COURT_LINKID="${SELECT_COURT_LINKID:-182}"
SELECT_COURT_DIFFLINKID="${SELECT_COURT_DIFFLINKID:-182}"
SELECT_COURT_MODE="${SELECT_COURT_MODE:-0}"
DEFAULT_FCICRI="${DEFAULT_FCICRI:-3}"
DEFAULT_SESSION_HCDC="${DEFAULT_SESSION_HCDC:-2}"
# Optional fallback if bulkorder.php page does not expose fname1.
BULK_ORDER_DB_NAME="${BULK_ORDER_DB_NAME:-}"

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
  if [[ -n "${DEBUG_BULK_ORDER_UPLOAD:-}" ]]; then
    local dbg
    dbg="$(dirname "$OUTPUT_JSON")/../debug/bulk-order-upload-$(date +%Y%m%d-%H%M%S)"
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

parse_bulkorder_form() {
  local html="$1" out="$2"
  "$PYTHON_BIN" - "$html" "$out" <<'PY'
import json, sys
from html.parser import HTMLParser
html=open(sys.argv[1], encoding='utf-8', errors='ignore').read()
class FP(HTMLParser):
    def __init__(self):
        super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]; self.sel=None; self.selval=''
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        # bulkorder.php uses #frm in JS; if the id is absent in a deployed build,
        # still collect top-level inputs as a safe fallback.
        if tag=='form' and (attrs.get('id')=='frm' or attrs.get('name')=='frm'):
            self.in_form=True
        active=self.in_form or tag=='input'
        if not active: return
        if tag=='input':
            n=attrs.get('name')
            if not n: return
            typ=(attrs.get('type') or '').lower()
            if typ in ('button','submit','reset','file','image'): return
            if typ in ('radio','checkbox') and 'checked' not in attrs: return
            self.items.append((n, attrs.get('value','')))
        elif tag=='select' and self.in_form:
            self.sel=attrs.get('name'); self.selval=''
        elif tag=='option' and self.sel and ('selected' in attrs or not self.selval):
            self.selval=attrs.get('value','')
        elif tag=='textarea' and self.in_form:
            self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, data):
        if self.in_textarea: self.ta += data
    def handle_endtag(self, tag):
        if tag=='select' and self.sel:
            self.items.append((self.sel,self.selval)); self.sel=None; self.selval=''
        elif tag=='textarea' and self.in_textarea:
            self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False
p=FP(); p.feed(html)
d={}
for k,v in p.items:
    if k not in d:
        d[k]=v
json.dump(d, open(sys.argv[2],'w',encoding='utf-8'), ensure_ascii=False, indent=2)
PY
}

run_uploads() {
  mkdir -p "$(dirname "$OUTPUT_JSON")"
  "$PYTHON_BIN" - \
    "$INPUT_JSON" "$OUTPUT_JSON" "$COOKIE" "$BASE" "$LOGIN_DATE" \
    "$DEFAULT_FCICRI" "$DEFAULT_SESSION_HCDC" "$BULK_ORDER_DB_NAME" \
    "$BULK_ORDER_LINKID" "$BULK_ORDER_MODE" "$SELECT_COURT_LINKID" "$SELECT_COURT_DIFFLINKID" "$SELECT_COURT_MODE" \
    "${COURT_NO:-}" "${CIS_COURT_SELECTION_STATUS:-}" <<'PY'
import json, os, re, subprocess, sys
from html.parser import HTMLParser
from pathlib import Path

(input_json, output_json, cookie, base, login_date, default_fcicri, default_hcdc, fallback_db_name,
 bulk_order_linkid, bulk_order_mode, select_court_linkid, select_court_difflinkid, select_court_mode,
 stage_court_no, stage_court_selection_status) = sys.argv[1:16]
records=json.load(open(input_json, encoding='utf-8'))
if not isinstance(records, list):
    raise SystemExit('INPUT_JSON must be a JSON array')

base=base.rstrip('/')
form={}
results=[]

def item_val(item, *keys, default=''):
    for k in keys:
        v=item.get(k)
        if v not in (None, ''):
            return str(v)
    return str(default or '')

def form_val(*keys, default=''):
    for k in keys:
        v=form.get(k)
        if v not in (None, ''):
            return str(v)
    return str(default or '')

def run_curl(args):
    proc=subprocess.run(['curl','-sS','-b',cookie,'-c',cookie] + args, text=True, capture_output=True)
    return proc.returncode, proc.stdout, proc.stderr

def parse_jsonish(s):
    m=re.search(r'\{.*\}', s or '', re.S)
    if not m:
        return {'_raw': (s or '')[:1000]}
    try:
        return json.loads(m.group(0))
    except Exception:
        return {'_raw': (s or '')[:1000]}

class BulkOrderFormParser(HTMLParser):
    def __init__(self):
        super().__init__(); self.in_form=False; self.in_textarea=None; self.ta=''; self.items=[]; self.sel=None; self.selval=''
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if tag=='form' and (attrs.get('id')=='frm' or attrs.get('name')=='frm'):
            self.in_form=True
        active=self.in_form or tag=='input'
        if not active: return
        if tag=='input':
            n=attrs.get('name')
            if not n: return
            typ=(attrs.get('type') or '').lower()
            if typ in ('button','submit','reset','file','image'): return
            if typ in ('radio','checkbox') and 'checked' not in attrs: return
            self.items.append((n, attrs.get('value','')))
        elif tag=='select' and self.in_form:
            self.sel=attrs.get('name'); self.selval=''
        elif tag=='option' and self.sel and ('selected' in attrs or not self.selval):
            self.selval=attrs.get('value','')
        elif tag=='textarea' and self.in_form:
            self.in_textarea=attrs.get('name'); self.ta=''
    def handle_data(self, data):
        if self.in_textarea: self.ta += data
    def handle_endtag(self, tag):
        if tag=='select' and self.sel:
            self.items.append((self.sel,self.selval)); self.sel=None; self.selval=''
        elif tag=='textarea' and self.in_textarea:
            self.items.append((self.in_textarea,self.ta)); self.in_textarea=None; self.ta=''
        elif tag=='form' and self.in_form: self.in_form=False

def parse_bulkorder_html(html):
    p=BulkOrderFormParser(); p.feed(html or '')
    d={}
    for k,v in p.items:
        if k not in d:
            d[k]=v
    return d

def fetch_bulkorder_form():
    rc,out,err=run_curl([f'{base}/proceedings/bulkorder.php?linkid={bulk_order_linkid}&mode={bulk_order_mode}'])
    if rc != 0:
        return {}, {'_curl_error': err}
    return parse_bulkorder_html(out), {}

def show_order_count(cino):
    rc,out,err=run_curl([
        '-X','POST', f'{base}/proceedings/bulkorder_ajax.php',
        '--data-urlencode','x=showordercount',
        '--data-urlencode',f'cino={cino}',
    ])
    parsed=parse_jsonish(out)
    if rc != 0:
        parsed['_curl_error']=err
    return parsed

def int_or_zero(v):
    try:
        return int(str(v).strip())
    except Exception:
        return 0

def validate_path(path_s):
    expanded=os.path.expandvars(path_s)
    app_root=Path(os.environ.get('UPLOADER_APP_DIR') or os.getcwd())
    candidates=[Path(path_s), Path(expanded)]
    if not Path(expanded).is_absolute():
        candidates.append(app_root / expanded)
    for p in candidates:
        try:
            if p.exists():
                return str(p)
        except Exception:
            pass
    return ''

for idx,item in enumerate(records, start=1):
    if not isinstance(item, dict):
        results.append({'status':'failed','error':f'record {idx} is not an object'})
        continue

    external_id=item_val(item, 'external_id', 'external_filing_id', default=f'bulk-order-upload-{idx}')
    cino=item_val(item, 'cis_cnr', 'cino')
    case_no=item_val(item, 'case_no', 'registered_case_number', 'fetched_case_no')
    doc_type=item_val(item, 'document_type', 'doc_type', 'fdoc_type')
    file_path=item_val(item, 'file_path', 'pdf_path', 'path')
    court_no=item_val(item, 'court_no', 'fcourt_no', 'target_court_no', 'allocated_court_no', default=stage_court_no)
    radio_flag=item_val(item, 'radio_flag', default='active')

    base_identity={
        'external_id': external_id,
        'cis_cnr': cino,
        'case_no': case_no,
        'court_no': court_no,
        'document_type': doc_type,
        'file_path': file_path,
    }

    form, form_error = fetch_bulkorder_form()
    if form_error:
        results.append({**base_identity, 'court_selection_status':stage_court_selection_status, 'status':'failed', 'error':'bulkorder.php form fetch failed after court selection', 'form_error': form_error})
        continue

    pet_name=item_val(item, 'pet_name', 'complainant_name', default='')
    order_date=item_val(item, 'order_date', 'forder_dt', 'upload_date', default=(form_val('sessdate', default=login_date) or login_date))
    fcicri=item_val(item, 'fcicri', 'fci_cri', default=form_val('fcicri', default=default_fcicri))
    session_hcdc=item_val(item, 'sessionHcdc', 'hcdc', default=form_val('sessionHcdc', default=default_hcdc))
    fname1=item_val(item, 'fname1', 'db_name', default=form_val('fname1', default=fallback_db_name))
    fcourt_no=item_val(item, 'fcourt_no', 'court_no', default=form_val('fcourt_no', default=court_no))
    fcauselistid=item_val(item, 'fcauselistid', 'causelist_id', default=form_val('fcauselistid', default=''))
    linked_count=item_val(item, 'linkedcount', default='Y')
    filing_flag=item_val(item, 'filing_flag', default='')
    ia_case_type=item_val(item, 'ia_case_type', default='')

    base_result={
        **base_identity,
        'court_selection_status': stage_court_selection_status,
        'order_date': order_date,
    }

    missing=[]
    for label,value in [('cis_cnr',cino),('case_no',case_no),('document_type',doc_type),('file_path',file_path)]:
        if not value: missing.append(label)
    resolved_file=validate_path(file_path) if file_path else ''
    if file_path and not resolved_file:
        missing.append('file_path_exists')
    if missing:
        results.append({**base_result, 'status':'failed', 'error':'missing/invalid required field(s): '+', '.join(missing)})
        continue

    # bulkupload.php validates case_no against the registered-cases table, so it must
    # be the internal registered case number (all digits, e.g. 205500000112026) -- NOT
    # the display label like 'NACT/11/2026'. A display label here makes the server
    # reply with the opaque 'not uploaded' string. The registration stage emits this
    # as 'registered_case_number' (with 'registered_case_label' as the human form).
    if not re.fullmatch(r'\d{6,}', case_no):
        results.append({**base_result, 'status':'failed',
            'error': (f"case_no must be the registered case number (digits only); "
                      f"got {case_no!r} which looks like a display label. "
                      f"Use 'registered_case_number' from the registration stage output.")})
        continue

    before=show_order_count(cino)
    explicit_order=item_val(item, 'order_no', 'forder_no', default='')
    order_no=explicit_order or str(int_or_zero(before.get('max_ord_no')) + 1 or 1)

    # HAR uses row index based field names and btn_val to identify the active row.
    # We submit one active row per JSON record, always index 1.
    fields=[]
    if form_val('__csrf_magic'):
        fields.append(('__csrf_magic', form_val('__csrf_magic')))
    fields.extend([
        ('formaction', item_val(item, 'formaction', default='1')),
        ('num_rows', item_val(item, 'num_rows', default='')),
        ('btn_val', '1'),
        ('sessdate', order_date),
        ('fname1', fname1),
        ('sessionHcdc', session_hcdc),
        ('fcicri', fcicri),
        ('fcourt_no', fcourt_no),
        ('fcauselistid', fcauselistid),
        ('forder_dt', order_date),
        ('fchkorder', item_val(item, 'fchkorder', default='on')),
        ('chek1', '1'),
        ('ia_case_type[1]', ia_case_type),
        ('case_no[1]', case_no),
        ('linkedcount1', linked_count),
        ('linkcase_no[1][]', f'{cino}~{case_no}~1'),
        ('filing_flag[1]', filing_flag),
        ('forder_no[1]', order_no),
        ('cino[1]', cino),
        ('pet_name[1]', pet_name),
        ('fdoc_type[1]', doc_type),
    ])

    args=['-X','POST', f'{base}/proceedings/bulkupload.php']
    for k,v in fields:
        args.extend(['-F', f'{k}={v}'])
    args.extend(['-F', f'fmyfile_1=@{resolved_file};type=application/pdf'])
    args.extend(['-F', 'button1='])
    rc,out,err=run_curl(args)
    raw=(out or '').strip()
    after=show_order_count(cino) if rc == 0 else {'_skipped':'curl upload failed'}

    if rc == 0 and raw == '1':
        results.append({
            **base_result,
            'status':'success',
            'order_no': order_no,
            'raw_upload_response': raw,
            'order_count_before': before,
            'order_count_after': after,
            'fname1': fname1,
        })
    else:
        error = f'bulkupload.php returned {raw!r}' if rc == 0 else f'curl failed: {err}'
        results.append({
            **base_result,
            'status':'failed',
            'order_no': order_no,
            'error': error,
            'raw_upload_response': raw,
            'curl_stderr': err,
            'order_count_before': before,
            'order_count_after': after,
            'fname1': fname1,
        })

json.dump(results, open(output_json, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print(f'Wrote {len(results)} results to {output_json}')
PY
}

COUNT="$($PYTHON_BIN - "$INPUT_JSON" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding='utf-8'))
if not isinstance(d, list): raise SystemExit('INPUT_JSON must be a JSON array')
print(len(d))
PY
)"

if [[ "$COUNT" == "0" ]]; then
  echo "No bulk-order-upload records."
  mkdir -p "$(dirname "$OUTPUT_JSON")"
  printf '[]\n' > "$OUTPUT_JSON"
  exit 0
fi

login_cis
cis_select_court_if_enabled "$BASE" "$COOKIE" "${COURT_NO:-}" "${SKIP_COURT_SELECTION:-false}" "bulk_order_upload"
run_uploads
logout_cis
echo "CIS logout complete." >&2
