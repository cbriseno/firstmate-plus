#!/usr/bin/env bash
# Live guard for bin/fm-busy-lib.sh's launch-prompt backstop (live-harness-optin
# family). Per .agents/skills/firstmate-coding-guidelines "Harness-dependent
# checks", a classifier built on vendor-rendered dialog text must be proven
# against the REAL installed harness, because a stub can only confirm the
# assumption already written into the stub - and this guard exists because that
# assumption was wrong once already: an initial Pi signature, sourced only from
# the installed binary's own UI strings ("Project trust", an internal panel
# title never rendered as the dialog's own heading), silently never matched the
# real screen ("Trust project folder?") until this guard's first live run
# caught it.
#
# For each of claude, pi (covering pi-signed, which share Pi's engine
# and trust gate) that is actually installed, this drives the REAL
# binary in an isolated tmux server into its genuine interactive launch prompt
# (a fresh untrusted worktree carrying a project-local trust-requiring
# resource for claude and pi),
# captures the pane with the exact production shape (bin/fm-backend.sh's
# fm_backend_tmux_capture: `tmux capture-pane -p -S -40`), arms a scratch
# busy-state record exactly as fm-spawn.sh does at launch, and requires
# fm_busy_classify to report `unknown launch-prompt` instead of the record's
# seeded `busy fm-spawn`. No prompt is ever submitted and no dialog is ever
# answered (Escape only, never Enter), so no model tokens are spent and no
# operator credential store is written to. An absent harness binary is
# reported explicitly and skipped rather than silently passing over it; a run
# that checked nothing fails.
#
# Precondition: this machine's default `claude` config must already be past
# first-run onboarding (a subscription or API key already selected, and a
# theme already chosen) - the guard targets a brand-new SCRATCH WORKTREE under
# the operator's own already-onboarded config, exactly the shape a real
# crewmate spawn produces, never a fresh CLAUDE_CONFIG_DIR. An unonboarded
# machine reports that precondition explicitly rather than failing the
# signature.
#
# Codex also supplies a real wrapped folder dialog, replayed without writing
# its trust store, to guard the startup dialog path comparison.
#
# Run explicitly with FM_LAUNCH_PROMPT_SIGNALS_LIVE=1. Refresh
# docs/verification/runtime-backends.md ("Launch-prompt backstop signatures")
# from this guard's output after any of claude/pi upgrades.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-launch-prompt-$$"
CHECKED=0
LABS=()

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  local lab
  for lab in "${LABS[@]:-}"; do
    [ -z "$lab" ] || fm_test_remove_tree "$lab"
  done
}
trap cleanup_all EXIT

# shellcheck source=tests/reporter.sh
. "$(dirname "${BASH_SOURCE[0]}")/reporter.sh"
fail() { fm_test_fail "$1"; }

fm_live_gate opt-in FM_LAUNCH_PROMPT_SIGNALS_LIVE tmux

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
EV="$ROOT/bin/fm-busy-event.sh"

# watcher_gate_not_busy: exercise the watcher's production absorb predicate on
# the same real pane capture. The custom tmux socket is intentionally not the
# watcher's default socket, so this checks the pure semantic gate with the
# recorded target while the harness itself remains a real live pane.
watcher_gate_not_busy() {  # <lab> <state> <target> <harness> <tail>
  local lab=$1 state=$2 target=$3 harness=$4 tail=$5
  mkdir -p "$lab/config"
  printf 'window=%s\nbackend=tmux\nharness=%s\n' "$target" "$harness" > "$state/t1.meta"
  FM_ROOT_OVERRIDE="$ROOT"
  FM_HOME="$lab"
  FM_STATE_OVERRIDE="$state"
  FM_CONFIG_OVERRIDE="$lab/config"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  if window_is_busy "$target" "$tail"; then
    fail "$harness: the watcher still treats the real parked prompt as busy"
  fi
}

# check_harness: launch <harness> (checked with fm_busy_classify, which may
# differ from the tmux <session> name when several harnesses share one real
# binary) via <cmd...> into a fresh worktree carrying <extra-file>
# (path,content - empty means none), wait up to 15s for <expect-regex> to
# render, capture the pane the production way, arm a scratch busy-state
# record, and require the launch-prompt backstop to classify it unknown
# launch-prompt. Never answers the dialog: Escape only, never Enter.
#
# Writes the captured tail to <tail-out> rather than returning it on stdout:
# a caller that needs the tail (the Pi case, which reuses it for pi-signed and
# omp) must NOT wrap this whole function in a command substitution just to
# capture that output, because `fail` calls `exit`, and `exit` inside a
# `$(...)` subshell only ends that subshell - a real failure would be silently
# swallowed there instead of failing the guard.
check_harness() {  # <harness> <session> <extra-path> <extra-content> <expect-regex> <tail-out> <cmd...>
  local harness=$1 session=$2 extra_path=$3 extra_content=$4 expect=$5 tail_out=$6
  local target="$session:w" lab state tail out
  shift 6
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-launch-prompt-$harness.XXXXXX") || fail "$harness: could not create the isolated lab"
  LABS+=("$lab")
  mkdir -p "$lab/wt"
  git -C "$lab/wt" init -q || fail "$harness: could not initialize the isolated worktree"
  if [ -n "$extra_path" ]; then
    mkdir -p "$lab/wt/$(dirname "$extra_path")"
    printf '%s' "$extra_content" > "$lab/wt/$extra_path"
  fi

  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$session" -n w -c "$lab/wt" -- "$@" \
    || fail "$harness: could not launch the real binary"

  tail=''
  for _ in $(seq 1 75); do
    tail=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S -40 2>/dev/null) || true
    printf '%s' "$tail" | grep -qiE "$expect" && break
    sleep 0.2
  done
  if ! printf '%s' "$tail" | grep -qiE "$expect"; then
    "$REAL_TMUX" -L "$SOCKET" kill-session -t "$session" >/dev/null 2>&1 || true
    fail "$harness: the real launch never rendered its expected prompt ('$expect') within 15s - captured tail:
$tail"
  fi

  state="$lab/state"
  mkdir -p "$state"
  "$EV" arm "$state" t1 >/dev/null || fail "$harness: could not arm the scratch busy-state record"
  out=$(fm_busy_classify tmux w1 "$harness" t1 "$state" "$tail")
  [ "$out" = "unknown launch-prompt" ] \
    || fail "$harness: real launch parked on its prompt classified '$out', expected 'unknown launch-prompt'"
  watcher_gate_not_busy "$lab" "$state" "$target" "$harness" "$tail"

  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Escape >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" kill-session -t "$session" >/dev/null 2>&1 || true
  CHECKED=$((CHECKED + 1))
  [ -z "$tail_out" ] || printf '%s' "$tail" > "$tail_out"
}

CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
if [ -x "${CLAUDE_BIN:-}" ] && [ "${FM_TEST_CODEX_WRAPPED_ONLY:-0}" != 1 ]; then
  VERSION_OUT=$("$CLAUDE_BIN" --version 2>&1) || fail "claude --version failed: $VERSION_OUT"
  note "live claude version: $VERSION_OUT"
  check_harness claude fm-lp-claude-$$ '' '' \
    'Is this a project you created or one you trust' '' \
    "$CLAUDE_BIN" --dangerously-skip-permissions hello
  pass "claude: a real launch parked on its own rendered trust dialog surfaces through the watcher gate"
elif [ "${FM_TEST_CODEX_WRAPPED_ONLY:-0}" = 1 ]; then
  note "claude check excluded by focused Codex run"
else
  note "claude not installed - launch-prompt signature not checked"
fi

# Capture Codex's real wrapped folder dialog without answering it or writing its
# trust store, then replay that exact screen through the production dialog code.
CODEX_BIN=$(command -v codex 2>/dev/null || true)
if [ -x "${CODEX_BIN:-}" ]; then
  VERSION_OUT=$("$CODEX_BIN" --version 2>&1) || fail "codex --version failed: $VERSION_OUT"
  note "live codex version: $VERSION_OUT"
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-wrapped-folder.XXXXXX") || fail "codex $VERSION_OUT: cannot create lab"
  LABS+=("$lab")
  folder="$lab/a-long-project-directory-to-force-the-folder-access-path-to-wrap-in-the-terminal"
  mkdir -p "$folder"
  git -C "$folder" init -q || fail "codex $VERSION_OUT: cannot initialize lab"
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s codex-real -n w -x 80 -y 35 -c "$folder" "$CODEX_BIN" || fail "codex $VERSION_OUT: launch failed"
  tail=''
  update_skipped=0
  for _ in $(seq 1 300); do
    tail=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t codex-real:w -S -40 2>/dev/null) || true
    printf '%s' "$tail" | grep -q 'Trust this folder?' && break
    if [ "$update_skipped" = 0 ] && printf '%s' "$tail" | grep -q 'esc skip'; then
      "$REAL_TMUX" -L "$SOCKET" send-keys -t codex-real:w Escape
      update_skipped=1
    fi
    sleep 0.2
  done
  printf '%s\n' "$tail" | grep -q 'Trust this folder?' || fail "codex $VERSION_OUT: folder dialog did not appear; captured:
$tail"
  printf '%s\n' "$tail" | awk '/Folder access/{f=1;next} f && /Trust this folder/{exit} f && NF{n++} END{exit n<2}' || fail "codex $VERSION_OUT: path did not wrap; guard is vacuous"
  printf '%s\n' "$tail" > "$lab/screen"
  "$REAL_TMUX" -L "$SOCKET" kill-session -t codex-real >/dev/null 2>&1 || true
  # The positional parameters belong to the shell inside the replay pane.
  # shellcheck disable=SC2016
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s codex-replay -n w -x 80 -y 35 -c "$folder" \
    bash -c 'cat "$1"; IFS= read -r _; echo accepted > "$2"; sleep 10' _ "$lab/screen" "$lab/accepted" || fail "codex $VERSION_OUT: replay failed"
  socket_context=$("$REAL_TMUX" -L "$SOCKET" display-message -p '#{socket_path},#{pid},0')
  out=$(TMUX="$socket_context" FM_STARTUP_DIALOGS_POLL=0.2 "${FM_DIALOGS_BASH:-bash}" "$ROOT/bin/fm-startup-dialogs.sh" tmux codex-replay:w codex "$folder" 5 2>&1)
  [ -f "$lab/accepted" ] || fail "codex $VERSION_OUT: wrapped real dialog was not accepted: $out"
  "$REAL_TMUX" -L "$SOCKET" kill-session -t codex-replay >/dev/null 2>&1 || true
  CHECKED=$((CHECKED + 1))
  pass "codex $VERSION_OUT: real wrapped folder dialog accepted in private replay"
else
  note "codex not installed - wrapped folder dialog not checked"
fi

[ "$CHECKED" -gt 0 ] || fail "no installed harness could be checked; this run verified nothing"
note "checked $CHECKED launch-prompt signature(s) against real installed binaries"
cleanup_all
trap - EXIT
