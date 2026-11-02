#!/usr/bin/env bash
# Explicit, bounded supervisor declaration, not a model/process heartbeat.
# Usage: FM_HOME=/absolute/home bash bin/fm-supervisor-activity.sh [--json]
#        FM_HOME=/absolute/home bash bin/fm-supervisor-activity.sh
#          --state coordinating|waiting|idle --summary TEXT [--ttl 300] [--json]
# The supervisor declares its purpose once at an actual coordination transition.
# Readers never refresh it. After TTL (1..900 seconds), current state is unknown;
# the last declaration, source, instant and age remain visible as stale evidence.
# Writes state/supervisor-activity.json atomically. No wake, daemon or lifecycle
# change; no pid/spinner/lock is accepted as evidence of current model execution.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_delivery.py" activity "$@"
