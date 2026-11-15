#!/usr/bin/env bash
# PR check security: recovery faults.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_retirement_queue_failure_and_receipt_tampering \
  test_gitlab_merged_poll_retires
