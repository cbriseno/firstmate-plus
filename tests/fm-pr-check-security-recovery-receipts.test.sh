#!/usr/bin/env bash
# PR check security: recovery receipts.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_retirement_receipt_and_check_removal_recovery
