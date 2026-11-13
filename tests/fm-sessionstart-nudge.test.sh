#!/usr/bin/env bash
# Behavior tests for both native session-open tiers: the nudge wrapper that
# only asks the agent to take the helm, and the run wrapper that takes it.
#
# The run-wrapper cases drive the REAL bin/fm-session-start.sh against a
# throwaway home, so they prove routing by the digest that actually appears,
# not by inspecting the wrapper's source. docs/sessionstart-nudge.md owns the
# tier assignment and the source table these pin.
set -u

# Run the whole suite beneath one long-lived fixture harness, matching the real
# lifecycle in which startup and later clear/compact hooks share one harness
# ancestor. This also prevents a developer's ambient harness from making the
# portable regression pass locally while failing on a harness-free CI runner.
if [ "${FM_SESSIONSTART_TEST_HARNESS:-0}" != 1 ]; then
  HARNESS_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/fm-sessionstart-harness.XXXXXX") || exit 1
  ln -s /bin/bash "$HARNESS_FIXTURE/codex" || exit 1
  # shellcheck disable=SC2016 # Expand in the fixture shell, not this parent.
  FM_SESSIONSTART_TEST_HARNESS=1 "$HARNESS_FIXTURE/codex" \
    -c '"$@"; rc=$?; :; exit "$rc"' _ "$0" "$@"
  HARNESS_STATUS=$?
  rm -rf "$HARNESS_FIXTURE"
  exit "$HARNESS_STATUS"
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset NO_MISTAKES_GATE

TMP_ROOT=$(fm_test_tmproot fm-sessionstart-nudge)
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
RUN="$ROOT/bin/fm-sessionstart-run.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
NUDGE_TEXT="Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions."
fm_operational_input_encode session-start "$NUDGE_TEXT" NUDGE_LINE \
  || fail "could not construct expected session-start nudge"
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_nudge() {
  local root=$1
  FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
}

expect_silent_zero() {
  local label=$1
  shift
  local out status=0
  out=$("$@" 2>&1) || status=$?
  expect_code 0 "$status" "$label must exit 0"
  [ -z "$out" ] || fail "$label must be silent, got: $out"
}

test_genuine_primary_nudges() {
  local root="$TMP_ROOT/primary" out prefix_hex status=0
  make_primary "$root"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "genuine primary nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "genuine primary printed unexpected output: $out"
  prefix_hex=$(printf '%s' "$out" | head -c 3 | od -An -tx1 | tr -d ' \n')
  [ "$prefix_hex" = e281a3 ] || fail "genuine primary nudge lost its U+2063 operational marker: $prefix_hex"
  pass "fm-sessionstart-nudge: a genuine primary gets one explicitly marked instruction line"
}

test_gate_env_is_silent() {
  local root="$TMP_ROOT/gate-env"
  make_primary "$root"
  expect_silent_zero "gate env nudge" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: NO_MISTAKES_GATE is silent"
}

test_gate_common_dir_is_silent() {
  local source="$TMP_ROOT/gate-source" bare="$TMP_ROOT/.no-mistakes/repos/gate.git"
  local root="$TMP_ROOT/gate-worktree"
  fm_git_init_commit "$source"
  mkdir -p "$(dirname "$bare")"
  git clone --quiet --bare "$source" "$bare"
  git --git-dir="$bare" worktree add --quiet -b gate-test "$root" HEAD
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'gate-test\n' > "$root/.fm-secondmate-home"
  expect_silent_zero "gate common-dir nudge" env FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$NUDGE"
  pass "fm-sessionstart-nudge: .no-mistakes gate common-dir is silent"
}

test_unmarked_linked_worktree_is_silent() {
  local base="$TMP_ROOT/worktree-base" root="$TMP_ROOT/worktree-child"
  fm_git_worktree "$base" "$root" fm/sessionstart-linked
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  expect_silent_zero "linked worktree nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: an unmarked linked task worktree is silent"
}

test_linked_secondmate_primary_nudges() {
  local base="$TMP_ROOT/secondmate-base" root="$TMP_ROOT/secondmate-home" out status=0
  fm_git_worktree "$base" "$root" fm/sessionstart-secondmate
  mkdir -p "$root/bin" "$root/state"
  : > "$root/AGENTS.md"
  printf 'sessionstart-sm\n' > "$root/.fm-secondmate-home"
  out=$(run_nudge "$root") || status=$?
  expect_code 0 "$status" "linked secondmate nudge"
  [ "$out" = "$NUDGE_LINE" ] || fail "linked secondmate printed unexpected output: $out"
  pass "fm-sessionstart-nudge: a marked linked secondmate home is a primary"
}

test_missing_state_is_silent() {
  local root="$TMP_ROOT/missing-state"
  make_primary "$root"
  rmdir "$root/state"
  expect_silent_zero "missing state nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a checkout without state is silent"
}

test_owned_lock_is_silent() {
  local root="$TMP_ROOT/already-ran"
  make_primary "$root"
  printf '%s\n' "$$" > "$root/state/.lock"
  expect_silent_zero "owned lock nudge" run_nudge "$root"
  pass "fm-sessionstart-nudge: a lock holder in process ancestry is already run"
}

# A firstmate running inside a PID namespace - a container, or `codex sandbox` -
# holds its home lock from a harness that IS pid 1, so this hook must recognize
# that owner. The old walk rejected a lock pid of 1 outright and stopped before
# comparing pid 1, so the hook nudged a session that had already run.
# A fake ps cannot reach this path: `kill -0` is a shell builtin gating the lock
# pid, and on a host `kill -0 1` fails for an unprivileged user, so the case
# needs a real namespace where pid 1 is this user's own process.
test_namespace_pid1_lock_holder_is_silent() {
  local root="$TMP_ROOT/namespace-pid1" out status=0
  if ! command -v unshare >/dev/null 2>&1 \
    || ! unshare -rpf --mount-proc true >/dev/null 2>&1; then
    printf '# skip: unprivileged PID namespaces are unavailable here, so the namespace pid 1 lock owner is unverified\n'
    return 0
  fi
  make_primary "$root"

  # Non-vacuity: inside the same namespace, with no lock at all, the hook must
  # still produce its nudge, so silence below means the owner was recognized.
  out=$(unshare -rpf --mount-proc bash -c \
    "FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE='$root' FM_HOME='$root' '$NUDGE'; exit \$?") || status=$?
  expect_code 0 "$status" "namespace nudge without a lock"
  [ "$out" = "$NUDGE_LINE" ] \
    || fail "the namespace fixture did not nudge without a lock, so its silence proves nothing: $out"

  printf '1\n' > "$root/state/.lock"
  status=0
  out=$(unshare -rpf --mount-proc bash -c \
    "FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE='$root' FM_HOME='$root' '$NUDGE'; exit \$?") || status=$?
  expect_code 0 "$status" "namespace pid 1 lock nudge"
  [ -z "$out" ] \
    || fail "a lock held by the harness at namespace pid 1 was not recognized, got: $out"
  pass "fm-sessionstart-nudge: a lock holder that is pid 1 of its own namespace is already run"
}


# --- run tier ----------------------------------------------------------------
#
# make_run_primary builds a primary the run wrapper accepts and the REAL
# fm-session-start.sh can execute: a git repo on main so the tangle check
# behaves, plus the home directories the digest reads. The deliberately bare
# PATH keeps every bootstrap probe fast and hermetic - it reports missing tools
# instead of reaching the host's real gh/tmux/tasks-axi.
RUN_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_run_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data" "$dir/config"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_hook() {  # <root> [args...]
  local root=$1
  shift
  env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$RUN_PATH" "$RUN" "$@"
}


# Every run-tier assertion keys off the digest banner, which fm-session-start.sh
# prints before the lock result, so routing is proven whether or not the lock
# was won in the test environment.
FULL_BANNER="SESSION START - "
REEMIT_BANNER="SESSION START (CONTEXT RE-EMIT) - "

test_run_startup_runs_the_full_digest() {
  local root="$TMP_ROOT/run-startup" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source startup </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper startup"
  assert_contains "$out" "$FULL_BANNER$root" "startup did not run the full digest"
  assert_contains "$out" "lock acquired: harness pid" \
    "the portable startup fixture did not supply a real harness process"
  assert_not_contains "$out" "$REEMIT_BANNER" "startup was misrouted to a context re-emit"
  assert_not_contains "$out" "FIRSTMATE_OP" "a run-tier open also emitted the nudge instruction"
  assert_contains "$out" "NEXT STEP" "the run wrapper did not deliver a complete digest"
  pass "run wrapper: startup runs the full digest and never also nudges"
}

test_run_clear_and_compact_reemit() {
  local root out source status
  for source in clear compact; do
    root="$TMP_ROOT/run-$source"
    make_run_primary "$root"
    run_hook "$root" --source startup </dev/null >/dev/null
    assert_present "$root/state/.session-start-complete" \
      "startup did not publish the completion proof needed by $source"
    status=0
    out=$(run_hook "$root" --source "$source" </dev/null) || status=$?
    expect_code 0 "$status" "run wrapper $source"
    assert_contains "$out" "$REEMIT_BANNER$root" "$source did not re-emit the digest"
    assert_contains "$out" "are NOT repeated" "$source did not report the skipped startup sweeps"
    assert_contains "$out" "Queued wakes ARE still drained" "$source did not preserve the wake-queue drain"
    assert_not_contains "$out" "FIRSTMATE_OP" "a $source open also emitted the nudge instruction"
  done
  pass "run wrapper: clear and compact re-emit the digest without repeating startup sweeps"
}

test_run_clear_without_completion_finishes_startup() {
  local root="$TMP_ROOT/run-clear-incomplete" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source clear </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper clear without completion proof"
  assert_contains "$out" "$FULL_BANNER$root" \
    "clear skipped full startup when no completed startup could be proven"
  assert_not_contains "$out" "$REEMIT_BANNER" \
    "clear trusted lock ownership as proof that startup completed"
  assert_present "$root/state/.session-start-complete" \
    "the recovery full startup did not publish completion proof"
  pass "run wrapper: clear falls back to full startup when completion is unproven"
}

test_run_clear_rejects_previous_owner_completion() {
  local root="$TMP_ROOT/run-clear-previous-owner" out status=0 previous_pid
  make_run_primary "$root"
  sleep 0 &
  previous_pid=$!
  wait "$previous_pid"
  printf '%s\n' "$previous_pid" > "$root/state/.lock"
  printf '%s\n' "$previous_pid" > "$root/state/.session-start-complete"

  out=$(run_hook "$root" --source clear </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper clear with previous owner completion"
  assert_contains "$out" "$FULL_BANNER$root" \
    "clear treated a previous session's completion as current"
  assert_not_contains "$out" "$REEMIT_BANNER" \
    "clear skipped startup sweeps completed only by a previous session"
  [ "$(cat "$root/state/.lock")" != "$previous_pid" ] \
    || fail "the recovery startup did not replace the previous session's stale lock"
  pass "run wrapper: clear accepts completion only from the current harness"
}

make_run_hook_fixture() {
  local fixture=$1
  make_run_primary "$fixture"
  mkdir -p "$fixture/tmp"
  cp "$ROOT/bin/fm-sessionstart-run.sh" "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/"
  cat > "$fixture/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_HOME/session-start-called"
printf 'FIXTURE_DIGEST\n'
SH
  chmod +x "$fixture/bin/"*.sh
}

test_run_hook_budget_bounds_preparation() {
  local stage fixture fakebin tool real_tool source out status started elapsed
  for stage in gate scope state payload parse completion-clear completion-compact capture-out capture-err; do
    fixture="$TMP_ROOT/preparation-$stage"
    fakebin="$fixture/fakebin"
    make_run_hook_fixture "$fixture"
    mkdir -p "$fakebin"
    source=startup
    case "$stage" in
      gate|scope) tool=git ;;
      state) tool='mkdir'; rmdir "$fixture/state" ;;
      payload) tool='cat'; source= ;;
      parse) tool='awk'; source= ;;
      completion-*)
        tool='cat'
        source=${stage#completion-}
        printf '%s\n' "$$" > "$fixture/state/.lock"
        printf '%s\n' "$$" > "$fixture/state/.session-start-complete"
        ;;
      capture-*) tool=mktemp ;;
    esac
    real_tool=$(PATH="$RUN_PATH" command -v "$tool")
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
stall=0
case "$FM_PREPARATION_STAGE" in
  gate|state|parse) stall=1 ;;
  scope) [ "${1:-}" != -C ] || stall=1 ;;
  payload) [ "$#" -ne 0 ] || stall=1 ;;
  completion-*) [ "${1:-}" != "$FM_HOME/state/.lock" ] || stall=1 ;;
  capture-*)
    case "${1:-}" in
      *"fm-sessionstart-run.${FM_PREPARATION_STAGE#capture-}."*) stall=1 ;;
    esac
    ;;
esac
if [ "$stall" = 1 ]; then
  printf '%s\n' "$FM_PREPARATION_STAGE" > "$FM_HOME/preparation-stalled"
  exec sleep 8
fi
exec "$FM_REAL_PREPARATION_TOOL" "$@"
SH
    chmod +x "$fakebin/$tool"
    started=$(date +%s)
    status=0
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      FM_SESSION_START_HOOK_BUDGET=2 FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$fixture" \
      FM_HOME="$fixture" TMPDIR="$fixture/tmp" PATH="$fakebin:$RUN_PATH" \
      FM_PREPARATION_STAGE="$stage" \
      FM_REAL_PREPARATION_TOOL="$real_tool" \
      "$fixture/bin/fm-sessionstart-run.sh" --source "$source" \
      <<<'{"source":"startup"}') || status=$?
    elapsed=$(( $(date +%s) - started ))
    expect_code 0 "$status" "run wrapper during stalled $stage preparation"
    assert_present "$fixture/preparation-stalled" "$stage preparation never reached the stalled operation"
    [ "$elapsed" -lt 5 ] || fail "$stage preparation took ${elapsed}s against a 2s hook budget"
    assert_absent "$fixture/session-start-called" "$stage preparation launched session start after its budget"
    assert_contains "$out" "SESSION START INCOMPLETE - IT DID NOT FINISH INSIDE THE 2s HOOK BUDGET" \
      "$stage preparation exhausted the hook budget silently"
    assert_contains "$out" "Run bin/fm-session-start.sh now, exactly once" \
      "$stage preparation did not explain how to recover"
  done
  pass "run wrapper: eligibility, state, payload, completion, and capture preparation share the hook budget"
}

test_run_capture_failure_never_launches_an_uncaptured_digest() {
  local source completion stream fixture out status owner real_mktemp
  owner=$(bash -c '. "$1"; fm_harness_ancestry_pid' _ "$ROOT/bin/fm-session-lock-lib.sh") \
    || fail "capture-failure fixture could not resolve its real harness owner"
  real_mktemp=$(PATH="$RUN_PATH" command -v mktemp)
  for source in startup clear compact; do
    for completion in absent complete; do
      for stream in out err; do
        fixture="$TMP_ROOT/capture-failure-$source-$completion-$stream"
        make_run_hook_fixture "$fixture"
        mkdir -p "$fixture/fakebin"
        if [ "$completion" = complete ]; then
          printf '%s\n' "$owner" > "$fixture/state/.lock"
          printf '%s\n' "$owner" > "$fixture/state/.session-start-complete"
        fi
        cat > "$fixture/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *"fm-sessionstart-run.$FM_FAILED_CAPTURE_STREAM."*)
    printf 'failed\n' > "$FM_HOME/capture-failed"
    exit 1
    ;;
esac
exec "$FM_REAL_MKTEMP" "$@"
SH
        chmod +x "$fixture/fakebin/mktemp"
        status=0
        out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
          FM_SESSION_START_HOOK_BUDGET=10 FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$fixture" \
          FM_HOME="$fixture" TMPDIR="$fixture/tmp" PATH="$fixture/fakebin:$RUN_PATH" \
          FM_FAILED_CAPTURE_STREAM="$stream" FM_REAL_MKTEMP="$real_mktemp" \
          "$fixture/bin/fm-sessionstart-run.sh" --source "$source" </dev/null) || status=$?
        expect_code 0 "$status" "capture failure on $source with $completion completion and missing $stream"
        assert_present "$fixture/capture-failed" "$source did not attempt to allocate its $stream capture"
        assert_absent "$fixture/session-start-called" "$source ran session start without its $stream capture"
        assert_contains "$out" "SESSION START INCOMPLETE - OUTPUT CAPTURE FAILED" \
          "$source capture failure did not produce an explicit notice"
        assert_contains "$out" "Run bin/fm-session-start.sh now, exactly once" \
          "$source capture failure did not explain how to recover"
        [ -z "$(ls -A "$fixture/tmp")" ] || fail "$source left capture files behind after $stream allocation failed"
      done
    done
  done
  pass "run wrapper: failure of either capture prevents startup and both clear/compact routes from running uncaptured"
}

# A hook harness discards a killed hook's whole output, so the run wrapper must
# hand back what it has, plus an explicit rerun notice, inside its own budget -
# even while a descendant that escaped the digest's process group still holds
# the digest's stdout open.
test_run_hook_budget_delivers_partial_digest_and_rerun_notice() {
  local fixture="$TMP_ROOT/run-hook-budget" out status=0 started elapsed stray
  make_run_primary "$fixture"
  cp "$ROOT/bin/fm-sessionstart-run.sh" "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-hook-host-lib.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/"
  cat > "$fixture/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf 'HOOK_BUDGET_DIGEST_HEAD deadline=%s\n' "${FM_SESSION_START_DEADLINE:-unset}"
# A nested bound runs in a process group of its own, so it outlives a group
# kill of this script while still holding this script's stdout.
perl -e 'setpgrp(0, 0); exec @ARGV' sleep 60 &
printf '%s\n' "$!" > "$FM_HOME/state/escaped.pid"
# The slow sweep that runs past the hook budget.
sleep 60
printf 'HOOK_BUDGET_DIGEST_TAIL\n'
SH
  chmod +x "$fixture/bin/"*.sh

  started=$(date +%s)
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_SESSION_START_HOOK_BUDGET=5 FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$fixture" \
    FM_HOME="$fixture" PATH="$RUN_PATH" "$fixture/bin/fm-sessionstart-run.sh" --source startup \
    </dev/null) || status=$?
  elapsed=$(( $(date +%s) - started ))
  stray=$(cat "$fixture/state/escaped.pid" 2>/dev/null || true)
  [ -z "$stray" ] || kill "$stray" 2>/dev/null || true
  expect_code 0 "$status" "run wrapper past its hook budget"
  [ "$elapsed" -lt 10 ] \
    || fail "run wrapper took ${elapsed}s against a 5s hook budget, so a harness timeout would discard it"
  assert_contains "$out" "HOOK_BUDGET_DIGEST_HEAD deadline=" \
    "the digest emitted before the budget was not delivered"
  assert_not_contains "$out" "deadline=unset" "the digest was not told the hook delivery deadline"
  assert_not_contains "$out" "HOOK_BUDGET_DIGEST_TAIL" "the digest claimed to finish past its budget"
  assert_contains "$out" "SESSION START INCOMPLETE - IT DID NOT FINISH INSIDE THE 5s HOOK BUDGET" \
    "an overrun hook budget was silent"
  assert_contains "$out" "Run bin/fm-session-start.sh now, exactly once" \
    "the overrun notice did not tell the agent how to finish taking the helm"
  pass "run wrapper: a slow session start returns its partial digest and a rerun notice inside the hook budget"
}

# The real digest caps its own bound to the hook deadline, so a slow stage ends
# with the stage-naming truncation banner instead of the coarser hook notice.
test_run_real_digest_truncates_inside_the_hook_budget() {
  local root="$TMP_ROOT/run-real-slow" fakebin="$TMP_ROOT/run-real-slow-bin" real_git
  local out status=0 started elapsed stray
  make_run_primary "$root"
  mkdir -p "$fakebin"
  real_git=$(PATH="$RUN_PATH" command -v git)
  # Eligibility reads stay fast; every other git call is a sweep that hangs.
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" rev-parse "*) exec "$real_git" "\$@" ;; esac
printf '%s\n' "\$\$" >> "$fakebin/hung.pids"
exec sleep 300
SH
  chmod +x "$fakebin/git"

  started=$(date +%s)
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    FM_SESSION_START_HOOK_BUDGET=12 FM_SESSION_START_TIMEOUT=120 FM_STARTUP_NETWORK_TIMEOUT=2 \
    FM_GATE_REFUSE_BYPASS=0 FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$fakebin:$RUN_PATH" \
    "$RUN" --source startup </dev/null) || status=$?
  elapsed=$(( $(date +%s) - started ))
  while read -r stray; do kill "$stray" 2>/dev/null || true; done 2>/dev/null < "$fakebin/hung.pids"
  FM_HOME="$root" FM_ROOT_OVERRIDE="$root" FM_STARTUP_NETWORK_TIMEOUT=2 \
    "$ROOT/bin/fm-startup-network.sh" wait 30 >/dev/null 2>&1 || true
  expect_code 0 "$status" "run wrapper over a slow real digest"
  [ "$elapsed" -lt 18 ] \
    || fail "a slow real digest took ${elapsed}s against a 12s hook budget"
  assert_contains "$out" "$FULL_BANNER$root" "the slow digest lost the output it had already produced"
  assert_contains "$out" "STARTUP TRUNCATED - SESSION START HIT ITS" \
    "the digest bound did not shrink to fit the hook budget"
  assert_contains "$out" "Rerun bin/fm-session-start.sh now" \
    "the truncated digest did not tell the agent to finish taking the helm"
  assert_not_contains "$out" "NEXT STEP" "a truncated digest claimed to have reached its closing reminder"
  pass "run wrapper: a slow real digest truncates with its stage banner inside the hook budget"
}

test_run_resume_delegates_to_the_nudge() {
  local root="$TMP_ROOT/run-resume" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source resume </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper resume"
  [ "$out" = "$NUDGE_LINE" ] || fail "resume did not delegate to the exact nudge line, got: $out"
  assert_absent "$root/state/.lock" "resume acquired the fleet lock instead of delegating"
  pass "run wrapper: resume delegates to the nudge instead of re-running the digest"
}

test_run_reads_source_from_the_hook_payload() {
  local root="$TMP_ROOT/run-payload" out status=0
  make_run_primary "$root"
  run_hook "$root" --source startup </dev/null >/dev/null
  out=$(printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"compact"}' |
    run_hook "$root") || status=$?
  expect_code 0 "$status" "run wrapper payload compact"
  assert_contains "$out" "$REEMIT_BANNER$root" "a compact hook payload was not routed to a re-emit"

  # A fresh root, because the compact case above legitimately took the lock and
  # an owned lock is exactly when the nudge is supposed to stay silent.
  root="$TMP_ROOT/run-payload-resume"
  make_run_primary "$root"
  status=0
  out=$(printf '{"source":"resume","cwd":"/nowhere"}' | run_hook "$root") || status=$?
  expect_code 0 "$status" "run wrapper payload resume"
  assert_contains "$out" "FIRSTMATE_OP" "a resume hook payload did not delegate to the nudge"
  assert_not_contains "$out" "SESSION START" "a resume hook payload still ran the digest"
  pass "run wrapper: the hook payload's source field drives routing with no explicit argument"
}

test_run_unknown_source_takes_the_helm() {
  local root="$TMP_ROOT/run-unknown" out status=0
  make_run_primary "$root"
  out=$(run_hook "$root" --source somethingnew </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper unknown source"
  assert_contains "$out" "$FULL_BANNER$root" "an unrecognized source did not fall through to the full digest"

  status=0
  out=$(printf '{"hook_event_name":"SessionStart"}' | run_hook "$root") || status=$?
  expect_code 0 "$status" "run wrapper sourceless payload"
  assert_contains "$out" "$FULL_BANNER$root" "a payload with no source did not fall through to the full digest"
  pass "run wrapper: an unrecognized or absent source takes the helm rather than skipping it"
}

test_run_gate_and_scope_are_silent() {
  local root="$TMP_ROOT/run-gate" base="$TMP_ROOT/run-linked-base" linked="$TMP_ROOT/run-linked"
  local out status=0
  make_run_primary "$root"
  expect_silent_zero "gate env run" env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$RUN_PATH" "$RUN" --source startup
  assert_absent "$root/state/.lock" "a gate agent's session open still took the fleet lock"
  out=$(env NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" PATH="$RUN_PATH" \
    "$RUN" --source startup 2>&1) || status=$?
  expect_code 0 "$status" "gate env hook stand-down"
  [ -z "$out" ] || fail "gate env hook stand-down must be silent, got: $out"

  fm_git_worktree "$base" "$linked" fm/run-linked
  mkdir -p "$linked/bin" "$linked/state"
  : > "$linked/AGENTS.md"
  expect_silent_zero "linked worktree run" run_hook "$linked" --source startup
  status=0
  out=$(run_hook "$linked" --source startup 2>&1) || status=$?
  expect_code 0 "$status" "linked worktree hook stand-down"
  [ -z "$out" ] || fail "linked worktree hook stand-down must be silent, got: $out"
  assert_absent "$linked/state/.lock" "an unmarked task worktree still took the fleet lock"
  pass "run wrapper: ineligible opens stay silent-zero"
}

test_run_creates_missing_state_on_a_fresh_primary() {
  local root="$TMP_ROOT/run-fresh-primary" base="$TMP_ROOT/run-fresh-linked-base"
  local linked="$TMP_ROOT/run-fresh-linked" out status=0
  make_run_primary "$root"
  rmdir "$root/state"
  assert_absent "$root/state" "the fixture still had a state dir before the assertion began"

  out=$(run_hook "$root" --source startup </dev/null) || status=$?
  expect_code 0 "$status" "run wrapper startup on a fresh primary with no state dir"
  assert_present "$root/state" "a fresh primary root did not get its state dir created"
  assert_contains "$out" "$FULL_BANNER$root" \
    "creating the state dir did not let a fresh primary's session start run"
  assert_contains "$out" "lock acquired: harness pid" \
    "creating the state dir did not let a fresh primary take the fleet lock"
  assert_not_contains "$out" "$REEMIT_BANNER" \
    "a fresh primary's first session was misrouted to a context re-emit"
  assert_contains "$out" "NEXT STEP" "a fresh primary did not receive the complete digest"

  # An unmarked linked task worktree stays ineligible: it must not have a state
  # dir manufactured for it, so the existing scope refusal is unchanged.
  fm_git_worktree "$base" "$linked" fm/run-fresh-linked
  mkdir -p "$linked/bin"
  : > "$linked/AGENTS.md"
  assert_absent "$linked/state" "the linked fixture already had a state dir before the assertion began"
  expect_silent_zero "linked worktree fresh state run" run_hook "$linked" --source startup
  assert_absent "$linked/state" "an unmarked linked task worktree got a state dir created for it"
  pass "run wrapper: a fresh primary checkout gets its missing state dir created, a linked worktree still does not"
}

test_run_reports_a_state_dir_it_cannot_create() {
  local root="$TMP_ROOT/run-fresh-readonly" out err_file="$TMP_ROOT/run-fresh-readonly.err" status=0
  make_run_primary "$root"
  rmdir "$root/state"
  chmod 0500 "$root"
  out=$(run_hook "$root" --source startup </dev/null 2>"$err_file") || status=$?
  chmod 0700 "$root"
  expect_code 0 "$status" "run wrapper on a fresh primary whose state dir cannot be created"
  [ -z "$out" ] || fail "a failed state dir creation must still stand down without a digest, got: $out"
  assert_absent "$root/state" "a read-only fresh primary somehow got a state dir"
  [ "$(wc -l <"$err_file")" -eq 1 ] || fail "expected exactly one stderr line, got: $(cat "$err_file")"
  assert_contains "$(cat "$err_file")" \
    "startup could not create the state directory $root/state: Permission denied" \
    "a failed state dir creation did not say what failed and why"
  pass "run wrapper: a fresh primary that cannot create its state dir says so on stderr, then stands down"
}

test_run_reports_a_failed_session_start_as_digest_text() {
  local root="$TMP_ROOT/run-unwritable" out status=0
  make_run_primary "$root"
  chmod 0500 "$root/state"
  out=$(run_hook "$root" --source startup </dev/null) || status=$?
  chmod 0700 "$root/state"
  expect_code 0 "$status" "run wrapper with an unwritable state directory"
  assert_contains "$out" "READ-ONLY SESSION" "a failed lock did not reach the agent as digest text"
  pass "run wrapper: a session start that cannot take the lock still opens the session and says so"
}

test_genuine_primary_nudges
test_gate_env_is_silent
test_gate_common_dir_is_silent
test_unmarked_linked_worktree_is_silent
test_linked_secondmate_primary_nudges
test_missing_state_is_silent
test_owned_lock_is_silent
test_namespace_pid1_lock_holder_is_silent
test_run_startup_runs_the_full_digest
test_run_clear_and_compact_reemit
test_run_clear_without_completion_finishes_startup
test_run_clear_rejects_previous_owner_completion
test_run_resume_delegates_to_the_nudge
test_run_reads_source_from_the_hook_payload
test_run_unknown_source_takes_the_helm
test_run_gate_and_scope_are_silent
test_run_creates_missing_state_on_a_fresh_primary
test_run_reports_a_state_dir_it_cannot_create
test_run_reports_a_failed_session_start_as_digest_text
test_run_hook_budget_bounds_preparation
test_run_capture_failure_never_launches_an_uncaptured_digest
test_run_hook_budget_delivers_partial_digest_and_rerun_notice
test_run_real_digest_truncates_inside_the_hook_budget
