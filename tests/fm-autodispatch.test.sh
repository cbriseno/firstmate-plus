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
      printf '# Task\n## Captain'"'"'s intent\nx\n'
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

test_watcher_launches_ready_work() {
  local dir=$TMP_ROOT/watch home state out child i
  mkdir -p "$dir"; make_home "$dir"; home="$dir/home"; state="$home/state"; out="$dir/watch.out"
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" update good --priority 0 >/dev/null || fail "fixture: prioritize good"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  printf '%s\n' 'error: another Treehouse slot allocation or return is in progress for fixture; refusing to race it' > "$state/.autodispatch-failed-good"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$dir/bin/fm-watch.sh" > "$out" 2>&1 &
  child=$!
  for ((i=0; i<300; i++)); do
    grep -qF 'review and dispatch' "$state/.wake-queue" 2>/dev/null && break
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
  pass "watcher launches ready work itself, reports a failed launch once, and still wakes the primary for the rest"
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

  run_continuation_watch "$dir" "$state" 'prepare (prepare its brief'
  [ "$(awk -F '\t' '$4 ~ /^ready-work:primary:/ {print $4}' "$state/.wake-queue")" = \
    "$(printf 'ready-work:primary:result:result:%s\nready-work:primary:brief:prepare' "$ready_head")" ] ||
    fail "result and brief did not reach the primary in priority order"
  mkdir "$dir/branch-state"
  awk -F '\t' '$4 ~ /^ready-work:primary:/ ' "$state/.wake-queue" > "$dir/branch-state/.wake-queue"
  FM_STATE_OVERRIDE="$dir/branch-state" node "$dir/bin/fm-branch-dispatch.mjs" scope --afk |
    grep -Fx 'rows=' >/dev/null || fail "optional supervision claimed a primary obligation"
  ! grep -F 'ready work for the primary:' "$state/.wake-queue" | grep -Eq ' (dependent|validating|held) \(' ||
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
  bash "$ROOT/bin/fm-tasks-axi.sh" add new-brief 'Added after recovery' --repo demo >/dev/null || fail "fixture: add after recovery"
  # Recover a pending wake even if the former watcher stopped before its marker was saved.
  rm -f -- "$state/.ready-work-wake"
  run_continuation_watch "$dir" "$state" 'new-brief (prepare its brief'
  [ "$(grep -Fc 'result (check acceptance' "$state/.wake-queue")" = 1 ] || fail "result was queued again"
  [ "$(grep -Fc $'\tready-work:primary:brief:prepare\t' "$state/.wake-queue")" = 1 ] || fail "old brief obligation was queued again"
  [ "$(cat "$state/validating.status")" = 'paused: existing validation is running' ] || fail "existing validation was changed"
  [ ! -e "$dir/spawn.log" ] || fail "a worker was launched during the zero-lane replay"
  pass "watcher routes ready results and old and new brief obligations without lanes, preserving holds and running validation"
)

run_continuation_watch() {
  local dir=$1 state=$2 expected=$3 child i
  PATH="$dir/fakebin:$PATH" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$dir/bin/fm-watch.sh" > "$dir/continuation.out" 2>&1 &
  child=$!
  for ((i=0; i<600; i++)); do
    grep -Fq -- "$expected" "$state/.wake-queue" 2>/dev/null && break
    kill -0 "$child" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$child" 2>/dev/null || true
  wait_for_exit "$child" 100 || true
  grep -Fq -- "$expected" "$state/.wake-queue" || fail "missing primary obligation: $expected; $(cat "$dir/continuation.out" "$state/.wake-queue" 2>/dev/null)"
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
  [ -z "$out" ] || fail "dirty work was mislabeled: $out"
  git -C "$slot" checkout -q -- landed
  git -C "$slot" commit -qm unlanded --allow-empty
  out=$(PATH="$dir/fakebin:$PATH" bash "$ROOT/bin/fm-treehouse-diagnose.sh" "$repo")
  assert_contains "$out" 'branch absent from both local main and origin/main' 'unlanded work was mislabeled'
  pass "Treehouse exhaustion diagnosis distinguishes locally landed branches from dirty and unlanded work"
}

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
  test_manual_profile_reaches_launch_and_record
  exit 0
fi
test_autodispatch_resolves_the_spawn
test_manual_profile_reaches_launch_and_record
test_treehouse_exhaustion_diagnosis
test_retry_job_is_not_duplicated
test_retry_reports_real_failure
test_watcher_retries_allocation_after_release || exit $?
FM_TEST_STOP_WATCHER=1 test_watcher_retries_allocation_after_release || exit $?
test_watcher_launches_ready_work
test_watcher_continues_without_lanes
