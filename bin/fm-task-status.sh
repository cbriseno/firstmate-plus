#!/usr/bin/env bash
# Append a worker status, queue an actionable status span, and publish the
# task card and progress checkpoint in the same report.
# Usage: FM_HOME=<owning-home> fm-task-status.sh <task-id> <state> <note>
#          [--card-status TEXT] [--summary TEXT] [--presentation-file FILE]
# Timestamps are generated here. Routine progress stays silent; decisions,
# blockers and terminal events reach the queue even without a watcher.
# The watcher remains the backstop for legacy plain status appends.
# Any presentation option publishes through `fm-tasks-axi.sh presentation`
# right after the status line, so the checkpoint covers that line. FILE is a
# progress input (never data/<id>/presentation.json); the flags override its
# card_status and summary. Without progress in FILE, the current declaration's
# phase and steps are carried forward unchanged. The owner's busy refusal is
# retried once after one second. Exit 3: the status line was recorded but the
# presentation was not confirmed published; never repeat the status line,
# republish with `fm-tasks-axi.sh presentation <id> --presentation-file FILE`.
set -eu
[ -n "${FM_HOME:-}" ] || { echo 'error: FM_HOME is required' >&2; exit 2; }
[ "$#" -ge 3 ] || { sed -n '2,16p' "$0" >&2; exit 2; }
ID=$1 VERB=$2 NOTE=$3
shift 3
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
case "$VERB" in working|resolved|needs-decision|blocked|paused|done|failed|captain-held) ;; *) exit 2 ;; esac
PFILE='' OVERRIDES=() PUBLISH=0
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
  case "$1" in
    --card-status) OVERRIDES+=(card_status "$2") ;;
    --summary) OVERRIDES+=(summary "$2") ;;
    --presentation-file) PFILE=$2; [ -r "$PFILE" ] || { echo "error: cannot read $PFILE" >&2; exit 2; } ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  PUBLISH=1
  shift 2
done
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
FILE="$STATE/$ID.status"
printf '%s [at=%s]: %s\n' "$VERB" "$(date +%s)" "$NOTE" >> "$FILE"
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
[ ! -e "$CONFIG/fleet-ledger" ] || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$FILE" >/dev/null 2>&1 || true
record='' decision=0 status_error=0 rc=0 wake_rc=0
status_span_first_actionable_record "$FILE" "$(fm_wake_signal_seen_size "$STATE" "$FILE")" record decision status_error || rc=$?
if [ "$rc" = 2 ]; then
  wake_rc=1
elif [ -n "$record" ]; then
  endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
  if [ "$rc" = 0 ] || [ "$decision" = 1 ]; then
    reason="signal: $FILE"
    if [ "$decision" = 1 ]; then reason="needs-decision: $FILE"; fi
    case "$VERB" in needs-decision|blocked|captain-held) reason="needs-decision: $FILE" ;; esac
    [ "$status_error" = 0 ] || reason="needs-decision: status-error: $FILE"
    fm_wake_append signal "$ID.status" "$reason"
    # Commit only the snapshot actually queued, so a concurrent append stays unread.
    fm_wake_status_seen_commit "$STATE" "$FILE" "$endpoint" "$ident"
  fi
fi
[ "$PUBLISH" = 1 ] || exit "$wake_rc"
python3 - "$SCRIPT_DIR/fm-tasks-axi.sh" "$ID" "$PFILE" ${OVERRIDES[@]+"${OVERRIDES[@]}"} <<'PY' || exit 3
import json, os, subprocess, sys, tempfile, time
tool, task, source = sys.argv[1:4]
def owner(*args):
    return subprocess.run([tool, 'presentation', task, *args], capture_output=True, text=True)
value = {}
if source:
    with open(source, encoding='utf-8') as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        sys.exit('fm-task-status: presentation input must be a JSON object')
if 'progress' not in value:
    read = owner('--json')
    current = json.loads(read.stdout).get('presentation') or {} if read.returncode == 0 else {}
    if current.get('progress'):
        value['progress'] = current['progress']
        if current.get('phase') and 'phase' not in value:
            value['phase'] = current['phase']
value.update(zip(sys.argv[4::2], sys.argv[5::2]))
fd, path = tempfile.mkstemp(prefix='fm-task-status.', suffix='.json')
with os.fdopen(fd, 'w', encoding='utf-8') as stream:
    json.dump(value, stream, ensure_ascii=False)
try:
    for attempt in (0, 1):
        run = owner('--presentation-file', path)
        try:
            result = json.loads(run.stdout)
        except ValueError:
            result = {}
        busy = run.stderr.startswith('work mutation busy:') or result.get('code') == 'busy'
        if not busy or attempt:
            break
        time.sleep(1)
finally:
    os.unlink(path)
sys.stdout.write(run.stdout)
sys.stderr.write(run.stderr)
lifecycle = (result.get('lifecycle') or {}).get('evidence') or {}
if (run.returncode != 0 or result.get('ok') is not True or result.get('state') != 'published'
        or (result.get('evidence') or {}).get('available') is not True
        or ('progress' in value and lifecycle.get('current') is not True)):
    sys.exit('fm-task-status: status recorded; presentation not confirmed published - do not repeat the status line')
PY
exit "$wake_rc"
