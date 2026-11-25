#!/usr/bin/env bash
# Append a worker status, queue an actionable status span, and publish the
# task card and progress checkpoint in the same report.
# Usage: FM_HOME=<owning-home> fm-task-status.sh <task-id> <state> <note>
#          [--card-status TEXT] [--summary TEXT] [--presentation-file FILE]
# For paused, put [wait-task=ID] in the note to wait for another task in this home.
# The watcher sends a resume notice when that task is integrated or closed.
# Workers reporting terminal failure must pass --exhausted-recovery with the
# recovery evidence in <note>. See the worker contract for when to stop.
# A worker reporting blocked must pass --tried 'route one; route two': at least
# two distinct routes it attempted, appended to the note as `[tried: ...]`, so
# a block never rests on a single failed path. Firstmate's own use is exempt.
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
[ "$#" -ge 3 ] || { sed -n '2,20p' "$0" >&2; exit 2; }
ID=$1 VERB=$2 NOTE=$3
shift 3
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
case "$VERB" in working|resolved|needs-decision|blocked|paused|done|failed|captain-held) ;; *) echo "error: invalid state '$VERB'; expected working, resolved, needs-decision, blocked, paused, done, failed, or captain-held" >&2; exit 2 ;; esac
PFILE='' OVERRIDES=() PUBLISH=0 EXHAUSTED=0 TRIED=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = --exhausted-recovery ] && [ "$VERB" = failed ]; then
    EXHAUSTED=1
    shift
    continue
  fi
  [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
  if [ "$1" = --tried ] && [ "$VERB" = blocked ]; then
    TRIED=$2
    shift 2
    continue
  fi
  case "$1" in
    --card-status) OVERRIDES+=(card_status "$2") ;;
    --summary) OVERRIDES+=(summary "$2") ;;
    --presentation-file) PFILE=$2; [ -r "$PFILE" ] || { echo "error: cannot read $PFILE" >&2; exit 2; } ;;
    *) echo "error: unknown option $1" >&2; exit 2 ;;
  esac
  PUBLISH=1
  shift 2
done
if [ "$VERB" = failed ] && [ -n "${FM_TASK_ID:-}" ] && [ "$EXHAUSTED" = 0 ]; then
  echo 'error: if authorized work remains, choose a reversible step, record why, and continue. For terminal failure, follow Obstacles and escalation, describe the exhausted recovery in the status note, and pass --exhausted-recovery.' >&2
  exit 2
fi
if [ "$VERB" = blocked ] && [ -n "${FM_TASK_ID:-}" ]; then
  tried_count=$(printf '%s\n' "$TRIED" | tr ';' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u | wc -l | tr -d '[:space:]')
  if [ "${tried_count:-0}" -lt 2 ]; then
    echo "error: blocked needs --tried 'route one; route two': at least two distinct routes you already attempted to get past it. Try another authorized route first (a different tool, address, account or method), then report all of them." >&2
    exit 2
  fi
  NOTE="$NOTE [tried: $TRIED]"
fi
SCRIPT_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
if threshold=$(FM_CLASSIFY_PAUSED_VERB=paused status_paused_load1 "$VERB: $NOTE"); then
  check_rc=0
  ceiling=$(FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" bash "$SCRIPT_DIR/fm-capacity.sh" --check-load-wait "$threshold") || check_rc=$?
  case "$check_rc" in
    0) echo "error: load1 < $threshold is below the admission ceiling $ceiling; choose another exit condition" >&2; exit 2 ;;
    1) ;;
    *) echo 'error: cannot compare the load wait with admission; repair capacity configuration or choose another exit condition' >&2; exit 2 ;;
  esac
fi
if [ "$VERB" = paused ]; then
  # A wait must name a process of this task's own copy, never another copy's.
  for pid in $(printf '%s' "$NOTE" | grep -Eo '\[wait-pid=[1-9][0-9]*\]' | grep -Eo '[0-9]+' || true); do
    # A process already gone has no owner to confuse; the watcher wakes the worker for it.
    kill -0 "$pid" 2>/dev/null || continue
    own_rc=0
    python3 "$SCRIPT_DIR/fm-worker-processes.py" owns "$STATE/$ID.meta" "$pid" || own_rc=$?
    [ "$own_rc" != 1 ] || { echo "error: [wait-pid=$pid] is not a process of this task's own copy; start your own run and declare its PID (echo \$! after launching it in the background)" >&2; exit 2; }
  done
fi
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
