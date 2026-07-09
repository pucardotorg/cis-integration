#!/usr/bin/env bash
set -euo pipefail

# Build a Linux portable package for uploader/V3 only.
# Run this on Ubuntu 20.04 x86_64 (or the oldest Ubuntu you need to support):
#   bash uploader/V3/packaging/build-linux-portable.sh
#
# Output:
#   uploader/V3/dist/uploader-v3-linux-x86_64.tar.gz
#   uploader/V3/dist/uploader-v3-linux-x86_64.sha256

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V3_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$V3_ROOT/dist"
WORK_DIR=""
PKG_NAME="uploader-v3-linux-x86_64"
RUNTIME_DIR=""
SKIP_RUNTIME=false
COPY_SYSTEM_RUNTIME=true
OFFLINE_DOCTOR=true

usage() {
  cat <<'EOF'
Usage: build-linux-portable.sh [options]

Options:
  --output DIR          Dist directory (default: uploader/V3/dist)
  --name NAME           Package folder/archive name (default: uploader-v3-linux-x86_64)
  --runtime-dir DIR     Copy a prebuilt runtime/ directory into the package
                        Expected: bin/curl, bin/openssl, python/bin/python3
  --skip-runtime        Build app/wrappers only; target machine must provide python3,curl,openssl
  --copy-system-runtime Copy python3/curl/openssl + shared-library closure from this Linux host (default)
  --no-doctor           Do not run generated doctor.sh --offline during build
  -h, --help            Show this help

Recommended: build on Ubuntu 20.04 x86_64 for maximum compatibility.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) DIST_DIR="$2"; shift 2 ;;
    --output=*) DIST_DIR="${1#--output=}"; shift ;;
    --name) PKG_NAME="$2"; shift 2 ;;
    --name=*) PKG_NAME="${1#--name=}"; shift ;;
    --runtime-dir) RUNTIME_DIR="$2"; COPY_SYSTEM_RUNTIME=false; shift 2 ;;
    --runtime-dir=*) RUNTIME_DIR="${1#--runtime-dir=}"; COPY_SYSTEM_RUNTIME=false; shift ;;
    --skip-runtime) SKIP_RUNTIME=true; COPY_SYSTEM_RUNTIME=false; shift ;;
    --copy-system-runtime) COPY_SYSTEM_RUNTIME=true; shift ;;
    --no-doctor) OFFLINE_DOCTOR=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command for build: $1" >&2; exit 1; }; }
need tar
need find
need chmod
need sha256sum

if [[ "$SKIP_RUNTIME" == false && -z "$RUNTIME_DIR" && "$COPY_SYSTEM_RUNTIME" == true && "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: Linux runtime can only be copied while building on Linux." >&2
  echo "Run this script on Ubuntu, pass --runtime-dir, or use --skip-runtime for a non-self-contained smoke build." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

STAGE="$WORK_DIR/$PKG_NAME"
mkdir -p "$STAGE/app" "$STAGE/output" "$STAGE/logs" "$STAGE/runtime/bin" "$DIST_DIR"

copy_app() {
  echo "Copying uploader/V3 app..."
  (
    cd "$V3_ROOT"
    tar \
      --exclude='./.git' \
      --exclude='./output' \
      --exclude='./packaging' \
      --exclude='./dist' \
      --exclude='./*.7z' \
      -cf - .
  ) | (cd "$STAGE/app" && tar -xf -)

  find "$STAGE/app" -type d \( -name __pycache__ -o -name .pytest_cache \) -prune -exec rm -rf {} +
  find "$STAGE/app" -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '*_old.json' -o -name '* old.json' \) -delete
  rm -rf "$STAGE/app/.git" "$STAGE/app/output"
  mkdir -p "$STAGE/app/output"

  # Do not ship live credentials. First-run bootstrap copies template to config.json.
  if [[ -f "$STAGE/app/Data/config.template.json" ]]; then
    rm -f "$STAGE/app/Data/config.json"
  else
    cat > "$STAGE/app/Data/config.template.json" <<'EOF'
{
  "_comment": "Template for CIS connection settings. Fill before live runs.",
  "CIS_BASE_URL": "http://168.144.70.80/swecourtis/",
  "COURT_CODE": "HRPK02",
  "CIS_USER": "",
  "CIS_PASSWORD": "",
  "UNLOCK_PASSWORD": "",
  "LOGIN_DATE": "",
  "LANG_ID": "0",
  "CLOUD_FLAG": "N"
}
EOF
    rm -f "$STAGE/app/Data/config.json"
  fi
}

copy_ldd_deps() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  if ! command -v ldd >/dev/null 2>&1; then return 0; fi
  while IFS= read -r dep; do
    [[ -n "$dep" && -f "$dep" ]] || continue
    case "$dep" in
      */ld-linux*|*/libc.so.*|*/libpthread.so.*|*/libdl.so.*|*/libm.so.*|*/librt.so.*|*/libresolv.so.*)
        # Keep glibc from the target OS for compatibility/security.
        continue ;;
    esac
    cp -L "$dep" "$STAGE/runtime/lib/" 2>/dev/null || true
  done < <(ldd "$target" 2>/dev/null | awk '
    /=> \/.*\// {print $(NF-1)}
    /^[[:space:]]*\/.*\// {print $1}
  ')
}

copy_binary_with_deps() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")" "$STAGE/runtime/lib"
  cp -L "$src" "$dest"
  chmod +x "$dest"
  copy_ldd_deps "$dest"
}

copy_system_runtime() {
  echo "Copying Linux runtime from this host..."
  [[ "$(uname -s)" == "Linux" ]] || { echo "copy_system_runtime requires Linux" >&2; exit 1; }
  need python3
  need curl
  need openssl

  local py_bin curl_bin openssl_bin py_ver stdlib stdlib_parent stdlib_base
  # Prefer distro binaries over Conda/Homebrew-style shims; portable PYTHONHOME
  # packages built from an active Conda env are fragile on target machines.
  py_bin="$(command -v python3)"
  curl_bin="$(command -v curl)"
  openssl_bin="$(command -v openssl)"
  [[ -x /usr/bin/python3 ]] && py_bin=/usr/bin/python3
  [[ -x /usr/bin/curl ]] && curl_bin=/usr/bin/curl
  [[ -x /usr/bin/openssl ]] && openssl_bin=/usr/bin/openssl

  py_ver="$(python3 - <<'PY'
import sys
print(f'{sys.version_info.major}.{sys.version_info.minor}')
PY
)"
  stdlib="$(python3 - <<'PY'
import sysconfig
print(sysconfig.get_paths()['stdlib'])
PY
)"
  stdlib_parent="$(dirname "$stdlib")"
  stdlib_base="$(basename "$stdlib")"

  copy_binary_with_deps "$py_bin" "$STAGE/runtime/python/bin/python3"
  mkdir -p "$STAGE/runtime/python/lib"
  (
    cd "$stdlib_parent"
    tar \
      --exclude='*/__pycache__' \
      --exclude='*/test' \
      --exclude='*/tests' \
      --exclude='*/idlelib' \
      --exclude='*/tkinter' \
      -cf - "$stdlib_base"
  ) | (cd "$STAGE/runtime/python/lib" && tar -xf -)

  # Copy shared-library deps for Python extension modules too.
  if [[ -d "$STAGE/runtime/python/lib/python$py_ver/lib-dynload" ]]; then
    while IFS= read -r so; do copy_ldd_deps "$so"; done < <(find "$STAGE/runtime/python/lib/python$py_ver/lib-dynload" -type f -name '*.so')
  fi

  copy_binary_with_deps "$curl_bin" "$STAGE/runtime/bin/curl"
  copy_binary_with_deps "$openssl_bin" "$STAGE/runtime/bin/openssl"

  if [[ -f /etc/ssl/openssl.cnf ]]; then
    mkdir -p "$STAGE/runtime/ssl"
    cp /etc/ssl/openssl.cnf "$STAGE/runtime/ssl/openssl.cnf"
  fi
  if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
    mkdir -p "$STAGE/runtime/ssl/certs"
    cp /etc/ssl/certs/ca-certificates.crt "$STAGE/runtime/ssl/certs/ca-certificates.crt"
  fi

  cat > "$STAGE/runtime/runtime-info.txt" <<EOF
Built from host runtime
Host: $(uname -a)
Python: $($py_bin --version 2>&1)
Curl: $($curl_bin --version | head -1)
OpenSSL: $($openssl_bin version)
Build time: $(date -Is)
EOF
}

copy_supplied_runtime() {
  local dir="$1"
  echo "Copying supplied runtime: $dir"
  [[ -d "$dir" ]] || { echo "runtime dir not found: $dir" >&2; exit 1; }
  cp -a "$dir"/. "$STAGE/runtime/"
  [[ -x "$STAGE/runtime/bin/curl" ]] || echo "WARN: supplied runtime missing executable bin/curl" >&2
  [[ -x "$STAGE/runtime/bin/openssl" ]] || echo "WARN: supplied runtime missing executable bin/openssl" >&2
  [[ -x "$STAGE/runtime/python/bin/python3" ]] || echo "WARN: supplied runtime missing executable python/bin/python3" >&2
}

generate_wrappers() {
  echo "Generating launchers..."
  cat > "$STAGE/bootstrap-env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$PKG_ROOT/app"
RUNTIME_DIR="$PKG_ROOT/runtime"

if [[ -d "$RUNTIME_DIR/lib" ]]; then
  export LD_LIBRARY_PATH="$RUNTIME_DIR/lib:${LD_LIBRARY_PATH:-}"
fi
if [[ -f "$RUNTIME_DIR/ssl/openssl.cnf" ]]; then
  export OPENSSL_CONF="$RUNTIME_DIR/ssl/openssl.cnf"
fi
if [[ -f "$RUNTIME_DIR/ssl/certs/ca-certificates.crt" ]]; then
  export SSL_CERT_FILE="$RUNTIME_DIR/ssl/certs/ca-certificates.crt"
  export CURL_CA_BUNDLE="$RUNTIME_DIR/ssl/certs/ca-certificates.crt"
fi
if [[ -x "$RUNTIME_DIR/python/bin/python3" ]]; then
  export PYTHONHOME="$RUNTIME_DIR/python"
  export PYTHON_BIN="$RUNTIME_DIR/python/bin/python3"
  export PATH="$RUNTIME_DIR/python/bin:$RUNTIME_DIR/bin:$PATH"
else
  export PATH="$RUNTIME_DIR/bin:$PATH"
fi

export UPLOADER_PACKAGE_ROOT="$PKG_ROOT"
export UPLOADER_APP_DIR="$APP_DIR"

if [[ ! -f "$APP_DIR/Data/config.json" && -f "$APP_DIR/Data/config.template.json" ]]; then
  cp "$APP_DIR/Data/config.template.json" "$APP_DIR/Data/config.json"
  chmod 600 "$APP_DIR/Data/config.json" 2>/dev/null || true
fi
EOF

  cat > "$STAGE/run-pipeline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap-env.sh
source "$ROOT/bootstrap-env.sh"
cd "$UPLOADER_APP_DIR"
exec bash RUN_PIPELINE.sh "$@"
EOF

  cat > "$STAGE/run-stage.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap-env.sh
source "$ROOT/bootstrap-env.sh"
cd "$UPLOADER_APP_DIR"
exec bash RUN_STAGE.sh "$@"
EOF

  cat > "$STAGE/open-editor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap-env.sh
source "$ROOT/bootstrap-env.sh"
cd "$UPLOADER_APP_DIR"
exec bash RUN_DATA_EDITOR.sh "$@"
EOF

  cat > "$STAGE/run-advocate-lookup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap-env.sh
source "$ROOT/bootstrap-env.sh"
cd "$UPLOADER_APP_DIR"
exec bash RUN_ADVOCATE_LOOKUP.sh "$@"
EOF

  cat > "$STAGE/doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap-env.sh
source "$ROOT/bootstrap-env.sh"
APP="$UPLOADER_APP_DIR"
OFFLINE=false
if [[ "${1:-}" == "--offline" ]]; then OFFLINE=true; fi

FAIL=0
warn() { printf 'WARN: %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAIL=1; }

check_cmd() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then ok "$c: $(command -v "$c")"; else bad "missing command: $c"; fi
}

check_cmd bash
check_cmd curl
check_cmd openssl
if [[ -n "${PYTHON_BIN:-}" && -x "${PYTHON_BIN:-}" ]]; then
  ok "python: $PYTHON_BIN"
else
  if command -v python3 >/dev/null 2>&1; then export PYTHON_BIN="$(command -v python3)"; ok "python: $PYTHON_BIN"; else bad "missing python3"; fi
fi

if [[ -n "${PYTHON_BIN:-}" ]]; then
  if "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import json, http.server, html.parser, urllib.parse, subprocess, datetime
PY
  then
    ok "python stdlib imports"
  else
    bad "python stdlib imports failed"
  fi
fi

if [[ -f "$APP/Data/config.json" ]]; then ok "Data/config.json exists"; else bad "Data/config.json missing"; fi
if [[ -f "$APP/Data/pipeline.json" ]]; then ok "Data/pipeline.json exists"; else bad "Data/pipeline.json missing"; fi
if [[ -w "$APP/output" ]]; then ok "app/output writable"; else bad "app/output not writable"; fi
if [[ -w "$ROOT/output" ]]; then ok "package output writable"; else warn "package output not writable (app/output is used by V3)"; fi

if [[ -n "${PYTHON_BIN:-}" ]]; then
  if ! "$PYTHON_BIN" - "$APP" <<'PY'
import json, os, sys
app=sys.argv[1]
fail=0
def emit(level,msg):
    print(f'{level}: {msg}')
def load_json(rel):
    p=os.path.join(app, rel)
    try:
        with open(p, encoding='utf-8') as fh: return json.load(fh)
    except Exception as e:
        emit('FAIL', f'{rel} invalid: {e}'); return None
cfg=load_json('Data/config.json')
pipe=load_json('Data/pipeline.json')
if isinstance(cfg, dict):
    for k in ['CIS_BASE_URL','COURT_CODE','CIS_USER','CIS_PASSWORD']:
        v=str(cfg.get(k,'')).strip()
        if not v:
            emit('WARN', f'Data/config.json {k} is blank; live CIS runs will fail until edited')
        elif '<' in v or '>' in v:
            emit('WARN', f'Data/config.json {k} still looks like a placeholder')
if isinstance(pipe, dict):
    for s in pipe.get('stages', []):
        if s.get('run') is not True:
            continue
        name=s.get('name','<unnamed>')
        inp=s.get('input_file','')
        transform=s.get('transform_from','')
        bridge=s.get('bridge_script','')
        if bridge and not os.path.exists(os.path.join(app, bridge)):
            emit('FAIL', f'stage {name}: bridge missing: {bridge}'); fail=1
        if inp and not transform and not os.path.exists(os.path.join(app, inp)):
            emit('FAIL', f'stage {name}: input missing: {inp}'); fail=1
        elif inp and not transform:
            try:
                data=json.load(open(os.path.join(app, inp), encoding='utf-8'))
                if not isinstance(data, list):
                    emit('WARN', f'stage {name}: input is not a JSON array: {inp}')
            except Exception as e:
                emit('FAIL', f'stage {name}: input invalid JSON: {inp}: {e}'); fail=1
raise SystemExit(fail)
PY
  then
    FAIL=1
  fi
fi

if [[ "$OFFLINE" == false && -f "$APP/Data/config.json" && -n "${PYTHON_BIN:-}" ]]; then
  URL="$($PYTHON_BIN - "$APP/Data/config.json" <<'PY'
import json, sys
try: print((json.load(open(sys.argv[1], encoding='utf-8')).get('CIS_BASE_URL') or '').strip())
except Exception: print('')
PY
)"
  if [[ -z "$URL" || "$URL" == *'<'* ]]; then
    warn "skipping CIS reachability: CIS_BASE_URL is blank/placeholder"
  else
    if curl -fsS --connect-timeout 5 --max-time 10 -o /dev/null "$URL"; then ok "CIS_BASE_URL reachable"; else bad "CIS_BASE_URL not reachable: $URL"; fi
  fi
else
  warn "offline mode: skipped CIS reachability"
fi

if [[ $FAIL -eq 0 ]]; then
  echo "OK: package is ready"
else
  echo "FAIL: package has problems"
fi
exit $FAIL
EOF

  cat > "$STAGE/README_LINUX_PORTABLE.md" <<'EOF'
# Uploader V3 Linux portable package

Run from this directory:

```bash
./doctor.sh
./open-editor.sh          # edit Data/config.json in browser
./run-pipeline.sh --validate
./run-stage.sh --list
./run-advocate-lookup.sh
./run-stage.sh filing --dry-run
```

`Data/config.json` is created from `app/Data/config.template.json` on first run. Fill credentials before live CIS runs.
Runtime output is written inside `app/output/DDMMYYYY/`.

If the machine is headless, run:

```bash
./open-editor.sh --no-browser
```

Then open the printed URL through an SSH tunnel or edit `app/Data/config.json` directly.
EOF

  chmod +x "$STAGE"/*.sh "$STAGE/app"/*.sh 2>/dev/null || true
  find "$STAGE/app/source" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

copy_app
if [[ -n "$RUNTIME_DIR" ]]; then
  copy_supplied_runtime "$RUNTIME_DIR"
elif [[ "$SKIP_RUNTIME" == true ]]; then
  echo "Skipping bundled runtime; package will use target machine commands."
  cat > "$STAGE/runtime/runtime-info.txt" <<EOF
No bundled runtime included. Built with --skip-runtime at $(date -Is).
EOF
elif [[ "$COPY_SYSTEM_RUNTIME" == true ]]; then
  copy_system_runtime
fi
generate_wrappers

if [[ "$OFFLINE_DOCTOR" == true ]]; then
  echo "Running offline doctor in staging..."
  if ! (cd "$STAGE" && ./doctor.sh --offline); then
    echo "ERROR: staging doctor failed" >&2
    exit 1
  fi
fi

ARCHIVE="$DIST_DIR/$PKG_NAME.tar.gz"
SHA="$DIST_DIR/$PKG_NAME.sha256"
rm -f "$ARCHIVE" "$SHA"
(
  cd "$WORK_DIR"
  tar -czf "$ARCHIVE" "$PKG_NAME"
)
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$SHA")"
)

echo "Built: $ARCHIVE"
echo "SHA256: $SHA"
