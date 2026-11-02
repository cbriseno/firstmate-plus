#!/usr/bin/env bash
# Session-open entry point for harnesses that RUN the digest instead of asking
# the agent to. It is the one command those harnesses' session-open adapters
# invoke, and it decides, from the session-open source, whether this open needs
# the full digest, a context re-emit, or nothing at all.
#
# Why running beats nudging: bin/fm-sessionstart-nudge.sh can only ASK the agent
# to take the helm, and an agent can defer that, including when a first-command
# skill has its own read-only path. When the native adapter injects this
# command's stdout into model context, running the digest here removes that
# discretion - the helm is taken before the model's first turn, whatever the
# first turn is.
#
# Usage: fm-sessionstart-run.sh [--source <source>] [--pi-prerequisite]
#   --source  The harness's own session-open source. When omitted, the source is
#             read from a Claude/Codex-shaped JSON hook payload on stdin
#             (the `source` field). An unreadable or unrecognized source is
#             treated as `startup`, because taking the helm redundantly is
#             cheap and idempotent while not taking it is the whole bug.
#   --pi-prerequisite
#             Internal Pi extension mode. An intentional gate/scope stand-down
#             exits 3 so provider preflight can distinguish it from an eligible
#             native attempt that settled without output. Every ordinary hook
#             invocation retains the always-zero compatibility contract below.
#
# Source routing (see docs/sessionstart-nudge.md for the per-harness names):
#   startup, new            full digest - this process has not taken the helm
#   clear, compact          `--reemit` digest only when this lock owner recorded
#                           a completed full startup; otherwise a full digest,
#                           so a startup killed mid-sweep is finished first
#   resume, reload, fork    delegate to the nudge wrapper. Prior context is
#                           restored on these, so re-running is redundant when
#                           this process still holds the lock (the nudge stays
#                           silent) and a plain instruction is enough when a new
#                           process resumed an old session (the nudge fires).
#
# Every ordinary transport path exits 0, exactly like the nudge wrapper: a
# Claude SessionStart exit 2 blocks session initialization, so a failed session
# start must reach the agent as digest text it can act on, never as a refusal to
# open the session. The internal Pi prerequisite's silent exit 3 never reaches a
# harness hook; it only distinguishes intentional ineligibility before provider
# preflight. A lock another live session holds and a truncated digest are
# reported inside the digest, while broken GitHub auth arrives through the
# deferred network result inline or as a wake, for exactly that reason.
# A fresh clone has no gitignored state dir yet; a root that otherwise
# qualifies as primary gets one created here before the scope check runs, so
# the first session takes the helm without a manual `mkdir state`.
#
# HOOK BUDGET. A hook harness discards everything a hook printed when it kills
# the hook at its registered timeout (180s for Claude, Codex, and Cursor), so a
# digest that is still running then is lost without a word. The digest's own
# FM_SESSION_START_TIMEOUT bound does not close that gap alone: a nested bounded
# call runs in a process group of its own, survives the digest's group kill,
# and keeps the hook's stdout open until its own bound expires, while a loaded
# host can spend the remaining margin before the digest even starts.
# So this wrapper bounds preparation and execution together from entry under
# FM_SESSION_START_HOOK_BUDGET (default 150s, below every registered hook timeout).
# Eligibility, payload reads and parsing, completion checks, and capture-file
# allocation all spend that budget. A host without a whole-wrapper bound gets
# the incomplete notice instead of launching the digest. The digest runs only
# with stdout and stderr captured to private files; capture failure produces
# the incomplete notice
# without launching it. The wrapper delivers captured output with time reserved
# before the outer bound. No digest descendant holds the harness's pipe.
# The budget's deadline also reaches
# bin/fm-session-start.sh as FM_SESSION_START_DEADLINE, which caps the digest's
# own bound to fit inside it, so on a slow host that script's stage-naming
# STARTUP TRUNCATED banner normally reports first, and this budget stays the
# backstop for a start that cannot even reach its own bound. A run the budget
# stops, or one that exits nonzero for any other reason, ends with a SESSION
# START INCOMPLETE notice telling the agent to run bin/fm-session-start.sh, so
# an overrun is never silent. bin/fm-session-start.sh stays the owner of what
# runs and in what order.
set -u
SECONDS=0

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

HOOK_BUDGET=${FM_SESSION_START_HOOK_BUDGET:-150}
case "$HOOK_BUDGET" in ''|*[!0-9]*) HOOK_BUDGET=150 ;; esac
[ "$HOOK_BUDGET" -gt 0 ] 2>/dev/null || HOOK_BUDGET=150

incomplete_notice() {
  local rc=$1 bar='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '\n%s\n' "$bar"
  if [ "$rc" = capture ]; then
    printf '●  SESSION START INCOMPLETE - OUTPUT CAPTURE FAILED\n'
  elif fm_timed_out "$rc"; then
    printf '●  SESSION START INCOMPLETE - IT DID NOT FINISH INSIDE THE %ss HOOK BUDGET\n' "$HOOK_BUDGET"
    printf '●  The session-open hook stopped it so this notice arrives before the\n'
    printf '●  harness hook timeout would discard the whole digest.\n'
  else
    printf '●  SESSION START INCOMPLETE - IT EXITED WITH STATUS %s\n' "$rc"
  fi
  printf '●  Anything above is partial. Run bin/fm-session-start.sh now, exactly once,\n'
  printf '●  before acting on anything else.\n'
  printf '%s\n' "$bar"
}

if [ "${1:-}" != --hook-budget-child ]; then
  HOOK_REMAINING=$(( HOOK_BUDGET - SECONDS ))
  if [ "$HOOK_REMAINING" -gt 0 ]; then
    (
      fm_exec_timed "$HOOK_REMAINING" 1 "$BASH" "$SCRIPT_DIR/fm-sessionstart-run.sh" \
        --hook-budget-child "$HOOK_REMAINING" "$@"
    )
    HOOK_STATUS=$?
  else
    HOOK_STATUS=124
  fi
  [ "$HOOK_STATUS" -ne 3 ] || exit 3
  [ "$HOOK_STATUS" -eq 0 ] || incomplete_notice "$HOOK_STATUS"
  exit 0
fi
HOOK_DEADLINE=$(( $(date +%s) + $2 - SECONDS ))
shift 2

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
COMPLETION_FILE="$STATE/.session-start-complete"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

SOURCE=
PI_PREREQUISITE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      SOURCE=${2:-}
      # A bare trailing --source leaves the source empty rather than aborting,
      # so a malformed call still falls through to taking the helm.
      if [ $# -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*) SOURCE=${1#--source=}; shift ;;
    --pi-prerequisite) PI_PREREQUISITE=1; shift ;;
    *) shift ;;
  esac
done

stand_down() {
  if [ "$PI_PREREQUISITE" = 1 ]; then
    exit 3
  fi
  exit 0
}

# The same two eligibility owners the nudge wrapper uses, so a no-mistakes gate
# agent and an unmarked task worktree can never run a session start for a home
# they do not own. Pi's preflight-only status preserves that intentional silence
# without mistaking it for a failed eligible attempt that needs the manual nudge.
fm_is_gate_agent "$FM_ROOT" && stand_down
if [ ! -d "$STATE" ] && fm_primary_root_matches "$FM_ROOT"; then
  if ! MKDIR_ERR=$(mkdir -p "$STATE" 2>&1); then
    printf 'fm-sessionstart-run: startup could not create the state directory %s: %s\n' \
      "$STATE" "${MKDIR_ERR##*: }" >&2
    stand_down
  fi
fi
fm_primary_scope_matches "$FM_ROOT" "$STATE" || stand_down

session_start_completed() {
  local lock_pid completion_pid
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  [ -f "$COMPLETION_FILE" ] && [ ! -L "$COMPLETION_FILE" ] || return 1
  fm_session_lock_owned_by_self "$STATE" || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  completion_pid=$(cat "$COMPLETION_FILE" 2>/dev/null) || return 1
  fm_session_pid_valid "$lock_pid" || return 1
  [ "$completion_pid" = "$lock_pid" ]
}

if [ -z "$SOURCE" ] && [ ! -t 0 ]; then
  # Claude and Codex both deliver a JSON SessionStart payload on stdin whose
  # `source` field carries startup|resume|clear|compact. Parsed without jq so a
  # host missing it still gets correct routing rather than silent full runs.
  # A terminal stdin is skipped outright: a hook always pipes its payload, and
  # an operator running this by hand must not be left waiting on a read.
  # Splitting on the quote character finds the FIRST "source" key and its value
  # without depending on greedy-regex luck, and it cannot mistake a string VALUE
  # of "source" for the key, because only a key is followed by a bare colon.
  PAYLOAD=$(cat 2>/dev/null || true)
  # Cursor loads the tracked Claude settings as well as its own registration,
  # so a Cursor-delivered payload here is the duplicate: bin/fm-sessionstart-
  # cursor.sh already owns that session open and calls this wrapper with an
  # explicit --source and no payload. Running twice would take the helm twice
  # and repeat every startup sweep.
  if fm_hook_payload_is_foreign_host "$PAYLOAD"; then
    exit 0
  fi
  SOURCE=$(printf '%s' "$PAYLOAD" | awk '
    BEGIN { RS = "\"" }
    seen == 2 { print; exit }
    seen == 1 && $0 ~ /^[[:space:]]*:[[:space:]]*$/ { seen = 2; next }
    seen == 1 { seen = 0 }
    $0 == "source" { seen = 1 }
  ')
fi

run_session_start() {  # <fm-session-start.sh args...>
  local out err rc remaining
  out=$(mktemp "${TMPDIR:-/tmp}/fm-sessionstart-run.out.XXXXXX" 2>/dev/null) || out=
  err=$(mktemp "${TMPDIR:-/tmp}/fm-sessionstart-run.err.XXXXXX" 2>/dev/null) || err=
  if [ -n "$out" ] && [ -n "$err" ]; then
    remaining=$(( HOOK_DEADLINE - $(date +%s) - 2 ))
    if [ "$remaining" -gt 0 ]; then
      fm_run_timed "$remaining" env FM_SESSION_START_DEADLINE="$HOOK_DEADLINE" \
        "$SCRIPT_DIR/fm-session-start.sh" "$@" >"$out" 2>"$err"
      rc=$?
    else
      rc=124
    fi
    cat "$out" 2>/dev/null
    cat "$err" >&2 2>/dev/null
  else
    rc=capture
  fi
  rm -f "$out" "$err" 2>/dev/null
  [ "$rc" = 0 ] || incomplete_notice "$rc"
}

case "$SOURCE" in
  resume|reload|fork)
    exec "$SCRIPT_DIR/fm-sessionstart-nudge.sh"
    ;;
  clear|compact)
    if session_start_completed; then
      run_session_start --reemit --source "$SOURCE"
    else
      run_session_start --source "$SOURCE"
    fi
    ;;
  *)
    run_session_start --source "$SOURCE"
    ;;
esac
exit 0
