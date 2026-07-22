#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OFFLOAD_TEST_CURL_CALLS"
case "$OFFLOAD_TEST_GITHUB_API_SCENARIO" in
  public) printf '%s\n%s' '{"private":false}' '200' ;;
  private) printf '%s\n%s' '{"message":"Not Found"}' '404' ;;
  malformed) printf '%s\n%s' '{}' '200' ;;
  error) exit 7 ;;
esac
