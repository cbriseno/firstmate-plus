#!/usr/bin/env bash
# Crew-state: decision history.
set -u

# shellcheck source=tests/crew-state-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/crew-state-helpers.sh"

test_secondmate_open_block_survives_unrelated_append
test_newest_open_decision_supplies_the_reported_detail
test_latest_status_preserves_legacy_completions
test_latest_status_subshell_work_does_not_grow_with_history

echo "all crew-state decision-history tests passed"
