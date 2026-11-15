#!/usr/bin/env bash
# PR check security: requests cases; shared fixtures own each behavior case.
# Provider, retirement and artifact cases run in the companion test scripts.
# FM_PR_CHECK_SECURITY_TEST_RETIREMENT=1 selects the first merge/retirement wake.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

if [ "${FM_PR_CHECK_SECURITY_TEST_RETIREMENT:-0}" = 1 ]; then
  test_merged_poll_retires_once
  exit $?
fi

pr_security_run_cases \
  test_parser_matrix \
  test_invalid_entrypoints_have_zero_side_effects \
  test_draft_pull_request_is_not_armed \
  test_secondmate_record_refuses_a_pr_watch \
  test_unpushed_named_head_refuses_registration \
  test_direct_pr_unpushed_commit_refuses_registration \
  test_static_poll_contract
