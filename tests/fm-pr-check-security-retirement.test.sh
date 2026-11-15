#!/usr/bin/env bash
# PR check security: retirement cases; shared fixtures own each behavior case.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_merged_poll_retires_once \
  test_merged_poll_reregistration_after_notification_is_absorbed \
  test_merged_poll_retries_a_failed_upward_report \
  test_self_merge_and_poll_publish_one_outcome \
  test_merged_poll_reports_upward_from_a_secondmate_home_once \
  test_different_merged_pr_for_same_task_is_not_absorbed \
  test_persistent_secondmate_retirement_is_poll_only
