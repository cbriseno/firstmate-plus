#!/usr/bin/env bash
# PR check security: attended and external merges without a persisted grant.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases test_merged_poll_row_names_no_authority_when_no_record_grants_one
