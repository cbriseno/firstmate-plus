#!/usr/bin/env bash
# PR check security: authority cases; shared fixtures own each behavior case.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_merged_poll_row_carries_the_merge_authority \
  test_merged_poll_row_names_no_authority_when_no_record_grants_one \
  test_authority_persistence_refuses_rebound_metadata \
  test_authority_persists_before_control_unlock \
  test_teardown_cannot_race_authority_consumption \
  test_authority_retirement_preserves_replacement
