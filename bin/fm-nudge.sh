#!/usr/bin/env bash
# Usage: fm-nudge.sh record --level captain|overseer|primary --cause CAUSE --text TEXT [--task ROOT-ID] [--target ID] [--category CATEGORY]
#        fm-nudge.sh link --cause CAUSE --task ROOT-ID
#        fm-nudge.sh causes
# Record one correction or push in the current home's correction ledger;
# bin/fm_nudge.py --help owns root-task linking and recurrence.
set -euo pipefail
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 "$script_dir/fm_nudge.py" "$@"
