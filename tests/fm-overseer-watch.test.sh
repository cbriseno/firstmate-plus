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
mkdir -p "$FM_HOME/state"
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
mkdir -p "$FM_HOME/state"
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
mkdir -p "$FM_HOME/state"
printf 'failed [at=1]: a required step failed\n' > "$FM_HOME/state/demo.status"
failure=$(bash "$WATCH") || fail 'watch did not surface a failure'
assert_contains "$failure" 'a required step failed' 'failure omitted its reason'
pass 'surfaces an unattended failure'

FM_HOME="$T/absent-home"
export FM_HOME
mkdir -p "$FM_HOME/state"
absence=$(bash "$WATCH") || fail 'watch did not surface an absent primary'
assert_contains "$absence" 'primary absent' 'missing primary was not identified'
pass 'surfaces an absent primary'

# Replace only the external capacity and backlog readings; the watch itself and
# its classifier run unchanged. These fixtures do not depend on a host's load.
mkdir -p "$T/bin"
for item in "$ROOT"/bin/*; do
  name=${item##*/}
  case "$name" in fm-overseer-watch.sh|fm-capacity.sh|fm-tasks-axi.sh|fm-procevent.sh) continue ;; esac
  ln -s "$item" "$T/bin/$name"
done
cp "$WATCH" "$T/bin/fm-overseer-watch.sh"
cat > "$T/bin/fm-capacity.sh" <<'STUB'
#!/usr/bin/env bash
[ -z "${FM_TEST_CAPACITY_CALLED:-}" ] || : > "$FM_TEST_CAPACITY_CALLED"
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
WATCH="$T/bin/fm-overseer-watch.sh"
FM_HOME="$T/resource-home"
export FM_HOME FM_TEST_CAPACITY='capacity: free_lanes=unknown mem_free_pct=4 disk_free_mb=9000'
mkdir -p "$FM_HOME/state"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
resource=$(bash "$WATCH") || fail 'watch did not surface low memory'
assert_contains "$resource" 'host resource low: memory=4' 'resource event omitted the measured value'
pass 'surfaces measured low memory without requiring a platform-specific probe'

FM_HOME="$T/queue-home"
export FM_HOME FM_TEST_CAPACITY='capacity: free_lanes=2 mem_free_pct=50 disk_free_mb=9000'
export FM_TEST_CONTINUATIONS='{"tasks":[{"id":"ready","state":"queued"}]}'
mkdir -p "$FM_HOME/state"
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
mkdir -p "$FM_HOME/state"
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
[ ! -s "$T/quiet-output" ] || fail 'watch emitted a timer-only wake'
kill "$watch_pid" 2>/dev/null || :
wait "$watch_pid" 2>/dev/null || :
watch_pid=''
pass 'polls silently when no actionable event exists'
