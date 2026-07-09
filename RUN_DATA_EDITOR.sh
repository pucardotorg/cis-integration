#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# DATA/ JSON EDITOR - RUN THIS FILE
# ============================================================
# Opens a browser UI to view/edit/create the JSON files in Data/.
# CIS connection values live in Data/config.json (editable here too).
# Binds 127.0.0.1 only (no external exposure). Ctrl+C to stop.
#
# Options: --port 8766 --no-browser
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDITOR_SCRIPT="$SCRIPT_DIR/tools/data_editor.py"

if [[ ! -f "$EDITOR_SCRIPT" ]]; then
  echo "ERROR: Missing editor script: $EDITOR_SCRIPT" >&2; exit 1; fi

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN=python3;
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN=python;
  else echo "Missing python3/python" >&2; exit 1; fi
fi

PORT="8766"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--port" ]]; then PORT="$arg"; prev=""; continue; fi
  case "$arg" in
    --port=*) PORT="${arg#--port=}" ;;
    --port) prev="--port" ;;
    *) prev="" ;;
  esac
done

# Avoid the common confusing case: a V2 editor is already running on the same
# port, so the browser keeps showing that old server/Data folder. Fail early
# with the active server's Data path instead of silently opening a stale tab.
"$PYTHON_BIN" - "$PORT" <<'PY'
import http.client, json, socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", port))
except OSError:
    data_dir = "unknown"
    try:
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1.5)
        conn.request("GET", "/api/meta")
        res = conn.getresponse()
        if res.status == 200:
            data_dir = json.loads(res.read().decode("utf-8", "replace")).get("data_dir", "unknown")
    except Exception:
        pass
    print(f"ERROR: port {port} is already in use.", file=sys.stderr)
    print(f"Existing editor/server data_dir: {data_dir}", file=sys.stderr)
    print("Stop the existing editor (Ctrl+C in its terminal) or run:", file=sys.stderr)
    print(f"  bash RUN_DATA_EDITOR.sh --port {port + 1}", file=sys.stderr)
    sys.exit(1)
finally:
    s.close()
PY

echo "Starting V3 Data/ JSON editor"
echo "  URL:    http://127.0.0.1:$PORT"
echo "  Script: $EDITOR_SCRIPT"
echo "  Data:   $SCRIPT_DIR/Data"
"$PYTHON_BIN" "$EDITOR_SCRIPT" "$@" --data "$SCRIPT_DIR/Data"
