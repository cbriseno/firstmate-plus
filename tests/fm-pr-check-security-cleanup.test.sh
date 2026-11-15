#!/usr/bin/env bash
# PR check security: artifact cleanup cases; shared fixtures own each behavior case.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_bootstrap_leaves_unauthenticated_checks \
  test_custom_snapshot_cleanup_on_signal \
  test_returned_custom_check_descendants_are_drained \
  test_teardown_removes_poll_artifacts
