#!/usr/bin/env bash
#
# offload.sh - CLI client for the agent offload host API.
#
# One-time setup:
#   offload.sh auth start
#   offload.sh auth exchange DEVICE_CODE --name my-laptop
#   offload.sh github install-url --repo OWNER/REPO  # private repos only
#
# Project environment variables:
#   offload.sh env
#   offload.sh env -d /path/to/folder
#   offload.sh env -d /path/to/folder --expect CLAUDE_BRR_MODEL=claude-sonnet-5
#   Set values once per project in the printed browser URL. The CLI shows key names only.
#   Values are injected automatically on every run; browser changes apply to the next run.
#
# Submit and inspect runs:
#   offload.sh "implement the thing"
#   offload.sh submit -d /path/to/folder "fix the bug in checkout"
#   offload.sh --no-wait "long task"
#   offload.sh runs
#   offload.sh status RUN_ID
#
# Config (env or ~/.config/offload/config):
#   OFFLOAD_API_URL   e.g. https://accelerator.functio.ai (default for auth)
#   OFFLOAD_API_KEY   host-issued client API key
#   OFFLOAD_GITHUB_LOGIN authenticated GitHub login, saved when returned by auth
#   OFFLOAD_REMOTE    optional explicit git remote override
#   OFFLOAD_POLL_INTERVAL successful run/event polling interval (default 1 second)
#   OFFLOAD_RETRY_BACKOFF_BASE transient-error retry base (default 5 seconds)
#   OFFLOAD_POLL_TIMEOUT maximum wait for a submitted run (default 3600 seconds)
#   OFFLOAD_POLL_CONNECT_TIMEOUT connection bound for status/event polls (default 5 seconds)
#
set -Eeuo pipefail

DEFAULT_API_URL="https://accelerator.functio.ai"
CONFIG="${OFFLOAD_CONFIG:-$HOME/.config/offload/config}"
ENV_OFFLOAD_API_URL="${OFFLOAD_API_URL-}"
ENV_OFFLOAD_API_KEY="${OFFLOAD_API_KEY-}"
ENV_OFFLOAD_REMOTE="${OFFLOAD_REMOTE-}"
ENV_OFFLOAD_GITHUB_LOGIN="${OFFLOAD_GITHUB_LOGIN-}"
ENV_OFFLOAD_POLL_INTERVAL="${OFFLOAD_POLL_INTERVAL-}"
ENV_OFFLOAD_RETRY_BACKOFF_BASE="${OFFLOAD_RETRY_BACKOFF_BASE-}"
ENV_OFFLOAD_POLL_TIMEOUT="${OFFLOAD_POLL_TIMEOUT-}"
ENV_OFFLOAD_POLL_CONNECT_TIMEOUT="${OFFLOAD_POLL_CONNECT_TIMEOUT-}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
[[ -n "$ENV_OFFLOAD_API_URL" ]] && OFFLOAD_API_URL="$ENV_OFFLOAD_API_URL"
[[ -n "$ENV_OFFLOAD_API_KEY" ]] && OFFLOAD_API_KEY="$ENV_OFFLOAD_API_KEY"
[[ -n "$ENV_OFFLOAD_REMOTE" ]] && OFFLOAD_REMOTE="$ENV_OFFLOAD_REMOTE"
[[ -n "$ENV_OFFLOAD_GITHUB_LOGIN" ]] && OFFLOAD_GITHUB_LOGIN="$ENV_OFFLOAD_GITHUB_LOGIN"
[[ -n "$ENV_OFFLOAD_POLL_INTERVAL" ]] && OFFLOAD_POLL_INTERVAL="$ENV_OFFLOAD_POLL_INTERVAL"
[[ -n "$ENV_OFFLOAD_RETRY_BACKOFF_BASE" ]] && OFFLOAD_RETRY_BACKOFF_BASE="$ENV_OFFLOAD_RETRY_BACKOFF_BASE"
[[ -n "$ENV_OFFLOAD_POLL_TIMEOUT" ]] && OFFLOAD_POLL_TIMEOUT="$ENV_OFFLOAD_POLL_TIMEOUT"
[[ -n "$ENV_OFFLOAD_POLL_CONNECT_TIMEOUT" ]] && OFFLOAD_POLL_CONNECT_TIMEOUT="$ENV_OFFLOAD_POLL_CONNECT_TIMEOUT"

POLL_INTERVAL="${OFFLOAD_POLL_INTERVAL:-1}"
RETRY_BACKOFF_BASE="${OFFLOAD_RETRY_BACKOFF_BASE:-5}"
POLL_TIMEOUT="${OFFLOAD_POLL_TIMEOUT:-3600}"
POLL_CONNECT_TIMEOUT="${OFFLOAD_POLL_CONNECT_TIMEOUT:-5}"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

normalize_api_url() {
  local url
  url="$(printf '%s' "$1" | sed 's:/*$::')"
  case "$url" in
    https://*|http://127.0.0.1:*|http://localhost:*) printf '%s' "$url" ;;
    *) echo "error: OFFLOAD_API_URL must use HTTPS (HTTP is allowed only for localhost)" >&2; return 78 ;;
  esac
}

api_url() {
  normalize_api_url "${OFFLOAD_API_URL:-$DEFAULT_API_URL}"
}

require_api_key() {
  [[ -n "${OFFLOAD_API_KEY:-}" ]] && return
  echo "error: OFFLOAD_API_KEY not set (see $CONFIG or run: $0 auth start)" >&2
  exit 78
}

require_run_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && return
  echo "protocol error: run_id must be 1-128 URL- and filename-safe characters" >&2
  exit 65
}

json_field() {
  python3 -c 'import json, sys
field = sys.argv[1]
doc = json.load(sys.stdin)
value = doc
for part in field.split("."):
    if isinstance(value, dict):
        value = value.get(part, "")
    else:
        value = ""
        break
if value is None:
    value = ""
print(json.dumps(value) if isinstance(value, (dict, list)) else value)' "$1"
}

apply_events_response() {
  local body_file="$1" run_id="$2" requested_after="$3" state_file="$4" log_file="$5"

  python3 - "$body_file" "$run_id" "$requested_after" "$state_file" "$log_file" <<'PY'
import json
import os
from pathlib import Path
import re
import sys

body_path, requested_run_id, requested_after, state_path, log_path = sys.argv[1:]
requested_after = int(requested_after)
state_path = Path(state_path)
log_path = Path(log_path)

def protocol_error(message):
    print(f"protocol error: {message}", file=sys.stderr)
    raise SystemExit(65)

def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)

try:
    doc = json.loads(Path(body_path).read_text())
except Exception as exc:
    protocol_error(f"events response is not valid JSON: {exc}")

if not isinstance(doc, dict):
    protocol_error("events response must be an object")
new_events = []
legacy_status = "-"
legacy_terminal = False
legacy_has_more = False

if isinstance(doc.get("events"), list) and "next_cursor" in doc:
    shape = "current"
    next_cursor = doc["next_cursor"]
    logs_truncated = doc.get("logs_truncated")
    if not integer(next_cursor) or not requested_after <= next_cursor <= 9223372036854775807:
        protocol_error("events response next_cursor must be a valid cursor not behind after")
    if not isinstance(logs_truncated, bool):
        protocol_error("events response logs_truncated must be boolean")
    previous_key = None
    previous_seq = None
    prompt_indexes = set()
    for event_index, event in enumerate(doc["events"]):
        if not isinstance(event, dict):
            protocol_error(f"event {event_index} must be an object")
        seq = event.get("seq")
        prompt_index = event.get("prompt_index")
        text = event.get("text")
        if not integer(seq) or not requested_after < seq <= next_cursor:
            protocol_error(f"event {event_index} seq must be after the requested cursor and at most next_cursor")
        if not integer(prompt_index) or prompt_index < 0:
            protocol_error(f"event {event_index} prompt_index must be a non-negative integer")
        if not isinstance(text, str):
            protocol_error(f"event {event_index} text must be a string")
        key = (seq, prompt_index)
        if previous_key is not None and key <= previous_key:
            protocol_error("events must be ordered by seq, then prompt_index")
        if seq != previous_seq:
            prompt_indexes = set()
            previous_seq = seq
        if prompt_index in prompt_indexes:
            protocol_error(f"batch {seq} contains duplicate prompt_index {prompt_index}")
        prompt_indexes.add(prompt_index)
        previous_key = key
        new_events.append({"seq": seq, "prompt_index": prompt_index, "text": text})
    if doc["events"] and next_cursor != doc["events"][-1]["seq"]:
        protocol_error("events response next_cursor must equal the last returned batch seq")
    if not doc["events"] and next_cursor != requested_after:
        protocol_error("empty events response must preserve the requested cursor")
elif isinstance(doc.get("batches"), list) and "last_seq" in doc:
    shape = "legacy"
    run = doc.get("run")
    if not isinstance(run, dict) or run.get("run_id") != requested_run_id:
        protocol_error("legacy events response run_id does not match the requested run")
    legacy_status = run.get("status")
    legacy_terminal = run.get("terminal")
    legacy_has_more = doc.get("has_more")
    if not isinstance(legacy_status, str) or not isinstance(legacy_terminal, bool):
        protocol_error("legacy events response run status/terminal is invalid")
    if not isinstance(legacy_has_more, bool):
        protocol_error("legacy events response has_more must be boolean")
    next_cursor = doc["last_seq"]
    logs_truncated = bool(doc.get("logs_truncated", False))
    if not integer(next_cursor) or next_cursor < requested_after:
        protocol_error("legacy events response last_seq must not be behind after")
    previous_seq = requested_after
    for batch_index, batch in enumerate(doc["batches"]):
        if not isinstance(batch, dict):
            protocol_error(f"batch {batch_index} must be an object")
        seq = batch.get("seq")
        events = batch.get("events")
        if not integer(seq) or seq != previous_seq + 1:
            protocol_error(f"batch {batch_index} seq must be contiguous after {previous_seq}")
        if not isinstance(events, list):
            protocol_error(f"batch {seq} events must be an array")
        prompt_indexes = set()
        for event_index, event in enumerate(events):
            if not isinstance(event, dict):
                protocol_error(f"batch {seq} event {event_index} must be an object")
            prompt_index = event.get("prompt_index")
            text = event.get("text")
            if not integer(prompt_index) or prompt_index < 0:
                protocol_error(f"batch {seq} event {event_index} prompt_index must be a non-negative integer")
            if prompt_index in prompt_indexes:
                protocol_error(f"batch {seq} contains duplicate prompt_index {prompt_index}")
            if not isinstance(text, str):
                protocol_error(f"batch {seq} event {event_index} text must be a string")
            prompt_indexes.add(prompt_index)
            new_events.append({"seq": seq, "prompt_index": prompt_index, "text": text})
        previous_seq = seq
    expected_cursor = doc["batches"][-1]["seq"] if doc["batches"] else requested_after
    if next_cursor != expected_cursor:
        protocol_error(f"legacy events response last_seq must equal {expected_cursor}")
else:
    protocol_error("unknown events response shape")

try:
    state = json.loads(state_path.read_text()) if state_path.exists() else {"after": 0, "events": []}
    committed_after = state["after"]
    committed_events = state["events"]
    if not integer(committed_after) or not isinstance(committed_events, list):
        raise ValueError("invalid polling state")
except Exception as exc:
    protocol_error(f"local polling state is invalid: {exc}")

if committed_after == requested_after:
    state = {"after": next_cursor, "events": committed_events + new_events}
    temporary_state = state_path.with_name(f"{state_path.name}.{os.getpid()}.tmp")
    temporary_state.write_text(json.dumps(state))
    os.replace(temporary_state, state_path)
elif committed_after == next_cursor and new_events:
    # A previous application committed before its caller observed success.
    # Re-render the committed state without duplicating sequence batches.
    state = {"after": committed_after, "events": committed_events}
else:
    protocol_error(f"local polling cursor {committed_after} does not match requested cursor {requested_after}")

ansi = re.compile(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
rendered = []
for event in state["events"]:
    text = ansi.sub("", event["text"])
    text = "".join(char for char in text if char in "\n\t" or ord(char) >= 32)
    rendered.append(f"[prompt {event['prompt_index']}] {text}")
    if text and not text.endswith("\n"):
        rendered.append("\n")
rendered = "".join(rendered)
committed_log = log_path.read_text() if log_path.exists() else ""
if not rendered.startswith(committed_log):
    protocol_error("local worker log does not match committed polling state")
with log_path.open("a") as stream:
    stream.write(rendered[len(committed_log):])

print(f"{next_cursor}\t{shape}\t{int(logs_truncated)}\t{legacy_status}\t{int(legacy_terminal)}\t{int(legacy_has_more)}")
PY
}

parse_run_record() {
  local body_file="$1" run_id="$2"
  python3 - "$body_file" "$run_id" <<'PY'
import json
import math
from pathlib import Path
import re
import sys

doc = json.loads(Path(sys.argv[1]).read_text())
if not isinstance(doc, dict) or doc.get("run_id") != sys.argv[2]:
    print("protocol error: run record does not match requested run_id", file=sys.stderr)
    raise SystemExit(65)
status = doc.get("status")
finished_at = doc.get("finished_at")
claim_attempts = doc.get("claim_attempts", 0)
latest_cursor = doc.get("latest_log_cursor", 0)
latest_cursor_present = "latest_log_cursor" in doc
logs_truncated = doc.get("logs_truncated", False)
if not isinstance(status, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", status):
    print("protocol error: run status must be an identifier", file=sys.stderr)
    raise SystemExit(65)
if finished_at is not None and (isinstance(finished_at, bool) or not isinstance(finished_at, (int, float)) or not math.isfinite(finished_at)):
    print("protocol error: run finished_at must be a finite number or null", file=sys.stderr)
    raise SystemExit(65)
if isinstance(claim_attempts, bool) or not isinstance(claim_attempts, int) or claim_attempts < 0:
    print("protocol error: run claim_attempts must be a non-negative integer", file=sys.stderr)
    raise SystemExit(65)
if isinstance(latest_cursor, bool) or not isinstance(latest_cursor, int) or latest_cursor < 0:
    print("protocol error: run latest_log_cursor must be a non-negative integer", file=sys.stderr)
    raise SystemExit(65)
if not isinstance(logs_truncated, bool):
    print("protocol error: run logs_truncated must be boolean", file=sys.stderr)
    raise SystemExit(65)
live_logs = doc.get("live_logs")
logs_complete = live_logs.get("logs_complete") if isinstance(live_logs, dict) else None
logs_complete_value = int(logs_complete) if isinstance(logs_complete, bool) else -1
print(f"{status}\t{int(finished_at is not None)}\t{claim_attempts}\t{latest_cursor}\t{int(latest_cursor_present)}\t{int(logs_truncated)}\t{logs_complete_value}")
PY
}

reset_live_state() {
  local state_file="$1" log_file="$2"
  python3 - "$state_file" <<'PY'
import json
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
temporary.write_text(json.dumps({"after": 0, "events": []}))
os.replace(temporary, path)
PY
  : > "$log_file"
}

json_error_message() {
  python3 -c 'import json, pathlib, sys
try:
    doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
    if not isinstance(doc, dict):
        print("")
    else:
        error = doc.get("error", "")
        code = doc.get("code", "")
        if isinstance(error, dict):
            code = error.get("code", code)
            error = error.get("message", "")
        print(": ".join(str(value) for value in (code, error) if value))
except Exception:
    print("")' "$1"
}

retry_after_seconds() {
  python3 - "$1" <<'PY'
import email.utils
import math
from pathlib import Path
import time
import sys

value = ""
for line in Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if line.lower().startswith("retry-after:"):
        value = line.split(":", 1)[1].strip()
if value.isdigit():
    print(value)
elif value:
    try:
        print(max(0, math.ceil(email.utils.parsedate_to_datetime(value).timestamp() - time.time())))
    except Exception:
        pass
PY
}

bounded_backoff() {
  python3 -c 'import sys
attempt = int(sys.argv[1])
base = float(sys.argv[2])
print(min(30.0, base * (2 ** min(attempt - 1, 5))))' "$1" "$RETRY_BACKOFF_BASE"
}

validate_poll_configuration() {
  python3 - "$POLL_INTERVAL" "$RETRY_BACKOFF_BASE" "$POLL_TIMEOUT" "$POLL_CONNECT_TIMEOUT" <<'PY'
import math
import re
import sys

poll_interval, retry_base, poll_timeout, connect_timeout = sys.argv[1:]

def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(78)

def bounded_number(name, raw, minimum, maximum):
    try:
        value = float(raw)
    except (TypeError, ValueError):
        fail(f"{name} must be a finite number between {minimum:g} and {maximum:g} seconds")
    if not math.isfinite(value) or not minimum <= value <= maximum:
        fail(f"{name} must be a finite number between {minimum:g} and {maximum:g} seconds")

bounded_number("OFFLOAD_POLL_INTERVAL", poll_interval, 0.1, 60.0)
bounded_number("OFFLOAD_RETRY_BACKOFF_BASE", retry_base, 0.1, 30.0)
bounded_number("OFFLOAD_POLL_CONNECT_TIMEOUT", connect_timeout, 0.1, 60.0)
if not re.fullmatch(r"[1-9][0-9]*", poll_timeout) or not 1 <= int(poll_timeout) <= 31_536_000:
    fail("OFFLOAD_POLL_TIMEOUT must be an integer between 1 and 31536000 seconds")
PY
}

poll_sleep() {
  local delay="$1" started="$2" remaining
  remaining=$(( POLL_TIMEOUT - (SECONDS - started) ))
  (( remaining > 0 )) || return 0
  delay="$(python3 -c 'import sys; print(min(float(sys.argv[1]), float(sys.argv[2])))' "$delay" "$remaining")"
  sleep "$delay"
}

repo_meta() {
  python3 - "$1" <<'PY'
import re
import sys
from urllib.parse import urlparse

url = sys.argv[1]
owner = repo = ""
if url.startswith("git@github.com:"):
    path = url.removeprefix("git@github.com:")
elif url.startswith("ssh://"):
    parsed = urlparse(url)
    path = parsed.path.lstrip("/") if parsed.hostname == "github.com" else ""
elif url.startswith("https://") or url.startswith("http://"):
    parsed = urlparse(url)
    path = parsed.path.lstrip("/") if parsed.hostname == "github.com" else ""
else:
    path = ""

if path:
    match = re.fullmatch(r"([^/]+)/([^/]+?)(?:\.git)?", path)
    if match:
        owner, repo = match.group(1), match.group(2)

if not owner or not repo:
    print("error: OFFLOAD_REMOTE must point to a GitHub repo (git@github.com:owner/repo.git or https://github.com/owner/repo.git)", file=sys.stderr)
    sys.exit(65)

print(f"{owner}\t{repo}\thttps://github.com/{owner}/{repo}.git")
PY
}

github_remotes() {
  local remote repo_url meta
  while IFS= read -r remote; do
    [[ -n "$remote" ]] || continue
    repo_url="$(git remote get-url "$remote" 2>/dev/null || true)"
    [[ -n "$repo_url" ]] || continue
    meta="$(repo_meta "$repo_url" 2>/dev/null || true)"
    [[ -n "$meta" ]] || continue
    printf '%s\t%s\n' "$remote" "$meta"
  done < <(git remote)
}

select_github_remote() {
  local explicit="${OFFLOAD_REMOTE:-}"
  local login="${OFFLOAD_GITHUB_LOGIN:-}"
  local login_lc remote owner repo clone_url line count match_count selected
  if [[ -n "$explicit" ]]; then
    clone_url="$(git remote get-url "$explicit")"
    IFS=$'\t' read -r owner repo clone_url < <(repo_meta "$clone_url")
    SELECTED_REMOTE="$explicit"
    SELECTED_REPO_OWNER="$owner"
    SELECTED_REPO_NAME="$repo"
    SELECTED_REPO_CLONE_URL="$clone_url"
    return
  fi

  count=0
  match_count=0
  login_lc="$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
  while IFS=$'\t' read -r remote owner repo clone_url; do
    [[ -n "$remote" ]] || continue
    count=$(( count + 1 ))
    selected="$remote"$'\t'"$owner"$'\t'"$repo"$'\t'"$clone_url"
    if [[ -n "$login_lc" && "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" == "$login_lc" ]]; then
      match_count=$(( match_count + 1 ))
      line="$selected"
    elif [[ -z "${line:-}" ]]; then
      line="$selected"
    fi
  done < <(github_remotes)

  if [[ "$match_count" -eq 1 ]]; then
    IFS=$'\t' read -r SELECTED_REMOTE SELECTED_REPO_OWNER SELECTED_REPO_NAME SELECTED_REPO_CLONE_URL <<<"$line"
    return
  fi
  if [[ "$count" -eq 1 ]]; then
    IFS=$'\t' read -r SELECTED_REMOTE SELECTED_REPO_OWNER SELECTED_REPO_NAME SELECTED_REPO_CLONE_URL <<<"$line"
    return
  fi

  if [[ "$count" -eq 0 ]]; then
    echo "error: no GitHub remotes found; add a GitHub remote or set OFFLOAD_REMOTE" >&2
  elif [[ "$match_count" -gt 1 ]]; then
    echo "error: multiple GitHub remotes match OFFLOAD_GITHUB_LOGIN=$login; set OFFLOAD_REMOTE" >&2
  else
    echo "error: multiple GitHub remotes found and none uniquely match OFFLOAD_GITHUB_LOGIN=${login:-<unset>}; set OFFLOAD_REMOTE" >&2
  fi
  github_remotes | awk -F '\t' '{ printf "  %s -> %s/%s\n", $1, $2, $3 }' >&2
  exit 65
}

resolve_project_context() {
  local folder="$1"
  local toplevel rel

  cd "$folder"
  PROJECT_FOLDER="$(pwd -P)"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: $PROJECT_FOLDER is not a git repo" >&2; exit 65; }

  toplevel="$(git rev-parse --show-toplevel)"
  rel="${PROJECT_FOLDER#"$toplevel"}"
  rel="${rel#/}"
  select_github_remote

  PROJECT_TOPLEVEL="$toplevel"
  PROJECT_REL="$rel"
  PROJECT_REMOTE="$SELECTED_REMOTE"
  PROJECT_REPO_OWNER="$SELECTED_REPO_OWNER"
  PROJECT_REPO_NAME="$SELECTED_REPO_NAME"
  PROJECT_REPO_CLONE_URL="$SELECTED_REPO_CLONE_URL"
  PROJECT_FOLDER_ID="$(project_folder_id "$PROJECT_REPO_OWNER" "$PROJECT_REPO_NAME" "$rel")"
}

env_settings_url() {
  printf '%s/settings/projects/%s' "$(api_url)" "$1"
}

project_folder_id() {
  python3 -c 'import hashlib, sys; print(f"{sys.argv[2]}--{hashlib.sha256(chr(0).join(sys.argv[1:]).encode()).hexdigest()}")' "$1" "$2" "$3"
}

cli_login_start() {
  local api="$1" resp http_code body
  if ! resp="$(curl -sS -X POST "$api/v1/auth/cli/start" -H "Accept: application/json" -H "Content-Type: application/json" -d '{}' -w $'\n%{http_code}')"; then
    echo "error: login start connection failed" >&2
    return 1
  fi
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$http_code" != "200" ]]; then
    [[ "$http_code" != "503" ]] || echo "error: GitHub OAuth or the host public URL is not configured" >&2
    echo "error: login start failed with HTTP $http_code" >&2
    return 1
  fi
  printf '%s' "$body"
}

auth_start() {
  local api
  api="$(api_url)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url) api="$(normalize_api_url "$2")"; shift 2 ;;
      -h|--help) echo "usage: $0 auth start [--api-url URL]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done

  local resp login_url device_code
  resp="$(cli_login_start "$api")"
  login_url="$(printf '%s' "$resp" | json_field login_url)"
  device_code="$(printf '%s' "$resp" | json_field device_code)"
  printf '%s\n' "$resp"
  [[ -n "$login_url" ]] && echo "login_url=$login_url"
  [[ -n "$device_code" ]] && echo "device_code=$device_code"
}

save_config() {
  local api="$1"
  local token="$2"
  local github_login="${3:-${OFFLOAD_GITHUB_LOGIN:-}}"
  mkdir -p "$(dirname "$CONFIG")"
  umask 077
  {
    printf 'OFFLOAD_API_URL=%s\n' "$api"
    printf 'OFFLOAD_API_KEY=%s\n' "$token"
    [[ -n "${OFFLOAD_REMOTE:-}" ]] && printf 'OFFLOAD_REMOTE=%s\n' "$OFFLOAD_REMOTE"
    [[ -n "$github_login" ]] && printf 'OFFLOAD_GITHUB_LOGIN=%s\n' "$github_login"
    [[ -n "${OFFLOAD_POLL_INTERVAL:-}" ]] && printf 'OFFLOAD_POLL_INTERVAL=%s\n' "$OFFLOAD_POLL_INTERVAL"
    [[ -n "${OFFLOAD_RETRY_BACKOFF_BASE:-}" ]] && printf 'OFFLOAD_RETRY_BACKOFF_BASE=%s\n' "$OFFLOAD_RETRY_BACKOFF_BASE"
    [[ -n "${OFFLOAD_POLL_TIMEOUT:-}" ]] && printf 'OFFLOAD_POLL_TIMEOUT=%s\n' "$OFFLOAD_POLL_TIMEOUT"
    [[ -n "${OFFLOAD_POLL_CONNECT_TIMEOUT:-}" ]] && printf 'OFFLOAD_POLL_CONNECT_TIMEOUT=%s\n' "$OFFLOAD_POLL_CONNECT_TIMEOUT"
  } > "$CONFIG"
  chmod 600 "$CONFIG"
  echo "saved config: $CONFIG"
}

auth_exchange() {
  local api name device_code resp token github_login exchange_code exchange_dir header_file interval payload retry_delay
  api="$(api_url)"
  name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo client)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url) api="$(normalize_api_url "$2")"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      -h|--help) echo "usage: $0 auth exchange DEVICE_CODE [--name NAME] [--api-url URL]"; exit 0 ;;
      -* ) echo "unknown flag: $1" >&2; exit 64 ;;
      * ) device_code="${device_code:-$1}"; shift ;;
    esac
  done
  [[ -n "${device_code:-}" ]] || { echo "error: missing DEVICE_CODE" >&2; exit 64; }

  payload="$(python3 - "$device_code" "$name" <<'PY'
import json
import sys

print(json.dumps({"device_code": sys.argv[1], "name": sys.argv[2], "scopes": "runs:read,runs:write,github:setup,env:read"}))
PY
)"
  exchange_dir="$(mktemp -d "${TMPDIR:-/tmp}/offload-auth.XXXXXX")"
  header_file="$exchange_dir/headers"
  trap "rm -rf $(printf '%q' "$exchange_dir")" EXIT
  interval=3
  while true; do
    : > "$header_file"
    if ! exchange_code="$(curl -sS -X POST "$api/v1/auth/cli/exchange" -H "Accept: application/json" -H "Content-Type: application/json" --dump-header "$header_file" --output "$exchange_dir/body" --write-out '%{http_code}' -d "$payload")"; then
      echo "error: login exchange connection failed" >&2
      exit 1
    fi
    resp="$(<"$exchange_dir/body")"
    case "$exchange_code" in
      200|201) break ;;
      202)
        interval="$(printf '%s' "$resp" | json_field interval)"
        [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || interval=3
        echo "> GitHub authorization is pending; retrying after ${interval}s" >&2
        sleep "$interval"
        ;;
      429)
        retry_delay="$(retry_after_seconds "$header_file")"
        [[ -n "$retry_delay" ]] || retry_delay="$interval"
        echo "> login exchange rate limited; retrying after ${retry_delay}s" >&2
        sleep "$retry_delay"
        ;;
      404) echo "error: invalid login device code" >&2; exit 1 ;;
      409) echo "error: login device code was already consumed" >&2; exit 1 ;;
      410) echo "error: login device code expired; start login again" >&2; exit 1 ;;
      *) echo "error: login exchange failed with HTTP $exchange_code" >&2; exit 1 ;;
    esac
  done
  token="$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token") or d.get("api_key") or d.get("client_key") or d.get("offload_api_key") or "")')"
  github_login="$(printf '%s' "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); u=d.get("user") or {}; print(d.get("github_login") or d.get("user_login") or d.get("login") or d.get("account_login") or u.get("login") or "")')"
  [[ -n "$token" ]] || { echo "error: exchange response did not include a token" >&2; printf '%s\n' "$resp" >&2; exit 1; }
  save_config "$api" "$token" "$github_login"
}

auth_login() {
  local api name start_resp login_url device_code
  api="$(api_url)"
  name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo client)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url) api="$(normalize_api_url "$2")"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      -h|--help) echo "usage: $0 auth login [--name NAME] [--api-url URL]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done

  start_resp="$(cli_login_start "$api")"
  login_url="$(printf '%s' "$start_resp" | json_field login_url)"
  device_code="$(printf '%s' "$start_resp" | json_field device_code)"
  [[ -n "$login_url" && -n "$device_code" ]] || { echo "error: auth start response missing login_url or device_code" >&2; printf '%s\n' "$start_resp" >&2; exit 1; }
  echo "Open this URL in your browser:"
  echo "$login_url"
  echo "device_code=$device_code"
  if [[ -t 0 ]]; then
    read -r -p "Press Enter after GitHub says login complete..."
  fi
  auth_exchange "$device_code" --name "$name" --api-url "$api"
}

auth_cmd() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    start) auth_start "$@" ;;
    exchange) auth_exchange "$@" ;;
    login) auth_login "$@" ;;
    -h|--help|"") echo "usage: $0 auth {start|exchange|login}"; exit 0 ;;
    *) echo "unknown auth command: $sub" >&2; exit 64 ;;
  esac
}

github_install_url() {
  local owner repo repo_arg remote api resp install_url payload http_code install_dir retry_delay error_message
  remote="${OFFLOAD_REMOTE:-}"
  api="$(api_url)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo_arg="$2"; shift 2 ;;
      --owner) owner="$2"; shift 2 ;;
      --name|--repo-name) repo="$2"; shift 2 ;;
      --remote) OFFLOAD_REMOTE="$2"; remote="$2"; shift 2 ;;
      -h|--help) echo "usage: $0 github install-url [--repo OWNER/REPO] [--remote REMOTE]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done
  if [[ -n "${repo_arg:-}" ]]; then
    owner="${repo_arg%%/*}"
    repo="${repo_arg#*/}"
  fi
  if [[ -z "${owner:-}" || -z "${repo:-}" || "$owner" == "$repo" ]]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: --repo OWNER/REPO is required outside a git repo" >&2; exit 65; }
    [[ -n "$remote" ]] && OFFLOAD_REMOTE="$remote"
    select_github_remote
    owner="$SELECTED_REPO_OWNER"
    repo="$SELECTED_REPO_NAME"
  fi
  require_api_key
  payload="$(python3 - "$owner" "$repo" <<'PY'
import json
import sys

print(json.dumps({"owner": sys.argv[1], "repo": sys.argv[2]}))
PY
)"
  install_dir="$(mktemp -d "${TMPDIR:-/tmp}/offload-github.XXXXXX")"
  trap "rm -rf $(printf '%q' "$install_dir")" EXIT
  if ! http_code="$(curl -sS -X POST "$api/v1/github/app/install-url" -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json" -H "Content-Type: application/json" --dump-header "$install_dir/headers" --output "$install_dir/body" --write-out '%{http_code}' -d "$payload")"; then
    echo "error: repository access request failed" >&2
    exit 1
  fi
  resp="$(<"$install_dir/body")"
  if [[ "$http_code" != "200" ]]; then
    retry_delay="$(retry_after_seconds "$install_dir/headers")"
    error_message="$(json_error_message "$install_dir/body")"
    echo "error: repository access request failed with HTTP $http_code${error_message:+: $error_message}${retry_delay:+ (Retry-After: ${retry_delay}s)}" >&2
    exit 1
  fi
  install_url="$(printf '%s' "$resp" | json_field install_url)"
  printf '%s\n' "$resp"
  [[ -n "$install_url" ]] && echo "install_url=$install_url"
  return 0
}

github_cmd() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    install-url) github_install_url "$@" ;;
    -h|--help|"") echo "usage: $0 github install-url [--repo OWNER/REPO]"; exit 0 ;;
    *) echo "unknown github command: $sub" >&2; exit 64 ;;
  esac
}

runs_list() {
  require_api_key
  curl -fsS "$(api_url)/v1/runs" -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json"
  echo
}

run_status() {
  local run_id="${1:-}"
  [[ -n "$run_id" ]] || { echo "usage: $0 status RUN_ID" >&2; exit 64; }
  require_run_id "$run_id"
  require_api_key
  curl -fsS "$(api_url)/v1/runs/$run_id" -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json"
  echo
}

save_run_result() {
  local run_body_file="$1" events_body_file="$2" patch_file="$3" output_file="$4"

  python3 - "$run_body_file" "$events_body_file" "$patch_file" "$output_file" <<'PY'
import json
from pathlib import Path
import sys

run_body_path, events_body_path, patch_path, output_path = map(Path, sys.argv[1:])
run_doc = json.loads(run_body_path.read_text())
event_doc = json.loads(events_body_path.read_text()) if events_body_path.exists() and events_body_path.stat().st_size else {}
result = run_doc
if not any(field in result for field in ("patch", "agent_output", "prompt_results")) and isinstance(event_doc.get("result"), dict):
    result = event_doc["result"]
patch = result.get("patch")
agent_output = result.get("agent_output")
if patch is not None and not isinstance(patch, str):
    print("protocol error: run patch must be a string", file=sys.stderr)
    raise SystemExit(65)
if agent_output is not None and not isinstance(agent_output, str):
    print("protocol error: run agent_output must be a string", file=sys.stderr)
    raise SystemExit(65)
if patch is not None:
    patch_path.write_text(patch)
if agent_output is not None:
    output_path.write_text(agent_output)
print(f"{int(patch is not None)}\t{int(agent_output is not None)}")
PY
}

print_safe_text_file() {
  python3 - "$1" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
text = re.sub(r"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])", "", text)
print("".join(char for char in text if char in "\n\t" or ord(char) >= 32))
PY
}

print_env_metadata() {
  local folder_id="$1"

  python3 -c '
import json
import sys

folder_id = sys.argv[1]
doc = json.load(sys.stdin)
keys = doc.get("keys") or []
count = doc.get("count")
if count is None:
    count = len(keys)

print(f"folder_id={doc.get('folder_id') or folder_id}")
if not keys:
    print(f"No env vars configured (count={count}).")
else:
    print(f"Configured env vars (count={count}):")
    for item in keys:
        key = item.get("key") if isinstance(item, dict) else str(item)
        if key:
            print(f"  {key}")
' "$folder_id"
}

build_env_verify_payload() {
  python3 - "$@" <<'PY'
import json
import re
import sys
import urllib.parse

allowed = {
    "ANTHROPIC_BASE_URL",
    "CLAUDE_BRR_EFFORT",
    "CLAUDE_BRR_MAX_BUDGET_USD",
    "CLAUDE_BRR_MODEL",
    "CLAUDE_BRR_PROVIDER_TELEMETRY",
    "CLAUDE_BRR_TOOLS",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
}
allowed_tools = {
    "Agent", "Bash", "CronCreate", "CronDelete", "CronList", "DesignSync", "Edit",
    "EnterWorktree", "ExitWorktree", "Monitor", "NotebookEdit", "PushNotification",
    "Read", "ReportFindings", "ScheduleWakeup", "SendMessage", "Skill", "TaskCreate",
    "TaskGet", "TaskList", "TaskOutput", "TaskStop", "TaskUpdate", "WebFetch",
    "WebSearch", "Workflow", "Write",
}
expected = {}
for item in sys.argv[1:]:
    if "=" not in item:
        print("error: --expect requires KEY=VALUE", file=sys.stderr)
        raise SystemExit(64)
    key, value = item.split("=", 1)
    if key not in allowed:
        print(f"error: {key or '<empty>'} is not an attestable non-secret runtime key", file=sys.stderr)
        raise SystemExit(64)
    if key in expected:
        print(f"error: duplicate --expect key: {key}", file=sys.stderr)
        raise SystemExit(64)
    value_limit = 512 if key == "CLAUDE_BRR_TOOLS" else 256
    if not value or any(character in value for character in "\n\r\0") or len(value.encode()) > value_limit:
        print(f"error: expected value for {key} exceeds its bounded single-line grammar", file=sys.stderr)
        raise SystemExit(64)
    if key == "ANTHROPIC_BASE_URL":
        try:
            parts = urllib.parse.urlsplit(value)
            valid = (
                parts.scheme == "https"
                and bool(parts.hostname)
                and parts.username is None
                and parts.password is None
                and not parts.query
                and not parts.fragment
                and (parts.port is None or 1 <= parts.port <= 65535)
            )
        except ValueError:
            valid = False
    elif key == "CLAUDE_BRR_MODEL":
        valid = re.fullmatch(r"[A-Za-z0-9._:/@-]{1,200}", value) is not None
    elif key == "CLAUDE_BRR_EFFORT":
        valid = value in {"low", "medium", "high", "xhigh", "max"}
    elif key == "CLAUDE_BRR_MAX_BUDGET_USD":
        valid = re.fullmatch(r"(?:0|[1-9][0-9]{0,3})(?:\.[0-9]{1,6})?", value) is not None
        valid = valid and 0.000001 <= float(value) <= 1000 if valid else False
    elif key == "CLAUDE_BRR_TOOLS":
        tools = value.split(",")
        valid = (
            1 <= len(tools) <= 32
            and len(tools) == len(set(tools))
            and all(tool in allowed_tools for tool in tools)
        )
    elif key == "CLAUDE_BRR_PROVIDER_TELEMETRY":
        valid = value in {"0", "1"}
    else:
        valid = value == "1"
    if not valid:
        print(f"error: expected value for {key} is outside the attestable benchmark grammar", file=sys.stderr)
        raise SystemExit(64)
    expected[key] = value
if not expected:
    print("error: at least one --expect KEY=VALUE is required", file=sys.stderr)
    raise SystemExit(64)
print(json.dumps({"expected": expected}, separators=(",", ":")))
PY
}

print_env_verification() {
  local folder_id="$1"
  shift

  python3 -c '
import json
import sys

folder_id = sys.argv[1]
expectations = sys.argv[2:]
expected_keys = []
for item in expectations:
    key = item.split("=", 1)[0]
    if key in expected_keys:
        print("protocol error: duplicate expected key", file=sys.stderr)
        raise SystemExit(65)
    expected_keys.append(key)
expected_keys.sort()
try:
    doc = json.load(sys.stdin)
except (ValueError, json.JSONDecodeError):
    print("protocol error: env verification response is not valid JSON", file=sys.stderr)
    raise SystemExit(65)
if not isinstance(doc, dict) or set(doc) != {"folder_id", "matches", "checked_keys", "missing_keys", "mismatched_keys"}:
    print("protocol error: env verification response shape is invalid", file=sys.stderr)
    raise SystemExit(65)
if doc.get("folder_id") != folder_id or not isinstance(doc.get("matches"), bool):
    print("protocol error: env verification identity or match flag is invalid", file=sys.stderr)
    raise SystemExit(65)
matches = doc["matches"]
checked = doc.get("checked_keys") or []
missing = doc.get("missing_keys") or []
mismatched = doc.get("mismatched_keys") or []
for name, values in (("checked_keys", checked), ("missing_keys", missing), ("mismatched_keys", mismatched)):
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values) or values != sorted(set(values)):
        print(f"protocol error: env verification {name} must be a string list", file=sys.stderr)
        raise SystemExit(65)
if checked != expected_keys or set(missing) & set(mismatched) or not set(missing + mismatched) <= set(checked):
    print("protocol error: env verification key classification is invalid", file=sys.stderr)
    raise SystemExit(65)
if matches != (not missing and not mismatched):
    print("protocol error: env verification match result is inconsistent", file=sys.stderr)
    raise SystemExit(65)
print(f"folder_id={doc.get('"'"'folder_id'"'"') or folder_id}")
print(f"runtime_env_match={'"'"'true'"'"' if matches else '"'"'false'"'"'}")
print(f"checked_keys={'"'"','"'"'.join(checked)}")
if missing:
    print(f"missing_keys={'"'"','"'"'.join(missing)}")
if mismatched:
    print(f"mismatched_keys={'"'"','"'"'.join(mismatched)}")
raise SystemExit(0 if matches else 1)
' "$folder_id" "$@"
}

env_cmd() {
  local folder resp http_code body settings_url payload verified
  local -a expectations=()
  folder="$PWD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir) [[ $# -ge 2 ]] || { echo "error: $1 requires a directory" >&2; exit 64; }; folder="$2"; shift 2 ;;
      --expect) [[ $# -ge 2 ]] || { echo "error: --expect requires KEY=VALUE" >&2; exit 64; }; expectations+=("$2"); shift 2 ;;
      -h|--help) echo "usage: $0 env [-d DIR] [--expect KEY=VALUE ...]"; exit 0 ;;
      *) echo "unknown flag: $1" >&2; exit 64 ;;
    esac
  done

  require_api_key
  resolve_project_context "$folder"
  settings_url="$(env_settings_url "$PROJECT_FOLDER_ID")"

  if [[ "${#expectations[@]}" -gt 0 ]]; then
    payload="$(build_env_verify_payload "${expectations[@]}")"
    if ! resp="$(curl -sS -X POST -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json" -H "Content-Type: application/json" -d "$payload" -w $'\n%{http_code}' "$(api_url)/v1/folders/$PROJECT_FOLDER_ID/env/verify")"; then
      echo "error: failed to verify project env values" >&2
      exit 1
    fi
    http_code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    if [[ "$http_code" != 2* || -z "$body" ]]; then
      echo "error: env value verification failed with HTTP $http_code" >&2
      exit 1
    fi
    verified=0
    if printf '%s' "$body" | print_env_verification "$PROJECT_FOLDER_ID" "${expectations[@]}"; then
      verified=0
    else
      verified=$?
    fi
    echo "settings_url=$settings_url"
    echo "Stored values remain write-only; verification returns only key-level match metadata."
    [[ "$verified" -eq 0 ]] || exit "$verified"
    return 0
  fi

  if ! resp="$(curl -sS -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json" -w $'\n%{http_code}' "$(api_url)/v1/folders/$PROJECT_FOLDER_ID/env")"; then
    echo "error: failed to fetch env metadata" >&2
    exit 1
  fi
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$http_code" == 2* && -n "$body" ]]; then
    printf '%s' "$body" | print_env_metadata "$PROJECT_FOLDER_ID"
  else
    echo "error: env metadata request failed with HTTP $http_code" >&2
    [[ -n "$body" ]] && printf '%s\n' "$body" >&2
    exit 1
  fi

  echo "settings_url=$settings_url"
  echo "Stored env values are managed in the browser and never returned; --expect accepts only allowlisted non-secret comparison values."
}

submit_cmd() {
  local folder wait prompt branch dirty_files git_ref body resp run_id elapsed status log_file log_prefix
  local after apply_meta claim_attempts error_message event_after_before event_code event_logs_truncated event_shape has_patch has_output header_file
  local latest_cursor latest_cursor_present legacy_has_more legacy_status legacy_terminal live_events_unavailable logs_complete next_after
  local current_events_confirmed poll_dir remaining remembered_claim_attempts retry_attempt retry_delay run_code run_logs_truncated run_meta started state_file terminal warned_logs_truncated
  folder="$PWD"
  wait=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir) folder="$2"; shift 2 ;;
      --no-wait) wait=0; shift ;;
      # Multiline prompts are always split now; retain the old low-level flag
      # as a no-op for pinned automation while keeping the removed :ind UX gone.
      --individual-instances) shift ;;
      -h|--help) usage 0 ;;
      --) shift; break ;;
      -*) echo "unknown flag: $1" >&2; usage 64 ;;
      *) break ;;
    esac
  done

  prompt="${*:-}"
  [[ -n "$prompt" ]] || { echo "error: no task prompt given" >&2; usage 64; }
  validate_poll_configuration
  require_api_key

  local toplevel rel repo_owner repo_name folder_id remote
  resolve_project_context "$folder"
  toplevel="$PROJECT_TOPLEVEL"
  rel="$PROJECT_REL"
  remote="$PROJECT_REMOTE"
  repo_owner="$PROJECT_REPO_OWNER"
  repo_name="$PROJECT_REPO_NAME"
  folder_id="$PROJECT_FOLDER_ID"

  if ! branch="$(git symbolic-ref --quiet --short HEAD)"; then
    echo "error: detached HEAD - check out a branch before offloading" >&2
    exit 65
  fi

  dirty_files="$(git status --short)"
  if [[ -n "$dirty_files" ]]; then
    echo "> ignoring local uncommitted changes; cloud run uses GitHub $remote/$branch"
  fi

  git_ref="$branch"
  echo "> using GitHub ref $remote/$git_ref"

  body="$(python3 - "$folder_id" "$repo_owner" "$repo_name" "$rel" "$git_ref" "$prompt" <<'PY'
import json
import re
import sys

folder_id, owner, repo, folder_path, git_ref, prompt = sys.argv[1:]
identifier = re.compile(r"[A-Za-z0-9_.-]+")
if not 1 <= len(folder_id) <= 200 or not identifier.fullmatch(folder_id):
    raise SystemExit("error: folder_id is not valid for the offload protocol")
if not identifier.fullmatch(owner) or not identifier.fullmatch(repo):
    raise SystemExit("error: GitHub owner/repo contains unsupported characters")
if folder_path.startswith("/") or any(part in ("", ".", "..") for part in folder_path.split("/") if folder_path):
    raise SystemExit("error: folder_path is not normalized and repository-relative")
if any(ord(char) < 32 or ord(char) == 127 for char in folder_path):
    raise SystemExit("error: folder_path contains control characters")

body = {
    "folder_id": folder_id,
    "provider": "github",
    "owner": owner,
    "repo": repo,
    "folder_path": folder_path,
    "git_ref": git_ref,
}
prompts = prompt.splitlines()
if not prompts or len(prompts) > 128 or any(not item.strip() for item in prompts):
    raise SystemExit("error: prompt input must contain 1-128 nonblank lines")
if any(len(item.encode()) > 256 * 1024 for item in prompts):
    raise SystemExit("error: a prompt exceeds the 256 KiB host limit")
body["prompts"] = prompts
encoded = json.dumps(body)
if len(encoded.encode()) > 8 * 1024 * 1024:
    raise SystemExit("error: submission exceeds the 8 MiB host limit")
print(encoded)
PY
)"

  echo "> submitting run (folder_id=$folder_id ref=$git_ref)..."
  poll_dir="$(mktemp -d "${TMPDIR:-/tmp}/offload-client.XXXXXX")"
  header_file="$poll_dir/headers"
  state_file="$poll_dir/state.json"
  trap 'rm -rf "$poll_dir"' EXIT
  trap 'exit 130' INT TERM HUP
  if ! run_code="$(curl -sS -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json" -H "Content-Type: application/json" -X POST --dump-header "$header_file" --output "$poll_dir/submit-body" --write-out '%{http_code}' "$(api_url)/v1/runs" -d "$body")"; then
    echo "error: submission connection failed; the outcome is uncertain and retrying may create a duplicate run" >&2
    exit 1
  fi
  if [[ "$run_code" != "202" ]]; then
    error_message="$(json_error_message "$poll_dir/submit-body")"
    retry_delay="$(retry_after_seconds "$header_file")"
    echo "error: submission failed with HTTP $run_code${error_message:+: $error_message}${retry_delay:+ (Retry-After: ${retry_delay}s)}" >&2
    exit 1
  fi
  resp="$(<"$poll_dir/submit-body")"
  run_id="$(printf '%s' "$resp" | json_field run_id)"
  status="$(printf '%s' "$resp" | json_field status)"
  [[ -n "$run_id" && "$status" == "queued" ]] || { echo "protocol error: submit response must contain run_id and status=queued" >&2; exit 65; }
  require_run_id "$run_id"
  echo "  run_id=$run_id"

  if [[ "$wait" -eq 0 ]]; then
    echo "submitted. check later: $0 status $run_id"
    exit 0
  fi

  log_prefix="${run_id//[^A-Za-z0-9._-]/-}"
  log_file="$(mktemp "${TMPDIR:-/tmp}/offload-${log_prefix}.XXXXXX")"
  echo "  Claude Code output on the worker: $log_file"
  printf '  To see live Claude Code output, run: tail -f %q\n' "$log_file"

  echo "> waiting for completion..."
  after=0
  remembered_claim_attempts=0
  live_events_unavailable=0
  current_events_confirmed=0
  warned_logs_truncated=0
  retry_attempt=0
  started=$SECONDS
  while (( SECONDS - started < POLL_TIMEOUT )); do
    remaining=$(( POLL_TIMEOUT - (SECONDS - started) ))
    : > "$header_file"
    : > "$poll_dir/run-body"
    if ! run_code="$(curl -sS --connect-timeout "$POLL_CONNECT_TIMEOUT" --max-time "$remaining" -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json" --dump-header "$header_file" --output "$poll_dir/run-body" --write-out '%{http_code}' "$(api_url)/v1/runs/$run_id")"; then
      retry_attempt=$(( retry_attempt + 1 ))
      retry_delay="$(bounded_backoff "$retry_attempt")"
      echo "> run-status request failed; retrying after ${retry_delay}s" >&2
      poll_sleep "$retry_delay" "$started"
      continue
    fi
    case "$run_code" in
      200)
        run_meta="$(parse_run_record "$poll_dir/run-body" "$run_id")" || exit $?
        IFS=$'\t' read -r status terminal claim_attempts latest_cursor latest_cursor_present run_logs_truncated logs_complete <<<"$run_meta"
        ;;
      401)
        error_message="$(json_error_message "$poll_dir/run-body")"
        echo "authentication error: run API key rejected (HTTP 401${error_message:+: $error_message})" >&2
        exit 77
        ;;
      403)
        error_message="$(json_error_message "$poll_dir/run-body")"
        echo "authorization error: cannot access run $run_id (HTTP 403${error_message:+: $error_message})" >&2
        exit 77
        ;;
      404)
        error_message="$(json_error_message "$poll_dir/run-body")"
        echo "not-found protocol error: unknown run_id $run_id (HTTP 404${error_message:+: $error_message})" >&2
        exit 65
        ;;
      429|5??)
        retry_attempt=$(( retry_attempt + 1 ))
        retry_delay="$(retry_after_seconds "$header_file")"
        [[ -n "$retry_delay" ]] || retry_delay="$(bounded_backoff "$retry_attempt")"
        echo "> run API returned HTTP $run_code; retrying after ${retry_delay}s" >&2
        poll_sleep "$retry_delay" "$started"
        continue
        ;;
      *)
        error_message="$(json_error_message "$poll_dir/run-body")"
        echo "protocol error: run API returned HTTP $run_code${error_message:+: $error_message}" >&2
        exit 65
        ;;
    esac

    if [[ "$claim_attempts" -ne "$remembered_claim_attempts" || "$latest_cursor" -lt "$after" ]]; then
      if [[ "$after" -gt 0 ]]; then
        echo "> worker attempt changed; clearing abandoned live output and restarting at cursor 0" >&2
      fi
      reset_live_state "$state_file" "$log_file"
      after=0
    fi
    remembered_claim_attempts="$claim_attempts"
    event_shape="none"
    event_logs_truncated=0
    legacy_has_more=0
    event_after_before="$after"
    : > "$poll_dir/events-body"

    if [[ "$live_events_unavailable" -eq 0 && ! ( "$latest_cursor_present" -eq 1 && "$current_events_confirmed" -eq 1 && "$after" -ge "$latest_cursor" ) ]]; then
      : > "$header_file"
      if ! event_code="$(curl -sS --connect-timeout "$POLL_CONNECT_TIMEOUT" --max-time "$remaining" -H "Authorization: Bearer $OFFLOAD_API_KEY" -H "Accept: application/json" --dump-header "$header_file" --output "$poll_dir/events-body" --write-out '%{http_code}' "$(api_url)/v1/runs/$run_id/events?after=$after&limit_bytes=262144")"; then
        retry_attempt=$(( retry_attempt + 1 ))
        retry_delay="$(bounded_backoff "$retry_attempt")"
        echo "> event request failed; retrying after ${retry_delay}s with after=$after" >&2
        poll_sleep "$retry_delay" "$started"
        continue
      fi
      case "$event_code" in
        200)
          apply_meta="$(apply_events_response "$poll_dir/events-body" "$run_id" "$after" "$state_file" "$log_file")" || exit $?
          IFS=$'\t' read -r next_after event_shape event_logs_truncated legacy_status legacy_terminal legacy_has_more <<<"$apply_meta"
          after="$next_after"
          if [[ "$event_shape" == "current" ]]; then
            current_events_confirmed=1
          fi
          if [[ "$event_shape" == "legacy" && "$legacy_terminal" -eq 1 ]]; then
            status="$legacy_status"
            terminal=1
          fi
          retry_attempt=0
          ;;
        400)
          error_message="$(json_error_message "$poll_dir/events-body")"
          echo "protocol error: event request rejected (HTTP 400${error_message:+: $error_message})" >&2
          exit 65
          ;;
        401)
          error_message="$(json_error_message "$poll_dir/events-body")"
          echo "authentication error: event API key rejected (HTTP 401${error_message:+: $error_message})" >&2
          exit 77
          ;;
        403)
          error_message="$(json_error_message "$poll_dir/events-body")"
          echo "authorization error: cannot access events for run $run_id (HTTP 403${error_message:+: $error_message})" >&2
          exit 77
          ;;
        404)
          live_events_unavailable=1
          echo "> live output is unavailable on this host; continuing with run-status polling" >&2
          ;;
        429|5??)
          retry_attempt=$(( retry_attempt + 1 ))
          retry_delay="$(retry_after_seconds "$header_file")"
          [[ -n "$retry_delay" ]] || retry_delay="$(bounded_backoff "$retry_attempt")"
          echo "> event API returned HTTP $event_code; retrying after ${retry_delay}s with after=$after" >&2
          poll_sleep "$retry_delay" "$started"
          continue
          ;;
        *)
          error_message="$(json_error_message "$poll_dir/events-body")"
          echo "protocol error: event API returned HTTP $event_code${error_message:+: $error_message}" >&2
          exit 65
          ;;
      esac
    fi

    elapsed=$(( SECONDS - started ))
    printf '  ...%s (%ds)\r' "$status" "$elapsed"
    if [[ "$warned_logs_truncated" -eq 0 && ( "$event_logs_truncated" -eq 1 || "$run_logs_truncated" -eq 1 ) ]]; then
      echo "warning: live logs were truncated" >&2
      warned_logs_truncated=1
    fi
    if [[ "$legacy_has_more" -eq 1 ]]; then
      continue
    fi
    if [[ "$terminal" -eq 1 && ( "$live_events_unavailable" -eq 1 || "$after" -ge "$latest_cursor" || ( "$after" -eq "$event_after_before" && ( "$event_logs_truncated" -eq 1 || "$run_logs_truncated" -eq 1 || "$logs_complete" -eq 0 ) ) ) ]]; then
      local out_dir output_file patch_check_failed patch_check_file patch_file record_file result_meta
      echo
      [[ "$logs_complete" -ne 0 ]] || echo "warning: the run finished but live logs are incomplete" >&2
      out_dir="$(git rev-parse --git-path offload)"
      mkdir -p "$out_dir"
      out_dir="$(cd "$out_dir" && pwd)"
      patch_file="$out_dir/$run_id.patch"
      output_file="$out_dir/$run_id.output.txt"
      record_file="$out_dir/$run_id.result.json"
      patch_check_file="$out_dir/$run_id.patch-check.txt"
      cp "$poll_dir/run-body" "$record_file"
      result_meta="$(save_run_result "$poll_dir/run-body" "$poll_dir/events-body" "$patch_file" "$output_file")" || exit $?
      IFS=$'\t' read -r has_patch has_output <<<"$result_meta"
      patch_check_failed=0
      if [[ "$status" == "ok_patch" && "$has_patch" -eq 1 && -s "$patch_file" ]]; then
        if git -C "$toplevel" apply --check "$patch_file" >"$patch_check_file" 2>&1; then
          rm -f "$patch_check_file"
          echo "  patch:  $patch_file"
          echo "  apply:  git apply $patch_file"
        else
          patch_check_failed=1
          echo "  patch:  $patch_file"
          echo "  check:  failed (details: $patch_check_file)"
        fi
      elif [[ "$status" == "ok_patch" ]]; then
        rm -f "$patch_check_file"
        echo "  patch:  no changes"
      elif [[ "$has_patch" -eq 1 ]]; then
        echo "  partial patch: $patch_file"
      fi
      [[ "$has_output" -eq 0 ]] || echo "  output: $output_file"
      echo "  result: $record_file"
      echo "  Claude Code output on the worker: $log_file"
      if [[ "$has_output" -eq 1 ]]; then
        echo
        echo "Agent output:"
        print_safe_text_file "$output_file"
      fi
      if [[ "$patch_check_failed" -ne 0 ]]; then
        echo "x returned patch failed git apply --check; it may be corrupted in transport or not match this checkout" >&2
        exit 65
      fi
      if [[ "$status" == "ok_patch" || "$status" == "ok" || "$status" == "ok_no_pr" ]]; then
        echo "OK $status done."
        exit 0
      fi
      if [[ "$status" == "env_failed" ]]; then
        echo "x run $status - project environment injection failed; manage values in the browser: $(env_settings_url "$folder_id")" >&2
      else
        error_message="$(json_error_message "$poll_dir/run-body")"
        echo "x run $status${error_message:+: $error_message}" >&2
      fi
      exit 1
    fi
    poll_sleep "$POLL_INTERVAL" "$started"
  done
  echo
  echo "still running after ${POLL_TIMEOUT}s; check later with run_id=$run_id" >&2
  exit 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    auth) shift; auth_cmd "$@" ;;
    github) shift; github_cmd "$@" ;;
    runs|list) shift; runs_list "$@" ;;
    status|get) shift; run_status "$@" ;;
    env) shift; env_cmd "$@" ;;
    submit) shift; submit_cmd "$@" ;;
    -h|--help) usage 0 ;;
    "" ) usage 64 ;;
    *) submit_cmd "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
