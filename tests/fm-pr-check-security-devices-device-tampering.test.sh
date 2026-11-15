#!/usr/bin/env bash
# PR check security: devices device tampering.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases test_device_rerecord_refuses_device_tampering
