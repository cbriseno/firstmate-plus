#!/usr/bin/env bash
# Append a worker status and immediately queue an actionable status span.
# Usage: FM_HOME=<owning-home> fm-task-status.sh <task-id> <state> <note>
# Timestamps are generated here. Routine progress stays silent; decisions,
# blockers and terminal events reach the queue even without a watcher.
# The watcher remains the backstop for legacy plain status appends.
set -eu
[ -n "${FM_HOME:-}" ] || { echo 'error: FM_HOME is required' >&2; exit 2; }
[ "$#" = 3 ] || { sed -n '2,6p' "$0" >&2; exit 2; }
ID=$1
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
case "$2" in working|resolved|needs-decision|blocked|paused|done|failed|captain-held) ;; *) exit 2 ;; esac
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
FILE="$STATE/$ID.status"
printf '%s [at=%s]: %s\n' "$2" "$(date +%s)" "$3" >> "$FILE"
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
[ ! -e "$CONFIG/fleet-ledger" ] || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$FILE" >/dev/null 2>&1 || true
record='' decision=0 status_error=0 rc=0
status_span_first_actionable_record "$FILE" "$(fm_wake_signal_seen_size "$STATE" "$FILE")" record decision status_error || rc=$?
[ "$rc" != 2 ] || exit 1
[ -n "$record" ] || exit 0
endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
if [ "$rc" = 0 ] || [ "$decision" = 1 ]; then
  reason="signal: $FILE"
  if [ "$decision" = 1 ]; then reason="needs-decision: $FILE"; fi
  case "$2" in needs-decision|blocked|captain-held) reason="needs-decision: $FILE" ;; esac
  [ "$status_error" = 0 ] || reason="needs-decision: status-error: $FILE"
  fm_wake_append signal "$ID.status" "$reason"
fi
# Commit only the snapshot actually queued, so a concurrent append stays unread.
if [ "$rc" = 0 ] || [ "$decision" = 1 ]; then
  fm_wake_status_seen_commit "$STATE" "$FILE" "$endpoint" "$ident"
fi
