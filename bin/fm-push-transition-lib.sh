#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the four production boundaries the transition handler actually calls.

FM_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-transition-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
FM_WAKE_POST_OUTPUT_ACTION=
# Set only after this watcher has printed a durable actionable reason. The
# watcher's EXIT cleanup uses it to distinguish an ordinary delivered close from
# an interruption that leaves a recovery gap before the next arm.
FM_WATCH_DELIVERED_REASON=
FM_WATCH_DELIVERY_PID=
FM_WATCH_DELIVERY_IDENTITY=
WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_MAX_BYTES=${FM_WATCH_DELIVERY_MAX_BYTES:-65536}
WATCH_DELIVERY_KEEP_LINES=${FM_WATCH_DELIVERY_KEEP_LINES:-64}
case "$WATCH_DELIVERY_MAX_BYTES" in ''|*[!0-9]*|0) WATCH_DELIVERY_MAX_BYTES=65536 ;; esac
case "$WATCH_DELIVERY_KEEP_LINES" in ''|*[!0-9]*|0) WATCH_DELIVERY_KEEP_LINES=64 ;; esac

watch_delivery_clean_identity() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_clean_reason() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-4096
}

watch_delivery_publish() {
  # Identity/reason cleaning are sequential $(): sibling $() args to one
  # printf are a bash 5.2 parse-error landmine when a CHLD trap is set.
  local reason=$1 i size tmp raw ident cleaned_reason
  [ -n "$FM_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$FM_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  ident=$(watch_delivery_clean_identity "$FM_WATCH_DELIVERY_IDENTITY")
  cleaned_reason=$(watch_delivery_clean_reason "$reason")
  printf '%s\t%s\t%s\n' \
    "$FM_WATCH_DELIVERY_PID" \
    "$ident" \
    "$cleaned_reason" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  size=$(wc -c < "$WATCH_DELIVERY_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$WATCH_DELIVERY_MAX_BYTES" ]; then
        tmp="$WATCH_DELIVERY_LOG.tmp.$FM_WATCH_DELIVERY_PID"
        raw="$tmp.raw"
        tail -n "$WATCH_DELIVERY_KEEP_LINES" "$WATCH_DELIVERY_LOG" 2>/dev/null \
          | tail -c "$WATCH_DELIVERY_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^[0-9]+\t/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$WATCH_DELIVERY_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$WATCH_DELIVERY_LOCK"
}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Information, ordinary completions and questions share one fleet-wide deadline.
# Default one hour; FM_INFO_SUMMARY_SECS can lengthen it or shorten it to 15 min.
# The existing .last-info-summary records every successful primary delivery;
# urgent events can bypass the deadline and start a new interval.
watch_batch_interval() {
  local interval=${FM_INFO_SUMMARY_SECS:-3600}
  case "$interval" in ''|*[!0-9]*) interval=3600 ;; esac
  [ "$interval" -ge 900 ] || interval=900
  printf '%s\n' "$interval"
}

watch_attention_batch_due() {
  local last first now
  now=$(date +%s)
  last=$(cat "$STATE/.last-info-summary" 2>/dev/null || true)
  case "$last" in
    ''|*[!0-9]*)
      first=$(awk -F '\t' '$1 ~ /^[0-9]+$/ && (!first || $1 < first) { first=$1 } END { print first }' \
        "$STATE/.watch-info" "$FM_WAKE_QUEUE" 2>/dev/null)
      case "$first" in ''|*[!0-9]*) return 1 ;; esac
      last=$first
      ;;
  esac
  [ "$((now - last))" -ge "$(watch_batch_interval)" ]
}

# Keep informational detail outside the queue until the shared batch is due.
watch_info_record() {  # <category> <detail>
  triage_log "absorbed benign $2"
  printf '%s\t%s\n' "$(date +%s)" "$1" >> "$STATE/.watch-info"
}

# Classify before publishing; recheck at delivery because an intervening answer
# can resolve a previously actionable event. Both use the same predicate.
watch_event_append() {  # <kind> <key> <payload>
  if declare -F watch_queued_event_actionable >/dev/null \
    && ! watch_queued_event_actionable "$@"; then
    watch_info_record "$1" "$3"
    return 0
  fi
  fm_wake_append "$@"
}

# Categories that only repeat background upkeep (heartbeat, watcher re-arm,
# endpoint observation). A batch made of nothing else needs no primary turn.
watch_info_only_upkeep() {
  ! awk -F '\t' '$2 != "heartbeat" && $2 != "recovery" && $2 != "lifecycle" { found=1 } END { exit !found }' \
    "$STATE/.watch-info" 2>/dev/null
}

watch_info_summary_tick() {
  local now summary reason
  [ -s "$STATE/.watch-info" ] || return 0
  watch_attention_batch_due || return 0
  if watch_info_only_upkeep; then
    : > "$STATE/.watch-info"
    return 0
  fi
  now=$(date +%s)
  summary=$(awk -F '\t' '{ n[$2]++ } END { for (k in n) print k "=" n[k] }' \
    "$STATE/.watch-info" | LC_ALL=C sort | tr '\n' ' ')
  reason="check: informational summary: $summary; details=$TRIAGE_LOG"
  fm_wake_append check informational-summary "$reason" || exit 1
  printf '%s\n' "$now" > "$STATE/.last-info-summary"
  : > "$STATE/.watch-info"
  wake "$reason"
}

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  local output_status=0 surfaced='' f endpoint ident deferred=0
  # Every producer goes through the same delivery decision, including the
  # away-mode handoff and recovery paths. Queued history is not current work.
  if declare -F main_has_eligible_queued_row >/dev/null; then
    if ! main_has_eligible_queued_row; then
      watch_info_record deferred "$1"
      deferred=1
    elif ! watch_attention_batch_due && ! main_has_eligible_queued_row immediate; then
      # The pending rows already record these actions. Do not consume them or
      # manufacture another informational record on every poll.
      deferred=1
    fi
  fi
  if [ "$deferred" = 1 ]; then
    if [ -n "$FM_WAKE_POST_OUTPUT_ACTION" ]; then
      "$FM_WAKE_POST_OUTPUT_ACTION" 1 || true
      FM_WAKE_POST_OUTPUT_ACTION=
    fi
    return 0
  fi
  if declare -F queued_status_surface_snapshot >/dev/null; then
    surfaced=$(queued_status_surface_snapshot)
  fi
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  trap '' HUP INT TERM
  [ -z "$FM_WAKE_POST_OUTPUT_ACTION" ] || trap '' PIPE
  if echo "$1"; then
    output_status=0
    while IFS=$'\t' read -r f endpoint ident; do
      [ -n "$f" ] || continue
      if [ "$endpoint" = ERROR ]; then
        mark_surface_reported "$f" "$ident" || true
      else
        mark_surfaced "$f" "$endpoint" "$ident" || true
      fi
    done <<EOF
$surfaced
EOF
    watch_delivery_publish "$1" || true
    printf '%s\n' "$(date +%s)" > "$STATE/.last-info-summary"
    # shellcheck disable=SC2034 # Read by bin/fm-watch.sh's EXIT cleanup.
    FM_WATCH_DELIVERED_REASON=$1
  else
    output_status=1
  fi
  if [ -n "$FM_WAKE_POST_OUTPUT_ACTION" ]; then
    "$FM_WAKE_POST_OUTPUT_ACTION" "$output_status" || true
  fi
  [ "$output_status" -eq 0 ] || exit "$output_status"
  exit 0
}

_hb_surfaced_path() {
  status_heartbeat_seen_marker_path "$STATE" "$1"
}

# The byte offset in <task>'s status log that the heartbeat backstop has already
# classified, or 0 when it has no usable position. A position rather than an
# event line lets the backstop catch an event the per-wake path missed,
# and comparing the last line cannot see an event a later routine append moved
# past - exactly the masking fm-classify-lib.sh's span read exists to stop. An
# absent or malformed marker (including one an older watcher wrote as a status
# line) reads 0, so the log is re-classified and the backstop errs toward
# surfacing rather than swallowing.
hb_surfaced_offset() {  # <task>
  status_presentation_marker_offset "$(_hb_surfaced_path "$1")" "$STATE/$1.status"
}

# Record a status log as successfully classified through the captured endpoint.
mark_surfaced() {  # <status-file> <captured-end-offset> <captured-identity>
  local f=$1 task
  case "$f" in *.status) ;; *) return 0 ;; esac
  task=$(basename "$f"); task="${task%.status}"
  status_presentation_marker_commit "$(_hb_surfaced_path "$task")" "$f" "$2" "$3"
}

mark_surface_reported() {  # <status-file> <reported-signature>
  local f=$1 task
  task=$(basename "$f"); task="${task%.status}"
  status_presentation_marker_report "$(_hb_surfaced_path "$task")" "$2"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to detail window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  detail=$(fm_transition_detail "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  # A declared wait already names the human this transition would report: an
  # external dependency, or the captain a verified hold transferred the work to.
  # Either way the wait is durably recorded, so absorb the immediate escalation
  # and leave the bounded re-surface to the watcher's own pause cadence.
  if status_is_paused_or_captain_held "$(status_declared_wait_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared wait, awaiting external or captain): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window ($backend: agent $to${detail:+ ($detail)} - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append check "native-transition:$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  wake "$reason"
}
