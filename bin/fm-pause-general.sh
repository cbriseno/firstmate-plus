#!/usr/bin/env bash
# fm-pause-general.sh - the captain's general pause: stop everything new, free
# idle sessions, and resume it all on one order, without touching the lane cap.
#
# Usage:
#   fm-pause-general.sh on [reason]   record the pause (state/.pause-general)
#   fm-pause-general.sh off           lift it
#   fm-pause-general.sh status        print "paused: <epoch> <reason>" or "running"
#
# While the record exists the code enforces the pause on its own:
#   - fm-capacity.sh --admit defers every fresh launch (exit 75, queued work
#     keeps its place), with or without config/lane-capacity, and the
#     watcher's autodispatch tick launches nothing; config/lane-capacity is
#     never edited, so its cap and the parked workers' lanes mean what they did.
#   - fm-watch.sh parks every idle, park-safe worker whatever its declared
#     wait, with no date or load threshold: the pause is the condition. A worker
#     still in a turn finishes it and is parked when it ends.
#   - declared-wait expiry notices and resumes stay quiet until the pause lifts.
# `off` removes the record; the watcher then resumes each worker the pause
# parked, one admission-checked worker per tick, before it launches new work.
# The record is one file: line 1 the epoch it began, line 2 the reason.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.pause-general"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  on)
    reason=${2:-"pausa general del capitán"}
    reason=$(printf '%s' "$reason" | tr '\r\n' '  ')
    mkdir -p "$STATE" || exit 1
    tmp="$RECORD.tmp.$$"
    if [ -e "$RECORD" ]; then echo "already paused: $(sed -n '2p' "$RECORD")"; exit 0; fi
    if ! { printf '%s\n%s\n' "$(date +%s)" "$reason" > "$tmp" && mv "$tmp" "$RECORD"; }; then rm -f -- "$tmp"; exit 1; fi
    echo "paused: $reason"
    ;;
  off)
    if [ -e "$RECORD" ]; then rm -f -- "$RECORD" || exit 1; echo "resumed"; else echo "already running"; fi
    ;;
  status)
    if [ -e "$RECORD" ]; then echo "paused: $(sed -n '1p' "$RECORD") $(sed -n '2p' "$RECORD")"; else echo running; fi
    ;;
  *) echo "usage: fm-pause-general.sh on [reason] | off | status" >&2; exit 2 ;;
esac
