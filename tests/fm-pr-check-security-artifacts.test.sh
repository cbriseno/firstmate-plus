#!/usr/bin/env bash
# PR check security: artifacts cases; shared fixtures own each behavior case.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_atomic_interruption_leaves_no_partial_artifact \
  test_concurrent_watcher_sees_only_complete_publication \
  test_poll_publication_refuses_unsafe_destinations \
  test_live_artifact_single_link_and_privacy_validation
