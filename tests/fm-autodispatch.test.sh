#!/usr/bin/env bash
# Ready, briefed ship work launches by itself when lanes are free: the watcher
# runs bin/fm-autodispatch.sh, which resolves the spawn from the brief, the
# registry and the dispatch rules, and leaves everything else to the primary.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-autodispatch)
export NODE_NO_WARNINGS=1
# The fixture's lane capacity is independent of test runs queued on this host.
export FM_TEST_LOCK_DIR="$TMP_ROOT/test-locks"
mkdir -p "$FM_TEST_LOCK_DIR"

# A home whose bin/ is a copy with fm-spawn.sh replaced by a recorder.
make_home() {
  local dir=$1 home="$1/home" id
  mkdir -p "$home/data" "$home/config" "$home/state" "$dir/proj/.git" "$dir/fakebin"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/spawn.log"
case "\$1" in fail-*) echo 'error: boom' >&2; exit 1 ;; esac
exit 0
SH
  chmod +x "$dir/bin/fm-spawn.sh"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  printf '# Tasks\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '2\nmax-load1 1000\n' > "$home/config/lane-capacity"
  printf '%s\n' "- demo [local-only +yolo] - Fixture project at $dir/proj (added 2026-01-01)" > "$home/data/projects.md"
  cat > "$home/config/crew-dispatch.json" <<'J'
{"rules":[{"when":"std","category":"standard","use":{"harness":"claude","model":"m1","effort":"medium"}},
          {"when":"pick","category":"either","use":[{"harness":"claude","model":"a"},{"harness":"codex","model":"b"}]}]}
J
  for id in good fail-one held plain either no-effort chosen-effort chosen-model; do
    [ "${2:-}" != only-good ] || [ "$id" = good ] || continue
    FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$id work" --repo demo >/dev/null 2>&1 || fail "fixture: add $id"
    mkdir -p "$home/data/$id"
    {
      printf '# Task\n## Captain'"'"'s intent\nx\n## Firstmate spec\ny\n'
      if [ "$id" = plain ]; then printf 'Dispatch category: standard\n'; continue; fi
      case "$id" in either) category=either ;; no-effort|chosen-effort) category=without-effort ;; chosen-model) category=without-model ;; *) category=standard ;; esac
      printf 'Dispatch category: %s\n' "$category"
      [ "$id" != chosen-effort ] || printf 'Dispatch effort: low\n'
      [ "$id" != chosen-model ] || printf 'Dispatch model: m3\n'
      printf 'Delivery contract: mode=local-only\nShip branch: fm/%s\n' "$id"
    } > "$home/data/$id/brief.md"
  done
  jq '.rules += [{"when":"simple","category":"without-effort","use":{"harness":"codex","model":"m2"}},{"when":"model","category":"without-model","use":{"harness":"codex","effort":"medium"}}]' "$home/config/crew-dispatch.json" > "$home/config/crew-dispatch.next"
  mv "$home/config/crew-dispatch.next" "$home/config/crew-dispatch.json"
  if [ "${2:-}" != only-good ]; then
    FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold held --kind external --reason waiting >/dev/null 2>&1 || fail "fixture: hold"
  fi
}

test_autodispatch_resolves_the_spawn() {
  local dir=$TMP_ROOT/unit home rc
  mkdir -p "$dir"; make_home "$dir"; home="$dir/home"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" good >/dev/null 2>&1 || fail "good ready task was not launched"
  grep -Fx "good $dir/proj --mode local-only --yolo on --harness claude --model m1 --effort medium" "$dir/spawn.log" >/dev/null \
    || fail "wrong spawn arguments: $(cat "$dir/spawn.log")"
  for id in plain either no-effort; do
    rc=0; FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" "$id" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || fail "$id must be left to the primary (exit $rc)"
  done
  [ "$(wc -l < "$dir/spawn.log")" -eq 1 ] || fail "a non-launchable task reached the spawn"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" chosen-effort >/dev/null 2>&1 || fail "recorded effort was not dispatched"
  grep -Fx "chosen-effort $dir/proj --mode local-only --yolo on --harness codex --model m2 --effort low" "$dir/spawn.log" >/dev/null || fail "recorded effort was not passed to spawn"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" chosen-model >/dev/null 2>&1 || fail 'recorded model was not dispatched'
  grep -Fx "chosen-model $dir/proj --mode local-only --yolo on --harness codex --model m3 --effort medium" "$dir/spawn.log" >/dev/null || fail 'recorded model was not passed to spawn'
  mv "$home/config/crew-dispatch.json" "$home/config/crew-dispatch.saved"
  rc=0; FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" good >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "a missing dispatch profile must be left to the primary (exit $rc)"
  printf 'Dispatch harness: codex\nDispatch model: m2\nDispatch effort: low\n' >> "$home/data/good/brief.md"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" good >/dev/null 2>&1 || fail 'brief-selected axes did not dispatch without a profile file'
  grep -Fx "good $dir/proj --mode local-only --yolo on --harness codex --model m2 --effort low" "$dir/spawn.log" >/dev/null || fail 'brief-selected axes did not reach automatic spawn'
  pass "autodispatch launches a briefed ship with its category profile and leaves the rest to the primary"
}

# The primary's own procedure: scaffold the brief, fill it, leave it queued.
# The scaffold must record what the category leaves open, and the watcher's
# dispatcher must wait until the task sections are written.
test_scaffolded_ship_launches_itself() {
  local dir=$TMP_ROOT/scaffold home id=scaffolded out rc
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"
  jq '.rules += [{"when":"hard","category":"open-effort","use":{"harness":"claude","model":"m4"}}]' \
    "$home/config/crew-dispatch.json" > "$home/config/crew-dispatch.next" && mv "$home/config/crew-dispatch.next" "$home/config/crew-dispatch.json"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$id work" --repo demo >/dev/null 2>&1 || fail "fixture: add $id"
  rc=0; out=$(FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" "$id" demo --mode local-only --category open-effort 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a ship brief left the category's open effort unrecorded"
  assert_contains "$out" '--dispatch-effort' "the scaffold refusal must name the missing option"
  [ ! -e "$home/data/$id/brief.md" ] || fail "a refused scaffold left a brief behind"
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" "$id" demo --mode local-only --category open-effort --dispatch-effort high >/dev/null 2>&1 ||
    fail "cannot scaffold the ship brief with its selected effort"
  rc=0; out=$(FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" "$id" 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "an unfilled scaffold must not launch (exit $rc)"
  assert_contains "$out" 'brief is not written yet' "an unfilled scaffold needs its own reason: $out"
  [ ! -s "$dir/spawn.log" ] || fail "an unfilled scaffold reached the spawn"
  python3 - "$home/data/$id/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Fix the queue.').replace('{FIRSTMATE_SPEC}', 'Find the cause.').replace('{CAPTAIN_REQUIREMENTS}', '1. Fix the queue.'))
PY
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" "$id" >/dev/null 2>&1 || fail "the written brief was not launched automatically"
  grep -Fx "$id $dir/proj --mode local-only --yolo on --harness claude --model m4 --effort high" "$dir/spawn.log" >/dev/null ||
    fail "wrong automatic spawn: $(cat "$dir/spawn.log")"
  : > "$home/data/good/brief.md"
  rc=0; out=$(FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" good 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "an empty brief must not launch (exit $rc)"
  assert_contains "$out" 'brief is not written yet' "an empty brief must not be reported as a delivery problem: $out"
  pass "a scaffolded ship records its open dispatch axes and launches itself once its brief is written"
}

test_watcher_launches_ready_work() {
  local dir=$TMP_ROOT/watch home state out child i
  mkdir -p "$dir"; make_home "$dir"; home="$dir/home"; state="$home/state"; out="$dir/watch.out"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" update good --priority 0 >/dev/null || fail "fixture: prioritize good"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add verify-work 'Verify phase completion' --repo demo --kind scout >/dev/null ||
    fail "fixture: the accepted verification must enter the canonical queue"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  printf '%s\n' 'error: another Treehouse slot allocation or return is in progress for fixture; refusing to race it' > "$state/.autodispatch-failed-good"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 FM_UNBRIEFED_GRACE_SECS=0 \
    bash "$dir/bin/fm-watch.sh" > "$out" 2>&1 &
  child=$!
  for ((i=0; i<900; i++)); do
    grep -qF 'review and dispatch' "$state/.wake-queue" 2>/dev/null && break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$child" 2>/dev/null; for ((i=0; i<50; i++)); do kill -0 "$child" 2>/dev/null || break; sleep 0.1; done; kill -KILL "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
  grep -q "^good " "$dir/spawn.log" || fail "watcher did not launch the ready task: $(cat "$out")"
  grep -q '^fail-one ' "$dir/spawn.log" || fail "watcher did not try the second ready task"
  [ "$(head -n 1 "$dir/spawn.log" | cut -d ' ' -f1)" = good ] || fail "a lower priority task launched first"
  grep -q '^held ' "$dir/spawn.log" && fail "held task was launched"
  [ "$(grep -c '^fail-one ' "$dir/spawn.log")" -eq 1 ] || fail "failed launch was retried"
  grep -F 'launched automatically' "$state/.wake-queue" | grep -F good >/dev/null || fail "no launch wake: $(cat "$state/.wake-queue" 2>&1; echo OUT; cat "$out"; ls -a "$state")"
  grep -F 'automatic launch of ready task fail-one failed: error: boom' "$state/.wake-queue" >/dev/null || fail "no failure wake: $(cat "$state/.wake-queue")"
  grep -F 'review and dispatch' "$state/.wake-queue" | grep -F plain >/dev/null || fail "unlaunchable task lost its primary wake"
  grep -F 'ready-work:primary:dispatch' "$state/.wake-queue" |
    grep -Fq 'plain: brief has no ship delivery contract' ||
    fail "a free lane wake must send the dispatch diagnosis to the primary"
  assert_grep 'verify-work: no brief yet, so autodispatch skips it' "$state/.wake-queue" "a queued row with no brief must reach the primary watcher"
  pass "watcher launches ready work itself, reports a failed launch once, and still wakes the primary for the rest"
}

# Run a real watcher until <pattern> shows in <file> or <seconds> pass; extra arguments are environment.
run_watch_until() {
  local dir=$1 state=$2 pattern=$3 file=$4 seconds=$5 child i; shift 5
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 "$@" \
    bash "$dir/bin/fm-watch.sh" > "$dir/watch-run.out" 2>&1 &
  child=$!
  for ((i=0; i<seconds*10; i++)); do
    grep -qF -- "$pattern" "$file" 2>/dev/null && break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$child" 2>/dev/null || true
  wait_for_exit "$child" 100 || true
  kill -KILL "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  grep -qF -- "$pattern" "$file" 2>/dev/null
}

# An unbriefed queued ship is never launched, so its absence must reach the
# primary once, after the add-then-brief grace, and the written brief launches.
test_unbriefed_queued_ship_reaches_the_primary() {
  local dir=$TMP_ROOT/unbriefed home state
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add nobrief 'queued with no brief' --repo demo >/dev/null 2>&1 || fail "fixture: add nobrief"
  : > "$dir/spawn.log"; mv "$home/data/good" "$dir/good-brief"
  run_watch_until "$dir" "$state" '' "$state/.unbriefed-seen-nobrief" 30 FM_UNBRIEFED_GRACE_SECS=3600 ||
    fail "the first sighting of the unbriefed row was not recorded: $(cat "$dir/watch-run.out")"
  ! grep -qF 'nobrief' "$state/.wake-queue" 2>/dev/null || fail "the notice arrived inside the grace period: $(cat "$state/.wake-queue")"
  run_watch_until "$dir" "$state" 'nobrief: no brief yet' "$state/.wake-queue" 20 FM_UNBRIEFED_GRACE_SECS=0 ||
    fail "an unbriefed queued ship never reached the primary: $(cat "$state/.wake-queue" "$dir/watch-run.out" 2>&1)"
  grep -F 'ready-work:primary:dispatch' "$state/.wake-queue" | grep -F 'bin/fm-brief.sh' >/dev/null || fail "the notice names no action"
  [ "$(grep -c 'ready-work:primary:dispatch' "$state/.wake-queue")" -eq 1 ] || fail "the notice was queued more than once"
  [ ! -s "$dir/spawn.log" ] || fail "a row with no brief reached the spawn"
  : > "$state/.wake-queue"  # the primary drained the notice
  mkdir -p "$home/data/nobrief"; cp "$dir/good-brief/brief.md" "$home/data/nobrief/brief.md"
  sed -i.bak 's/good/nobrief/' "$home/data/nobrief/brief.md"; rm -f "$home/data/nobrief/brief.md.bak"
  run_watch_until "$dir" "$state" 'launched automatically with its dispatch rules: nobrief' "$state/.wake-queue" 30 FM_UNBRIEFED_GRACE_SECS=0 ||
    fail "the watcher did not report the launch of the briefed row: $(cat "$dir/watch-run.out")"
  grep -q '^nobrief ' "$dir/spawn.log" || fail "the briefed row did not reach the spawn"
  [ ! -f "$state/.unbriefed-seen-nobrief" ] || fail "the grace marker outlived the missing brief"
  pass "a queued ship with no brief reaches the primary once with its action, and launches once briefed"
}

# The general pause: nothing launches, replays or is reported while it stands;
# a timed pause lifts itself; resuming lets the same queued work launch.
test_general_pause_stops_automatic_dispatch() {
  local dir=$TMP_ROOT/pause home state out rc
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add nobrief 'queued with no brief' --repo demo >/dev/null 2>&1 || fail "fixture: add nobrief"
  out=$(FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" --pause --reason 'captain pause') || fail "pause was refused"
  assert_contains "$out" 'PAUSED' "pause must say it is on: $out"
  assert_contains "$(FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" --status)" 'captain pause' "status must show the reason"
  rc=0; FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" good >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 77 ] || fail "a paused autodispatch must exit 77, got $rc"
  printf '%s\n' "$dir/proj" > "$state/good.spawn-deferred"
  run_watch_until "$dir" "$state" 'good' "$dir/spawn.log" 5 FM_UNBRIEFED_GRACE_SECS=0 &&
    fail "the watcher launched or replayed work while paused: $(cat "$dir/spawn.log")"
  [ ! -s "$state/.wake-queue" ] || ! grep -Eq 'review and dispatch|launched automatically|automatic launch' "$state/.wake-queue" ||
    fail "the watcher reported ready work while paused: $(cat "$state/.wake-queue")"
  rm -f -- "$state/good.spawn-deferred"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" --pause --for 90m >/dev/null || fail "timed pause was refused"
  grep -Eq '^until=[1-9][0-9]+$' "$state/.autodispatch-paused" || fail "a timed pause must record its end"
  rc=0; FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" --pause --for soon >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unreadable --for must be refused (exit $rc)"
  printf 'since=1\nuntil=2\nreason=expired\n' > "$state/.autodispatch-paused"
  assert_contains "$(FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" --status)" 'expired' "an expired pause must read as running"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" --pause >/dev/null || fail "pause again"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" --resume >/dev/null || fail "resume was refused"
  [ ! -e "$state/.autodispatch-paused" ] || fail "resume left the marker"
  run_watch_until "$dir" "$state" 'good' "$dir/spawn.log" 20 FM_UNBRIEFED_GRACE_SECS=0 ||
    fail "the queued work did not launch after resume: $(cat "$dir/watch-run.out")"
  pass "the general pause stops every automatic launch and report, expires on request, and resume restores dispatch"
}

test_watcher_continues_without_lanes() (
  local dir=$TMP_ROOT/continuation home state result ready_head before id
  mkdir -p "$dir"; make_home "$dir"; home="$dir/home"; state="$home/state"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  # This fixture intentionally confines its environment to the test subshell.
  # shellcheck disable=SC2030
  export FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data"
  export GIT_ALLOW_PROTOCOL=file
  for id in result validating prepare; do
    bash "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$id work" --repo demo >/dev/null || fail "fixture: add $id"
  done
  bash "$ROOT/bin/fm-tasks-axi.sh" add dependent 'Wait for validation' --repo demo --priority 0 --blocked-by validating >/dev/null || fail "fixture: add dependent"
  for id in result validating; do
    bash "$ROOT/bin/fm-tasks-axi.sh" start "$id" >/dev/null || fail "fixture: start $id"
    mkdir -p "$home/data/$id"
    printf '# Legacy brief\n' > "$home/data/$id/brief.md"
  done
  cat > "$home/data/result/brief.md" <<'BRIEF'
# Task
## Captain's intent
Deliver the approved file.

## Captain's requirements
1. Deliver the approved file.
BRIEF
  printf '%s\n' '{"requirements":[{"text":"Deliver the approved file.","status":"fulfilled","evidence":"Verified against the approved fixture."}]}' \
    > "$home/data/result/acceptance.json"
  fm_git_identity
  git -C "$dir/proj" init -q -b main
  git -C "$dir/proj" commit -qm base --allow-empty
  git -C "$dir/proj" switch -qc fm/result
  printf '%s\n' approved > "$dir/proj/result"
  git -C "$dir/proj" add result
  git -C "$dir/proj" commit -qm result
  ready_head=$(git -C "$dir/proj" rev-parse HEAD)
  git clone -q --local "$dir/proj" "$dir/copy"
  git -C "$dir/proj" switch -q main
  before=$(git -C "$dir/proj" rev-parse HEAD)
  for id in result validating; do
    printf 'kind=ship\nmode=local-only\nproject=%s\nworktree=%s\nbranch=fm/%s\nyolo=on\n' \
      "$dir/proj" "$dir/copy" "$id" > "$state/$id.meta"
  done
  printf 'done: ready in branch fm/result\n' > "$state/result.status"
  printf 'paused: existing validation is running\n' > "$state/validating.status"
  printf '%s\n' '{"request":{"id":"approved-work","label":"Approved work","project":"demo"}}' > "$dir/presentation.json"
  bash "$ROOT/bin/fm-tasks-axi.sh" presentation result --presentation-file "$dir/presentation.json" >/dev/null ||
    fail "fixture: link the result to its request"
  result=$(bash "$dir/bin/fm-capacity.sh" --json | jq -r '.verdict.free_lanes')
  [ "$result" = 0 ] || fail "fixture did not fill the lanes"

  run_continuation_watch "$dir" "$state" 'result (check acceptance'
  [ "$(awk -F '\t' '$4 ~ /^ready-work:primary:/ {print $4}' "$state/.wake-queue")" = \
    "ready-work:primary:result:result:$ready_head" ] ||
    fail "the ready local result did not reach the primary on its own"
  mkdir "$dir/branch-state"
  awk -F '\t' '$4 ~ /^ready-work:primary:/ ' "$state/.wake-queue" > "$dir/branch-state/.wake-queue"
  FM_STATE_OVERRIDE="$dir/branch-state" node "$dir/bin/fm-branch-dispatch.mjs" scope --afk |
    grep -Fx 'rows=' >/dev/null || fail "optional supervision claimed a primary obligation"
  ! grep -F 'ready work for the primary:' "$state/.wake-queue" | grep -Eq ' (dependent|validating|held|prepare) \(' ||
    fail "a blocked task or live validation was marked ready"
  [ ! -e "$dir/spawn.log" ] || fail "watcher launched a worker without lanes"
  [ "$(git -C "$dir/proj" rev-parse HEAD)" = "$before" ] || fail "watcher bypassed the primary merge gate"
  # Act as the fixture's primary, with the approved, validated branch, through
  # the same local merge owner the wake identifies.
  FM_ROOT_OVERRIDE="$dir" bash "$dir/bin/fm-merge-local.sh" result >/dev/null 2>&1 || fail "primary could not land the approved branch"
  [ "$(git -C "$dir/proj" rev-parse HEAD)" = "$ready_head" ] || fail "the authorized result did not land"
  bash "$ROOT/bin/fm-tasks-axi.sh" presentation result --json |
    jq -e --arg head "$ready_head" '.presentation.request.id == "approved-work" and .lifecycle.gates.integrated.head == $head' >/dev/null ||
    fail "landed head and approved request were not reconciled together"
  [ "$(cat "$state/validating.status")" = 'paused: existing validation is running' ] || fail "existing validation was changed"
  [ ! -e "$dir/spawn.log" ] || fail "a worker was launched during the zero-lane replay"
  pass "watcher routes and integrates ready results without lanes, preserving holds and running validation"
)

run_continuation_watch() {
  local dir=$1 state=$2 expected=$3 observation=${4:-$2/.wake-queue} child i
  PATH="$dir/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$dir/bin/fm-watch.sh" > "$dir/continuation.out" 2>&1 &
  child=$!
  for ((i=0; i<600; i++)); do
    grep -Fq -- "$expected" "$observation" 2>/dev/null && break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$child" 2>/dev/null || true
  wait_for_exit "$child" 100 || true
  grep -Fq -- "$expected" "$observation" || fail "missing watcher observation: $expected; $(cat "$dir/continuation.out" "$observation" 2>/dev/null)"
}

test_watcher_classifies_cpu_deferral() (
  local dir=$TMP_ROOT/cpu home="$TMP_ROOT/cpu/home" state="$TMP_ROOT/cpu/home/state"
  mkdir -p "$dir"
  make_home "$dir" only-good
  fm_test_track_watcher_state "$state"
  printf '2\nmax-load5-per-core 4\n' > "$home/config/lane-capacity"
  printf 'Dispatch CPU: heavy\n' >> "$home/data/good/brief.md"
  printf '%s\n' "$dir/proj" > "$state/good.spawn-deferred"
  printf '#!/bin/sh\necho Darwin\n' > "$dir/fakebin/uname"
  printf '#!/bin/sh\necho 4\n' > "$dir/fakebin/getconf"
  cat > "$dir/fakebin/sysctl" <<'SH'
#!/bin/sh
[ "$2" = vm.loadavg ] && echo '{ 32.00 30.00 18.00 }'
SH
  chmod +x "$dir/fakebin/"{uname,getconf,sysctl}
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    run_continuation_watch "$dir" "$state" 'cpu: sustained load 30.00 on 4 cores' "$state/good.spawn-deferred.reason"
  assert_grep '[cpu-admission] cpu: sustained load' "$state/good.spawn-deferred.reason" 'the CPU deferral lacks its detector class'
  [ ! -e "$dir/spawn.log" ] || fail 'CPU classification unexpectedly bypassed admission'
  pass 'watcher records the CPU class from the admission owner'
)

# A deferred launch that takes minutes under load must not stop the watcher's
# liveness beacon, which the Stop hook reads as "the watcher is dead".
test_deferred_spawn_keeps_the_beacon_alive() (
  local dir=$TMP_ROOT/slow-spawn home="$TMP_ROOT/slow-spawn/home" state="$TMP_ROOT/slow-spawn/home/state" child i
  mkdir -p "$dir"
  make_home "$dir" only-good
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  cat > "$dir/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/spawn.log"
for ((i=0; i<1800; i++)); do
  [ -e "$dir/release" ] && break
  sleep 0.1
done
touch "$dir/spawn.done"
exit 0
SH
  printf '%s\n' "$dir/proj" > "$state/good.spawn-deferred"
  printf '%s\0' good "$dir/proj" --mode local-only >> "$state/good.spawn-deferred"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$dir/bin/fm-watch.sh" > "$dir/watch.out" 2>&1 &
  child=$!
  for ((i=0; i<600; i++)); do
    [ -s "$dir/spawn.log" ] && break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  [ -s "$dir/spawn.log" ] || fail "the watcher never replayed the deferred launch: $(cat "$dir/watch.out")"
  touch "$dir/beacon-check"
  for ((i=0; i<600; i++)); do
    [ "$state/.last-watcher-beat" -nt "$dir/beacon-check" ] && break
    [ ! -e "$dir/spawn.done" ] || break
    sleep 0.1
  done
  [ ! -e "$dir/spawn.done" ] || fail "fixture: the slow launch ended before the beacon advanced"
  [ "$state/.last-watcher-beat" -nt "$dir/beacon-check" ] || fail "the beacon did not advance while the deferred launch ran"
  touch "$dir/release"
  for ((i=0; i<600; i++)); do
    grep -Fq 'launched deferred task good' "$state/.wake-queue" 2>/dev/null && break
    sleep 0.1
  done
  kill -TERM "$child" 2>/dev/null || true
  wait_for_exit "$child" 100 || true
  grep -Fq 'launched deferred task good' "$state/.wake-queue" || fail "the launch result never reached the wake queue: $(cat "$state/.wake-queue" "$dir/watch.out" 2>&1)"
  [ "$(wc -l < "$dir/spawn.log")" -eq 1 ] || fail "the deferred launch ran more than once"
  pass "a slow deferred launch runs beside the watcher without stopping its beacon"
)

test_diagnostic_scope_mapping() {
  local dir="$TMP_ROOT/scope" home="$TMP_ROOT/scope/home" fakebin out rc
  mkdir -p "$dir/target"
  fm_test_spawn_home "$home" codex
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  cat > "$home/config/crew-dispatch.json" <<'JSON'
{"diagnosis_scope":{"bounded":"routine","long":"complex","ambiguous":"complex"},"rules":[{"category":"routine","use":{"harness":"codex","model":"balanced"}},{"category":"complex","use":{"harness":"codex","model":"strong"}}]}
JSON
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" wrong --host --path "$dir/target" --category routine --dispatch-effort high >/dev/null || fail 'cannot scaffold unassessed task'
  python3 - "$home/data/wrong/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Investigate ambiguous queue behavior.').replace('{FIRSTMATE_SPEC}', 'Find the cause.').replace('{CAPTAIN_REQUIREMENTS}', '1. Find the cause.'))
PY
  rc=0
  out=$(FM_DIAGNOSTICS=0 FM_FAKE_LAUNCH_LOG="$dir/wrong.launch" fm_test_run_spawn "$home" "$home/data/wrong/work" "$fakebin" wrong --host --harness codex --model balanced --effort high 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'task without an assessment launched'
  printf '\nDispatch diagnosis scope: ambiguous\n' >> "$home/data/wrong/brief.md"
  rc=0
  out=$(FM_DIAGNOSTICS=0 FM_FAKE_LAUNCH_LOG="$dir/wrong.launch" fm_test_run_spawn "$home" "$home/data/wrong/work" "$fakebin" wrong --host --harness codex --model balanced --effort high 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'ambiguous work launched with the routine category'
  assert_contains "$out" 'scope/category mismatch' 'refusal omitted the mismatch'
  [ ! -s "$dir/wrong.launch" ] || fail 'rejected worker reached the launcher'
  python3 - "$home/data/wrong/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); p.write_text(p.read_text().replace('Dispatch category: routine', 'Dispatch category: complex'))
PY
  rc=0
  out=$(FM_DIAGNOSTICS=0 FM_FAKE_LAUNCH_LOG="$dir/right.launch" fm_test_run_spawn "$home" "$home/data/wrong/work" "$fakebin" wrong --host --harness codex --model strong --effort high 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "mapped complex dispatch failed: $out"
  grep -Fxq 'model=strong' "$home/state/wrong.meta" || fail 'mapped profile was not launched'
  pass 'configured diagnostic scopes reject a mismatched category before launch'
}

test_manual_profile_reaches_launch_and_record() {
  local dir="$TMP_ROOT/manual" home="$TMP_ROOT/manual/home" fakebin id category model effort reason out rc
  mkdir -p "$dir/target"
  fm_test_spawn_home "$home" codex
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  cat > "$home/config/crew-dispatch.json" <<'J'
{"rules":[{"when":"simple","category":"simple","use":{"harness":"codex"}},
{"when":"complex","category":"complex","reason_required":true,"use":{"harness":"codex","model":"strong","effort":"high"}}]}
J
  for id in simple complex; do
    category=$id
    if [ "$id" = simple ]; then model=small; effort=low; reason='A bounded lookup'; else model=strong; effort=high; reason='Cross-cutting diagnosis'; fi
    FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" "$id" --host --path "$dir/target" --category "$category" --rationale "$reason" --dispatch-model "$model" --dispatch-effort "$effort" >/dev/null || fail "cannot prepare $id brief"
    python3 - "$home/data/$id/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Check the task.').replace('{FIRSTMATE_SPEC}', 'Check the result.').replace('{CAPTAIN_REQUIREMENTS}', '1. Check the task.'))
PY
    rc=0
    out=$(FM_DIAGNOSTICS=0 FM_FAKE_LAUNCH_LOG="$dir/$id.launch" fm_test_run_spawn "$home" "$home/data/$id/work" "$fakebin" "$id" --host --harness codex) || rc=$?
    [ "$rc" -eq 0 ] || fail "$id dispatch failed: $out"
    assert_contains "$out" 'no diagnosis_scope mapping' 'legacy matrix did not warn'
    grep -Fxq "model=$model" "$home/state/$id.meta" || fail "$id model not recorded"
    grep -Fxq "effort=$effort" "$home/state/$id.meta" || fail "$id effort not recorded"
    grep -Fq "model_reasoning_effort=\"$effort\"" "$dir/$id.launch" || fail "$id effort missing from launch"
  done
  mv "$home/config/crew-dispatch.json" "$home/config/crew-dispatch.saved"
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" unprofiled --host --path "$dir/target" >/dev/null || fail 'cannot prepare unprofiled brief'
  python3 - "$home/data/unprofiled/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Check the task.').replace('{FIRSTMATE_SPEC}', 'Check the result.').replace('{CAPTAIN_REQUIREMENTS}', '1. Check the task.'))
PY
  rc=0
  out=$(FM_DIAGNOSTICS=0 fm_test_run_spawn "$home" "$home/data/unprofiled/work" "$fakebin" unprofiled --host --harness codex) || rc=$?
  [ "$rc" -ne 0 ] || fail 'unprofiled launch used ambient defaults'
  assert_contains "$out" 'FM_MODEL_CATEGORY_OVERRIDE=1' 'refusal omitted the explicit skip'
  rc=0
  out=$(FM_MODEL_CATEGORY_OVERRIDE=1 FM_DIAGNOSTICS=0 fm_test_run_spawn "$home" "$home/data/unprofiled/work" "$fakebin" unprofiled --host --harness codex) || rc=$?
  [ "$rc" -eq 0 ] || fail "explicit legacy bypass failed: $out"
  grep -Fxq 'model=default' "$home/state/unprofiled.meta" || fail 'legacy model default was lost'
  grep -Fxq 'effort=default' "$home/state/unprofiled.meta" || fail 'legacy effort default was lost'
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" recorded --host --path "$dir/target" --dispatch-harness codex --dispatch-model small --dispatch-effort low --rationale 'Bounded lookup' >/dev/null || fail 'cannot prepare selected profile'
  python3 - "$home/data/recorded/brief.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Check the task.').replace('{FIRSTMATE_SPEC}', 'Check the result.').replace('{CAPTAIN_REQUIREMENTS}', '1. Check the task.'))
PY
  rc=0
  out=$(FM_DIAGNOSTICS=0 FM_FAKE_LAUNCH_LOG="$dir/recorded.launch" fm_test_run_spawn "$home" "$home/data/recorded/work" "$fakebin" recorded --host --harness codex) || rc=$?
  [ "$rc" -eq 0 ] || fail "brief-selected manual profile failed: $out"
  grep -Fxq 'model=small' "$home/state/recorded.meta" || fail 'brief-selected model not recorded'
  grep -Fxq 'effort=low' "$home/state/recorded.meta" || fail 'brief-selected effort not recorded'
  pass "manual simple and complex profiles reach launch and records"
}

# A transient allocation lock is watched without blocking the watcher or
# waiting for the next 30-second ready-work review.
test_watcher_retries_allocation_after_release() (
  local dir=$TMP_ROOT/retry${FM_TEST_STOP_WATCHER:-0} home state lock child i released_at elapsed launched_at job_state
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  lock="$dir/allocation.lock"
  fm_lock_try_acquire "$lock" || fail 'fixture: acquire allocation lock'
  child=
  # The EXIT trap invokes this cleanup indirectly.
  # shellcheck disable=SC2329
  retry_fixture_cleanup() {
    local i job
    [ -z "$child" ] || { kill -TERM "$child" 2>/dev/null || true; wait_for_exit "$child" 100 || true; }
    fm_lock_release "$lock" || true
    for job in "$state"/good.jobs/autodispatch-*.json; do
      [ -f "$job" ] || continue
      for ((i=0; i<300; i++)); do
        case "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state", ""))' "$job" 2>/dev/null)" in
          done|failed) break ;;
        esac
        sleep 0.1
      done
    done
  }
  trap retry_fixture_cleanup EXIT
  cat > "$dir/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$dir/attempts"
if [ -d "$lock" ]; then
  printf '%s\n' "$lock" > "$state/.autodispatch-lock-\$1"
  exit 76
fi
printf 'kind=ship\nlaunched_at=%s\n' "\$(date +%s)" > "$state/\$1.meta.tmp"
mv "$state/\$1.meta.tmp" "$state/\$1.meta"
SH
  chmod +x "$dir/bin/fm-spawn.sh"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  env -u FM_WORKER_PROCESS_SCOPE PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" \
    FM_POLL=15 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$dir/bin/fm-watch.sh" > "$dir/watch.out" 2>&1 &
  child=$!
  for ((i=0; i<600; i++)); do
    [ ! -f "$state/.autodispatch-lock-good" ] || break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  [ -f "$state/.autodispatch-lock-good" ] || fail "watcher did not record contention: $(cat "$dir/watch.out")"
  kill -0 "$child" 2>/dev/null || fail 'watcher stopped while allocation was held'
  [ ! -f "$state/.autodispatch-failed-good" ] || fail 'contention was recorded as a failure'
  if [ "${FM_TEST_STOP_WATCHER:-0}" = 1 ]; then
    for ((i=0; i<600; i++)); do
      job_state=$(python3 - "$state/good.jobs" <<'PYJOB'
import json, sys
from pathlib import Path
for path in Path(sys.argv[1]).glob('autodispatch-*.json'):
    print(json.loads(path.read_text()).get('state', ''))
PYJOB
)
      [ "$job_state" != running ] || break
      kill -0 "$child" 2>/dev/null || break
      sleep 0.1
    done
    [ "$job_state" = running ] || fail 'managed retry never started'
    kill -TERM "$child" 2>/dev/null || true
    wait_for_exit "$child" 100 || true
    child=
  fi
  released_at=$(date +%s)
  fm_lock_release "$lock" || fail 'fixture: release allocation lock'
  for ((i=0; i<1000; i++)); do
    [ ! -f "$state/good.meta" ] || break
    [ -z "$child" ] || kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  launched_at=$(sed -n 's/^launched_at=//p' "$state/good.meta" 2>/dev/null || true)
  elapsed=$(( ${launched_at:-released_at} - released_at ))
  if [ -n "$child" ]; then
    kill -TERM "$child" 2>/dev/null || true
    wait_for_exit "$child" 100 || true
    child=
  fi
  [ -n "$launched_at" ] || fail "watcher did not record a retry: $(cat "$dir/watch.out")"
  [ "$elapsed" -lt 30 ] || fail "retry took ${elapsed}s, at least the 30-second review interval"
  [ "$(grep -c '^good$' "$dir/attempts")" = 2 ] || fail 'watcher did not attempt exactly once after release'
  pass "managed retry launches on release (watcher stopped: ${FM_TEST_STOP_WATCHER:-0})"
)

# Repeated watcher scans share one live job; a later wait may use a new job
# after the previous one has finished.
test_retry_job_is_not_duplicated() {
  local dir=$TMP_ROOT/job home state count job
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"
  python3 "$dir/bin/fm-task-job.py" --autodispatch "$state" good "$home" "$home/config" || fail 'cannot submit retry job'
  python3 "$dir/bin/fm-task-job.py" --autodispatch "$state" good "$home" "$home/config" || fail 'cannot revisit retry job'
  count=$(find "$state/good.jobs" -name 'autodispatch-*.json' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "live retry was duplicated ($count jobs)"
  for job in "$state"/good.jobs/autodispatch-*.json; do
    python3 - "$job" <<'PYJOB'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); record=json.loads(p.read_text()); record['state']='done'; p.write_text(json.dumps(record))
PYJOB
  done
  python3 "$dir/bin/fm-task-job.py" --autodispatch "$state" good "$home" "$home/config" || fail 'cannot submit a later retry'
  count=$(find "$state/good.jobs" -name 'autodispatch-*.json' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "later retry did not get a new job ($count jobs)"
  pass 'repeated scans share a live retry and later retries can start'
}

# A real refusal after the allocation wait is reported once, never retried.
test_retry_reports_real_failure() {
  local dir=$TMP_ROOT/retry-failure home state rc=0
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"
  cat > "$dir/bin/fm-autodispatch.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'error: treehouse exhausted with protected work' >&2
exit 1
SH
  chmod +x "$dir/bin/fm-autodispatch.sh"
  printf '%s\n' "$dir/allocation.lock" > "$state/.autodispatch-lock-good"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$dir/bin/fm-autodispatch-retry.sh" good "$home" "$state" "$home/config" >/dev/null || rc=$?
  [ "$rc" = 1 ] || fail "real failure returned $rc"
  [ ! -e "$state/.autodispatch-lock-good" ] || fail 'failed launch left a retry waiting'
  assert_contains "$(cat "$state/.autodispatch-failed-good")" 'treehouse exhausted with protected work' 'failure cause was lost'
  assert_contains "$(cat "$state/.wake-queue")" 'treehouse exhausted with protected work' 'failure did not reach the supervisor'
  pass 'a real launch failure is reported and not retried blindly'
}

# A clean, available parked branch already landed locally but absent upstream
# explains why Treehouse refuses to recycle it. Dirty or unlanded work must not
# be mislabeled as that case.
test_treehouse_exhaustion_diagnosis() {
  local dir=$TMP_ROOT/treehouse-diagnosis repo slot out
  repo="$dir/project"; slot="$dir/slot"
  mkdir -p "$dir/fakebin" "$repo"
  fm_git_identity
  git -C "$repo" init -q -b main
  git -C "$repo" commit -qm base --allow-empty
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf 'landed\n' > "$repo/landed"
  git -C "$repo" add landed
  git -C "$repo" commit -qm landed
  git -C "$repo" worktree add -qb fm/parked "$slot" main
  cat > "$dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' '[{"path":"$slot","status":"available","branch":"fm/parked"}]'
SH
  chmod +x "$dir/fakebin/treehouse"
  out=$(PATH="$dir/fakebin:$PATH" bash "$ROOT/bin/fm-treehouse-diagnose.sh" "$repo")
  assert_contains "$out" 'branch integrated into local main but absent from origin/main' 'missing local-only divergence diagnosis'
  printf 'uncommitted\n' >> "$slot/landed"
  out=$(PATH="$dir/fakebin:$PATH" bash "$ROOT/bin/fm-treehouse-diagnose.sh" "$repo")
  assert_contains "$out" 'uncommitted changes' 'dirty work was not reported'
  [[ "$out" != *'branch integrated into local main but absent from origin/main'* ]] || fail "dirty work was mislabeled: $out"
  git -C "$slot" checkout -q -- landed
  git -C "$slot" commit -qm unlanded --allow-empty
  out=$(PATH="$dir/fakebin:$PATH" bash "$ROOT/bin/fm-treehouse-diagnose.sh" "$repo")
  assert_contains "$out" 'branch absent from both local main and origin/main' 'unlanded work was mislabeled'
  pass "Treehouse exhaustion diagnosis distinguishes locally landed branches from dirty and unlanded work"
}

# After the allocation wait, a task the dispatcher leaves to the primary says why.
test_retry_names_why_it_is_not_launchable() {
  local dir=$TMP_ROOT/retry-skip home state rc=0
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"
  cat > "$dir/bin/fm-autodispatch.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "not auto-launchable: dispatch category 'x' needs a recorded effort" >&2
exit 3
SH
  chmod +x "$dir/bin/fm-autodispatch.sh"
  printf '%s\n' "$dir/allocation.lock" > "$state/.autodispatch-lock-good"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$dir/bin/fm-autodispatch-retry.sh" good "$home" "$state" "$home/config" >/dev/null || rc=$?
  [ "$rc" = 1 ] || fail "skip after the wait returned $rc"
  assert_contains "$(cat "$state/.wake-queue")" "needs a recorded effort" 'the skip reason did not reach the primary'
  pass 'a task left to the primary after the allocation wait names its reason'
}

# With free lanes, a failed automatic launch is not left to its single wake: it
# keeps reminding until the task is dispatched or held.
test_failed_launch_keeps_reminding_while_lanes_are_free() {
  local dir=$TMP_ROOT/failed-reminder home state queue
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"; queue="$state/.wake-queue"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold good --kind external --reason fixture >/dev/null || fail "fixture: hold good"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add fail-one 'Launch that fails' --repo demo --kind ship >/dev/null || fail "fixture: add fail-one"
  mkdir -p "$home/data/fail-one"
  printf '# Task\n## Captain'"'"'s intent\nx\n## Firstmate spec\ny\nDispatch category: standard\nDelivery contract: mode=local-only\nShip branch: fm/fail-one\n' > "$home/data/fail-one/brief.md"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  run_watch_until "$dir" "$state" 'automatic launch of ready task fail-one failed: error: boom' "$queue" 300 FM_OBLIGATION_SECONDS=1 ||
    fail "no failure wake: $(cat "$dir/watch-run.out")"
  # The primary has read that wake, so each later watcher starts from an empty queue.
  : > "$queue"
  run_watch_until "$dir" "$state" '' "$state/.obligation-ready-failed-fail-one" 300 FM_OBLIGATION_SECONDS=1 ||
    fail "a failed launch left no obligation"
  sleep 2
  : > "$queue"
  run_watch_until "$dir" "$state" 'fail-one (automatic launch failed: error: boom' "$queue" 300 FM_OBLIGATION_SECONDS=1 ||
    fail "a failed launch was not reminded while lanes stayed free: $(cat "$queue" "$dir/watch-run.out" 2>&1)"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold fail-one --kind external --reason fixture >/dev/null || fail "fixture: hold fail-one"
  # A watcher that starts with another wake pending ends on it before its pass, so give it a few turns.
  for _ in 1 2 3; do
    : > "$queue"
    run_watch_until "$dir" "$state" 'never-appears' "$queue" 60 FM_OBLIGATION_SECONDS=1 || true
    [ -e "$state/.obligation-ready-failed-fail-one" ] || break
  done
  [ ! -e "$state/.obligation-ready-failed-fail-one" ] || fail "a held task kept its failure reminder: $(cat "$dir/watch-run.out")"
  pass "a failed automatic launch keeps reminding while lanes are free and stops once the task is held"
}

# A higher-priority task waiting for home capacity keeps its place: a task behind
# it must not launch into the lane it waits for, even when that task would fit.
test_deferred_task_keeps_its_place() {
  local dir=$TMP_ROOT/priority home state holder
  mkdir -p "$dir"; make_home "$dir" only-good; home="$dir/home"; state="$home/state"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add urgent 'Urgent work' --repo demo --kind ship --priority 0 >/dev/null || fail "fixture: add urgent"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add nobrief 'Ship nobody briefed' --repo demo --kind ship --priority 3 >/dev/null || fail "fixture: add nobrief"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" update good --priority 2 >/dev/null || fail "fixture: prioritize good"
  mkdir -p "$home/data/urgent"
  sed 's#fm/good#fm/urgent#' "$home/data/good/brief.md" > "$home/data/urgent/brief.md"
  printf '%s\n' "$dir/proj" > "$state/urgent.spawn-deferred"
  printf '%s\n' 'memory: no room for a 0.46 GB lane' > "$state/urgent.spawn-deferred.reason"
  # Another replay is still running, so the waiting task cannot start this cycle.
  sleep 600 &
  # shellcheck disable=SC2031
  holder=$!
  printf '%s\n' "$holder" > "$state/.spawn-retry.pid"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  # The unbriefed row sits behind both tasks, so its notice proves the pass reached the end of the queue.
  if ! run_watch_until "$dir" "$state" 'nobrief: no brief yet' "$state/.wake-queue" 300 FM_UNBRIEFED_GRACE_SECS=0; then
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    fail "the watcher never finished its dispatch pass: $(cat "$dir/watch-run.out")"
  fi
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  ! grep -q '^good ' "$dir/spawn.log" 2>/dev/null || fail "a lower-priority task launched ahead of the one waiting for capacity"
  [ -f "$state/urgent.spawn-deferred" ] || fail "the waiting task lost its place"
  pass "a task waiting for capacity keeps its place against lower-priority launches"
}

if [ "${FM_TEST_CAPACITY_GAPS_ONLY:-0}" = 1 ]; then
  test_retry_names_why_it_is_not_launchable
  test_failed_launch_keeps_reminding_while_lanes_are_free
  test_deferred_task_keeps_its_place
  exit 0
fi

if [ "${FM_TEST_AUTODISPATCH_RETRY_ONLY:-0}" = 1 ]; then
  test_watcher_retries_allocation_after_release || exit $?
  exit 0
fi

if [ "${FM_TEST_TREEHOUSE_DIAGNOSIS_ONLY:-0}" = 1 ]; then
  test_treehouse_exhaustion_diagnosis
  exit 0
fi

if [ "${FM_TEST_MATRIX_ONLY:-0}" = 1 ]; then
  test_autodispatch_resolves_the_spawn
  test_scaffolded_ship_launches_itself
  test_diagnostic_scope_mapping
  test_manual_profile_reaches_launch_and_record
  exit 0
fi
test_autodispatch_resolves_the_spawn
test_scaffolded_ship_launches_itself
test_diagnostic_scope_mapping
test_manual_profile_reaches_launch_and_record
test_treehouse_exhaustion_diagnosis
test_retry_job_is_not_duplicated
test_retry_reports_real_failure
test_retry_names_why_it_is_not_launchable
test_watcher_retries_allocation_after_release || exit $?
FM_TEST_STOP_WATCHER=1 test_watcher_retries_allocation_after_release || exit $?
test_watcher_launches_ready_work
test_unbriefed_queued_ship_reaches_the_primary
test_general_pause_stops_automatic_dispatch
test_failed_launch_keeps_reminding_while_lanes_are_free
test_deferred_task_keeps_its_place
test_watcher_classifies_cpu_deferral
test_deferred_spawn_keeps_the_beacon_alive
test_watcher_continues_without_lanes
