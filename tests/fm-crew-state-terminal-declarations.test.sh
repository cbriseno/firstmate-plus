#!/usr/bin/env bash
# Crew-state: terminal declarations.
set -u

# shellcheck source=tests/crew-state-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/crew-state-helpers.sh"

test_single_owner_terminal_declaration_supersedes_stale_decision

echo "all crew-state terminal-declarations tests passed"
