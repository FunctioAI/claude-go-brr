#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OFFLOAD_TEST_CALLS"
case "$1 $2" in
  "auth start")
    printf '%s\n' '{"login_url":"https://example.test/login","device_code":"test-device-code"}' 'login_url=https://example.test/login' 'device_code=test-device-code'
    ;;
  "auth exchange")
    [[ -z "${OFFLOAD_TEST_EXCHANGE_FAIL:-}" ]] || exit 1
    {
      echo 'OFFLOAD_API_URL=https://example.test'
      echo 'OFFLOAD_API_KEY=test-key'
      echo 'OFFLOAD_GITHUB_LOGIN=tester'
    } > "$OFFLOAD_CONFIG"
    ;;
  "github visibility")
    echo "${OFFLOAD_TEST_REPO_VISIBILITY:-private}"
    ;;
  "github install-url")
    echo 'install_url=https://example.test/install'
    ;;
esac
