#!/usr/bin/env bash
# The overseer receives pending events until it confirms their delivery.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WATCH="$ROOT/bin/fm-overseer-watch.sh"
T=$(fm_test_tmproot fm-overseer-watch)
watch_pid=''
cleanup_watch_test() {
  if [ -n "$watch_pid" ]; then
    kill "$watch_pid" 2>/dev/null || :
    wait "$watch_pid" 2>/dev/null || :
  fi
  fm_test_cleanup
}
trap cleanup_watch_test EXIT
export FM_HOME="$T/home" FM_OVERSEER_WAIT=0 FM_OVERSEER_POLL=1
export FM_TEST_LOCK_DIR="$T/slots" LAVISH_AXI_STATE_DIR="$T/lavish"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf '1\t12\tstale\tworker\tworker needs attention\n' > "$FM_HOME/state/.wake-queue"
first=$(bash "$WATCH") || fail 'watch did not publish an unattended wake'
id=${first%%$'\n'*}; id=${id#event_id=}
[ -n "$id" ] || fail 'event has no id'
assert_contains "$first" 'worker needs attention' 'event omitted the reason'
second=$(bash "$WATCH") || fail 'watch did not replay an unacknowledged wake'
[ "$first" = "$second" ] || fail 'unacknowledged event changed on replay'
if bash "$WATCH" --ack invalid; then fail 'accepted an unrelated acknowledgement'; fi
bash "$WATCH" --ack "$id" || fail 'valid acknowledgement was refused'
printf '1\t13\tcheck\tnext\tanother pending wake\n' > "$FM_HOME/state/.wake-queue"
third=$(bash "$WATCH") || fail 'watch did not publish the next event'
assert_contains "$third" 'another pending wake' 'acknowledgement hid a later event'
[ "$third" != "$first" ] || fail 'later event reused the earlier record'
pass 'replays an event until acknowledged and then delivers a later event'

FM_HOME="$T/decision-home"
export FM_HOME
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
printf 'needs-decision [key=shape] [at=1]: needs an answer\n' > "$FM_HOME/state/demo.status"
printf '1\t14\tsignal\tdemo.status\tneeds an answer\n' > "$FM_HOME/state/.wake-queue"
decision=$(bash "$WATCH") || fail 'watch did not surface an open decision'
assert_contains "$decision" 'needs an answer' 'open decision omitted its reason'
assert_contains "$decision" 'unattended decision:' 'status signal was delivered separately from its decision'
decision_id=${decision%%$'\n'*}; decision_id=${decision_id#event_id=}
bash "$WATCH" --ack "$decision_id" || fail 'decision acknowledgement was refused'
printf 'resolved [key=shape]: answered\nfailed [at=1]: another failure\n' >> "$FM_HOME/state/demo.status"
next=$(bash "$WATCH") || fail 'watch did not move past the resolved decision'
assert_contains "$next" 'another failure' 'resolved decision hid a later failure'
next_id=${next%%$'\n'*}; next_id=${next_id#event_id=}
bash "$WATCH" --ack "$next_id" || fail 'failure acknowledgement was refused'
printf 'needs-decision [key=shape]: needs an answer\n' >> "$FM_HOME/state/demo.status"
reopened=$(bash "$WATCH") || fail 'watch did not surface a reopened decision'
assert_contains "$reopened" 'needs an answer' 'reopened decision was suppressed'
pass 'surfaces an open decision from the status classifier'

FM_HOME="$T/failed-home"
export FM_HOME
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf 'failed [at=1]: a required step failed\n' > "$FM_HOME/state/demo.status"
failure=$(bash "$WATCH") || fail 'watch did not surface a failure'
assert_contains "$failure" 'a required step failed' 'failure omitted its reason'
pass 'surfaces an unattended failure'

FM_HOME="$T/absent-home"
export FM_HOME
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
absence=$(bash "$WATCH") || fail 'watch did not surface an absent primary'
assert_contains "$absence" 'primary absent' 'missing primary was not identified'
pass 'surfaces an absent primary'

# Replace only the external capacity and backlog readings; the watch itself and
# its classifier run unchanged. These fixtures do not depend on a host's load.
mkdir -p "$T/bin"
for item in "$ROOT"/bin/*; do
  name=${item##*/}
  case "$name" in fm-overseer-watch.sh|fm-overseer-observations.py|fm-capacity.sh|fm-tasks-axi.sh|fm-procevent.sh|fm-captain-hold.sh) continue ;; esac
  ln -s "$item" "$T/bin/$name"
done
cp "$WATCH" "$T/bin/fm-overseer-watch.sh"
if [ -f "$ROOT/bin/fm-overseer-observations.py" ]; then
  cp "$ROOT/bin/fm-overseer-observations.py" "$T/bin/"
fi
cat > "$T/bin/fm-capacity.sh" <<'STUB'
#!/usr/bin/env bash
[ -z "${FM_TEST_CAPACITY_CALLED:-}" ] || : > "$FM_TEST_CAPACITY_CALLED"
if [ "${1:-}" = --admit-notice ]; then
  [ -z "${FM_TEST_ADMIT_CALLED:-}" ] || : > "$FM_TEST_ADMIT_CALLED"
  exit "${FM_TEST_ADMIT:-0}"
fi
printf '%s\n' "$FM_TEST_CAPACITY"
STUB
cat > "$T/bin/fm-tasks-axi.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_CONTINUATIONS"
STUB
cat > "$T/bin/fm-procevent.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_REVIEW"
STUB
chmod +x "$T/bin/fm-capacity.sh" "$T/bin/fm-tasks-axi.sh" "$T/bin/fm-procevent.sh"
cat > "$T/bin/fm-captain-hold.sh" <<'SH'
[ "$1" = open ] && [ "$2" = question ]
SH
WATCH="$T/bin/fm-overseer-watch.sh"
FM_HOME="$T/resource-home"
export FM_HOME FM_TEST_CAPACITY='capacity: free_lanes=unknown mem_free_pct=4 disk_free_mb=9000'
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
resource=$(bash "$WATCH") || fail 'watch did not surface low memory'
assert_contains "$resource" 'host resource low: memory=4' 'resource event omitted the measured value'
pass 'surfaces measured low memory without requiring a platform-specific probe'
rm -f -- "$FM_HOME/state/overseer/pending-event"
FM_TEST_CAPACITY='capacity: free_lanes=unknown mem_free_pct=50 disk_free_mb=3000'
resource=$(bash "$WATCH") || fail 'watch did not surface low disk'
assert_contains "$resource" 'host resource low: disk=3000' 'resource event omitted disk evidence'
pass 'surfaces measured low disk'

FM_HOME="$T/queue-home"
export FM_HOME FM_TEST_CAPACITY='capacity: free_lanes=2 mem_free_pct=50 disk_free_mb=9000'
export FM_TEST_CONTINUATIONS='{"tasks":[{"id":"ready","state":"queued"}]}'
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
queue=$(bash "$WATCH") || fail 'watch did not surface idle capacity with ready work'
assert_contains "$queue" 'free_lanes=2 queued=1' 'queue event omitted the measured facts'
pass 'surfaces free capacity alongside eligible queued work'

FM_HOME="$T/review-home"
export FM_HOME FM_TEST_CAPACITY='capacity: free_lanes=unknown mem_free_pct=50 disk_free_mb=9000'
mkdir -p "$FM_HOME/state/procevent-inbox"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
export FM_TEST_REVIEW="$FM_HOME/state/procevent-inbox/review.1.result"
printf 'captured feedback\n' > "$FM_TEST_REVIEW"
review=$(bash "$WATCH") || fail 'watch did not surface an unhandled review result'
assert_contains "$review" 'unattended review result:' 'review event omitted its reference'
pass 'surfaces an unhandled review result'

FM_HOME="$T/quiet-home"
export FM_HOME FM_TEST_CAPACITY='capacity: free_lanes=unknown mem_free_pct=50 disk_free_mb=9000'
export FM_TEST_CAPACITY_CALLED="$T/quiet-capacity-read"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
bash "$WATCH" > "$T/quiet-output" &
watch_pid=$!
attempt=0
while [ "$attempt" -lt 120 ]; do
  [ ! -f "$FM_TEST_CAPACITY_CALLED" ] || break
  attempt=$((attempt + 1))
  sleep 1
done
[ -f "$FM_TEST_CAPACITY_CALLED" ] || fail 'watch did not reach its capacity check'
sleep 2
kill -0 "$watch_pid" 2>/dev/null || fail 'watch exited without an event'
[ ! -s "$T/quiet-output" ] || fail 'watch emitted before its round was due'

wait_for_event() {
  local target=$1 reason=$2 attempt
  for attempt in $(seq 1 600); do
    grep -Fq "$reason" "$target" 2>/dev/null && return 0
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 0.1
  done
  assert_contains "$(cat "$target")" "$reason" 'watch did not emit the expected observation'
}

ack_event() {
  local id
  id=$(sed -n 's/^event_id=//p' "$1")
  bash "$WATCH" --ack "$id" || fail 'watch refused to acknowledge its event'
}

printf 'working: changed state\n' > "$FM_HOME/state/demo.status"
wait_for_event "$T/quiet-output" 'worker status changed: task=demo'
wait "$watch_pid"; watch_pid=''
ack_event "$T/quiet-output"
pass 'a working status wakes the supervisor on the next poll, even without a queue row'

touch -t 200001010000 "$FM_HOME/state/overseer/round"
bash "$WATCH" > "$T/round-output" & watch_pid=$!
wait_for_event "$T/round-output" 'periodic supervision round'
wait "$watch_pid"; watch_pid=''
ack_event "$T/round-output"
pass 'a due periodic round survives starting another background job'

check_observation() {
  local evidence=$1 out="$T/observation"
  bash "$WATCH" > "$out" & watch_pid=$!
  wait_for_event "$out" "$evidence"
  wait "$watch_pid"; watch_pid=''
  ack_event "$out"
}

: > "$FM_HOME/state/demo.meta"
touch -t 200001010000 "$FM_HOME/state/demo.status"
check_observation 'worker status changed: task=demo'
check_observation 'stalled worker: task=demo'
pass 'reports a worker stalled past 90 minutes, once per status version'

mkdir -p "$FM_HOME/data/question" "$FM_HOME/data/closed-question"
printf '%s\n' '{"schema":"fm-captain-call.v1","id":"question","hold_set":"fixture","call":{"question":"Proceed?"}}' > "$FM_HOME/data/question/captain-call.json"
printf '%s\n' '{"schema":"fm-captain-call.v1","id":"closed-question","hold_set":"fixture","call":{"question":"Closed?"}}' > "$FM_HOME/data/closed-question/captain-call.json"
check_observation 'primary has a question for the captain: task=question'
pass 'an open primary call wakes the supervisor, even when an earlier call is closed'

mkdir -p "$LAVISH_AXI_STATE_DIR" "$T/fake"
: > "$FM_HOME/data/review.html"
printf '%s\n' '{"sessions":{"abcd":{"file":"'"$FM_HOME"'/data/review.html","status":"open","url":"http://127.0.0.1:32001/session/0123456789abcdef","pending_prompts":1}}}' > "$LAVISH_AXI_STATE_DIR/state.json"
printf '#!/usr/bin/env bash\nexit 7\n' > "$T/fake/curl"
chmod +x "$T/fake/curl"
export PATH="$T/fake:$PATH"
check_observation 'unattended Lavish board:'
[ ! -d "$FM_HOME/state/procevent" ] || fail 'the supervisor attempted to recover the board itself'
pass 'detects saved feedback without a listener through the read-only coverage check'

git -C "$FM_HOME" init -q -b main
GIT_AUTHOR_DATE=2001-01-01T00:00:00Z GIT_COMMITTER_DATE=2001-01-01T00:00:00Z \
  git -C "$FM_HOME" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m 'Old integration'
check_observation 'no integration:'
pass 'detects no integration in the last two hours'

mkdir -p "$FM_TEST_LOCK_DIR"
python3 - "$FM_TEST_LOCK_DIR" <<'PY' &
import fcntl, os, pathlib, sys, time
directory = pathlib.Path(sys.argv[1])
prefix = f'firstmate-test-{os.getuid()}-'
with (directory / (prefix + 'run-one')).open('w') as first, (directory / (prefix + 'run-two')).open('w') as second:
    for runner, stream in enumerate((first, second), 1):
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(f'{runner} 1 {time.time()} 0\n')
        stream.flush()
    (directory / 'ready').touch()
    while not (directory / 'done').exists():
        time.sleep(0.1)
PY
slots_pid=$!
for _ in $(seq 1 120); do [ -e "$FM_TEST_LOCK_DIR/ready" ] && break; sleep 0.1; done
if (check_observation 'test slots saturated: 2 runs for 1 slots'); then
  : > "$FM_TEST_LOCK_DIR/done"
  wait "$slots_pid"
else
  kill "$slots_pid" 2>/dev/null || :
  wait "$slots_pid" 2>/dev/null || :
  fail 'the watch did not report actual test-slot contention'
fi
pass 'detects test demand through the host test-slot owner records'

FM_HOME="$T/draft-home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data"
printf '## In flight\n\n- [ ] demo - Demo\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
printf '%s\n' '11111111-2222-4333-8444-555555555555' > "$FM_HOME/state/.lock-session"
rm -f -- "$T/bin/fm-overseer-primary.sh"
cat > "$T/bin/fm-overseer-primary.sh" <<'SH'
[ "$1" = --locate ] && printf 'tmux %s\n' '%1'
SH
cat > "$T/fake/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *comm=*|*args=*) printf 'claude\n' ;;
  *stat=*) printf 'S\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fake/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message) printf '1\n' ;;
  capture-pane) printf '\n❯ Private draft still here\n\n' ;;
  send-keys) printf 'unexpected typing\n' > "$FM_HOME/typed" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fake/ps" "$T/fake/tmux"
check_observation 'primary has unsent text in its input'
assert_not_contains "$(cat "$T/observation")" 'Private draft' 'the event copied the draft'
[ ! -e "$FM_HOME/typed" ] || fail 'the watcher typed into the primary input'
pass 'detects proven unsent text at the primary without copying it or sending a key'

# Current backlog, not retained status files, owns supervision eligibility.
printf 'exit 1\n' > "$T/bin/fm-overseer-primary.sh"
FM_HOME="$T/active-home"
export FM_HOME FM_TEST_CAPACITY='capacity: free_lanes=2 mem_free_pct=50 disk_free_mb=9000'
export FM_TEST_CONTINUATIONS='{"tasks":[{"id":"ready","state":"queued"}]}' FM_TEST_ADMIT=1 FM_TEST_ADMIT_CALLED="$T/admission-called"
mkdir -p "$FM_HOME/state/overseer/status" "$FM_HOME/state/overseer/stalled" "$FM_HOME/data"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
cat > "$FM_HOME/data/backlog.md" <<'BACKLOG'
## In flight

- [ ] active - Active
- [ ] parked - Parked (hold: espera) (hold-kind: parked)

## Queued

## Done
BACKLOG
for task in active parked removed; do
  printf 'paused [key=pausa-capitan]: waiting\n' > "$FM_HOME/state/$task.status"
  : > "$FM_HOME/state/$task.meta"
  touch -t 200001010000 "$FM_HOME/state/$task.status"
done
active=$(python3 "$T/bin/fm-overseer-observations.py" active "$FM_HOME") || fail 'cannot read active backlog'
FM_OVERSEER_ACTIVE_TASKS="$active" python3 "$T/bin/fm-overseer-observations.py" status "$FM_HOME/state" "$FM_HOME/state/overseer" >/dev/null
rows=$(FM_OVERSEER_ACTIVE_TASKS="$active" python3 "$T/bin/fm-overseer-observations.py" status "$FM_HOME/state" "$FM_HOME/state/overseer")
assert_contains "$rows" 'stalled active' 'active old task was not observed'
assert_not_contains "$rows" 'parked' 'parked task was declared stalled'
assert_not_contains "$rows" 'removed' 'removed task was observed'
# The watcher must not emit a queue event while the admission verdict blocks it.
rm -f -- "$FM_HOME/state/active.status" "$FM_HOME/state/parked.status" "$FM_HOME/state/removed.status"
bash "$WATCH" > "$T/admission-output" & watch_pid=$!
for _ in $(seq 1 300); do [ -e "$FM_TEST_ADMIT_CALLED" ] && break; sleep 0.1; done
[ -e "$FM_TEST_ADMIT_CALLED" ] || fail 'watch did not evaluate admission'
printf 'working: resumed\n' > "$FM_HOME/state/active.status"
wait_for_event "$T/admission-output" 'worker status changed: task=active'
assert_not_contains "$(cat "$T/admission-output")" 'idle capacity' 'load brake was ignored'
wait "$watch_pid"; watch_pid=''
pass 'ignores removed and parked statuses and respects admission before idle capacity'
