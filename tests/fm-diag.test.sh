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

test_emit_keeps_only_schema_tokens
test_hook_timing_keeps_exit_status
test_worker_sample_counts_unreaped_zombies
