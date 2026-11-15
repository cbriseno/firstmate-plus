#!/usr/bin/env bash
# PR check security: adversarial watcher inputs cases; shared fixtures own each behavior case.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases test_rejected_metacharacter_bytes_are_inert
