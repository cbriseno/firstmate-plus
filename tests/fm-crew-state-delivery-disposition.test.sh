#!/usr/bin/env bash
# Crew-state: all 72 delivery disposition combinations.
set -u

# shellcheck source=tests/crew-state-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/crew-state-helpers.sh"

test_terminal_green_delivery_disposition

echo "all crew-state delivery-disposition tests passed"
