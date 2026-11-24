#!/usr/bin/env bash
# A pause may wait only on a process of its own copy, never on another copy's run.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp=$(fm_test_tmproot wait-pid-own)
state="$tmp/state"
mkdir -p "$state" "$tmp/config"
state=$(cd "$state" && pwd -P)
scope="$state/task:g1"
printf 'process_scope=%s\nspawn_gen=g1\n' "$scope" > "$state/task.meta"
env FM_WORKER_PROCESS_SCOPE="$scope" sleep 120 &
mine=$!
sleep 120 &
foreign=$!
trap 'kill "$mine" "$foreign" 2>/dev/null || true; wait 2>/dev/null || true; fm_test_cleanup' EXIT
status() { FM_HOME="$tmp" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$tmp/config" bash "$ROOT/bin/fm-task-status.sh" task paused "$1"; }

status "[wait-pid=$mine] my own run" || fail 'own process was refused'
rc=0
status "[wait-pid=$foreign] someone else's run" 2>"$tmp/err" || rc=$?
[ "$rc" = 2 ] || fail "foreign process was accepted (rc=$rc)"
grep -q 'own copy' "$tmp/err" || fail 'refusal did not explain itself'
[ "$(grep -c "wait-pid=$foreign" "$state/task.status")" = 0 ] || fail 'foreign declaration was recorded'

# A declaration written before this check stays unverifiable instead of holding the pause.
rc=0
python3 "$ROOT/bin/fm-pause-job.py" "$state" task "paused [wait-pid=$foreign]: x" || rc=$?
[ "$rc" = 2 ] || fail "foreign pid held the pause (rc=$rc)"
rc=0
python3 "$ROOT/bin/fm-pause-job.py" "$state" task "paused [wait-pid=$mine]: x" || rc=$?
[ "$rc" = 1 ] || fail "own live pid did not hold the pause (rc=$rc)"
# A process that died (here by signal, 144 = 128+16 style) wakes the worker.
sleep 120 &
dead=$!
kill -KILL "$dead"; wait "$dead" 2>/dev/null || true
rc=0
python3 "$ROOT/bin/fm-pause-job.py" "$state" task "paused [wait-pid=$dead]: x" || rc=$?
[ "$rc" = 0 ] || fail "dead pid did not wake the pause (rc=$rc)"
rc=0
python3 "$ROOT/bin/fm-pause-job.py" "$state" task "paused [wait-pid=$mine] [wait-pid=$dead]: x" || rc=$?
[ "$rc" = 0 ] || fail "one dead pid among live ones did not wake the pause (rc=$rc)"
status "[wait-pid=$dead] already gone" || fail 'declaring an ended process was refused as foreign'
pass 'wait-pid must belong to the declaring copy'
