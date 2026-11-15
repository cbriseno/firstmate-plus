#!/usr/bin/env bash
# Crew-state: parked gates.
set -u

# shellcheck source=tests/crew-state-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/crew-state-helpers.sh"

test_genuine_parked_not_superseded
test_parked_human_decision_comes_from_the_action_column
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded

echo "all crew-state parked-gates tests passed"
