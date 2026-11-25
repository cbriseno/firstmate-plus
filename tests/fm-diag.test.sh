#!/usr/bin/env bash
# Behavior tests for the always-on diagnostic log (bin/fm-diag.sh): schema
# filtering and anonymization, hook timing that keeps the hook's exit status,
# and the per-worker process and zombie sample.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-diag)
export FM_DIAGNOSTICS_HOME="$TMP_ROOT/diag"
LOG="$FM_DIAGNOSTICS_HOME/firstmate/events.jsonl"
DIAG="$ROOT/bin/fm-diag.sh"

test_emit_keeps_only_schema_tokens() {
  "$DIAG" emit hook.run hook=pretool-cd harness=claude ms=12 rc=2 extra=1 role='free text' \
    || fail "emit exits nonzero"
  "$DIAG" emit worker.procs task=secret-task-name procs=3 zombies=1
  "$DIAG" emit not.an.event ms=1
  [ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] || fail "expected two records, got: $(cat "$LOG")"
  jq -e -s '
    (.[0] | .c == "firstmate" and .e == "hook.run" and .hook == "pretool-cd" and .ms == 12 and .rc == 2
       and (has("extra") | not) and (has("role") | not) and (.t | test("^[0-9-]+T[0-9:.]+\\+00:00$")))
    and (.[1] | .task | test("^live-[0-9a-f]{16}$"))
  ' "$LOG" >/dev/null || fail "records do not match the schema: $(cat "$LOG")"
  grep -q secret-task-name "$LOG" && fail "raw task id reached the log"
  [ "$(jq -r -s '.[1].task' "$LOG")" = "$("$DIAG" id secret-task-name)" ] \
    || fail "fm-diag.sh id does not reproduce the logged task id"
  FM_DIAGNOSTICS=0 "$DIAG" emit hook.run ms=1
  [ "$(wc -l < "$LOG" | tr -d ' ')" = 2 ] || fail "FM_DIAGNOSTICS=0 still recorded"
  pass "emit keeps schema fields and short tokens, hashes task ids, honors FM_DIAGNOSTICS=0"
}

test_hook_timing_keeps_exit_status() {
  local hook="$TMP_ROOT/hook.sh" rc
  : > "$LOG"
  cat > "$hook" <<SH
#!/usr/bin/env bash
. "$DIAG"
fm_diag_hook_begin pretool-arm
trap fm_diag_hook_end EXIT
exit 3
SH
  chmod +x "$hook"
  "$hook"; rc=$?
  [ "$rc" -eq 3 ] || fail "hook exit status changed to $rc"
  printf '{}' | "$ROOT/bin/fm-cd-pretool-check.sh" --command 'ls' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "cd guard exit status changed to $rc"
  jq -e -s 'length == 2 and .[0].hook == "pretool-arm" and .[0].rc == 3 and (.[0].ms | type) == "number"
    and .[1].hook == "pretool-cd" and .[1].rc == 0 and (.[1].harness | type) == "string"' "$LOG" >/dev/null \
    || fail "hook.run records missing or wrong: $(cat "$LOG")"
  pass "hook timing records each run and keeps its exit status"
}

test_operation_stages() {
  local home="$TMP_ROOT/operation-home" archive="$TMP_ROOT/stages.zip" rc
  mkdir -p "$home/state" "$home/config"
  : > "$LOG"
  printf '%s' '{"stop_hook_active":true}' | FM_HOME="$home" bash "$ROOT/bin/fm-turnend-guard.sh" || fail "guard failed"
  FM_HOME="$home" bash "$ROOT/bin/fm-send.sh" absent hello >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "missing send target succeeded"
  FM_HOME="$home" bash "$ROOT/bin/fm-teardown.sh" absent >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "missing cleanup target succeeded"
  jq -e -s '
    ([.[] | select(.e == "operation.stage" and .operation == "stop-guard" and .stage == "input" and .rc == 0)] | length) == 1
    and ([.[] | select(.e == "operation.stage" and .operation == "protected-send" and .stage == "resolve" and .rc != 0)] | length) == 1
    and ([.[] | select(.e == "operation.stage" and .operation == "cleanup" and .rc != 0)] | length) == 1
    and ([.[] | select(.e == "hook.run" and .hook == "stop-guard") | .run] == [.[] | select(.e == "operation.stage" and .operation == "stop-guard") | .run])
    and all(.[] | select(.e == "operation.stage"); (.ms | type) == "number" and .ms >= 0 and (.run | type) == "number")
  ' "$LOG" >/dev/null || fail "operation stage records missing: $(cat "$LOG")"
  "$DIAG" export "$archive" >/dev/null || fail "stage export failed"
  if ! python3 - "$archive" <<'PYTEST'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    events = [json.loads(line) for line in archive.read('events.jsonl').splitlines()]
assert {e['operation'] for e in events if e['e'] == 'operation.stage'} == {'stop-guard', 'protected-send', 'cleanup'}
PYTEST
  then fail "export dropped operation stages"; fi
  pass "guard, protected send and cleanup record and export stages"
}

test_macos_stage_clock() {
  : > "$LOG"
  DIAG_FILE="$DIAG" bash -c 'OSTYPE=darwin; unset EPOCHREALTIME; . "$DIAG_FILE"; fm_diag_stage_begin fixture wait; sleep 0.2; fm_diag_stage_end' \
    || fail "macOS clock fixture failed"
  jq -e 'select(.e == "operation.stage" and .operation == "fixture" and .stage == "wait" and .ms >= 200)' "$LOG" >/dev/null \
    || fail "macOS clock fixture did not measure the wait: $(cat "$LOG")"
  pass "stage timing works without Bash EPOCHREALTIME on the macOS path"
}

test_worker_sample_counts_unreaped_zombies() {
  local state="$TMP_ROOT/state" pid i
  mkdir -p "$state"
  printf 'harness=codex\n' > "$state/t1.meta"
  : > "$LOG"
  # The scoped parent forks a child that exits at once and is never reaped.
  FM_WORKER_PROCESS_SCOPE="$state/t1:1" python3 -c '
import os, time
if os.fork() == 0:
    os._exit(0)
time.sleep(30)
' &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ps -axo ppid=,stat= | awk -v p="$pid" '$1 == p && $2 ~ /^Z/ { found = 1 } END { exit !found }' && break
    sleep 0.2
  done
  python3 "$ROOT/bin/fm-worker-processes.py" sample "$state" || fail "sample exits nonzero"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  jq -e -s --arg task "$("$DIAG" id t1)" 'length == 1 and .[0].e == "worker.procs" and .[0].task == $task
    and .[0].harness == "codex" and .[0].procs >= 1 and .[0].zombies == 1' "$LOG" >/dev/null \
    || fail "worker sample wrong (tries=$i): $(cat "$LOG")"
  pass "worker sample counts a scope's processes and its unreaped zombies"
}

test_wake_ack_records_attention_latency() {
  local home="$TMP_ROOT/wake-home" out ack
  mkdir -p "$home/state"
  : > "$LOG"
  FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh" && fm_wake_append check diag-test "test wake"' _ "$ROOT" \
    || fail "wake append failed"
  out=$(FM_HOME="$home" bash "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  seq=$(printf '%s\n' "$out" | awk -F '\t' 'NF >= 5 && $3 ~ /^(signal|stale|check|heartbeat)$/ { print $2 }')
  generation=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
  ack="--ack $seq --recovery-generation $generation"
  [ -n "$seq" ] && [ -n "$generation" ] || fail "drain printed no complete notice and acknowledgement generation: $out"
  # shellcheck disable=SC2086 # the printed flags are split on purpose
  FM_HOME="$home" bash "$ROOT/bin/fm-wake-drain.sh" $ack || fail "acknowledgement failed"
  jq -e -s 'length == 1 and .[0].e == "wake.ack" and .[0].kind == "check" and (.[0].age_s | type) == "number"' \
    "$LOG" >/dev/null || fail "an acknowledgement that empties the queue logged: $(cat "$LOG")"
  pass "a wake acknowledgement records each consumed row's kind and wait"
}

test_export_resalts_and_filters() {
  local out="$TMP_ROOT/export.zip" second="$TMP_ROOT/export2.zip"
  : > "$LOG"
  "$DIAG" emit worker.procs task=private-task procs=3
  printf '%s\n' '{"t":"2026-01-01T00:00:00+00:00","c":"firstmate","e":"worker.procs","task":"live-0123456789abcdef","extra":"private"}' 'bad json' >> "$LOG"
  "$DIAG" export "$out" || fail "export failed"
  "$DIAG" export "$second" || fail "second export failed"
  if ! python3 - "$out" "$second" <<'PYTEST'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as a, zipfile.ZipFile(sys.argv[2]) as b:
    rows = [json.loads(line) for line in a.read('events.jsonl').splitlines()]
    other = [json.loads(line) for line in b.read('events.jsonl').splitlines()]
    manifest = json.loads(a.read('manifest.json'))
    assert len(rows) == 2 and rows[0]['procs'] == 3
    assert rows[0]['task'].startswith('t-') and rows[0]['task'] != other[0]['task']
    assert 'extra' not in rows[1] and 'private-task' not in str(rows)
    assert manifest['component'] == 'firstmate' and manifest['installed_version']
PYTEST
  then fail "export contents invalid"; fi
  "$DIAG" export "$out" >/dev/null 2>&1 && fail "export replaced an existing file"
  pass "export filters records, re-salts task ids and preserves existing files"
}

test_emit_keeps_only_schema_tokens
test_hook_timing_keeps_exit_status
test_operation_stages
test_macos_stage_clock
test_worker_sample_counts_unreaped_zombies
test_wake_ack_records_attention_latency

test_export_resalts_and_filters
