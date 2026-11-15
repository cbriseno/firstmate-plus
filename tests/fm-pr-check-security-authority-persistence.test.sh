#!/usr/bin/env bash
# PR check security: authority persistence.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_authority_persistence_refuses_rebound_metadata \
  test_authority_persists_before_control_unlock
