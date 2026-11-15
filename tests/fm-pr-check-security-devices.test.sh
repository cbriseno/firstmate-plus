#!/usr/bin/env bash
# PR check security: device re-record and post-rename validation cases.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_device_renumbered_poll_stays_armed \
  test_device_rerecord_refuses_tampered_artifacts \
  test_device_rerecord_serializes_direct_rearm \
  test_device_rerecord_serializes_rerecord \
  test_postrename_poll_validation_revokes_and_retries
