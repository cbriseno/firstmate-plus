#!/usr/bin/env bash
# fm-overseer-watch.sh - wait for an actionable overseer event.
# Usage: FM_HOME=<home> bash bin/fm-overseer-watch.sh
#        FM_HOME=<home> bash bin/fm-overseer-watch.sh --ack <event-id>
#        bash bin/fm-overseer-watch.sh --help
# Prints event_id=<id> followed by the event. Unacknowledged events are
# replayed until the caller confirms delivery with --ack and the same id.
# Checks pending wakes, open decisions, failures, a missing primary, capacity,
# and unhandled review results. Polling itself never emits a timer-only wake.
# FM_OVERSEER_POLL sets the polling interval in seconds (default 30), and
# FM_OVERSEER_WAIT sets the attention delay in seconds (default 600).
set -u
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -u/p' "$0" | sed '$d;s/^# \{0,1\}//'
  exit 0
fi
umask 077
wait_seconds=${FM_OVERSEER_WAIT:-600}
poll_seconds=${FM_OVERSEER_POLL:-30}
for number in "$wait_seconds" "$poll_seconds"; do
  case "$number" in ''|*[!0-9]*|0[0-9]*) echo 'watch intervals must be nonnegative whole seconds' >&2; exit 2 ;; esac
  [ "${#number}" -le 9 ] || { echo 'watch interval is too large' >&2; exit 2; }
done
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
FM_HOME=${FM_HOME:-${script_dir%/bin}}
state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
oversee="$state/overseer"
mkdir -p "$oversee" || exit 1
pending="$oversee/pending-event"
if [ "${1:-}" = --ack ]; then
  [ "$#" -eq 2 ] && [ -f "$pending" ] && [ ! -L "$pending" ] || exit 1
  event_id=$(sed -n '1p' "$pending")
  marker=$(sed -n '2p' "$pending")
  [ "$event_id" = "$2" ] || exit 1
  case "$marker" in "$oversee/"*) ;; *) exit 1 ;; esac
  case "$marker" in *'/../'*|*/..) exit 1 ;; esac
  : > "$marker" || exit 1
  rm -f -- "$pending" || exit 1
  exit 0
fi
[ "$#" -eq 0 ] || exit 2
# shellcheck source=bin/fm-classify-lib.sh
. "$script_dir/fm-classify-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$script_dir/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$script_dir/fm-wake-lib.sh"
emit_pending() {
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  printf 'event_id=%s\n' "$(sed -n '1p' "$pending")"
  sed -n '3,$p' "$pending"
}
publish_event() {  # <marker> <message>
  local marker=$1 message=$2 tmp
  if [ -e "$pending" ]; then emit_pending; return; fi
  tmp=$(mktemp "$oversee/.pending-event.XXXXXX") || return 1
  if ! { printf '%s-%s\n%s\n%s\n' "$(date +%s)" "$$" "$marker" "$message" > "$tmp" && mv "$tmp" "$pending"; }; then
    rm -f -- "$tmp"
    return 1
  fi
  emit_pending
}
# Keep the classifier's incremental cursors in the overseer's own state.
_fm_open_decisions_cursor_path() {
  local name
  name=${1##*/}
  printf '%s/.%s.open-decisions-cursor' "$oversee" "${name%.status}"
}
scan_decisions() {
  local f task open key verb note marker observed now dir old oldkey source_cursor own_cursor tmp quiet_since
  now=$(date +%s) || return 1
  for f in "$state"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    task=${f##*/}; task=${task%.status}
    case "$task" in ''|[!a-zA-Z0-9]*|*[!a-zA-Z0-9_.-]*) continue ;; esac
    source_cursor="$state/.$task.open-decisions-cursor"
    own_cursor=$(_fm_open_decisions_cursor_path "$f")
    if [ ! -e "$own_cursor" ] && [ -f "$source_cursor" ] && [ ! -L "$source_cursor" ]; then
      tmp=$(mktemp "$oversee/.cursor.XXXXXX") || return 1
      if ! { cp -- "$source_cursor" "$tmp" && mv "$tmp" "$own_cursor"; }; then
        rm -f -- "$tmp"
        return 1
      fi
    fi
    open=$(status_open_decisions_incremental "$f") || continue
    dir="$oversee/decisions/$task"
    mkdir -p "$dir" || return 1
    for old in "$dir"/*; do
      [ -d "$old" ] && [ ! -L "$old" ] || continue
      oldkey=${old##*/}; oldkey=${oldkey#k-}
      if ! printf '%s\n' "$open" | awk -F '\t' -v key="$oldkey" '$1 == key {found=1} END {exit !found}'; then
        rm -f -- "$old/observed" "$old/observed.sent" || return 1
        rmdir -- "$old" || return 1
      fi
    done
    while IFS=$'\t' read -r key verb note; do
      [ -n "$key" ] || continue
      case "$task:$key" in *[!a-zA-Z0-9_.:-]*) continue ;; esac
      mkdir -p "$dir/k-$key" || return 1
      marker="$dir/k-$key/observed"
      if [ ! -f "$marker" ] || [ "$(sed '1d' "$marker")" != "$verb: $note" ]; then
        rm -f -- "$marker.sent" || return 1
        # A quiet status file proves inactivity, not the decision's emission time.
        quiet_since=$(fm_path_mtime "$f") || quiet_since=$now
        case "$quiet_since" in ''|*[!0-9]*) quiet_since=$now ;; esac
        [ "$quiet_since" -le "$now" ] || quiet_since=$now
        printf '%s\n%s: %s\n' "$quiet_since" "$verb" "$note" > "$marker" || return 1
      fi
      IFS= read -r observed < "$marker" || continue
      case "$observed" in ''|*[!0-9]*) continue ;; esac
      quiet_since=$(fm_path_mtime "$f") || quiet_since=$observed
      case "$quiet_since" in ''|*[!0-9]*) quiet_since=$observed ;; esac
      if [ ! -e "$marker.sent" ] && [ "$quiet_since" -gt "$observed" ] && [ "$quiet_since" -le "$now" ]; then
        observed=$quiet_since
        printf '%s\n%s: %s\n' "$observed" "$verb" "$note" > "$marker" || return 1
      fi
      [ $((now - observed)) -ge "$wait_seconds" ] || continue
      [ ! -f "$marker.sent" ] || continue
      publish_event "$marker.sent" "unattended decision: task=$task key=$key $verb: $note"
      return $?
    done <<EOT
$open
EOT
  done
  return 1
}
scan_wakes() {
  local timestamp sequence kind key reason now marker
  [ -f "$state/.wake-queue" ] || return 1
  now=$(date +%s) || return 1
  while IFS=$'\t' read -r timestamp sequence kind key reason; do
    case "$timestamp" in ''|*[!0-9]*|0[0-9]*) continue ;; esac
    case "$sequence" in ''|*[!0-9]*|0[0-9]*) continue ;; esac
    [ "${#timestamp}" -le 12 ] && [ "${#sequence}" -le 18 ] || continue
    # Decisions and failures have their own durable classifiers below; replaying
    # their signal rows here would wake twice for the same event.
    case "$kind" in stale|check) ;; *) continue ;; esac
    [ $((now - timestamp)) -ge "$wait_seconds" ] || continue
    marker="$oversee/wake-$sequence.sent"
    [ ! -e "$marker" ] || continue
    publish_event "$marker" "unattended wake: kind=$kind key=$key $reason"
    return $?
  done < "$state/.wake-queue"
  return 1
}
scan_failures() {
  local f task line verb marker now at dir
  now=$(date +%s) || return 1
  mkdir -p "$oversee/failures" || return 1
  for f in "$state"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    task=${f##*/}; task=${task%.status}
    case "$task" in ''|[!a-zA-Z0-9]*|*[!a-zA-Z0-9_.-]*) continue ;; esac
    dir="$oversee/failures/t-$task"
    marker="$dir/observed"
    line=$(last_status_line "$f") || continue
    verb=$(status_line_verb "$line")
    if [ "$verb" != failed ]; then
      rm -f -- "$marker" "$marker.sent" || return 1
      [ ! -d "$dir" ] || rmdir -- "$dir" || return 1
      continue
    fi
    mkdir -p "$dir" || return 1
    if [ ! -f "$marker" ] || [ "$(sed '1d' "$marker")" != "$line" ]; then
      rm -f -- "$marker.sent" || return 1
      at=$(status_line_at_epoch "$line") || at=$now
      [ "$at" -le "$now" ] || at=$now
      printf '%s\n%s\n' "$at" "$line" > "$marker" || return 1
    fi
    IFS= read -r at < "$marker" || continue
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ $((now - at)) -ge "$wait_seconds" ] || continue
    [ ! -e "$marker.sent" ] || continue
    publish_event "$marker.sent" "unattended failure: task=$task $line"
    return $?
  done
  return 1
}
next_queue_check=0
scan_capacity() {
  local report field mem='' disk='' free='' marker value threshold now queued
  report=$(FM_HOME="$FM_HOME" bash "$script_dir/fm-capacity.sh" 2>/dev/null) || return 1
  report=${report%%$'\n'*}
  for field in $report; do
    case "$field" in mem_free_pct=*) mem=${field#*=} ;; disk_free_mb=*) disk=${field#*=} ;; free_lanes=*) free=${field#*=} ;; esac
  done
  for field in memory disk; do
    case "$field" in memory) value=$mem; threshold=10 ;; disk) value=$disk; threshold=5120 ;; esac
    case "$value" in ''|*[!0-9]*) continue ;; esac
    marker="$oversee/resource-$field.sent"
    if [ "$value" -ge "$threshold" ]; then
      rm -f -- "$marker" || return 1
    elif [ ! -e "$marker" ]; then
      publish_event "$marker" "host resource low: $field=$value"
      return $?
    fi
  done
  case "$free" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$free" -eq 0 ]; then
    rm -f -- "$oversee/idle-queue" "$oversee/idle-queue.sent" || return 1
    return 1
  fi
  now=$(date +%s) || return 1
  [ "$now" -ge "$next_queue_check" ] || return 1
  next_queue_check=$((now + 120))
  queued=$(FM_HOME="$FM_HOME" bash "$script_dir/fm-tasks-axi.sh" work continuations 2>/dev/null | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    tasks = value["tasks"]
    if not isinstance(tasks, list): raise ValueError()
    print(sum(1 for item in tasks if isinstance(item, dict) and item.get("state") == "queued"))
except (ValueError, KeyError, TypeError):
    print("unknown")
') || return 1
  case "$queued" in ''|*[!0-9]*) return 1 ;; esac
  marker="$oversee/idle-queue"
  if [ "$queued" -eq 0 ]; then
    rm -f -- "$marker" "$marker.sent" || return 1
    return 1
  fi
  [ -f "$marker" ] || printf '%s\n' "$now" > "$marker" || return 1
  IFS= read -r value < "$marker" || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - value)) -ge "$wait_seconds" ] || return 1
  [ ! -e "$marker.sent" ] || return 1
  publish_event "$marker.sent" "idle capacity: free_lanes=$free queued=$queued"
  return $?
}
scan_primary() {
  local now observed marker="$oversee/primary-absent"
  fm_session_lock_inspect "$state"
  case "$FM_LOCK_INSPECT_STATE" in
    held) rm -f -- "$marker" "$marker.sent"; return 1 ;;
    free|stale) ;;
    *) return 1 ;;
  esac
  now=$(date +%s) || return 1
  [ -f "$marker" ] || printf '%s\n' "$now" > "$marker" || return 1
  IFS= read -r observed < "$marker" || return 1
  case "$observed" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - observed)) -ge "$wait_seconds" ] || return 1
  [ ! -e "$marker.sent" ] || return 1
  publish_event "$marker.sent" "primary absent: session lock is $FM_LOCK_INSPECT_STATE"
}
scan_reviews() {
  local rows result base at now marker
  [ -d "$state/procevent-inbox" ] || return 1
  rows=$(FM_HOME="$FM_HOME" bash "$script_dir/fm-procevent.sh" pending-lavish 2>/dev/null) || return 1
  now=$(date +%s) || return 1
  while IFS= read -r result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    base=${result##*/}
    case "$base" in ''|*[!a-zA-Z0-9_.-]*) continue ;; esac
    at=$(fm_path_mtime "$result") || continue
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ $((now - at)) -ge "$wait_seconds" ] || continue
    marker="$oversee/review-$base.sent"
    [ ! -e "$marker" ] || continue
    publish_event "$marker" "unattended review result: $result"
    return $?
  done <<EOT
$rows
EOT
  return 1
}
while :; do
  emit_pending && exit 0
  scan_wakes && exit 0
  scan_decisions && exit 0
  scan_failures && exit 0
  scan_primary && exit 0
  scan_capacity && exit 0
  scan_reviews && exit 0
  sleep "$poll_seconds"
done
