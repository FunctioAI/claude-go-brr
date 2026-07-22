#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN_ROOT="$ROOT/plugins/claude-go-brr"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

MOCK="$TMP/offload"
cp /dev/null "$TMP/calls"
cp "$ROOT/tests/setup_test_mock.sh" "$MOCK"
chmod +x "$MOCK"

mkdir "$TMP/bin"
cp "$ROOT/tests/github_api_curl_mock.sh" "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"
cp /dev/null "$TMP/curl-calls"

visibility="$(PATH="$TMP/bin:$PATH" OFFLOAD_TEST_CURL_CALLS="$TMP/curl-calls" OFFLOAD_TEST_GITHUB_API_SCENARIO=public "$PLUGIN_ROOT/offload.sh" github visibility --repo acme/widgets)"
[[ "$visibility" == "public" ]] || fail "public GitHub API response was classified as $visibility"
visibility="$(PATH="$TMP/bin:$PATH" OFFLOAD_TEST_CURL_CALLS="$TMP/curl-calls" OFFLOAD_TEST_GITHUB_API_SCENARIO=private "$PLUGIN_ROOT/offload.sh" github visibility --repo acme/widgets)"
[[ "$visibility" == "private" ]] || fail "private GitHub API response was classified as $visibility"
set +e
visibility="$(PATH="$TMP/bin:$PATH" OFFLOAD_TEST_CURL_CALLS="$TMP/curl-calls" OFFLOAD_TEST_GITHUB_API_SCENARIO=malformed "$PLUGIN_ROOT/offload.sh" github visibility --repo acme/widgets)"
status=$?
set -e
[[ "$status" -ne 0 && "$visibility" == "unknown" ]] || fail "malformed GitHub API response was not classified as unknown"
[[ "$(<"$TMP/curl-calls")" == *'https://api.github.com/repos/acme/widgets'* ]] || fail "GitHub repository metadata URL was not requested"

CONFIG="$TMP/config"
PENDING="$CONFIG.pending-device-code"

(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" "$PLUGIN_ROOT/scripts/setup.sh") > "$TMP/start.out"
[[ "$(<"$PENDING")" == "test-device-code" ]] || fail "pending device code was not saved"
[[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$PENDING")" == "0o600" ]] || fail "pending device code permissions are not 0600"
[[ "$(<"$TMP/start.out")" == *$'After GitHub says login complete, run:\n/claude-go-brr:setup'* ]] || fail "follow-up command still requires the device code"

(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" "$PLUGIN_ROOT/scripts/setup.sh") > "$TMP/exchange.out"
[[ ! -e "$PENDING" ]] || fail "pending device code was not removed after exchange"
[[ "$(<"$TMP/calls")" == *'auth exchange test-device-code --name '* ]] || fail "saved device code was not exchanged"
[[ "$(<"$TMP/calls")" == *'github visibility --remote origin'* ]] || fail "repo visibility was not checked"
[[ "$(<"$TMP/calls")" == *'github install-url --remote origin'* ]] || fail "repo install URL was not requested"
[[ "$(<"$TMP/exchange.out")" == *'Repository is private or not publicly accessible. GitHub App installation is required.'* ]] || fail "private repo message was not displayed"

cp /dev/null "$TMP/calls"
(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" OFFLOAD_TEST_REPO_VISIBILITY=public "$PLUGIN_ROOT/scripts/setup.sh") > "$TMP/public.out"
[[ "$(<"$TMP/calls")" == *'github visibility --remote origin'* ]] || fail "public repo visibility was not checked"
[[ "$(<"$TMP/calls")" != *'github install-url'* ]] || fail "public repo requested a GitHub App install URL"
[[ "$(<"$TMP/public.out")" == *'Repository is public. GitHub App installation is not required.'* ]] || fail "public repo message was not displayed"

rm -f "$CONFIG"
(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" "$PLUGIN_ROOT/scripts/setup.sh") >/dev/null
set +e
(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" OFFLOAD_TEST_EXCHANGE_FAIL=1 "$PLUGIN_ROOT/scripts/setup.sh") >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed exchange unexpectedly succeeded"
[[ -s "$PENDING" ]] || fail "failed exchange discarded the pending device code"

(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" "$PLUGIN_ROOT/scripts/setup.sh" logout) >/dev/null
[[ ! -e "$PENDING" ]] || fail "logout did not clear the pending device code"

echo "setup tests passed"
