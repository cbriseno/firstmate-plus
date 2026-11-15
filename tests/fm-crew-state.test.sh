#!/usr/bin/env bash
# Crew-state: captured states and cancellation.
set -u

# shellcheck source=tests/crew-state-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/crew-state-helpers.sh"

# FM_CREW_STATE_TEST_ENDPOINTS=1 selects the repaired endpoint/fallback pair.
if [ "${FM_CREW_STATE_TEST_ENDPOINTS:-0}" = 1 ]; then
  test_no_run_herdr_husk_dead_still_reads_gone
  test_no_timeout_uses_perl_bound
  exit $?
fi

test_captured_axi_status_shapes
test_captured_inventory_replay
test_captured_authority_transition
test_captured_completed_history
cancellation_failures=0
for cancellation_test in test_captured_cancelled_review_has_no_verdict \
  test_cancelled_without_delivery_has_no_verdict \
  test_cancelled_fleet_inventory_is_unverified_not_contradictory \
  test_cancelled_delivery_and_skipped_rebase; do
  ("$cancellation_test") || cancellation_failures=$((cancellation_failures + 1))
done
[ "$cancellation_failures" -eq 0 ] || fail "$cancellation_failures cancellation test groups failed"

echo "all crew-state captured tests passed"
