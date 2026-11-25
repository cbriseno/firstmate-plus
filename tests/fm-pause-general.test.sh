#!/usr/bin/env bash
# The captain's general pause (bin/fm-pause-general.sh): launches are held by
# admission without touching the lane cap, the watcher parks idle workers with
# no date or threshold and resumes exactly those when the pause lifts, and
# declared-wait expiry stays quiet while it stands.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pause-general)
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT
PAUSE="$ROOT/bin/fm-pause-general.sh"
CAPACITY="$ROOT/bin/fm-capacity.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

test_record_lifecycle() {
  local home out
  home=$(make_home record)
  out=$(FM_HOME="$home" bash "$PAUSE" status) || fail "$out"
  [ "$out" = running ] || fail "fresh home is not running: $out"
  out=$(FM_HOME="$home" bash "$PAUSE" on 'hasta orden del capitán') || fail "$out"
  [ "$(sed -n 2p "$home/state/.pause-general")" = 'hasta orden del capitán' ] || fail 'reason not recorded'
  out=$(FM_HOME="$home" bash "$PAUSE" status); assert_contains "$out" 'paused:' 'status reports the pause'
  FM_HOME="$home" bash "$PAUSE" off >/dev/null || fail 'off failed'
  [ ! -e "$home/state/.pause-general" ] || fail 'off left the record'
  pass 'pause record: on, status and off'
}

test_admission_holds_without_touching_the_cap() {
  local home rc out
  home=$(make_home admit)
  rc=0; FM_HOME="$home" "$CAPACITY" --admit >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" 'no config and no pause admits'
  FM_HOME="$home" bash "$PAUSE" on 'pausa de prueba' >/dev/null
  rc=0; out=$(FM_HOME="$home" "$CAPACITY" --admit 2>&1) || rc=$?
  expect_code 75 "$rc" 'a general pause defers even without config/lane-capacity'
  assert_contains "$out" 'general pause: pausa de prueba' 'deferral names the pause'
  printf '12\nmax-load1 100000\n' > "$home/config/lane-capacity"
  rc=0; out=$(FM_HOME="$home" "$CAPACITY" --admit 2>&1) || rc=$?
  expect_code 75 "$rc" 'a general pause defers with a cap that has free lanes'
  out=$(FM_HOME="$home" "$CAPACITY" --json 2>/dev/null) || fail 'json failed'
  [ "$(jq -r '.cap.target' <<< "$out")" = 12 ] || fail 'the pause changed the published cap'
  [ "$(jq -r '.verdict.admit' <<< "$out")" = false ] || fail 'verdict admits during a pause'
  jq -r '.verdict.reasons[]' <<< "$out" | grep -q 'general pause' || fail 'verdict lacks the pause reason'
  [ "$(sed -n 1p "$home/config/lane-capacity")" = 12 ] || fail 'the pause edited config/lane-capacity'
  FM_HOME="$home" bash "$PAUSE" off >/dev/null
  rc=0; FM_HOME="$home" "$CAPACITY" --admit >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" 'lifting the pause restores admission with the same cap'
  pass 'admission: a general pause holds launches and leaves the cap alone'
}

# watch_fn <home> <function-and-args...>: run one watcher function against a
# scratch scripts dir whose fm-control.sh records its arguments.
watch_fn() {
  local home=$1; shift
  mkdir -p "$home/scripts"
  cat > "$home/scripts/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CONTROL_LOG"
exit "${FM_TEST_CONTROL_RC:-0}"
SH
  printf 'import sys\nsys.exit(0)\n' > "$home/scripts/fm-worker-processes.py"
  cat > "$home/scripts/fm-capacity.sh" <<'SH'
#!/usr/bin/env bash
exit "${FM_TEST_ADMIT_RC:-0}"
SH
  chmod +x "$home/scripts/"*.sh
  FM_TEST_CONTROL_LOG="$home/control.log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1/bin/fm-watch.sh"; SCRIPT_DIR="$2/scripts"; shift 2; "$@"' _ "$ROOT" "$home" "$@"
}

test_idle_worker_parks_without_date() {
  local home
  home=$(make_home park)
  printf 'kind=ship\n' > "$home/state/t1.meta"
  watch_fn "$home" worker_wait_park t1 'paused [at=1]: waiting without a date' || fail 'park tick failed'
  [ ! -e "$home/control.log" ] || fail 'an undated pause parked without a general pause'
  FM_HOME="$home" bash "$PAUSE" on x >/dev/null
  watch_fn "$home" worker_wait_park t1 'paused [at=1]: waiting without a date' || fail 'park tick failed'
  grep -qx 't1 park --when-idle' "$home/control.log" || fail 'general pause did not park an undated pause'
  : > "$home/control.log"
  watch_fn "$home" worker_wait_park t1 'working: still on it' || fail 'park tick failed'
  grep -qx 't1 park --when-idle' "$home/control.log" || fail 'general pause did not park an idle working worker'
  pass 'watcher: a general pause parks idle workers whatever their declared wait'
}

test_lifting_resumes_only_pause_parked_workers() {
  local home
  home=$(make_home resume)
  printf 'park_phase=parked\npark_cause=general-pause\n' > "$home/state/a.parked"
  printf 'park_phase=parked\n' > "$home/state/b.parked"
  FM_HOME="$home" bash "$PAUSE" on x >/dev/null
  watch_fn "$home" pause_resume_tick || fail 'resume tick failed'
  [ ! -e "$home/control.log" ] || fail 'resumed while the pause stood'
  FM_HOME="$home" bash "$PAUSE" off >/dev/null
  FM_TEST_ADMIT_RC=75 watch_fn "$home" pause_resume_tick || fail 'resume tick failed'
  [ ! -e "$home/control.log" ] || fail 'resumed a worker the capacity did not admit'
  watch_fn "$home" pause_resume_tick || fail 'resume tick failed'
  [ "$(cat "$home/control.log")" = 'a resume' ] || fail "expected only the pause-parked worker to resume: $(cat "$home/control.log")"
  pass 'watcher: lifting the pause resumes only what it parked, one admitted worker per tick'
}

test_a_failed_resume_does_not_starve_the_next_worker() {
  local home
  home=$(make_home resume-fail)
  printf 'park_phase=parked\npark_cause=general-pause\n' > "$home/state/a.parked"
  printf 'park_phase=parked\npark_cause=general-pause\n' > "$home/state/b.parked"
  FM_TEST_CONTROL_RC=1 watch_fn "$home" pause_resume_tick || fail 'resume tick failed'
  FM_TEST_CONTROL_RC=1 watch_fn "$home" pause_resume_tick || fail 'resume tick failed'
  [ "$(cat "$home/control.log")" = 'a resume
b resume' ] || fail "a failed resume held back the next worker: $(cat "$home/control.log")"
  pass 'watcher: a failed resume retries later and never starves the rest'
}

test_declared_wait_expiry_is_quiet_during_the_pause() {
  local home out
  home=$(make_home quiet)
  printf 'window=test:fm-t1\nkind=ship\nbackend=tmux\n' > "$home/state/t1.meta"
  printf 'paused [at=100]: until 2000-01-01T00:00Z\n' > "$home/state/t1.status"
  FM_HOME="$home" bash "$PAUSE" on x >/dev/null
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" bash -c '
    . "$1/bin/fm-watch.sh"
    pause_backlog_hold() { return 1; }
    fm_obligation_observe() { printf "observed\n"; }
    paused_until_resume test:fm-t1 t1 "paused [at=100]: until 2000-01-01T00:00Z"
  ' _ "$ROOT") || fail "expiry check failed: $out"
  [ -z "$out" ] || fail "an expired wait was noticed during the pause: $out"
  [ ! -d "$home/state/t1.inbox" ] || [ -z "$(ls "$home/state/t1.inbox" 2>/dev/null)" ] || fail 'a resume steer was sent during the pause'
  pass 'watcher: declared-wait expiry stays quiet while the pause stands'
}

test_record_lifecycle
test_admission_holds_without_touching_the_cap
test_idle_worker_parks_without_date
test_lifting_resumes_only_pause_parked_workers
test_a_failed_resume_does_not_starve_the_next_worker
test_declared_wait_expiry_is_quiet_during_the_pause
