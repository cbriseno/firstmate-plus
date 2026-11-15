#!/usr/bin/env bash
# PR check security: recovery transitions.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_external_merge_transition_retires_only_terminal_poll
