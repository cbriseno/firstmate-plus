#!/usr/bin/env bash
# Crew-state: remote state, overrides and working predicates.
set -u

# shellcheck source=tests/crew-state-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/crew-state-helpers.sh"

test_scout_skips_run_lookup
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_mismatched_state_override_is_ignored
test_matched_state_override_is_honoured
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error

echo "all crew-state remote tests passed"
