#!/usr/bin/env bash
# Shared helpers for CIS bridge scripts. Source from bridge after setting defaults.

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need curl
need openssl

# Avoid silent indefinite hangs on unreachable CIS/network paths. Callers can override.
CIS_CONNECT_TIMEOUT="${CIS_CONNECT_TIMEOUT:-10}"
CIS_MAX_TIME="${CIS_MAX_TIME:-60}"
curl() {
  command curl --connect-timeout "$CIS_CONNECT_TIMEOUT" --max-time "$CIS_MAX_TIME" "$@"
}

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python
  else echo "Missing python3/python" >&2; exit 1; fi
fi

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
