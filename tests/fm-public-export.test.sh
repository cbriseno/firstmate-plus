#!/usr/bin/env bash
# Exercise publication filtering and patch reconstruction in synthetic repos.
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TASK_TMP=$(fm_test_tmproot fm-public-export)
PYTHONUNBUFFERED=1 python3 "$ROOT/tests/fm-public-export-cases.py" "$ROOT" "$TASK_TMP"
