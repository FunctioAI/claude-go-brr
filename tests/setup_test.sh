#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
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

CONFIG="$TMP/config"
PENDING="$CONFIG.pending-device-code"

(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" ./scripts/setup.sh) > "$TMP/start.out"
[[ "$(<"$PENDING")" == "test-device-code" ]] || fail "pending device code was not saved"
[[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$PENDING")" == "0o600" ]] || fail "pending device code permissions are not 0600"
[[ "$(<"$TMP/start.out")" == *$'After GitHub says login complete, run:\n/claude-go-brr:setup'* ]] || fail "follow-up command still requires the device code"

(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" ./scripts/setup.sh) > "$TMP/exchange.out"
[[ ! -e "$PENDING" ]] || fail "pending device code was not removed after exchange"
[[ "$(<"$TMP/calls")" == *'auth exchange test-device-code --name '* ]] || fail "saved device code was not exchanged"
[[ "$(<"$TMP/calls")" == *'github install-url --remote origin'* ]] || fail "repo install URL was not requested"

rm -f "$CONFIG"
(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" ./scripts/setup.sh) >/dev/null
set +e
(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" OFFLOAD_TEST_EXCHANGE_FAIL=1 ./scripts/setup.sh) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed exchange unexpectedly succeeded"
[[ -s "$PENDING" ]] || fail "failed exchange discarded the pending device code"

(cd "$ROOT" && OFFLOAD_BIN="$MOCK" OFFLOAD_CONFIG="$CONFIG" OFFLOAD_TEST_CALLS="$TMP/calls" ./scripts/setup.sh logout) >/dev/null
[[ ! -e "$PENDING" ]] || fail "logout did not clear the pending device code"

echo "setup tests passed"
