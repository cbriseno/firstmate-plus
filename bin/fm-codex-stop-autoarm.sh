#!/usr/bin/env bash
# Opt-in Codex Stop owner, adapted from the native Stop/queue path proposed in
# https://github.com/kunchenguid/firstmate/pull/4671.
# Usage: fm-codex-stop-autoarm.sh [--capable|--guard|--handling]
# Hook modes consume the native Stop JSON on stdin; not a manual arm command.
# --capable and --handling are read-only; neither invokes Codex.
#
# An explicit verified binding is required (docs/configuration.md). The default
# remains the existing foreground checkpoint. The async Stop owns one tracked
# fm-watch-arm child, bounded by a one-hour lease and the existing Perl owner-
# death watchdog. The native hook's two-hour timeout is an outer failure bound.
# It never acknowledges the wake queue. A successful queue receipt is only
# delivery acceptance, not proof of model handling; the handling turn drains
# and ACKs through the existing owner. After queue acceptance this callback
# observes the explicitly correlated turn through the attested 0.164 proxy
# client (Python 3 stdlib; no server). The next correlated Stop cooperatively
# takes over. Only that turn's positive capacity failure permits two fresh
# recovery instructions, with a durable claim before each dispatch. Neither
# retries nor handoff extend the current callback's one-hour lease. The watcher
# reserves its last minute for delivery/outcome observation. All other terminal
# or unproved outcomes latch foreground and append an existing durable wake.
#
# The singleton and atomic receipt bind thread, session, Stop turn, binding hash,
# lock PID/identity, callback PID/identity and generation. Replay of the current
# queued Stop never resubmits, even after the handling grace expires. A changed binding or dead/replaced session goes
# silent and reaps only its own child. A failed delivery latches foreground for
# this binding; the latch is written before dispatch so an interrupted sender
# cannot automatically retry an ambiguously accepted input.
# Removing the opt-in stops the owner on its next poll. The latch is
# state/.codex-native-fallback; inspect the receipt before explicitly retiring
# that latch as part of an approved retry. No hook/trust store is modified.
# A guard readiness timeout refuses the final without writing that latch:
# delayed async admission may still complete, and no input was dispatched.
# A selected root with required supervision cannot finish on foreground proof
# alone, including repeated Stop attempts. The legacy guard delegates here too.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MODE=${1:-stop}
case "$MODE" in
  -h|--help)
    echo 'Usage: fm-codex-stop-autoarm.sh [--capable|--guard|--handling]'
    exit 0 ;;
  stop|--capable|--guard|--handling) [ "$#" -le 1 ] || exit 2 ;;
  *) exit 2 ;;
esac

# Default-off must not create state, inspect processes or invoke a CLI.
if [ ! -f "$CONFIG/codex-native-supervision.json" ]; then
  case "$MODE" in
    --guard) exec "$SCRIPT_DIR/fm-turnend-guard.sh" ;;
    stop) exit 0 ;;
    *) exit 1 ;;
  esac
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-codex-native-lib.sh
. "$SCRIPT_DIR/fm-codex-native-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

LOCK="$STATE/.codex-native.lock"
RECORD="$STATE/.codex-native.json"
FALLBACK="$STATE/.codex-native-fallback"
HANDOFF="$STATE/.codex-native-handoff.json"
GRACE=${FM_GUARD_GRACE:-300}
PAYLOAD=
case "$MODE" in --guard|stop) PAYLOAD=$(cat) ;; esac
NATIVE_REQUIRED=0
if [ "$MODE" = --guard ] && fm_codex_native_required "$FM_ROOT" "$STATE" "$CONFIG" "$PAYLOAD" \
  && fm_supervision_needed "$STATE"; then
  NATIVE_REQUIRED=1
fi
block_native_stop() {
  if ! fm_codex_native_required "$FM_ROOT" "$STATE" "$CONFIG" "$PAYLOAD" || ! fm_supervision_needed "$STATE"; then
    printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"
    exit $?
  fi
  echo 'Codex native handoff is unproved; keep this turn open, continue foreground supervision and progress updates, and repair the bound native owner before finishing. A live foreground checkpoint does not prove native continuation.' >&2
  exit 2
}
binding() {
  case "$MODE" in
    --guard|stop) fm_codex_native_binding "$FM_ROOT" "$FM_HOME" "$STATE" "$CONFIG" "$PAYLOAD" ;;
    *) fm_codex_native_binding "$FM_ROOT" "$FM_HOME" "$STATE" "$CONFIG" ;;
  esac
}
if ! binding; then
  case "$MODE" in
    --guard)
      [ "$NATIVE_REQUIRED" -eq 0 ] || block_native_stop
      printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"; exit $? ;;
    stop) exit 0 ;;
    *) exit 1 ;;
  esac
fi
BINDING=$FM_CN_BINDING
case "$MODE" in
  --capable) [ ! -e "$STATE/.afk" ] && [ "$(cat "$FALLBACK" 2>/dev/null)" != "$BINDING" ]; exit $? ;;
esac

context() {
  binding \
    && [ "$FM_CN_BINDING" = "$BINDING" ] && [ ! -e "$STATE/.afk" ]
}

receipt() { # <phase>; rejects another thread, binding, process or session
  jq -e --arg phase "$1" --arg binding "$BINDING" --arg thread "$FM_CN_THREAD" \
    --arg session "$FM_CN_SESSION" --arg anchor "$FM_CN_ANCHOR" --arg identity "$FM_CN_ANCHOR_ID" '
    .phase == $phase and .binding == $binding and .thread == $thread and .session == $session
    and .anchor == $anchor and .anchor_identity == $identity and (.generation | type) == "string"
  ' "$RECORD" >/dev/null 2>&1
}

queued_fresh() {
  receipt queued || return 1
  callback_alive || return 1
  jq -e --argjson now "$(date +%s)" --argjson grace "$1" \
    '(.at | type) == "number" and .at <= $now and ($now - .at) < $grace' "$RECORD" >/dev/null 2>&1
}

callback_alive() {
  local pid identity
  pid=$(jq -r '.pid' "$RECORD")
  [ "$pid" = "$(cat "$LOCK/pid" 2>/dev/null)" ] || return 1
  fm_pid_alive "$pid" || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  jq -e --arg identity "$identity" --argjson now "$(date +%s)" \
    '.identity == $identity and .deadline > $now' "$RECORD" >/dev/null 2>&1
}

ready() {
  if receipt queued && jq -e --arg turn "$FM_CN_TURN" '.turn == $turn' "$RECORD" >/dev/null 2>&1; then callback_alive; return $?; fi
  receipt watching && callback_alive || return 1
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"
}

if [ "$MODE" = --handling ]; then
  context && queued_fresh "$GRACE"
  exit $?
fi

if [ "$MODE" = --guard ]; then
  if [ "$NATIVE_REQUIRED" -eq 1 ]; then
    if [ "$(cat "$FALLBACK" 2>/dev/null)" != "$BINDING" ]; then
      # Give the concurrently fired async hook time to publish a real watcher.
      guard_deadline=$(($(date +%s) + 10))
      while [ "$(date +%s)" -lt "$guard_deadline" ]; do
        ready && exit 0
        context || break
        sleep 0.1
      done
    fi
    block_native_stop
  fi
  printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"
  exit $?
fi

context && fm_supervision_needed "$STATE" || exit 0
[ "$(cat "$FALLBACK" 2>/dev/null)" != "$BINDING" ] || exit 0
ready && exit 0
umask 077
# A normal Stop of our handling turn transfers ownership before its guard
# deadline. An unrelated/replayed Stop cannot retire an observer. The request
# is scoped to the old generation and its explicitly joined client/turn IDs.
if receipt queued && callback_alive; then
  previous_generation=$(jq -r '.generation' "$RECORD")
  previous_client=$(jq -r '.client_id' "$RECORD")
  previous_turn=$(jq -r '.observed_turn // empty' "$RECORD")
  if [ -z "$previous_turn" ]; then
    previous_turn=$(CODEX_HOME="$FM_CN_HOME" fm_run_timed 6 python3 "$SCRIPT_DIR/fm-codex-native-rpc.py" outcome \
      --executable "$FM_CN_BIN" --remote "$FM_CN_REMOTE" --thread "$FM_CN_THREAD" \
      --client-id "$previous_client" 2>/dev/null | jq -r '.turn_id // empty')
  fi
  if [ "$previous_turn" = "$FM_CN_TURN" ] && context && receipt queued && callback_alive \
    && jq -e --arg generation "$previous_generation" '.generation == $generation' "$RECORD" >/dev/null; then
    jq -n --arg generation "$previous_generation" --arg binding "$BINDING" \
      --arg turn "$previous_turn" --arg client "$previous_client" \
      '{generation:$generation,binding:$binding,turn:$turn,client_id:$client}' > "$HANDOFF.tmp.$$" \
      && mv -f "$HANDOFF.tmp.$$" "$HANDOFF"
    takeover_deadline=$(($(date +%s) + 8))
    while callback_alive && [ "$(date +%s)" -lt "$takeover_deadline" ]; do context || exit 0; sleep 0.1; done
  fi
fi
fm_lock_try_acquire "$LOCK" || exit 0
CHILD=
OUT=
DEADLINE=$(($(date +%s) + 3600))
ATTEMPTS=0
CLIENT_ID=
SUBMISSION=
OBSERVED_TURN=
FAILED_TURN=
IDENTITY=$(fm_pid_identity "$$") || { fm_lock_release "$LOCK"; exit 1; }
GENERATION="$FM_CN_TURN:$$:$IDENTITY"
owned() {
  context && [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]
}
publish() {
  local tmp="$RECORD.tmp.$$"
  owned || return 1
  jq -n --arg phase "$1" --arg binding "$BINDING" --arg thread "$FM_CN_THREAD" \
    --arg session "$FM_CN_SESSION" --arg turn "$FM_CN_TURN" --arg anchor "$FM_CN_ANCHOR" \
    --arg anchor_identity "$FM_CN_ANCHOR_ID" --arg identity "$IDENTITY" --arg generation "$GENERATION" \
    --arg client_id "$CLIENT_ID" --arg submission "$SUBMISSION" --arg observed_turn "$OBSERVED_TURN" \
    --arg failed_turn "$FAILED_TURN" --argjson attempts "$ATTEMPTS" --argjson deadline "$DEADLINE" \
    --argjson pid "$$" --argjson at "$(date +%s)" \
    '{phase:$phase,binding:$binding,thread:$thread,session:$session,turn:$turn,anchor:$anchor,
      anchor_identity:$anchor_identity,pid:$pid,identity:$identity,generation:$generation,at:$at,
      client_id:$client_id,submission:$submission,observed_turn:$observed_turn,failed_turn:$failed_turn,
      attempts:$attempts,deadline:$deadline}' > "$tmp" \
    && owned && mv -f "$tmp" "$RECORD"
}
# shellcheck disable=SC2329 # EXIT trap owns the tracked child and private files.
cleanup() {
  if [ -n "$CHILD" ]; then
    kill -TERM "$CHILD" 2>/dev/null || true
    wait "$CHILD" 2>/dev/null || true
  fi
  [ -z "$OUT" ] || rm -f "$OUT"
  rm -f "$RECORD.tmp.$$" "$HANDOFF.tmp.$$"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
owned || exit 0
[ "$(cat "$FALLBACK" 2>/dev/null)" != "$BINDING" ] || exit 0
# Recheck after acquisition: a duplicate Stop can race the first publication.
if receipt queued && jq -e --arg turn "$FM_CN_TURN" '.turn == $turn' "$RECORD" >/dev/null 2>&1; then exit 0; fi
OUT=$(mktemp "$STATE/.codex-native-output.XXXXXX") || exit 1
protocol() { # <queue|outcome> [--turn-id ID]; child and transport die with this owner
  local rc=0 mode=$1
  shift
  owned || return 1
  # shellcheck disable=SC2030 # This child deliberately receives the callback PID.
  (export FM_EXEC_TIMED_OWNER_PID=$$ CODEX_HOME="$FM_CN_HOME"; fm_exec_timed 6 1 \
    python3 "$SCRIPT_DIR/fm-codex-native-rpc.py" "$mode" --executable "$FM_CN_BIN" \
      --remote "$FM_CN_REMOTE" --thread "$FM_CN_THREAD" --client-id "$CLIENT_ID" "$@") \
    > "$OUT" 2>/dev/null <&0 &
  CHILD=$!
  wait "$CHILD" || rc=$?
  CHILD=
  owned || return 1
  return "$rc"
}
terminal() { # metadata only, through the existing durable escalation path
  owned || return 1
  printf '%s\n' "$BINDING" > "$FALLBACK"
  publish "$1" || return 1
  fm_wake_append check codex-native "Native supervision requires foreground recovery: $1; inspect state/.codex-native.json. No automatic retry of an unproved delivery." >/dev/null
}
handoff_requested() {
  [ -n "$OBSERVED_TURN" ] || return 1
  jq -e --arg generation "$GENERATION" --arg binding "$BINDING" --arg client "$CLIENT_ID" --arg turn "$OBSERVED_TURN" \
    '.generation == $generation and .binding == $binding and .client_id == $client and .turn == $turn' "$HANDOFF" >/dev/null 2>&1
}
publish arming || exit 1
# Perl is required by the binding, so fm_exec_timed uses its owner-death reap.
# shellcheck disable=SC2031 # Independent child; explicitly assigns its own owner.
(export FM_EXEC_TIMED_OWNER_PID=$$; fm_exec_timed 3540 5 "$SCRIPT_DIR/fm-watch-arm.sh") > "$OUT" 2>&1 &
CHILD=$!
publish watching || exit 1
while kill -0 "$CHILD" 2>/dev/null; do
  owned && fm_supervision_needed "$STATE" || exit 0
  [ "$(cat "$FALLBACK" 2>/dev/null)" != "$BINDING" ] || exit 0
  sleep 1
done
rc=0
wait "$CHILD" || rc=$?
CHILD=
owned && fm_supervision_needed "$STATE" || exit 0
[ "$(cat "$FALLBACK" 2>/dev/null)" != "$BINDING" ] || exit 0
message='Firstmate watcher wake: drain the durable queue, handle every presented wake and open decision, then run the exact WAKE_ACK_REQUIRED command after handling. Native Stop owns the next cycle; do not start another watcher.'
case "$rc" in
  124|137) message='Firstmate native watcher lease ended: drain and handle pending events, ACK after handling, then let the next Stop renew the native cycle.' ;;
  0)
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" || rc=1 ;;
esac
KEEP_FALLBACK=0
if [ "$rc" -ne 0 ] && ! fm_timed_out "$rc"; then
  KEEP_FALLBACK=1
  message='Firstmate native watcher failed; supervision is not healthy. Drain durable events and inspect state/.codex-native.json; resume foreground checkpoints.'
  owned && printf '%s\n' "$BINDING" > "$FALLBACK" || exit 1
fi
while owned; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || { terminal lease-ended; exit 1; }
  CLIENT_ID=$(python3 -c 'import uuid; print(uuid.uuid4())') || exit 1
  SUBMISSION=
  OBSERVED_TURN=
  # The generation's singleton plus atomic pre-dispatch receipt is the claim.
  # A dead/interrupted sender retains the latch; no later hook replays it.
  publish delivering || exit 1
  owned && printf '%s\n' "$BINDING" > "$FALLBACK" || exit 1
  fm_operational_input_encode watcher "$message" message || exit 1
  if ! protocol queue <<< "$message"; then terminal delivery-unproved; exit 1; fi
  SUBMISSION=$(jq -er '.submission' "$OUT") || { terminal delivery-unproved; exit 1; }
  publish queued || exit 1
  if [ "$KEEP_FALLBACK" -eq 0 ]; then
    owned && [ "$(cat "$FALLBACK" 2>/dev/null)" = "$BINDING" ] && rm -f "$FALLBACK"
  fi
  missing=0
  completed_at=0
  while owned; do
    if handoff_requested; then publish handed-off; exit 0; fi
    [ "$(date +%s)" -lt "$DEADLINE" ] || { terminal lease-ended; exit 1; }
    fm_supervision_needed "$STATE" || exit 0
    if [ -n "$OBSERVED_TURN" ]; then
      protocol outcome --turn-id "$OBSERVED_TURN" || { terminal outcome-unproved; exit 1; }
    else
      protocol outcome || { terminal outcome-unproved; exit 1; }
    fi
    next_turn=$(jq -r '.turn_id // empty' "$OUT")
    status=$(jq -r '.status' "$OUT")
    if [ -n "$next_turn" ]; then OBSERVED_TURN=$next_turn; publish queued || exit 1; fi
    case "$status" in
      failed)
        [ "$(jq -r '.error_class' "$OUT")" = capacity ] || { terminal turn-failed; exit 1; }
        [ "$ATTEMPTS" -lt 2 ] || { terminal retry-exhausted; exit 1; }
        [ "$FAILED_TURN" != "$OBSERVED_TURN" ] && [ -n "$OBSERVED_TURN" ] || { terminal correlation-unproved; exit 1; }
        FAILED_TURN=$OBSERVED_TURN
        ATTEMPTS=$((ATTEMPTS + 1))
        owned && printf '%s\n' "$BINDING" > "$FALLBACK" || exit 1
        publish retry-claimed || exit 1
        message='Firstmate recovery after a verified capacity failure: inspect the current durable wake queue and open decisions, resume unfinished work, and ACK only after handling. Do not repeat already ACKed actions or replay the previous message. Native Stop owns renewal.'
        break ;;
      interrupted) terminal turn-interrupted; exit 1 ;;
      completed)
        [ "$completed_at" -ne 0 ] || completed_at=$(date +%s)
        [ "$(date +%s)" -lt "$((completed_at + 10))" ] || { terminal successor-unproved; exit 1; } ;;
      inProgress) missing=0 ;;
      unknown)
        missing=$((missing + 1))
        [ "$missing" -lt 4 ] || { terminal correlation-unproved; exit 1; } ;;
      *) terminal outcome-unproved; exit 1 ;;
    esac
    sleep 1
  done
done
