#!/usr/bin/env bash
# Usage: fm-nudge.sh record --category CATEGORY --text TEXT [--task ID]
# Record one supervisor steering event in the current home's state.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$script_dir/fm_nudge.py" "$@"
