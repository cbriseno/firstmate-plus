#!/usr/bin/env bash
# fm-autodispatch-pause-lib.sh - the general pause switch for automatic dispatch.
#
# The switch is one file, state/.autodispatch-paused, written and lifted only
# through `bin/fm-autodispatch.sh --pause|--resume|--status` (its header owns
# the command). While it stands and has not expired, nothing launches work by
# itself: the watcher skips fresh automatic launches, the replay of deferred
# launches, and every report about ready work waiting for a lane; a launch
# the primary starts by hand is not affected. Lowering config/lane-capacity is
# not a pause: that file only sets how many lanes admit work.
#
# File: lines "since=<epoch>", "until=<epoch, 0 for no expiry>", "reason=<text>".
# A source file defines functions only and keeps Bash 3.2 compatibility.

# fm_autodispatch_paused <state-dir> - 0 while a live pause marker stands.
fm_autodispatch_paused() {
  local marker="$1/.autodispatch-paused" stop_at now
  [ -f "$marker" ] || return 1
  stop_at=$(sed -n 's/^until=//p' "$marker" 2>/dev/null | head -n 1)
  case "$stop_at" in ''|*[!0-9]*) return 0 ;; esac  # a damaged marker stays a pause
  [ "$stop_at" -eq 0 ] && return 0
  now=$(date +%s)
  [ "$now" -lt "$stop_at" ]
}

# fm_autodispatch_pause_describe <state-dir> - one line naming the pause state.
fm_autodispatch_pause_describe() {
  local marker="$1/.autodispatch-paused" since stop_at reason
  if [ ! -f "$marker" ]; then echo "automatic dispatch: running"; return 0; fi
  since=$(sed -n 's/^since=//p' "$marker" | head -n 1)
  stop_at=$(sed -n 's/^until=//p' "$marker" | head -n 1)
  reason=$(sed -n 's/^reason=//p' "$marker" | head -n 1)
  if fm_autodispatch_paused "$1"; then
    case "$stop_at" in ''|0|*[!0-9]*) stop_at="until lifted with --resume" ;; *) stop_at="until epoch $stop_at" ;; esac
    echo "automatic dispatch: PAUSED since epoch ${since:-unknown}, $stop_at${reason:+ ($reason)}"
  else
    echo "automatic dispatch: running (an earlier pause expired; --resume removes its marker)"
  fi
}
