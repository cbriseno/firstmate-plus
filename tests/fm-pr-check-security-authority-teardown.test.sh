#!/usr/bin/env bash
# PR check security: authority teardown.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_teardown_cannot_race_authority_consumption
