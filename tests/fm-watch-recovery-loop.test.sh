#!/usr/bin/env bash
# A handling successor keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1


# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  # Continuity needs an immediate event; ordinary completions share the fleet batch.
  printf 'blocked: crew needs its missing input\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 300 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# T3: a row appended after the predecessor closes but before its handling
# successor can inspect the queue must survive the handoff and reach main.
test_handling_successor_resurfaces_a_row_appended_during_startup() {
  local dir home state fakebin child blocker now out
  dir=$(make_case recovery-startup-append)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'pending:downtime:later.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '%s\t1\tstale\tfm-demo\tstale: fm-demo (the delivered wake)\n' "$(date +%s)" > "$state/.wake-queue"
  printf '1\n' > "$state/.wake-queue.seq"
  out="$dir/watch.out"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    : > "$2/queue-held"
    while [ ! -e "$2/append-now" ]; do sleep 0.02; done
    fm_wake_append_locked check inbox:n1 "check: captain inbox note n1 - from Basecamp" || exit 1
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" &
  blocker=$!
  now=0
  while [ "$now" -lt 100 ] && [ ! -e "$state/queue-held" ]; do
    sleep 0.02
    now=$((now + 1))
  done
  [ -e "$state/queue-held" ] || { kill "$blocker" 2>/dev/null || true; fail "fixture: queue lock was not held"; }

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" "$blocker" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  : > "$state/append-now"
  wait "$blocker" || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: startup append failed"; }
  now=0
  while [ "$now" -lt 40 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    now=$((now + 1))
  done
  [ -e "$state/.last-watcher-beat" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: handling successor never finished startup"; }
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_begin_handling "$2/.watcher-down" later.1.aaa || exit 1
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    awk -F "\t" "\$2 != 1" "$FM_WAKE_QUEUE" > "$FM_WAKE_QUEUE.tmp" \
      && mv -f "$FM_WAKE_QUEUE.tmp" "$FM_WAKE_QUEUE" || exit 1
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    fm_recovery_marker_handling_settled "$2/.watcher-down"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: handled-turn settlement failed"; }

  now=0
  while [ "$now" -lt 200 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.25
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor never resurfaced the startup-window row: $(cat "$out"; cat "$state/.watcher-down")"
  fi
  wait "$child" 2>/dev/null || true
  [ "$(grep -c '^check: rearm-resurface$' "$out")" -eq 1 ] \
    || fail "handling successor did not close once with the recovery wake: $(cat "$out")"
  grep "$(printf '\tcheck\tinbox:n1\t')" "$state/.wake-queue" >/dev/null \
    || fail "the resurfaced inbox row must stay queued for main"
  grep -E '^(pending|announced):downtime:' "$state/.watcher-down" >/dev/null \
    || fail "the resurfaced close must leave a deliverable downtime episode: $(cat "$state/.watcher-down")"
  pass "a handling successor resurfaces a row appended during startup"
}

# A dispatch opportunity is work for the primary, even just after another delivery.
test_ready_work_wakes_once() {
  local dir home state fakebin out child i id sequence generation
  dir=$(make_case ready-capacity)
  home="$dir/home"; state="$home/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$home/data" "$home/config" "$state"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"
  date +%s > "$state/.last-info-summary"
  printf '2:demo\n' > "$state/.ready-work-wake"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  printf '# Tasks\n\n## In flight\n\n## Queued\n\n- [ ] demo - Ready work (repo: firstmate)\n\n## Done\n' > "$home/data/backlog.md"
  printf '2\nmax-load1 1000\n' > "$home/config/lane-capacity"
  for id in held grouped missing; do
    FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$id work" --repo firstmate >/dev/null 2>&1 || fail "fixture: add $id"
  done
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold held --kind external --reason waiting >/dev/null 2>&1 || fail "fixture: hold"
  printf "kind=ship\n" > "$state/missing.meta" # A previous attempt left metadata on a queued task.
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add dependent 'Dependent work' --repo firstmate --blocked-by demo >/dev/null 2>&1 || fail "fixture: dependency"
  for id in demo held dependent grouped; do
    mkdir -p "$home/data/$id"
    printf '# Brief\n' > "$home/data/$id/brief.md"
  done
  printf '%s\n' '- firstmate [local-only] - Fixture project' > "$home/data/projects.md"
  python3 - "$home" <<'PYFIX'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
(home/'data/work-structure.json').write_text(json.dumps(dict(schema='fm-work-structure.v1',
    groups={'subproject:firstmate/paused': dict(kind='subproject', repo='firstmate', label='Paused',
        pause=dict(kind='parked', reason='Captain pause'), blocked_by=[])},
    membership={'grouped': 'subproject:firstmate/paused'}, order=[], edge_meta={})))
PYFIX
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" work dispatch-check --task demo >/dev/null || fail "fixture: demo dispatch"
  if FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" work dispatch-check --task grouped >/dev/null; then
    fail "fixture: group pause was not active"
  fi
  for id in held grouped; do
    printf '%s\n' "$home" > "$state/$id.spawn-deferred"
  done
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$WATCH" > "$out" 2>&1 &
  child=$!
  for ((i=0; i<600; i++)); do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child"; wait "$child" 2>/dev/null || true
    fail "eligible dispatch waited for the information batch: $(cat "$out")"
  fi
  wait "$child" 2>/dev/null || true
  grep -F 'check: ready work' "$out" | grep -F '(demo:' >/dev/null || fail "wrong dispatch candidates: $(cat "$out")"
  [ "$(awk -F '\t' '$3=="check" && $4=="ready-work:primary:dispatch"{n++} END{print n+0}' "$state/.wake-queue")" -eq 1 ] \
    || fail "dispatch wake was not queued exactly once"
  ! grep -F 'ready-work:primary:brief:missing' "$state/.wake-queue" >/dev/null ||
    fail "a queued row with a missing brief was assigned to the primary"
  for id in held grouped; do
    [ -f "$state/$id.spawn-deferred" ] || fail "paused retry reminder was retired: $id"
  done
  grep -Fx "$(cat "$out")" "$state/.ready-work-wake" >/dev/null || fail "published dispatch reason was not preserved"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" || true
  sequence=$(fm_test_single_wake_sequence "$dir/drain.out")
  generation=$(fm_test_wake_generation "$dir/drain.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail 'fixture: no acknowledgement was offered'
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" --ack "$sequence" --recovery-generation "$generation" > /dev/null 2>&1 || fail 'fixture: acknowledgement failed'
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold missing --kind external --reason resolved >/dev/null || fail 'fixture: hold missing brief'
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_OBLIGATION_SECONDS=1 \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=1 FM_DIAGNOSTICS_HOME="$dir/diag" bash "$WATCH" > "$out" 2>&1 &
  child=$!
  for ((i=0; i<600; i++)); do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child"; wait "$child" 2>/dev/null || true
    fail 'acknowledged ready work was not reminded after its deadline'
  fi
  wait "$child" 2>/dev/null || true
  grep -F 'still unattended for' "$out" | grep -F '(demo:' >/dev/null || fail "wrong reminder: $(cat "$out")"
  jq -e 'select(.e == "obligation.overdue" and .category == "ready-work")' "$dir/diag/firstmate/events.jsonl" >/dev/null || fail 'reminder did not record its category'
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" || true
  sequence=$(fm_test_single_wake_sequence "$dir/drain.out")
  generation=$(fm_test_wake_generation "$dir/drain.err")
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" --ack "$sequence" --recovery-generation "$generation" > /dev/null 2>&1 || fail 'fixture: reminder acknowledgement failed'
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold demo --kind external --reason resolved >/dev/null || fail 'fixture: hold demo'
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_OBLIGATION_SECONDS=1 \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 bash "$WATCH" > "$out" 2>&1 &
  child=$!
  for ((i=0; i<600; i++)); do
    [ ! -e "$state/.obligation-ready-dispatch" ] && break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  [ ! -e "$state/.obligation-ready-dispatch" ] || { kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fail 'resolved work retained its deadline'; }
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  ! grep -F 'still unattended for' "$out" >/dev/null || fail 'resolved work woke the primary'
  pass "ready work bypasses the information batch, ignores unbriefed rows and respects holds, group pauses and dependencies"
}

test_upgraded_queue_batches_due_obligations() {
  local dir home state id digest child out drain
  dir=$(make_case upgraded-queue)
  home="$dir/home"; state="$home/state"
  mkdir -p "$home/data" "$home/config" "$state"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  digest=$(printf '%064d' 0)
  cat > "$home/data/backlog.md" <<EOF
# Tasks

## In flight

## Queued

- [ ] answered - Previously answered question (kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: $digest
  Resolution mode: answered

- [ ] deferred - Set aside until a later conversation
  Deferred until the captain asks to resume.

## Done
EOF
  # Legacy notices can have been queued by the old watcher just before upgrade.
  printf '1\n1\nbrief:answered\n' > "$state/.obligation-ready-brief-answered"
  printf 'brief:answered\n' > "$state/.ready-work-wake"
  append_wake "$state" check ready-work:primary:brief:answered 'check: legacy brief notice'
  append_wake "$state" check obligation:ready-brief-answered 'check: legacy brief reminder'

  for id in alpha beta; do
    FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$id dated work" --repo firstmate >/dev/null 2>&1 ||
      fail "fixture: add $id"
    FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold "$id" --kind future --reason date --until 2020-01-01 >/dev/null ||
      fail "fixture: hold $id"
    printf '2020-01-01\n' > "$state/.future-hold-$id"
    touch -t 202001010000 "$state/.future-hold-$id"
  done
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_BUDGETS=0 FM_POLL=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$WATCH" > "$out" 2>&1 &
  child=$!
  wait_for_exit "$child" 600 || fail "watcher failed: $(cat "$out")"
  assert_contains "$(cat "$out")" 'still unattended for' 'first delivered wake should be for a due obligation'
  [ "$(wc -l < "$out")" -eq 1 ] || fail "more than one wake: $(cat "$out")"
  for id in alpha beta; do
    grep -Fq "obligation:future-$id" "$state/.wake-queue" ||
      fail "the first wake left a due obligation behind: $id"
  done
  [ ! -e "$state/.obligation-ready-brief-answered" ] &&
    [ ! -e "$state/.obligation-ready-brief-deferred" ] ||
    fail 'an unbriefed queued record retained or created a reminder'
  drain=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" 2>"$dir/drain.err") ||
    fail "wake drain failed: $(cat "$dir/drain.err")"
  ! printf '%s\n' "$drain" | grep -Fq 'legacy brief' || fail 'drain showed retired notices'
  printf '%s\n' "$drain" | grep -Fq 'obligation:future-alpha' || fail 'drain lost a current notice'
  pass 'upgraded queue delivers both due obligations in one wake and skips legacy brief notices'
}

test_ready_result_reminded_until_integrated() {
  local dir home state repo out sequence generation
  dir=$(make_case ready-result); home="$dir/home"; state="$home/state"; repo="$dir/repo"
  mkdir -p "$home/data" "$home/config" "$state" "$repo"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  printf '# Tasks\n\n## In flight\n\n- [ ] result - Ready result (repo: firstmate)\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  mkdir -p "$home/data/result"
  printf '# Legacy brief\n' > "$home/data/result/brief.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name Fixture
  git -C "$repo" config user.email fixture@example.invalid
  git -C "$repo" commit -q --allow-empty -m initial
  git -C "$repo" checkout -qb fm/result
  git -C "$repo" commit -q --allow-empty -m result
  printf 'kind=ship\nmode=local-only\nproject=%s\nworktree=%s\nbranch=fm/result\nbase_branch=main\n' "$repo" "$repo" > "$state/result.meta"
  printf 'done: ready in branch fm/result\n' > "$state/result.status"
  printf '60\n' > "$home/config/obligation-seconds"
  result_tick() (
    unset FM_OBLIGATION_SECONDS
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DIAGNOSTICS=0 \
      bash -c '. "$1"; wake() { printf "%s\n" "$1"; }; ready_work_tick' _ "$WATCH"
  )
  acknowledge_result() {
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" || true
    sequence=$(fm_test_single_wake_sequence "$dir/drain.out")
    generation=$(fm_test_wake_generation "$dir/drain.err")
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-drain.sh" --ack "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || fail 'result acknowledgement failed'
  }
  out=$(result_tick) || fail "first result check failed: $out"
  assert_contains "$out" 'ready work for the primary: result' 'first result wake'
  # An interrupted watcher can leave a durable result without its marker.
  rm -f -- "$state/.ready-work-wake"
  out=$(result_tick) || fail "pending result check failed: $out"
  [ -z "$out" ] && [ "$(grep -Fc 'ready-work:primary:result:result:' "$state/.wake-queue")" -eq 1 ] ||
    fail "queued result was duplicated: $out"
  acknowledge_result
  # Simulate an installation upgrading after it already acknowledged this result.
  python3 - "$state/.obligation-ready-result-result" "$state/.ready-work-wake" <<'PY'
import os, pathlib, sys, time
pathlib.Path(sys.argv[1]).unlink(missing_ok=True)
os.utime(sys.argv[2], (time.time() - 61, time.time() - 61))
PY
  out=$(result_tick) || fail "result reminder failed: $out"
  assert_contains "$out" 'still unattended for' 'unintegrated result was not reminded'
  acknowledge_result
  git -C "$repo" branch -f main fm/result
  out=$(result_tick) || fail "integrated result check failed: $out"
  [ -z "$out" ] && [ ! -e "$state/.obligation-ready-result-result" ] || fail "integrated result remained actionable: $out"
  pass 'an acknowledged result resurfaces until its branch is integrated'
}

# T4: a check row already queued when a watcher arms is delivered before the
# poll's scanners run. Live 2026-11-23: a ready-work row queued during a long
# turn waited 233 s after the turn ended while the first poll scanned under
# load, and its acknowledged age reached 761 s. The scanner is made slow here.
test_queued_check_row_resurfaces_before_scanners() {
  local dir home state fakebin codebin child now out started
  dir=$(make_case queued-check-before-scan)
  home="$dir/home"; state="$dir/state"; fakebin="$dir/fakebin"; codebin="$dir/code/bin"
  mkdir -p "$home/data" "$dir/code"
  cp -R "$ROOT/bin" "$codebin"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$codebin/fm-inactive-reconcile.sh"
  chmod +x "$codebin/fm-inactive-reconcile.sh"
  printf '%s\t1\tcheck\tready-work\tcheck: ready work with 4 free lanes: review and dispatch eligible queued tasks (demo)\n' \
    "$(date +%s)" > "$state/.wake-queue"
  printf '1\n' > "$state/.wake-queue.seq"
  out="$dir/watch.out"
  started=$(date +%s)
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    "$codebin/fm-watch.sh" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 200 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.1
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    pkill -f "$codebin/fm-inactive-reconcile.sh" 2>/dev/null || true
    fail "queued check row waited for the poll scanners ($(( $(date +%s) - started ))s): $(cat "$out")"
  fi
  wait "$child" 2>/dev/null || true
  pkill -f "$codebin/fm-inactive-reconcile.sh" 2>/dev/null || true
  grep -Fx 'check: rearm-resurface' "$out" >/dev/null \
    || fail "queued check row was not resurfaced: $(cat "$out")"
  grep "$(printf '\tcheck\tready-work\t')" "$state/.wake-queue" >/dev/null \
    || fail "the resurfaced row must stay queued for main"
  pass "a check row queued before arming is delivered before the poll scanners"
}

# A completed worker turn must not wait behind an unrelated slow scan.
test_worker_turn_precedes_slow_scan() {
  local dir home state fakebin codebin child gen i out
  dir=$(make_case turn-before-scan); home="$dir/home"; state="$dir/state"
  fakebin="$dir/fakebin"; codebin="$dir/code/bin"; out="$dir/watch.out"
  mkdir -p "$home/data" "$dir/code"
  cp -R "$ROOT/bin" "$codebin"
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$codebin/fm-inactive-reconcile.sh"
  chmod +x "$codebin/fm-inactive-reconcile.sh"
  printf 'window=test:fm-task\nkind=ship\nharness=claude\nbackend=tmux\nsessions_file=%s\n' "$dir/sessions.jsonl" > "$state/task.meta"
  printf '{"status":"active","session":"%s"}\n' "$dir/session.jsonl" > "$dir/sessions.jsonl"
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"La investigación quedó incompleta."}]}}' > "$dir/session.jsonl"
  printf 'resolved: terminó el cálculo\n' > "$state/task.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" task)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" task idle --gen "$gen" --source claude-hook --event stop
  : > "$state/task.turn-ended"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: idle · source: pane' FM_FAKE_TMUX_WINDOW=test:fm-task FM_FAKE_TMUX_CURRENT_COMMAND=claude \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    "$codebin/fm-watch.sh" > "$out" 2>&1 &
  child=$!
  i=0
  while [ "$i" -lt 600 ] && kill -0 "$child" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    pkill -f "$codebin/fm-inactive-reconcile.sh" 2>/dev/null || true
    fail "worker turn waited behind an unrelated scan: $(cat "$out")"
  fi
  wait "$child" 2>/dev/null || true
  grep -F 'worker completed a message without declared status' "$out" >/dev/null \
    || fail "worker turn did not wake the primary: $(cat "$out")"
  pass 'a completed undeclared worker turn precedes slow scans'
}

test_upgraded_queue_batches_due_obligations
test_ready_work_wakes_once
test_ready_result_reminded_until_integrated
test_handling_successor_does_not_go_blind
test_handling_successor_resurfaces_a_row_appended_during_startup
test_queued_check_row_resurfaces_before_scanners
test_worker_turn_precedes_slow_scan
