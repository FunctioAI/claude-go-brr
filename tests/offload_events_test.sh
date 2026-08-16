#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CLIENT="$ROOT/plugins/claude-go-brr/offload.sh"
TMP="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
REQUESTS="$TMP/requests.jsonl"
SERVER_PID=""
CLIENT_PID=""

cleanup() {
  [[ -z "$CLIENT_PID" ]] || { kill "$CLIENT_PID" 2>/dev/null || true; wait "$CLIENT_PID" 2>/dev/null || true; }
  [[ -z "$SERVER_PID" ]] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  find "$ROOT/.git/offload" -maxdepth 1 -type f -name 'test-*.patch' -delete 2>/dev/null || true
  find "$ROOT/.git/offload" -maxdepth 1 -type f -name 'test-*.output.txt' -delete 2>/dev/null || true
  find "$ROOT/.git/offload" -maxdepth 1 -type f -name 'test-*.result.json' -delete 2>/dev/null || true
  find "$ROOT/.git/offload" -maxdepth 1 -type f -name 'test-*.patch-check.txt' -delete 2>/dev/null || true
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
import socket
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

port = int(sys.argv[1])
requests_path = sys.argv[2]
runs = {}
lock = threading.Lock()
serial = 0
auth_polls = 0

def run_record(run_id, status, terminal, latest_cursor=0, claim_attempts=1, patch=None, agent_output=None, logs_complete=True):
    data = {
        "run_id": run_id,
        "status": status,
        "folder_id": "test",
        "folder_path": "",
        "prompts": ["test"],
        "worker_id": "test-worker" if status != "queued" else "",
        "target_worker_id": "",
        "created_at": time.time(),
        "claim_attempts": claim_attempts,
        "latest_log_cursor": latest_cursor,
        "logs_truncated": False,
        "updated_at": time.time(),
        "finished_at": time.time() if terminal else None,
    }
    if terminal:
        data["live_logs"] = {"last_seq": latest_cursor, "accepted_through": latest_cursor, "logs_complete": logs_complete, "logs_truncated": False}
    if patch is not None:
        data["patch"] = patch
    if agent_output is not None:
        data["agent_output"] = agent_output
    return data

def events_response(events, next_cursor, logs_truncated=False):
    return {"events": events, "next_cursor": next_cursor, "logs_truncated": logs_truncated}

def record_for(run_id, record):
    scenario = record["scenario"]
    poll = record["polls"]
    if scenario == "happy":
        if poll == 0:
            return run_record(run_id, "queued", False)
        if poll == 1:
            return run_record(run_id, "running", False, 1)
        if poll == 2:
            return run_record(run_id, "ok_patch", True, 3, patch="premature patch\n", agent_output="Premature agent output.")
        patch = "diff --git a/offload-validation-test.txt b/offload-validation-test.txt\nnew file mode 100644\nindex 0000000..e69de29\n"
        return run_record(run_id, "ok_patch", True, 3, patch=patch, agent_output="Final \x1b[31magent\x1b[0m output.")
    if scenario == "invalid_patch":
        return run_record(run_id, "ok_patch", True, patch="not a patch\n", agent_output="Invalid patch output.")
    if scenario in {"network_retry", "server_retry", "rate_limit"}:
        return run_record(run_id, "ok", poll > 0, 1 if poll > 0 else 0, agent_output=f"{scenario} result")
    if scenario == "terminal_drained":
        return run_record(run_id, "ok" if poll > 0 else "running", poll > 0, 1, agent_output="Drained result" if poll > 0 else None)
    if scenario == "cursor_skip":
        status_poll = record["status_polls"]
        if status_poll < 2:
            return run_record(run_id, "running", False, 0)
        if status_poll == 2:
            return run_record(run_id, "running", False, 1)
        return run_record(run_id, "ok", True, 1, agent_output="Cursor skip complete")
    if scenario == "unknown_terminal":
        return run_record(run_id, "custom_terminal_error", True, patch="partial patch", agent_output="Partial output")
    if scenario == "incomplete_logs":
        return run_record(run_id, "ok", True, 5, agent_output="Completed with incomplete logs", logs_complete=False)
    if scenario == "http_404":
        return run_record(run_id, "ok" if poll > 0 else "running", poll > 0, agent_output="Status-only result" if poll > 0 else None)
    if scenario == "timeout":
        return run_record(run_id, "running", False)
    if scenario == "claim_reset":
        if poll == 0:
            return run_record(run_id, "running", False, 1, 1)
        if poll == 1:
            return run_record(run_id, "running", False, 1, 2)
        return run_record(run_id, "ok", True, 1, 2, agent_output="Replacement complete")
    if scenario == "legacy_host":
        return {"run_id": run_id, "status": "running"}
    return run_record(run_id, "queued" if scenario == "cancel" else "running", False, 1)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def send_json(self, data, status=200, headers=None):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global serial, auth_polls
        if self.path == "/v1/github/app/install-url":
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            with lock:
                with open(requests_path, "a") as stream:
                    stream.write(json.dumps({"kind": "github", "body": body, "authorization": self.headers.get("Authorization")}) + "\n")
            self.send_json({"installation_required": False, "access_mode": "anonymous", "message": "Repository is public."})
            return
        if self.path == "/v1/auth/cli/exchange":
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            with lock:
                auth_polls += 1
                with open(requests_path, "a") as stream:
                    stream.write(json.dumps({"kind": "auth", "body": body, "poll": auth_polls}) + "\n")
                poll = auth_polls
            if poll == 1:
                self.send_json({"status": "pending", "interval": 1}, 202)
            else:
                self.send_json({"token": "off_client_test", "github_login": "tester"}, 201)
            return
        if self.path != "/v1/runs":
            self.send_json({"error": "not found"}, 404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        scenario = body.get("prompts", ["unknown"])[0]
        with lock:
            with open(requests_path, "a") as stream:
                stream.write(json.dumps({"kind": "submit", "body": body}) + "\n")
        if scenario == "invalid_run_id":
            self.send_json({"run_id": "../escape", "status": "queued"}, 202)
            return
        with lock:
            serial += 1
            run_id = f"test-{scenario}-{serial}"
            runs[run_id] = {"scenario": scenario, "polls": 0, "status_polls": 0}
        self.send_json({"run_id": run_id, "status": "queued"}, 202)

    def do_GET(self):
        parsed = urlparse(self.path)
        parts = parsed.path.strip("/").split("/")
        if len(parts) == 3 and parts[:2] == ["v1", "runs"]:
            with lock:
                run_id = parts[2]
                if run_id not in runs:
                    self.send_json({"error": "not found"}, 404)
                    return
                record = runs[run_id]
                with open(requests_path, "a") as stream:
                    stream.write(json.dumps({"kind": "run", "scenario": record["scenario"], "event_polls": record["polls"], "time": time.monotonic()}) + "\n")
                data = record_for(run_id, record)
                record["status_polls"] += 1
            self.send_json(data)
            return
        if len(parts) != 4 or parts[:2] != ["v1", "runs"] or parts[3] != "events" or parts[2] not in runs:
            self.send_json({"error": "not found"}, 404)
            return

        run_id = parts[2]
        query = parse_qs(parsed.query)
        after = int(query.get("after", ["-1"])[0])
        limit = int(query.get("limit_bytes", ["-1"])[0])
        with lock:
            record = runs[run_id]
            record["polls"] += 1
            poll = record["polls"]
            scenario = record["scenario"]
            with open(requests_path, "a") as stream:
                stream.write(json.dumps({
                    "kind": "events",
                    "scenario": scenario,
                    "poll": poll,
                    "after": after,
                    "limit": limit,
                    "accept": self.headers.get("Accept"),
                    "authorization": self.headers.get("Authorization"),
                    "time": time.monotonic(),
                }) + "\n")

        if scenario == "happy":
            if poll == 1:
                self.send_json(events_response([], after))
            elif poll == 2:
                self.send_json(events_response([{"seq": 1, "prompt_index": 0, "text": "first worker line\n"}, {"seq": 1, "prompt_index": 1, "text": "<script>pwned()</script>\n"}], 1))
            elif poll == 3:
                self.send_json(events_response([{"seq": 2, "prompt_index": 0, "text": "same delta\n"}, {"seq": 2, "prompt_index": 1, "text": "prompt one final\n"}], 2))
            else:
                self.send_json(events_response([{"seq": 3, "prompt_index": 0, "text": "same delta\n"}], 3))
            return
        if scenario == "invalid_patch":
            self.send_json(events_response([], after))
            return
        if scenario == "network_retry" and poll == 1:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if scenario == "server_retry" and poll == 1:
            self.send_json({"error": "temporary host failure"}, 500)
            return
        if scenario == "rate_limit" and poll == 1:
            self.send_json({"error": "slow down"}, 429, {"Retry-After": "1"})
            return
        if scenario in {"network_retry", "server_retry", "rate_limit"}:
            self.send_json(events_response([{"seq": 1, "prompt_index": 0, "text": f"{scenario} done\n"}], 1))
            return
        if scenario == "terminal_drained":
            self.send_json(events_response([{"seq": 1, "prompt_index": 0, "text": "fully drained\n"}], 1))
            return
        if scenario == "cursor_skip":
            if poll == 1:
                self.send_json(events_response([], after))
            else:
                self.send_json(events_response([{"seq": 1, "prompt_index": 0, "text": "cursor advanced\n"}], 1))
            return
        if scenario.startswith("http_"):
            status = int(scenario.split("_", 1)[1])
            self.send_json({"error": f"test {status}"}, status)
            return
        if scenario == "malformed":
            self.send_json(events_response([{"seq": 1, "prompt_index": 0, "text": "must not commit\n"}, {"seq": 1, "prompt_index": 1, "text": 7}], 1))
            return
        if scenario == "unknown_terminal":
            self.send_json(events_response([], after))
            return
        if scenario == "incomplete_logs":
            self.send_json(events_response([], after, True))
            return
        if scenario == "cancel":
            self.send_json(events_response([], after))
            return
        if scenario == "timeout":
            self.send_json(events_response([], after))
            return
        if scenario == "claim_reset":
            if poll == 1:
                self.send_json(events_response([{"seq": 1, "prompt_index": 0, "text": "abandoned attempt\n"}], 1))
            elif poll == 2:
                self.send_json(events_response([{"seq": 1, "prompt_index": 0, "text": "replacement attempt\n"}], 1))
            else:
                self.send_json(events_response([], after))
            return
        if scenario == "legacy_host":
            self.send_json({
                "run": {"run_id": run_id, "status": "ok", "terminal": True},
                "batches": [{"seq": 1, "events": [{"prompt_index": 0, "text": "legacy host\n"}]}],
                "last_seq": 1,
                "has_more": False,
                "result": {"agent_output": "Legacy result", "patch": ""},
            })
            return
        self.send_json({"error": "unknown scenario"}, 400)

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
SERVER_PID=$!

for _ in {1..50}; do
  python3 -c 'import socket, sys; s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.1); s.close()' "$PORT" >/dev/null 2>&1 && break
  sleep 0.1
done

run_client() {
  local scenario="$1" expected_status="$2"
  RUN_OUTPUT="$TMP/$scenario.out"
  set +e
  (cd "$ROOT" && TMPDIR="$TMP" OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_REMOTE=origin OFFLOAD_POLL_INTERVAL= OFFLOAD_RETRY_BACKOFF_BASE=1 OFFLOAD_POLL_TIMEOUT=8 "$CLIENT" submit "$scenario") >"$RUN_OUTPUT" 2>&1
  RUN_STATUS=$?
  set -e
  [[ "$RUN_STATUS" -eq "$expected_status" ]] || fail "$scenario exited $RUN_STATUS, expected $expected_status: $(<"$RUN_OUTPUT")"
}

run_client happy 0
happy_output="$(<"$RUN_OUTPUT")"
happy_run_id="$(sed -n 's/^  run_id=//p' "$RUN_OUTPUT" | tail -n 1)"
happy_log="$(sed -n 's/^  Claude Code output on the worker: //p' "$RUN_OUTPUT" | head -n 1)"
[[ -f "$happy_log" ]] || fail "happy worker log was not created"
[[ "$happy_output" == *"To see live Claude Code output, run: tail -f $happy_log"* ]] || fail "live worker log command was not displayed"
[[ "$happy_output" != *'Ctrl-C to stop waiting'* ]] || fail "obsolete Ctrl-C message was displayed"
[[ "$happy_output" != *"<script>"* ]] || fail "untrusted event text was printed into the process UI"
[[ "$(<"$happy_log")" == *'[prompt 0] first worker line'* ]] || fail "prompt 0 output missing"
[[ "$(<"$happy_log")" == *'[prompt 1] <script>pwned()</script>'* ]] || fail "prompt 1 text was not preserved as plain text"
[[ "$(grep -c '^\[prompt 0\] same delta$' "$happy_log")" -eq 2 ]] || fail "identical deltas were deduplicated or duplicated"
[[ "$(<"$ROOT/.git/offload/$happy_run_id.patch")" == *"offload-validation-test.txt"* ]] || fail "terminal result was consumed before stored batches were drained"
[[ "$(<"$ROOT/.git/offload/$happy_run_id.output.txt")" == *$'Final \e[31magent\e[0m output.'* ]] || fail "saved output did not preserve raw agent_output"
[[ ! -e "$ROOT/.git/offload/$happy_run_id.patch-check.txt" ]] || fail "successful patch check report was not removed"
[[ "$happy_output" == *$'Agent output:\nFinal agent output.'* ]] || fail "agent_output was not safely displayed"
[[ "$happy_output" != *$'\e['* ]] || fail "terminal escape sequence reached process output"
[[ "$happy_output" != *'Premature agent output.'* ]] || fail "terminal result was displayed before stored batches were drained"
[[ -s "$ROOT/.git/offload/$happy_run_id.result.json" ]] || fail "full run record was not preserved"

run_client terminal_drained 0
terminal_drained_run_id="$(sed -n 's/^  run_id=//p' "$RUN_OUTPUT" | tail -n 1)"
[[ "$(<"$ROOT/.git/offload/$terminal_drained_run_id.output.txt")" == "Drained result" ]] || fail "terminal result was not saved after skipping its redundant event request"

run_client cursor_skip 0
cursor_skip_run_id="$(sed -n 's/^  run_id=//p' "$RUN_OUTPUT" | tail -n 1)"
[[ "$(<"$ROOT/.git/offload/$cursor_skip_run_id.output.txt")" == "Cursor skip complete" ]] || fail "cursor-skip result was not saved"

run_client invalid_patch 65
invalid_patch_run_id="$(sed -n 's/^  run_id=//p' "$RUN_OUTPUT" | tail -n 1)"
[[ "$(<"$ROOT/.git/offload/$invalid_patch_run_id.patch")" == "not a patch" ]] || fail "invalid patch was not preserved"
[[ -s "$ROOT/.git/offload/$invalid_patch_run_id.patch-check.txt" ]] || fail "invalid patch check details were not preserved"
[[ "$(<"$RUN_OUTPUT")" == *'returned patch failed git apply --check'* ]] || fail "invalid patch failure was not surfaced"
[[ "$(<"$RUN_OUTPUT")" == *$'Agent output:\nInvalid patch output.'* ]] || fail "invalid patch agent output was not displayed"

run_client invalid_run_id 65
[[ "$(<"$RUN_OUTPUT")" == *'protocol error: run_id must be 1-128 URL- and filename-safe characters'* ]] || fail "unsafe run_id was not rejected"
[[ ! -e "$ROOT/.git/escape.patch" ]] || fail "unsafe run_id escaped the offload output directory"

run_client network_retry 0
[[ "$(<"$RUN_OUTPUT")" == *'retrying after 1.0s with after=0'* ]] || fail "network retry did not retain cursor 0"
run_client server_retry 0
[[ "$(<"$RUN_OUTPUT")" == *'HTTP 500; retrying after 1.0s with after=0'* ]] || fail "500 retry did not retain cursor 0"
run_client rate_limit 0
[[ "$(<"$RUN_OUTPUT")" == *'HTTP 429; retrying after 1s with after=0'* ]] || fail "429 did not honor Retry-After"

run_client http_400 65
[[ "$(<"$RUN_OUTPUT")" == *'protocol error: event request rejected (HTTP 400: test 400)'* ]] || fail "400 protocol error was not surfaced"
run_client http_401 77
[[ "$(<"$RUN_OUTPUT")" == *'authentication error:'* ]] || fail "401 authentication error was not surfaced"
run_client http_403 77
[[ "$(<"$RUN_OUTPUT")" == *'authorization error:'* ]] || fail "403 authorization error was not surfaced"
run_client http_404 0
[[ "$(<"$RUN_OUTPUT")" == *'live output is unavailable'* ]] || fail "missing event endpoint did not degrade to status-only polling"
run_client malformed 65
malformed_log="$(sed -n 's/^  Claude Code output on the worker: //p' "$RUN_OUTPUT" | head -n 1)"
[[ ! -s "$malformed_log" ]] || fail "malformed response partially applied a batch"
[[ "$(<"$RUN_OUTPUT")" == *'protocol error: event 1 text must be a string'* ]] || fail "malformed response error was not clear"
run_client unknown_terminal 1
[[ "$(<"$RUN_OUTPUT")" == *'x run custom_terminal_error'* ]] || fail "authoritative unknown terminal status was not displayed"
unknown_run_id="$(sed -n 's/^  run_id=//p' "$RUN_OUTPUT" | tail -n 1)"
[[ "$(<"$ROOT/.git/offload/$unknown_run_id.output.txt")" == "Partial output" ]] || fail "failed-run partial output was not preserved"
[[ "$(<"$ROOT/.git/offload/$unknown_run_id.patch")" == "partial patch" ]] || fail "failed-run partial patch was not preserved"

run_client incomplete_logs 0
[[ "$(<"$RUN_OUTPUT")" == *'live logs were truncated'* ]] || fail "log truncation was not surfaced"
[[ "$(<"$RUN_OUTPUT")" == *'live logs are incomplete'* ]] || fail "incomplete terminal logs were not surfaced"

run_client claim_reset 0
claim_log="$(sed -n 's/^  Claude Code output on the worker: //p' "$RUN_OUTPUT" | head -n 1)"
[[ "$(<"$claim_log")" == *'replacement attempt'* ]] || fail "replacement attempt output missing"
[[ "$(<"$claim_log")" != *'abandoned attempt'* ]] || fail "abandoned attempt output was mixed with replacement output"
[[ "$(<"$RUN_OUTPUT")" == *'worker attempt changed'* ]] || fail "claim-attempt reset was not surfaced"

timeout_output="$TMP/timeout.out"
set +e
(cd "$ROOT" && TMPDIR="$TMP" OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_REMOTE=origin OFFLOAD_POLL_INTERVAL= OFFLOAD_RETRY_BACKOFF_BASE=1 OFFLOAD_POLL_TIMEOUT=2 "$CLIENT" submit timeout) >"$timeout_output" 2>&1
timeout_status=$?
set -e
[[ "$timeout_status" -eq 0 ]] || fail "timeout scenario exited $timeout_status instead of preserving the status-check workflow"
[[ "$(<"$timeout_output")" == *'still running after 2s'* ]] || fail "timeout status guidance was not preserved"

run_client legacy_host 0
legacy_run_id="$(sed -n 's/^  run_id=//p' "$RUN_OUTPUT" | tail -n 1)"
[[ "$(<"$ROOT/.git/offload/$legacy_run_id.output.txt")" == "Legacy result" ]] || fail "legacy terminal result fallback was not preserved"

cancel_output="$TMP/cancel.out"
(cd "$ROOT" && exec env TMPDIR="$TMP" OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_REMOTE=origin OFFLOAD_POLL_INTERVAL= OFFLOAD_RETRY_BACKOFF_BASE=1 OFFLOAD_POLL_TIMEOUT=8 "$CLIENT" submit cancel) >"$cancel_output" 2>&1 &
CLIENT_PID=$!
for _ in {1..50}; do
  cancel_count="$(python3 -c 'import json, pathlib, sys; print(sum(json.loads(line).get("scenario") == "cancel" for line in pathlib.Path(sys.argv[1]).read_text().splitlines()))' "$REQUESTS")"
  [[ "$cancel_count" -gt 0 ]] && break
  sleep 0.1
done
[[ "${cancel_count:-0}" -gt 0 ]] || fail "cancel scenario never started polling"
kill -TERM "$CLIENT_PID"
set +e
wait "$CLIENT_PID"
cancel_status=$?
set -e
CLIENT_PID=""
[[ "$cancel_status" -eq 130 ]] || fail "cancelled client exited $cancel_status instead of 130"
sleep 1.2
cancel_count_after="$(python3 -c 'import json, pathlib, sys; print(sum(json.loads(line).get("scenario") == "cancel" for line in pathlib.Path(sys.argv[1]).read_text().splitlines()))' "$REQUESTS")"
[[ "$cancel_count_after" -eq "$cancel_count" ]] || fail "polling continued after cancellation"
compgen -G "$TMP/offload-poll-*" >/dev/null && fail "polling state was not cleaned up after cancellation"

python3 - "$REQUESTS" <<'PY'
import json
from pathlib import Path
import sys

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
event_records = [record for record in records if record["kind"] == "events"]
run_records = [record for record in records if record["kind"] == "run"]
assert run_records, "client did not poll run records"
for record in event_records:
    assert record["limit"] == 262144
    assert record["accept"] == "application/json"
    assert record["authorization"] == "Bearer test"

def scenario(name):
    return [record for record in event_records if record.get("scenario") == name]

happy = scenario("happy")
assert [record["after"] for record in happy] == [0, 0, 1, 2]
assert happy[1]["time"] - happy[0]["time"] >= 0.8, "caught-up queued response did not wait"
assert happy[2]["time"] - happy[1]["time"] >= 0.8, "current event polling interval was skipped"
assert happy[3]["time"] - happy[2]["time"] >= 0.8, "terminal drain polling interval was skipped"
assert happy[1]["time"] - happy[0]["time"] < 3.0, "default healthy poll interval did not change from five seconds to one"
terminal_drained = scenario("terminal_drained")
assert len(terminal_drained) == 1, "fully drained terminal status made a redundant event request"
cursor_skip = scenario("cursor_skip")
assert [record["after"] for record in cursor_skip] == [0, 0], "caught-up current-protocol event request was not skipped or cursor advance was not drained"
cursor_skip_runs = [record for record in run_records if record.get("scenario") == "cursor_skip"]
assert len(cursor_skip_runs) == 4, "cursor-skip status sequence did not reach the terminal record"
for name in ("network_retry", "server_retry", "rate_limit"):
    attempts = scenario(name)
    assert [record["after"] for record in attempts] == [0, 0], f"{name} advanced its cursor while retrying"
    assert attempts[1]["time"] - attempts[0]["time"] >= 0.8, f"{name} did not back off"
PY

request_count() {
  python3 -c 'import json, pathlib, sys; print(sum(json.loads(line).get("kind") == sys.argv[2] for line in pathlib.Path(sys.argv[1]).read_text().splitlines()))' "$REQUESTS" "$1"
}

assert_invalid_poll_config() {
  local name="$1" value="$2" before after output status
  output="$TMP/invalid-${name}-${value//[^A-Za-z0-9]/_}.out"
  before="$(request_count submit)"
  set +e
  (cd "$ROOT" && env TMPDIR="$TMP" OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_REMOTE=origin OFFLOAD_POLL_INTERVAL=1 OFFLOAD_RETRY_BACKOFF_BASE=5 OFFLOAD_POLL_TIMEOUT=8 "$name=$value" "$CLIENT" submit --no-wait invalid-config) >"$output" 2>&1
  status=$?
  set -e
  after="$(request_count submit)"
  [[ "$status" -eq 78 ]] || fail "$name=$value exited $status instead of 78: $(<"$output")"
  [[ "$before" -eq "$after" ]] || fail "$name=$value submitted a run before rejecting invalid polling configuration"
  [[ "$(<"$output")" == *"$name must be"* ]] || fail "$name=$value did not identify the invalid setting"
}

assert_invalid_poll_config OFFLOAD_POLL_INTERVAL 0
assert_invalid_poll_config OFFLOAD_POLL_INTERVAL nan
assert_invalid_poll_config OFFLOAD_POLL_INTERVAL 60.1
assert_invalid_poll_config OFFLOAD_RETRY_BACKOFF_BASE 0
assert_invalid_poll_config OFFLOAD_RETRY_BACKOFF_BASE inf
assert_invalid_poll_config OFFLOAD_RETRY_BACKOFF_BASE 30.1
assert_invalid_poll_config OFFLOAD_POLL_TIMEOUT 0
assert_invalid_poll_config OFFLOAD_POLL_TIMEOUT 1.5
assert_invalid_poll_config OFFLOAD_POLL_TIMEOUT 31536001

export OFFLOAD_CONFIG="$TMP/config"
unset OFFLOAD_POLL_INTERVAL OFFLOAD_RETRY_BACKOFF_BASE OFFLOAD_POLL_TIMEOUT
# shellcheck source=../plugins/claude-go-brr/offload.sh
source "$CLIENT"
[[ "$POLL_INTERVAL" == "1" ]] || fail "default healthy polling interval is not one second"
[[ "$RETRY_BACKOFF_BASE" == "5" ]] || fail "default transient retry base is not five seconds"
[[ "$(bounded_backoff 1)" == "5.0" ]] || fail "first transient retry did not use the independent five-second base"
[[ "$(bounded_backoff 2)" == "10.0" ]] || fail "second transient retry did not back off exponentially"
[[ "$(bounded_backoff 4)" == "30.0" ]] || fail "transient retry backoff did not retain its 30-second cap"
require_run_id "$(printf 'a%.0s' {1..128})"
if (require_run_id "$(printf 'a%.0s' {1..129})") >/dev/null 2>&1; then
  fail "129-character run_id was accepted"
fi
[[ "$(project_folder_id owner repo a/b)" != "$(project_folder_id owner repo a-b)" ]] || fail "folder IDs collide for distinct subdirectory paths"
[[ "$(project_folder_id owner repo path)" != "$(project_folder_id other repo path)" ]] || fail "folder IDs collide for distinct repository owners"
unit_body="$TMP/unit.json"
unit_state="$TMP/unit-state.json"
unit_log="$TMP/unit.log"
python3 - "$unit_body" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(json.dumps({
    "events": [{"seq": 1, "prompt_index": 0, "text": "same\n"}, {"seq": 1, "prompt_index": 1, "text": "other\n"}],
    "next_cursor": 1,
    "logs_truncated": False,
}))
PY
apply_events_response "$unit_body" unit 0 "$unit_state" "$unit_log" >/dev/null
unit_log_inode="$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$unit_log")"
apply_events_response "$unit_body" unit 0 "$unit_state" "$unit_log" >/dev/null
[[ "$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$unit_log")" == "$unit_log_inode" ]] || fail "live worker log was replaced instead of appended"
[[ "$(grep -c '^\[prompt 0\] same$' "$unit_log")" -eq 1 ]] || fail "same-cursor replay duplicated committed output"
[[ "$(grep -c '^\[prompt 1\] other$' "$unit_log")" -eq 1 ]] || fail "multi-event batch was not applied atomically"

legacy_body="$TMP/legacy.json"
legacy_state="$TMP/legacy-state.json"
legacy_log="$TMP/legacy.log"
python3 - "$legacy_body" <<'PY'
import json
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(json.dumps({
    "run": {"run_id": "legacy", "status": "running", "terminal": False},
    "batches": [{"seq": 1, "events": [{"prompt_index": 0, "text": "legacy\n"}]}],
    "last_seq": 1,
    "has_more": False,
}))
PY
[[ "$(apply_events_response "$legacy_body" legacy 0 "$legacy_state" "$legacy_log")" == $'1\tlegacy\t0\trunning\t0\t0' ]] || fail "legacy response fallback did not parse"

auth_config="$TMP/auth-config"
OFFLOAD_CONFIG="$auth_config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_POLL_INTERVAL=2 OFFLOAD_RETRY_BACKOFF_BASE=3 OFFLOAD_POLL_TIMEOUT=10 "$CLIENT" auth exchange test-device --name protocol-test >/dev/null
[[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$auth_config")" == "0o600" ]] || fail "auth config permissions are not 0600"
[[ "$(<"$auth_config")" == *'OFFLOAD_API_KEY=off_client_test'* ]] || fail "exchange token was not saved"
[[ "$(<"$auth_config")" == *'OFFLOAD_POLL_INTERVAL=2'* ]] || fail "healthy poll interval was not preserved in saved config"
[[ "$(<"$auth_config")" == *'OFFLOAD_RETRY_BACKOFF_BASE=3'* ]] || fail "transient retry base was not preserved in saved config"
[[ "$(<"$auth_config")" == *'OFFLOAD_POLL_TIMEOUT=10'* ]] || fail "poll timeout was not preserved in saved config"
override_values="$(OFFLOAD_CONFIG="$auth_config" OFFLOAD_POLL_INTERVAL=0.5 OFFLOAD_RETRY_BACKOFF_BASE=4 OFFLOAD_POLL_TIMEOUT=9 bash -c 'source "$1"; printf "%s\t%s\t%s" "$POLL_INTERVAL" "$RETRY_BACKOFF_BASE" "$POLL_TIMEOUT"' _ "$CLIENT")"
[[ "$override_values" == $'0.5\t4\t9' ]] || fail "environment polling overrides did not take precedence over saved config"
python3 - "$REQUESTS" <<'PY'
import json
from pathlib import Path
import sys

auth = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if json.loads(line).get("kind") == "auth"]
assert len(auth) == 2, "pending exchange was not polled"
assert auth[0]["body"]["scopes"] == "runs:read,runs:write,github:setup,env:read"
assert auth[0]["body"]["name"] == "protocol-test"
PY

OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test "$CLIENT" github install-url --repo acme/widgets >"$TMP/github.out"
[[ "$(<"$TMP/github.out")" == *'"installation_required": false'* ]] || fail "host public-repository decision was not returned"
python3 - "$REQUESTS" <<'PY'
import json
from pathlib import Path
import sys

requests = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
request = [item for item in requests if item.get("kind") == "github"][-1]
assert request["body"] == {"owner": "acme", "repo": "widgets"}
assert request["authorization"] == "Bearer test"
PY

OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_REMOTE=origin "$CLIENT" submit --no-wait -- $'first\nsecond' >/dev/null
OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_REMOTE=origin "$CLIENT" submit --no-wait --individual-instances -- $'compat-first\ncompat-second' >/dev/null
python3 - "$REQUESTS" <<'PY'
import json
from pathlib import Path
import sys

submissions = [json.loads(line)["body"] for line in Path(sys.argv[1]).read_text().splitlines() if json.loads(line).get("kind") == "submit"]
assert submissions[-2]["prompts"] == ["first", "second"]
assert submissions[-1]["prompts"] == ["compat-first", "compat-second"]
assert all("prompt" not in submission for submission in submissions)
assert any(submission["prompts"] == ["happy"] for submission in submissions)
PY

set +e
(cd "$ROOT" && OFFLOAD_CONFIG="$TMP/config" OFFLOAD_API_URL="http://127.0.0.1:$PORT" OFFLOAD_API_KEY=test OFFLOAD_REMOTE=origin "$CLIENT" submit "   ") >"$TMP/blank.out" 2>&1
blank_status=$?
set -e
[[ "$blank_status" -ne 0 && "$(<"$TMP/blank.out")" == *'prompt input must contain 1-128 nonblank lines'* ]] || fail "blank prompt was accepted"

echo "PASS: current two-poll protocol, legacy fallback, retry resets, output safety, and cancellation"
