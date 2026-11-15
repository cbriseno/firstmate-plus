#!/usr/bin/env bash
# PR check security: devices publication.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_postrename_poll_validation_revokes_and_retries
