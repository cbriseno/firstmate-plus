#!/usr/bin/env bash
# PR check security: queued merge authority granted by explicit away words.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases test_merged_poll_row_carries_words_merge_authority
