#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CLIENT="$ROOT/plugins/claude-go-brr/offload.sh"
TMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
REQUESTS="$TMP/requests.jsonl"
SERVER_PID=""

cleanup() {
  [[ -z "$SERVER_PID" ]] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 - "$PORT" "$REQUESTS" <<'PY' &
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

port = int(sys.argv[1])
requests_path = Path(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def record(self, payload):
        with requests_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"method": self.command, "path": self.path, "payload": payload}) + "\n")

    def do_GET(self):
        self.record(None)
        self.send_json(200, {"folder_id": "test-folder", "keys": [{"key": "CLAUDE_BRR_TOOLS"}], "count": 1})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        self.record(payload)
        expected = payload.get("expected") or {}
        folder_id = self.path.split("/")[3]
        if expected.get("CLAUDE_BRR_EFFORT") == "xhigh":
            self.send_json(404, {"error": "not found"})
        elif expected.get("CLAUDE_BRR_MAX_BUDGET_USD") == "0.30":
            self.send_json(200, {
                "folder_id": folder_id,
                "matches": True,
                "checked_keys": sorted(expected),
                "missing_keys": [],
                "mismatched_keys": [],
            })
        else:
            self.send_json(200, {
                "folder_id": folder_id,
                "matches": False,
                "checked_keys": sorted(expected),
                "missing_keys": [],
                "mismatched_keys": ["CLAUDE_BRR_MAX_BUDGET_USD"],
            })

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
SERVER_PID=$!

for _ in $(seq 1 50); do
  if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(.1); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$PORT"; then
    break
  fi
  sleep 0.05
done

run_client() {
  OFFLOAD_CONFIG="$TMP/missing-config" \
  OFFLOAD_API_URL="http://127.0.0.1:$PORT" \
  OFFLOAD_API_KEY="test-client-key" \
  OFFLOAD_REMOTE="origin" \
  "$CLIENT" env -d "$ROOT" "$@"
}

run_client > "$TMP/metadata.out"
[[ "$(<"$TMP/metadata.out")" == *"Configured env vars (count=1):"* ]] || fail "ordinary env metadata output changed"

run_client \
  --expect CLAUDE_BRR_MODEL=claude-sonnet-5 \
  --expect CLAUDE_BRR_MAX_BUDGET_USD=0.30 \
  --expect CLAUDE_BRR_TOOLS=Bash > "$TMP/match.out"
[[ "$(<"$TMP/match.out")" == *"runtime_env_match=true"* ]] || fail "matching values were not attested"
[[ "$(<"$TMP/match.out")" != *"0.30"* ]] || fail "matching value leaked to output"

set +e
run_client --expect CLAUDE_BRR_MAX_BUDGET_USD=0.60 > "$TMP/mismatch.out" 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "mismatched value did not fail closed"
[[ "$(<"$TMP/mismatch.out")" == *"runtime_env_match=false"* ]] || fail "mismatch result was not reported"
[[ "$(<"$TMP/mismatch.out")" == *"mismatched_keys=CLAUDE_BRR_MAX_BUDGET_USD"* ]] || fail "mismatched key was not reported"
[[ "$(<"$TMP/mismatch.out")" != *"0.60"* ]] || fail "mismatched value leaked to output"

requests_before="$(wc -l < "$REQUESTS" | tr -d ' ')"
set +e
run_client --expect ANTHROPIC_API_KEY=guess > "$TMP/secret.out" 2>&1
status=$?
set -e
[[ "$status" -eq 64 ]] || fail "credential key was not rejected locally"
[[ "$(wc -l < "$REQUESTS" | tr -d ' ')" == "$requests_before" ]] || fail "credential expectation reached the host"
[[ "$(<"$TMP/secret.out")" != *"guess"* ]] || fail "rejected credential guess leaked to output"

set +e
run_client --expect CLAUDE_BRR_EFFORT=xhigh > "$TMP/legacy.out" 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "old host response did not fail closed"
[[ "$(<"$TMP/legacy.out")" == *"HTTP 404"* ]] || fail "old host failure was not explicit"

echo "env verification tests passed"
