#!/usr/bin/env bash
# PR check security: providers gerrit registration.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_gerrit_arming_records_no_patch_set_revision
