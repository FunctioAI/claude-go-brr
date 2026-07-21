#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

[[ $# -eq 1 && -z "$1" ]] && set --

CLIENT="${OFFLOAD_BIN:-$SCRIPT_DIR/../offload.sh}"

exec "$CLIENT" env "$@"
