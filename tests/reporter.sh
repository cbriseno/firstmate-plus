#!/usr/bin/env bash
# Shared assertion reporter. A subshell failure must stop the owning suite.
fm_test_fail() {
  local message=$1 cleanup=${2:-} mode=${3:-}
  printf 'not ok - %s\n' "$message" >&2
  if [ -n "$cleanup" ]; then ( "$cleanup" ) || true; fi
  if [ "$mode" = continue ] && [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then return 0; fi
  kill -s TERM "$$"
  exit 1
}
