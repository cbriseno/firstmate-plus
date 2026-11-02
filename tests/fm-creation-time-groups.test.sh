#!/usr/bin/env bash
# Logical project/subproject creation, preview, retries, edits and promotion.
set -euo pipefail
# shellcheck source=tests/creation-time-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/creation-time-helpers.sh"
fm_creation_case groups
