#!/usr/bin/env bash
# Crew-state: run authority.
set -u

# shellcheck source=tests/crew-state-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/crew-state-helpers.sh"

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_daemon_claim_over_live_run_reads_run_alive
test_socket_refusal_over_stale_fixing_run_reports_blocked
test_socket_refusal_over_terminal_run_reports_blocked
test_socket_refusal_override_expires_when_the_crew_moves_on
test_ordinary_blocked_over_live_run_keeps_plain_superseded
test_genuine_daemon_down_reports_blocked

echo "all crew-state run-authority tests passed"
