#!/usr/bin/env bash
# PR check security: recovery cases; shared fixtures own each behavior case.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_retirement_crash_recovery \
  test_external_merge_transition_retires_only_terminal_poll \
  test_retirement_refuses_replacement_and_nonterminal_results \
  test_retirement_queue_failure_and_receipt_tampering \
  test_gitlab_merged_poll_retires
