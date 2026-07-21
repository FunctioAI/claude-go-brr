#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  echo "usage: submit.sh <task prompt>" >&2
  exit "${1:-64}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0
[[ $# -gt 0 ]] || usage 64

CLIENT="${OFFLOAD_BIN:-$SCRIPT_DIR/../offload.sh}"

CONFIG="${OFFLOAD_CONFIG:-$HOME/.config/offload/config}"
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"
if [[ -z "${OFFLOAD_API_KEY:-}" ]]; then
  echo "error: OFFLOAD_API_KEY not set" >&2
  echo "Run /claude-go-brr:setup, open the printed GitHub URL, then run /claude-go-brr:setup again after GitHub completes." >&2
  exit 78
fi

exec "$CLIENT" submit "$@"
