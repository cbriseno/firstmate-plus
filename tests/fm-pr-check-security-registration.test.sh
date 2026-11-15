#!/usr/bin/env bash
# PR check security: valid registration, merge derivation and legacy task IDs.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases test_valid_recording_and_merge_derivation
