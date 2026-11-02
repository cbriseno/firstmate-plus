#!/usr/bin/env bash
# Ordinary add/create, minted IDs, legacy precision and immutable task receipts.
set -euo pipefail
# shellcheck source=tests/creation-time-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/creation-time-helpers.sh"
fm_creation_case tasks
