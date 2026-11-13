#!/usr/bin/env bash
# fm-control.sh: the agent lifecycle CONTROL plane.
#
# These tests pin the control plane's observable behavior hermetically - a
# stubbed session provider, no real agent - through the executable interface
# firstmate actually calls:
#   1. Adapter contract: every verified harness gets its own verified exit
#      command and interrupt key, delivered as bytes to the endpoint.
#   2. Backend capability: a backend that cannot deliver the harness's
#      interrupt key, and a backend with no recovery-grade agent-state
#      classifier, both refuse instead of acting blind.
#   3. Exact-id scoping: a window label, an explicit endpoint, an unknown id,
#      and a record bound to another task are all refused.
#   4. Verb allowlist: no arbitrary text, no raw keys, no resume.
#   5. Lifecycle states: busy interrupts first, idle does not, already-stopped
#      is idempotent success, and an agent that does not stop fails closed.
#   6. Marker non-regression: a control command to a kind=secondmate task
#      carries NO from-firstmate marker and opens no pending-reply expectation,
#      while fm-send's marking of the same task is untouched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SEND="$ROOT/bin/fm-send.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

VERIFIED_HARNESSES="claude codex opencode pi pi-signed cursor"

# The expectation table, written out independently of the implementation so a
# silent change to either side shows up here. The fourth field is the composer
# clear that must FOLLOW the interrupt key, empty for every adapter that leaves
# its composer empty on cancel.
verified_adapter_contract() {  # <harness> -> exit command, interrupt key, repeat, clear key
  case "$1" in
    claude) printf '/exit\tEscape\t1\t\n' ;;
    codex) printf '/quit\tEscape\t1\t\n' ;;
    opencode) printf '/exit\tEscape\t2\t\n' ;;
    pi) printf '/quit\tEscape\t1\t\n' ;;
    pi-signed) printf '/quit\tEscape\t1\t\n' ;;
    cursor) printf '/exit\tEscape\t1\t\n' ;;
    *) return 1 ;;
  esac
}

# --- fake session provider --------------------------------------------------
#
# A tmux stub whose whole model is four files under $FM_FAKE_DIR:
#   command  the pane's foreground process name, which IS the agent-state
#            classifier's input (bin/backends/tmux.sh).
#   cwd      the pane's current path.
#   literal  every `send-keys -l` payload, one per line - exactly what was
#            typed into the composer.
#   keys     every named key send, one per line.
#   pane     optional capture-pane override, for an adapter whose busy verdict
#            is read from the rendered tail.
#   key-times  every named key with its wall-clock send time.
# Two transitions make it a lifecycle model rather than a recorder: a literal
# that is the harness's exit command flips `command` to a shell (the agent
# stopped), and a literal carrying a launch brief flips it to the value in
# `becomes` (a new agent came up). FM_FAKE_NEVER_DIES suppresses the first, so
# a stubborn agent can be tested too.
make_tmux_stub() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      if [ -z "${FM_FAKE_NEVER_DIES:-}" ] \
         && { [ "$payload" = /exit ] || [ "$payload" = /quit ]; }; then
        printf 'zsh' > "$D/command"
      fi
      case "$payload" in
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      printf '%s %s\n' "$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" "$payload" >> "$D/key-times"
      if [ -n "${FM_FAKE_INTERRUPT_STOPS_AGENT:-}" ] \
         && { [ "$payload" = Escape ] || [ "$payload" = C-c ]; }; then
        printf 'zsh' > "$D/command"
      fi
      if [ -n "${FM_FAKE_SECOND_CTRL_C_STOPS_AGENT:-}" ] && [ "$payload" = C-c ]; then
        if [ -e "$D/first-ctrl-c" ]; then
          printf 'zsh' > "$D/command"
        else
          : > "$D/first-ctrl-c"
        fi
      fi
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*)
          printf '1\n'
          exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -f "$D/after-enter" ] && [ -f "$D/keys" ] && grep -qx Enter "$D/keys"; then
      # after-enter-late holds how many captures after Enter still show the
      # ordinary pane, for a screen that renders after the submit has read it.
      late=0
      [ ! -f "$D/after-enter-late" ] || late=$(cat "$D/after-enter-late")
      if [ "$late" -gt 0 ]; then
        printf '%s' "$((late - 1))" > "$D/after-enter-late"
      else
        cat "$D/after-enter"
        exit 0
      fi
    fi
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    exit 0 ;;
  list-windows)
    if [ -f "$D/windows" ]; then cat "$D/windows"; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# new_case <name> -> echoes a case dir holding home/, fake/, and fakebin.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_tmux_stub "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# add_task <case-dir> <id> <harness> [kind] [backend] [window]
# Builds the task's worktree (a real git worktree so the relaunch checkpoint
# has something to account for), its brief, and its state/<id>.meta.
add_task() {
  local dir=$1 id=$2 harness=$3 kind=${4:-ship} backend=${5:-tmux}
  local window=${6:-fmses:fm-$id}
  local home="$dir/home" proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=$window"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    [ "$backend" = tmux ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

# run_control <case-dir> <args...>: run fm-control against the case's home with
# the stubbed provider on PATH. Echoes combined output; returns its exit code.
run_control() {
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_FAKE_INTERRUPT_STOPS_AGENT="${FM_FAKE_INTERRUPT_STOPS_AGENT:-}" \
    FM_FAKE_SECOND_CTRL_C_STOPS_AGENT="${FM_FAKE_SECOND_CTRL_C_STOPS_AGENT:-}" \
    "$CONTROL" "$@" 2>&1
}

alive_as() {  # <case-dir> <command-name>
  printf '%s' "$2" > "$1/fake/command"
}

literals() {  # <case-dir>
  cat "$1/fake/literal"
}

# Every named key EXCEPT Enter, which is submission mechanics shared with every
# text send rather than a control-plane key.
keys_sent() {  # <case-dir>
  grep -v '^Enter$' "$1/fake/keys" || true
}

# --- 1. adapter contract across every verified harness -----------------------

test_exit_types_each_harness_verified_command() {
  local dir out rc harness expected key repeat clear
  for harness in $VERIFIED_HARNESSES; do
    dir=$(new_case "exit-$harness")
    add_task "$dir" t1 "$harness"
    case "$harness" in
      cursor) alive_as "$dir" cursor-agent ;;
      *) alive_as "$dir" "$harness" ;;
    esac
    out=$(run_control "$dir" t1 exit); rc=$?
    expect_code 0 "$rc" "exit on $harness should succeed"$'\n'"$out"
    IFS=$'\t' read -r expected key repeat clear <<< "$(verified_adapter_contract "$harness")"
    [ "$(literals "$dir")" = "$expected" ] \
      || fail "exit on $harness should type exactly '$expected', got: $(literals "$dir")"
    assert_contains "$out" "stopped t1 harness=$harness" "exit should report the stop for $harness"
  done
  pass "fm-control exit: every verified harness gets its own verified exit command"
}

# OpenCode's composer exit key changed between major lines: 1.x exits on the
# typed /exit, 2.x on a raw Ctrl-C. Spawn records the detected major in meta;
# fm-control must send the key the recorded version's TUI understands. The
# default adapter contract above (no opencode_version) already proves the
# version-agnostic /exit fallback; this locks both recorded branches.
test_opencode_exit_matches_recorded_major() {
  local dir out rc
  # 1.x: the recorded major keeps the typed /exit command.
  dir=$(new_case exit-opencode1)
  add_task "$dir" t1 opencode
  printf 'opencode_version=1.18.32\n' >> "$dir/home/state/t1.meta"
  alive_as "$dir" opencode
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit on a recorded OpenCode 1.x task should succeed"$'\n'"$out"
  [ "$(literals "$dir")" = /exit ] \
    || fail "OpenCode 1.x exit must type /exit, got: $(literals "$dir")"
  [ -z "$(keys_sent "$dir")" ] \
    || fail "OpenCode 1.x exit must send no control key, got: $(keys_sent "$dir")"
  assert_contains "$out" "stopped t1 harness=opencode" "OpenCode 1.x exit should report the stop"

  # 2.x: the recorded major clears the composer with Ctrl-U, then exits on a
  # raw Ctrl-C, and types nothing. An agent that stops on that Ctrl-C gets no
  # second one.
  dir=$(new_case exit-opencode2)
  add_task "$dir" t1 opencode
  printf 'opencode_version=2.0.21\n' >> "$dir/home/state/t1.meta"
  alive_as "$dir" opencode
  out=$(FM_FAKE_INTERRUPT_STOPS_AGENT=1 run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit on a recorded OpenCode 2.x task should succeed"$'\n'"$out"
  [ "$(keys_sent "$dir" | paste -sd' ' -)" = "C-u C-c" ] \
    || fail "OpenCode 2.x exit must send Ctrl-U then one Ctrl-C, got keys: $(keys_sent "$dir")"
  [ -z "$(literals "$dir")" ] \
    || fail "OpenCode 2.x exit must type no composer text, got: $(literals "$dir")"
  assert_contains "$out" "stopped t1 harness=opencode" "OpenCode 2.x exit should report the stop"
  pass "fm-control exit: a recorded OpenCode major picks /exit (1.x) or Ctrl-U then Ctrl-C (2.x)"
}

# An OpenCode 2 TUI whose first Ctrl-C only clears leftover composer text stays
# alive; exit sends exactly one more Ctrl-C and then confirms the stop.
test_opencode2_exit_retries_ctrl_c_once() {
  local dir out rc
  dir=$(new_case exit-opencode2-retry)
  add_task "$dir" t1 opencode
  printf 'opencode_version=2.0.22\n' >> "$dir/home/state/t1.meta"
  alive_as "$dir" opencode
  out=$(FM_FAKE_SECOND_CTRL_C_STOPS_AGENT=1 run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit on an OpenCode 2.x task needing a second Ctrl-C should succeed"$'\n'"$out"
  [ "$(keys_sent "$dir" | paste -sd' ' -)" = "C-u C-c C-c" ] \
    || fail "OpenCode 2.x exit must retry Ctrl-C once while the agent lives, got keys: $(keys_sent "$dir")"
  assert_contains "$out" "stopped t1 harness=opencode" "OpenCode 2.x exit should report the stop after the retry"

  dir=$(new_case exit-opencode2-stuck)
  add_task "$dir" t1 opencode
  printf 'opencode_version=2.0.22\n' >> "$dir/home/state/t1.meta"
  alive_as "$dir" opencode
  out=$(run_control "$dir" t1 exit); rc=$?
  [ "$rc" -ne 0 ] || fail "exit on an OpenCode 2.x agent that never stops must fail"$'\n'"$out"
  [ "$(keys_sent "$dir" | paste -sd' ' -)" = "C-u C-c C-c" ] \
    || fail "OpenCode 2.x exit must retry Ctrl-C only once, got keys: $(keys_sent "$dir")"
  assert_contains "$out" "exit=unconfirmed" "a still-alive OpenCode 2.x agent must report an unconfirmed exit"
  pass "fm-control exit: OpenCode 2.x retries Ctrl-C exactly once while the agent is still alive"
}

test_interrupt_sends_each_harness_verified_key() {
  local dir out rc harness expected key repeat clear got want
  for harness in $VERIFIED_HARNESSES; do
    dir=$(new_case "int-$harness")
    add_task "$dir" t1 "$harness"
    case "$harness" in
      cursor) alive_as "$dir" cursor-agent ;;
      *) alive_as "$dir" "$harness" ;;
    esac
    out=$(run_control "$dir" t1 interrupt); rc=$?
    expect_code 0 "$rc" "interrupt on $harness should succeed"$'\n'"$out"
    IFS=$'\t' read -r expected key repeat clear <<< "$(verified_adapter_contract "$harness")"
    want=$(for _ in $(seq 1 "$repeat"); do printf '%s\n' "$key"; done)
    [ -z "$clear" ] || want="$want"$'\n'"$clear"
    got=$(keys_sent "$dir")
    [ "$got" = "$want" ] \
      || fail "interrupt on $harness should send $repeat x $key${clear:+ then $clear}, got: $got"
    [ -z "$(literals "$dir")" ] \
      || fail "interrupt on $harness must type no text, got: $(literals "$dir")"
  done
  pass "fm-control interrupt: every verified harness gets its own verified key and repeat count"
}

test_harness_family_resolution() {
  local pair recorded want got
  for pair in claude:claude claude-latest:claude codex:codex codex-cli:codex \
      opencode:opencode cursor:cursor \
      cursor-agent:cursor pi:pi \
      pi-signed:pi-signed; do
    recorded=${pair%%:*}
    want=${pair#*:}
    got=$(fm_control_harness_family "$recorded") \
      || fail "'$recorded' should resolve to the $want adapter"
    [ "$got" = "$want" ] || fail "'$recorded' should resolve to $want, got '$got'"
  done
  fm_control_harness_family someagent \
    && fail "an unrecognized launch command must not be guessed into an adapter family"
  fm_control_harness_family '' \
    && fail "an empty harness must not resolve to an adapter family"
  # The signed adapter is a distinct launch profile, not a pi variant.
  [ "$(fm_control_harness_family pi-signed)" != "$(fm_control_harness_family pi)" ] \
    || fail "pi-signed must not collapse into pi"
  # omp is exact: an omp* prefix would claim unrelated commands such as ompd.
  fm_control_harness_family ompd \
    && fail "ompd must not be guessed into the omp adapter"
  fm_control_harness_family comp \
    && fail "comp must not be guessed into the omp adapter"
  pass "fm-control-lib: a recorded harness resolves to its verified adapter without guessing"
}

test_prefixed_recorded_harness_reaches_each_control_verb() {
  local dir out rc
  dir=$(new_case prefixed-interrupt)
  add_task "$dir" t1 codex-cli
  alive_as "$dir" codex-cli
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 0 "$rc" "interrupt should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(keys_sent "$dir")" = Escape ] \
    || fail "a Codex-prefixed task should receive grok's interrupt key"
  assert_contains "$out" "harness=codex" \
    "interrupt should report the verified adapter that supplied its mechanics"

  dir=$(new_case prefixed-exit)
  add_task "$dir" t1 codex-cli
  alive_as "$dir" codex-cli
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(literals "$dir")" = /quit ] \
    || fail "a Codex-prefixed task should receive grok's exit command"
  assert_contains "$out" "stopped t1 harness=codex" \
    "exit should report the verified adapter that supplied its mechanics"
  pass "fm-control: prefixed recorded harnesses reach interrupt and exit mechanics"
}

test_opencode_interrupts_twice_and_others_once() {
  # The one adapter that differs, asserted through the delivered keys rather
  # than the table, so a regression in either shows up here.
  local dir
  dir=$(new_case int-double)
  add_task "$dir" t1 opencode
  alive_as "$dir" opencode
  run_control "$dir" t1 interrupt >/dev/null
  [ "$(keys_sent "$dir" | wc -l | tr -d ' ')" = 2 ] \
    || fail "opencode should receive a double Escape"
  dir=$(new_case int-single)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  run_control "$dir" t1 interrupt >/dev/null
  [ "$(keys_sent "$dir" | wc -l | tr -d ' ')" = 1 ] \
    || fail "claude should receive a single Escape"
  pass "fm-control interrupt: opencode needs a double Escape, claude a single one"
}

test_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case unverified)
  add_task "$dir" t1 someagent
  alive_as "$dir" someagent
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "an unverified harness should refuse"
  assert_contains "$out" "no verified control mechanics" "refusal should name the missing verification"
  [ -z "$(literals "$dir")" ] || fail "an unverified harness must receive no bytes"
  pass "fm-control: a harness with no verified control mechanics is refused, not guessed at"
}

# --- 2. backend capability matrix -------------------------------------------

test_backend_key_capability_matrix() {
  local backend key
  for backend in tmux herdr; do
    for key in Escape Enter C-c C-u; do
      fm_control_backend_supports_key "$backend" "$key" \
        || fail "$backend should be able to deliver $key"
    done
  done
  pass "fm-control-lib: the backend key matrix matches each adapter's real send-key surface"
}

# A verified adapter is not automatically verified for every task kind, and the
# check has to sit on the pre-stop side of a relaunch, because
# discovering that only after the running agent was stopped would strand the
# secondmate with no agent at all.
test_harness_kind_capability() {
  local harness
  for harness in $VERIFIED_HARNESSES; do
    fm_control_harness_supports_kind "$harness" ship \
      || fail "$harness should be able to run a ship task"
    fm_control_harness_supports_kind "$harness" scout \
      || fail "$harness should be able to run a scout task"
  done
  for harness in claude codex opencode pi pi-signed; do
    fm_control_harness_supports_kind "$harness" secondmate \
      || fail "$harness should be able to run a secondmate"
  done
  fm_control_harness_supports_kind someagent ship \
    && fail "an unverified harness must not claim any kind"
  pass "fm-control-lib: adapter capability is per task kind, not per adapter alone"
}


test_state_verified_backends_are_exactly_tmux_and_herdr() {
  fm_control_backend_state_verified tmux || fail "tmux has a recovery-grade classifier"
  fm_control_backend_state_verified herdr || fail "herdr has a recovery-grade classifier"
  fm_control_backend_state_verified cmux \
    && fail "cmux has no recovery-grade classifier and must not claim one"
  pass "fm-control-lib: stop-proving verbs are gated on the backends that really classify agent state"
}

# --- 3. exact-id scoping ----------------------------------------------------

test_window_label_is_refused_with_the_exact_id() {
  local dir out rc
  dir=$(new_case label)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" fm-t1 exit); rc=$?
  expect_code 1 "$rc" "a window label should refuse"
  assert_contains "$out" "pass the exact task id 't1'" "the refusal should name the exact id"
  [ -z "$(literals "$dir")" ] || fail "a refused target must receive no bytes"
  pass "fm-control: a legacy window label is refused and the exact task id is named"
}

test_explicit_endpoint_is_refused() {
  local dir out rc
  dir=$(new_case endpoint)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" "fmses:fm-t1" exit); rc=$?
  expect_code 1 "$rc" "an explicit endpoint should refuse"
  assert_contains "$out" "exact task id only" "the refusal should name the exact-id rule"
  [ -z "$(literals "$dir")" ] || fail "a refused target must receive no bytes"
  pass "fm-control: an explicit backend endpoint is never a control target"
}

test_unknown_task_is_refused() {
  local dir out rc
  dir=$(new_case unknown)
  add_task "$dir" t1 claude
  out=$(run_control "$dir" t2 exit); rc=$?
  expect_code 1 "$rc" "an unknown task should refuse"
  assert_contains "$out" "no task 't2'" "the refusal should name the missing task"
  pass "fm-control: an unrecorded task id is refused"
}

test_record_bound_to_another_task_is_refused() {
  local dir out rc
  dir=$(new_case foreign)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  sed 's/^endpoint_task_id=t1$/endpoint_task_id=other/' "$dir/home/state/t1.meta" \
    > "$dir/home/state/t1.meta.tmp"
  mv "$dir/home/state/t1.meta.tmp" "$dir/home/state/t1.meta"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "a record bound to another task should refuse"
  assert_contains "$out" "belongs to task other" "the refusal should name the conflicting binding"
  [ -z "$(literals "$dir")" ] || fail "a foreign record must receive no bytes"
  pass "fm-control: a record whose endpoint identity names another task is refused"
}

# A remotely placed secondmate's agent runs on another host, so none of the
# postconditions this plane verifies could be read for it here. Endpoint
# validation would refuse the record anyway - `window=remote:<id>` can never
# match a local backend's shape - but it would blame malformed metadata for a
# correctly configured route, so the placement is named instead. Every verb
# refuses, and none of them reaches a local endpoint.
test_remote_secondmate_is_refused_by_placement() {
  local dir out rc verb
  for verb in interrupt exit relaunch; do
    dir=$(new_case "remote-$verb")
    add_task "$dir" t1 claude secondmate
    alive_as "$dir" claude
    {
      grep -v '^window=' "$dir/home/state/t1.meta"
      echo "window=remote:t1"
      echo "home=$dir/wt-t1"
      echo "remote_host=example.invalid"
      echo "remote_root=/srv/fm"
      echo "remote_backend=herdr"
      echo "remote_target=fm:pane-1"
    } > "$dir/home/state/t1.meta.tmp"
    mv "$dir/home/state/t1.meta.tmp" "$dir/home/state/t1.meta"
    if [ "$verb" = relaunch ]; then
      out=$(run_control "$dir" t1 "$verb" --note "x"); rc=$?
    else
      out=$(run_control "$dir" t1 "$verb"); rc=$?
    fi
    expect_code 1 "$rc" "$verb on a remotely placed secondmate should refuse"
    assert_contains "$out" "remotely placed secondmate on example.invalid" \
      "the $verb refusal should name the remote placement, not blame the record"
    assert_not_contains "$out" "malformed" \
      "a correctly configured remote route must not be reported as malformed"
    [ -z "$(literals "$dir")" ] && [ -z "$(keys_sent "$dir")" ] \
      || fail "$verb on a remote secondmate must reach no local endpoint"
  done
  pass "fm-control: a remotely placed secondmate is refused by placement, not by a metadata complaint"
}

hold_lifecycle_lock() {  # <lock-path>
  local lifecycle_lock_path=$1
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$lifecycle_lock_path" || return 1
  sleep 30
}

test_interrupt_and_exit_lock_before_task_state_resolution() {
  local case_dir out rc verb lifecycle_lock_path holder i
  for verb in interrupt exit; do
    case_dir=$(new_case "locked-$verb")
    add_task "$case_dir" t1 claude
    alive_as "$case_dir" claude
    lifecycle_lock_path="$case_dir/home/state/.control-t1.lock"
    hold_lifecycle_lock "$lifecycle_lock_path" &
    holder=$!
    i=0
    while [ ! -e "$lifecycle_lock_path" ] && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    [ -e "$lifecycle_lock_path" ] || fail "could not stage the lifecycle lock for $verb"
    sed 's/^endpoint_task_id=t1$/endpoint_task_id=other/' "$case_dir/home/state/t1.meta" \
      > "$case_dir/home/state/t1.meta.tmp"
    mv "$case_dir/home/state/t1.meta.tmp" "$case_dir/home/state/t1.meta"
    out=$(run_control "$case_dir" t1 "$verb"); rc=$?
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    expect_code 1 "$rc" "$verb should refuse a held lifecycle lock"
    assert_contains "$out" "another lifecycle action is already running" \
      "$verb should serialize before reading mutable task state"
    [ -z "$(literals "$case_dir")" ] || fail "contended $verb must type no command"
    [ -z "$(keys_sent "$case_dir")" ] || fail "contended $verb must send no control key"
  done
  pass "fm-control: interrupt and exit lock before task-state resolution"
}

# --- 4. verb allowlist ------------------------------------------------------

test_verb_allowlist_is_closed() {
  local dir out rc
  dir=$(new_case verbs)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" t1 restart); rc=$?
  expect_code 2 "$rc" "an unknown verb should be a usage error"
  assert_contains "$out" "is not a control verb" "the refusal should say so"
  assert_contains "$out" "interrupt" "the refusal should list the allowed verbs"
  out=$(run_control "$dir" t1 --key); rc=$?
  expect_code 2 "$rc" "a raw key is not a control verb"
  out=$(run_control "$dir" t1 clear); rc=$?
  expect_code 2 "$rc" "clear is not a control verb"
  out=$(run_control "$dir" t1 "please stop what you are doing"); rc=$?
  expect_code 2 "$rc" "arbitrary text is not a control verb"
  [ -z "$(literals "$dir")" ] || fail "a refused verb must send nothing"
  [ -z "$(keys_sent "$dir")" ] || fail "a refused verb must send no keys"
  pass "fm-control: the verb list is closed - no raw keys, arbitrary text, or clear verb"
}

test_resume_is_refused_with_its_reason() {
  local dir out rc
  dir=$(new_case resume)
  add_task "$dir" t1 claude
  out=$(run_control "$dir" t1 resume); rc=$?
  expect_code 2 "$rc" "resume should be refused"
  assert_contains "$out" "not deterministic across the verified adapters" \
    "the refusal should explain why resume is excluded"
  assert_contains "$out" "relaunch" "the refusal should point at the deterministic alternative"
  pass "fm-control: resume is refused with the determinism reason and the alternative"
}

test_relaunch_only_flags_are_rejected_on_other_verbs() {
  local dir out rc
  dir=$(new_case flags)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  out=$(run_control "$dir" t1 exit --harness codex); rc=$?
  expect_code 1 "$rc" "--harness should not apply to exit"
  assert_contains "$out" "apply to 'relaunch' only" "the refusal should scope the flags"
  pass "fm-control: profile and note flags belong to relaunch only"
}

# --- 5. lifecycle states ----------------------------------------------------

test_worker_resource_cleanup() {
  local dir out rc
  dir=$(new_case resources)
  add_task "$dir" t1 claude
  printf 'spawn_gen=test\nprocess_scope=%s/state/t1:test\n' "$dir/home" >> "$dir/home/state/t1.meta"
  # The helper uses only disposable real children, including a detached child
  # that clears its environment on Linux (the browser MCP failure mode).
  python3 - "$ROOT" "$dir" <<'PY' || fail 'worker cleanup fixture failed'
import os, pathlib, shlex, subprocess, sys, time
root, directory = map(pathlib.Path, sys.argv[1:])
tool = root / 'bin/fm-worker-processes.py'
scope = f'{directory}/home/state/t1:test'
fixture = directory / 'children.py'
fixture.write_text('''import os,subprocess,sys,time
from pathlib import Path
env={} if sys.platform=='linux' else os.environ.copy()
child=subprocess.Popen(['sleep','60'],env=env,start_new_session=True)
Path(sys.argv[1]).write_text(str(child.pid))
if len(sys.argv)>2: time.sleep(60)
''')
def launch(scope, path, hold=False):
    command = shlex.join([sys.executable, str(fixture), str(path)] + (['hold'] if hold else []))
    return subprocess.Popen([sys.executable,str(tool),'run',scope,command],
                            env=dict(os.environ,FM_WORKER_PROCESS_SCOPE=scope))
def ready(path):
    for _ in range(100):
        if path.exists(): return
        time.sleep(.1)
    raise AssertionError('fixture did not launch')
natural = launch(scope, directory/'natural.pid')
assert natural.wait(timeout=15)==0
pid=int((directory/'natural.pid').read_text())
try: os.kill(pid,0)
except ProcessLookupError: pass
else: raise AssertionError('automatic close leaked its detached child')
worker=launch(scope,directory/'worker.pid',True)
other=launch(scope+'-other-home',directory/'other.pid',True)
for path in ['worker.pid','other.pid']: ready(directory/path)
(directory/'wrappers').write_text(f'{worker.pid} {other.pid}')
PY
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "already-stopped exit must reclaim resources: $out"
  python3 - "$ROOT" "$dir" <<'PY' || fail 'worker resource ownership regression'
import os,pathlib,subprocess,sys
root,directory=map(pathlib.Path,sys.argv[1:])
def alive(pid):
    result=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')
worker,other=map(int,(directory/'wrappers').read_text().split())
try:
    assert not alive(worker), 'exit leaked wrapper'
    assert not alive(int((directory/'worker.pid').read_text())), 'exit leaked child'
    assert alive(other), 'exit touched another scope'
    assert alive(int((directory/'other.pid').read_text())), 'exit touched another child'
finally:
    os.kill(other,15)
PY
  pass "worker return and already-stopped exit reclaim detached resources without touching another scope"
}

test_worker_wrapper_reaps_orphans_while_running() {
  local dir
  dir=$(new_case reap)
  python3 - "$ROOT" "$dir" <<'PY' || fail 'a running worker wrapper left exited orphans as zombies'
import os, pathlib, shlex, subprocess, sys, time
root, directory = map(pathlib.Path, sys.argv[1:])
scope = f'{directory}/home/state/t1:reap'
# The worker double-forks short-lived orphans and keeps running.
command = 'for i in 1 2 3 4 5; do (sleep 0.1 &) ; done; sleep 3'
wrapper = subprocess.Popen([sys.executable, str(root/'bin/fm-worker-processes.py'), 'run', scope, command],
                           env=dict(os.environ, FM_WORKER_PROCESS_SCOPE=scope))
time.sleep(1.5)
out = subprocess.run(['ps', '-o', 'stat=', '--ppid', str(wrapper.pid)], capture_output=True, text=True).stdout
zombies = [s for s in out.split() if s.startswith('Z')]
assert wrapper.wait(timeout=15) == 0, 'wrapper must return the worker exit code'
if sys.platform == 'linux':
    assert not zombies, f'{len(zombies)} zombie(s) under a running wrapper'
PY
  pass "a running worker wrapper reaps exited orphans immediately and keeps the worker exit code"
}

test_worker_wrapper_owns_one_private_session_bus() {
  local dir
  if [ "$(uname -s)" != Linux ] || ! command -v dbus-daemon >/dev/null 2>&1; then
    printf 'skip: worker session bus: Linux dbus-daemon absent\n'
    return 0
  fi
  dir=$(new_case bus)
  python3 - "$ROOT" "$dir" <<'PY' || fail 'a worker without a session bus must get one private bus that dies with it'
import os, pathlib, subprocess, sys
root, directory = map(pathlib.Path, sys.argv[1:])
scope = f'{directory}/home/state/t1:bus'
env = {k: v for k, v in os.environ.items() if k != 'DBUS_SESSION_BUS_ADDRESS'}
env['FM_WORKER_PROCESS_SCOPE'] = scope
out = subprocess.run([sys.executable, str(root/'bin/fm-worker-processes.py'), 'run', scope,
                      'echo "$DBUS_SESSION_BUS_ADDRESS"; echo "$DBUS_SESSION_BUS_ADDRESS"'],
                     env=env, capture_output=True, text=True, timeout=30)
assert out.returncode == 0, out.stderr
first, second = out.stdout.split()
assert first == second and first.startswith('unix:path='), out.stdout
socket = first.split('=', 1)[1].split(',')[0]
assert socket not in pathlib.Path('/proc/net/unix').read_text(), 'private bus outlived its worker'
PY
  pass "a worker launched without a session bus gets one private bus that closes with the worker"
}

test_already_stopped_exit_is_idempotent() {
  local dir out rc
  dir=$(new_case idempotent)
  add_task "$dir" t1 claude
  alive_as "$dir" zsh
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exiting an already-stopped agent should succeed"
  assert_contains "$out" "already-stopped t1" "the outcome should say it was already stopped"
  [ -z "$(literals "$dir")" ] || fail "an already-stopped agent must not be sent an exit command"
  pass "fm-control exit: an already-stopped agent is idempotent success with no bytes sent"
}

test_missing_tmux_endpoint_refuses_rather_than_claiming_a_stop() {
  local dir out rc
  dir=$(new_case gone)
  add_task "$dir" t1 claude
  : > "$dir/fake/windows"
  out=$(run_control "$dir" t1 exit); rc=$?
  # `missing` on tmux is not a finding about the endpoint. A task record carries
  # no socket identity for it, and any inventory describes only the tmux server
  # this process addresses, so a window that is merely on a server this seat
  # cannot reach is indistinguishable from one that was destroyed. exit refuses
  # rather than claim a stop it cannot see, and sends nothing to an address it
  # cannot trust. Reclaim of a destroyed endpoint is Herdr-only
  # (docs/agent-control.md "Reclaiming a task whose endpoint is gone").
  expect_code 1 "$rc" "a tmux endpoint whose absence cannot be proven must refuse"
  assert_not_contains "$out" "endpoint-gone" "exit must not report a stop it could not prove"
  [ -z "$(literals "$dir")" ] || fail "nothing may be sent into an endpoint exit cannot trust"
  pass "fm-control exit: an unprovable tmux endpoint refuses instead of claiming the agent stopped"
}

test_interrupt_refuses_when_no_agent_runs() {
  local dir out rc
  dir=$(new_case nointerrupt)
  add_task "$dir" t1 claude
  alive_as "$dir" zsh
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 1 "$rc" "interrupting a stopped agent should refuse"
  assert_contains "$out" "nothing to interrupt" "the refusal should say there is no agent"
  [ -z "$(keys_sent "$dir")" ] || fail "no key should reach a stopped agent"
  pass "fm-control interrupt: refuses when no agent is running rather than keying a shell"
}

test_ambiguous_endpoint_refuses() {
  local dir out rc
  dir=$(new_case ambiguous)
  add_task "$dir" t1 claude
  alive_as "$dir" some-unrelated-process
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "an unattributed endpoint should refuse"
  assert_contains "$out" "positively classified" "the refusal should name the missing attribution"
  [ -z "$(literals "$dir")" ] || fail "an unattributed endpoint must receive no bytes"
  pass "fm-control exit: an endpoint whose process cannot be attributed refuses"
}

test_busy_agent_is_interrupted_before_the_exit_command() {
  local dir out rc
  dir=$(new_case busy)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  # Arm the semantic busy contract and record a busy turn, exactly as the
  # harness's own lifecycle hook would.
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exiting a busy agent should succeed"$'\n'"$out"
  [ "$(keys_sent "$dir")" = "Escape" ] \
    || fail "a busy agent should be interrupted once before its exit command, got: $(keys_sent "$dir")"
  [ "$(literals "$dir")" = "/exit" ] || fail "the exit command should follow the interrupt"
  pass "fm-control exit: a busy agent receives interrupt delivery before the exit command"
}

exit_picker_screen() {
  printf '%s\n' \
    'Background work is running' \
    '❯ 1. Exit and stop tasks' \
    'The following will stop when you exit:' \
    'shell · sleep 300' \
    '  2. Move to background and exit' \
    '  3. Stay' \
    'Enter to confirm · Esc to cancel'
}

test_exit_refuses_an_open_background_picker() {
  local dir out rc
  dir=$(new_case open-picker)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  exit_picker_screen > "$dir/fake/pane"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 1 "$rc" "an open exit picker should refuse"$'\n'"$out"
  assert_contains "$out" "blocked on a prompt: Claude background-task exit picker" \
    "the refusal should name the dialog"
  assert_not_contains "$out" "Esc" "the refusal must not name a dismissal key"
  [ ! -s "$dir/fake/literal" ] || fail "an open picker must not be typed into"
  [ ! -s "$dir/fake/keys" ] || fail "an open picker must receive no keys"
  pass "fm-control exit: an already-open background-task picker is not typed into"
}

test_exit_refuses_the_confirming_enter() {
  local dir out rc enters
  dir=$(new_case confirm-picker)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  exit_picker_screen > "$dir/fake/after-enter"
  out=$(env FM_FAKE_NEVER_DIES=1 PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_FAKE_DIR="$dir/fake" FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    "$CONTROL" t1 exit 2>&1); rc=$?
  expect_code 1 "$rc" "the confirming Enter should refuse"$'\n'"$out"
  assert_contains "$out" "blocked on a prompt: Claude background-task exit picker" \
    "the refusal should name the dialog"
  assert_not_contains "$out" "Esc" "the refusal must not name a dismissal key"
  [ "$(literals "$dir")" = /exit ] || fail "the exit command should still be typed, got '$(literals "$dir")'"
  enters=$(grep -c '^Enter$' "$dir/fake/keys" || true)
  [ "$enters" -eq 1 ] || fail "only the submitting Enter should be sent, got $enters"
  pass "fm-control exit: the Enter that opens the background-task picker is not followed by a confirming Enter"
}

# The submit reads a cleared composer before the picker renders, so it reports
# delivery and no read inside it sees the picker. Exit's own read after the
# stop wait times out must still name the dialog.
test_exit_names_a_picker_that_renders_after_the_submit() {
  local dir out rc enters
  dir=$(new_case late-picker)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  exit_picker_screen > "$dir/fake/after-enter"
  printf '1' > "$dir/fake/after-enter-late"
  out=$(env FM_FAKE_NEVER_DIES=1 PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_FAKE_DIR="$dir/fake" FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    "$CONTROL" t1 exit 2>&1); rc=$?
  expect_code 1 "$rc" "a picker that renders after the submit should refuse"$'\n'"$out"
  [ "$(cat "$dir/fake/after-enter-late")" = 0 ] \
    || fail "the submit should have read the ordinary pane once after Enter"
  assert_contains "$out" "blocked on a prompt: Claude background-task exit picker" \
    "the refusal should name the dialog"
  assert_not_contains "$out" "did not stop within" \
    "a recognised picker must not fall back to the generic timeout message"
  enters=$(grep -c '^Enter$' "$dir/fake/keys" || true)
  [ "$enters" -eq 1 ] || fail "only the submitting Enter should be sent, got $enters"
  pass "fm-control exit: a picker that renders after the submit returned is named when the stop wait times out"
}

test_idle_agent_is_not_interrupted() {
  local dir out rc gen
  dir=$(new_case idle)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1 --state idle --source fm-spawn --event seed)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exiting an idle agent should succeed"$'\n'"$out"
  [ -z "$(keys_sent "$dir")" ] \
    || fail "an idle agent needs no interrupt, got keys: $(keys_sent "$dir")"
  [ "$(literals "$dir")" = "/exit" ] || fail "the exit command should still be sent"
  pass "fm-control exit: an idle agent goes straight to its exit command"
}

test_exit_drops_meta_busy_gen_with_the_sidecar() {
  local dir out rc gen changed
  dir=$(new_case codex-retire)
  add_task "$dir" t1 codex
  alive_as "$dir" codex
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  grep -v '^busy_gen=' "$dir/home/state/t1.meta" > "$dir/expected.meta"
  out=$(run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exiting a codex agent should succeed"$'\n'"$out"
  [ ! -e "$dir/home/state/t1.busy-gen" ] && [ ! -e "$dir/home/state/t1.busy-state" ] \
    || fail "exit should retire the busy sidecar and record"
  changed=$(diff "$dir/expected.meta" "$dir/home/state/t1.meta") \
    || fail "exit should drop only busy_gen from the task record:"$'\n'"$changed"
  pass "fm-control exit: retiring a codex incarnation drops busy_gen with the sidecar"
}

test_interrupt_without_acknowledgement_preserves_busy_state() {
  local dir gen before after out rc
  dir=$(new_case unconfirmed)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  before=$(cat "$dir/home/state/t1.busy-state")
  out=$(run_control "$dir" t1 interrupt); rc=$?
  expect_code 0 "$rc" "an interrupt without acknowledgement should still deliver"$'\n'"$out"
  after=$(cat "$dir/home/state/t1.busy-state")
  grep -q "^busy_gen=$gen$" "$dir/home/state/t1.meta" \
    || fail "an interrupt must leave the task record's busy_gen in place"
  [ "$after" = "$before" ] || fail "an unconfirmed interrupt must preserve adapter-owned busy state"
  assert_contains "$out" "verified=agent-alive cancel=unconfirmed" \
    "the result should distinguish delivery proof from unconfirmed cancellation"
  assert_not_contains "$out" "cancel=confirmed" \
    "an adapter without acknowledgement must not report cancellation"
  pass "fm-control interrupt: unconfirmed delivery preserves observed busy state"
}

test_exit_accepts_agent_stopped_by_busy_interrupt() {
  local dir out rc gen
  dir=$(new_case interrupt-stops)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(FM_FAKE_INTERRUPT_STOPS_AGENT=1 run_control "$dir" t1 exit); rc=$?
  expect_code 0 "$rc" "exit should accept a busy agent stopped by interrupt"$'\n'"$out"
  assert_contains "$out" "stopped t1 harness=claude" \
    "the authoritative gone-state should complete exit successfully"
  [ "$(keys_sent "$dir")" = Escape ] \
    || fail "exit should deliver the busy agent's interrupt sequence"
  [ -z "$(literals "$dir")" ] \
    || fail "exit should not type a command after interrupt already stopped the agent"
  [ ! -e "$dir/home/state/t1.busy-gen" ] && [ ! -e "$dir/home/state/t1.busy-state" ] \
    || fail "exit should retire busy wiring for an agent stopped by interrupt"
  pass "fm-control exit: an interrupt-stopped agent satisfies the gone-state postcondition"
}

test_agent_that_does_not_stop_fails_closed() {
  local dir out rc gen
  dir=$(new_case stubborn)
  add_task "$dir" t1 claude
  alive_as "$dir" claude
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" t1)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/t1.meta"
  out=$(env FM_FAKE_NEVER_DIES=1 PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_FAKE_DIR="$dir/fake" FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    "$CONTROL" t1 exit 2>&1); rc=$?
  expect_code 1 "$rc" "an agent that ignores its exit command should fail closed"
  assert_contains "$out" "did not stop" "the failure should say the agent did not stop"
  assert_contains "$out" "exit-delivered t1 interrupt=delivered verified=agent-alive cancel=unconfirmed exit-command=delivered agent-state=alive exit=unconfirmed" \
    "the failure should distinguish delivered lifecycle input from the unconfirmed exit"
  assert_not_contains "$out" "nothing was changed" \
    "the failure must not deny the lifecycle input that was delivered"
  [ "$(keys_sent "$dir")" = Escape ] \
    || fail "a stubborn busy agent should receive its interrupt sequence"
  [ "$(literals "$dir")" = /exit ] \
    || fail "a stubborn busy agent should receive its exit command"
  grep -q "^busy_gen=$gen$" "$dir/home/state/t1.meta" \
    || fail "a failed exit must leave busy_gen in the task record"
  pass "fm-control exit: a stubborn agent reports delivered input and an unconfirmed exit"
}



# --- 6. marker non-regression -----------------------------------------------

test_secondmate_control_command_carries_no_marker() {
  local dir out rc typed home
  dir=$(new_case sm-marker)
  home="$dir/home"
  add_task "$dir" domain claude secondmate
  # A secondmate's worktree IS its home; give it the marker its records need.
  printf '%s\n' domain > "$dir/wt-domain/.fm-secondmate-home"
  alive_as "$dir" claude
  out=$(run_control "$dir" domain exit); rc=$?
  expect_code 0 "$rc" "exiting a secondmate's agent should succeed"$'\n'"$out"
  typed=$(literals "$dir")
  [ "$typed" = "/exit" ] \
    || fail "a secondmate control command must be the bare exit command, got: $typed"
  case "$typed" in
    *"$FM_FROMFIRST_MARK"*) fail "a control command must never carry the from-firstmate marker" ;;
  esac
  case "$typed" in
    *corr=*) fail "a control command must never carry a pending-reply correlation id" ;;
  esac
  [ -z "$(find "$home/state/pending-replies" -type f 2>/dev/null | head -n 1)" ] \
    || fail "a control command must not open a pending-reply expectation"
  pass "fm-control: a lifecycle command to a secondmate is unmarked and opens no reply expectation"
}

test_fm_send_still_marks_the_same_secondmate_task() {
  local dir log out rc
  dir=$(new_case sm-send)
  add_task "$dir" domain claude secondmate
  log="$dir/fake/sendlog"
  : > "$log"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SEND_SETTLE=0 FM_ROOT_OVERRIDE="$dir/home" \
    "$SEND" domain "audit the build" 2>&1); rc=$?
  expect_code 0 "$rc" "fm-send to a secondmate should still succeed"$'\n'"$out"
  # The marked steer rides fm-send's durable inbox plane; only the doorbell is
  # typed, so the marker is asserted on the recorded body.
  case "$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
    "$dir/home/state/domain.inbox/001.msg")" in
    "$FM_FROMFIRST_MARK"*) : ;;
    *) fail "fm-send must still mark a kind=secondmate target: $(literals "$dir")" ;;
  esac
  pass "fm-control's arrival leaves fm-send's from-firstmate marking untouched"
}

# Only an adapter whose runtime records an exact per-pane agent session has a
# relaunch resume form, and only a reference its OWN agent reported may be
# handed to it: resuming another adapter's reference would inject that agent's
# conversation into this launch. Every other pair must print nothing so the
# relaunch stays a fresh session exactly as it does today.
test_relaunch_resume_flag_is_per_adapter_and_reference_owner() {
  local got harness label want
  # (harness | registered agent label | expected flag) lines, written out
  # independently of the implementation.
  local cases='pi|pi|--session
pi-signed|pi|--session
pi||
pi-signed||
pi|codex|
pi-signed|claude|
claude|claude|
codex|codex|
opencode|opencode|
cursor|cursor|
'
  while IFS='|' read -r harness label want; do
    [ -n "$harness" ] || continue
    got=$(fm_control_relaunch_resume_flag "$harness" "$label") \
      || fail "the resume-flag lookup must never fail; it did for '$harness'/'$label'"
    [ "$got" = "$want" ] \
      || fail "$harness with a '$label' registration should print '$want', got '$got'"
  done <<EOF
$cases
EOF
  pass "fm-control-lib: only a runtime's own recorded session has a relaunch resume form"
}

test_exit_types_each_harness_verified_command
test_opencode_exit_matches_recorded_major
test_opencode2_exit_retries_ctrl_c_once
test_interrupt_sends_each_harness_verified_key
test_opencode_interrupts_twice_and_others_once
test_unverified_harness_is_refused
test_harness_family_resolution
test_relaunch_resume_flag_is_per_adapter_and_reference_owner
test_prefixed_recorded_harness_reaches_each_control_verb
test_backend_key_capability_matrix
test_harness_kind_capability
test_state_verified_backends_are_exactly_tmux_and_herdr
test_window_label_is_refused_with_the_exact_id
test_explicit_endpoint_is_refused
test_unknown_task_is_refused
test_record_bound_to_another_task_is_refused
test_remote_secondmate_is_refused_by_placement
test_interrupt_and_exit_lock_before_task_state_resolution
test_verb_allowlist_is_closed
test_resume_is_refused_with_its_reason
test_relaunch_only_flags_are_rejected_on_other_verbs
test_worker_resource_cleanup
test_worker_wrapper_reaps_orphans_while_running
test_worker_wrapper_owns_one_private_session_bus
test_already_stopped_exit_is_idempotent
test_missing_tmux_endpoint_refuses_rather_than_claiming_a_stop
test_interrupt_refuses_when_no_agent_runs
test_ambiguous_endpoint_refuses
test_busy_agent_is_interrupted_before_the_exit_command
test_idle_agent_is_not_interrupted
test_exit_drops_meta_busy_gen_with_the_sidecar
test_exit_refuses_an_open_background_picker
test_exit_refuses_the_confirming_enter
test_exit_names_a_picker_that_renders_after_the_submit
test_interrupt_without_acknowledgement_preserves_busy_state
test_exit_accepts_agent_stopped_by_busy_interrupt
test_agent_that_does_not_stop_fails_closed
test_secondmate_control_command_carries_no_marker
test_fm_send_still_marks_the_same_secondmate_task
