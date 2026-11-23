#!/usr/bin/env bash
# Opt-in real Codex/Claude park -> policy choice -> original chat or takeover.
# Run with FM_WORKER_PARKING_LIVE=1 through bin/fm-heavy-run.sh.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_WORKER_PARKING_LIVE herdr python3 jq
TMP_ROOT=$(fm_test_tmproot fm-worker-parking-live)
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name worker-parking)
export FM_HOME
export TMPDIR="$TMP_ROOT"
FM_HOME="$TMP_ROOT/home"
background_pid=
cleanup() {
 local rc=$?
 trap - EXIT
 if [ -n "$background_pid" ]; then kill "$background_pid" 2>/dev/null || true; wait "$background_pid" 2>/dev/null || true; fi
 export PATH="${ORIGINAL_PATH:-$PATH}"
 "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
 "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
 fm_test_cleanup
 exit "$rc"
}
trap cleanup EXIT
# Let the one EXIT cleanup close the lab before tests/lib.sh removes fixtures.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
"$LAB_HOME_HELPER" create "$FM_HOME"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
# All task-specific backend Herdr traffic passes through the guarded helper.
ORIGINAL_PATH=$PATH
export ORIGINAL_PATH HERDR_LAB_SESSION HERDR_LAB_HELPER
mkdir "$FM_HOME/fakebin"
cat > "$FM_HOME/fakebin/herdr" <<'WRAP'
#!/usr/bin/env bash
set -eu
args=()
while [ $# -gt 0 ]; do
 case "$1" in
 --session) [ "$2" = "$HERDR_LAB_SESSION" ] || exit 97; shift 2 ;;
 --session=*) [ "${1#*=}" = "$HERDR_LAB_SESSION" ] || exit 97; shift ;;
 *) args+=("$1"); shift ;;
 esac
done
PATH=$ORIGINAL_PATH exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAP
chmod +x "$FM_HOME/fakebin/herdr"
export PATH="$FM_HOME/fakebin:$PATH"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export HERDR_SESSION="$HERDR_LAB_SESSION" FM_BACKEND=herdr FM_SPAWN_NO_GUARD=1
fm_test_tasks_toml "$FM_HOME/.tasks.toml"
printf manual > "$FM_HOME/config/backlog-backend"
printf auto > "$FM_HOME/config/claude-permission-mode"
mkdir -p "$TMP_ROOT/allowed"
# A resumed Codex viewport can stay scrolled above its new activity. Prefer
# assistant transcript text to avoid mistaking a pinned screen for no response.
resumed_reply_seen() {
 python3 - "$FM_HOME/data/$id/sessions.jsonl" <<'REPLY'
import json,sys
from pathlib import Path
try:
    rows=[json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
    session=rows[-1].get('session')
    if not session: raise ValueError('transcript not yet bound')
    for line in Path(session).read_text().splitlines():
        row=json.loads(line); payload=row.get('payload',{})
        if row.get('type')=='response_item' and payload.get('role')=='assistant':
            content=payload.get('content',[])
        elif row.get('type')=='assistant':
            content=row.get('message',{}).get('content',[])
        else: continue
        if any('MARIGOLD P03-RESUMED' in part.get('text','') for part in content):
            sys.exit(0)
except (OSError,ValueError,IndexError): pass
sys.exit(1)
REPLY
}
checked=0
for harness in codex claude; do
 if ! command -v "$harness" >/dev/null; then printf 'skip: %s absent\n' "$harness"; continue; fi
 checked=$((checked + 1))
 "$harness" --version
 id=pilot-$harness
 (cd "$FM_HOME" && tasks-axi add "$id" "Resume pilot $harness" --kind ship --repo sample --start) >/dev/null
 bash "$ROOT/bin/fm-brief.sh" "$id" --host --path "$TMP_ROOT/allowed" >/dev/null
 python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text().replace('{TASK}', 'This is a tiny lifecycle pilot. Remember the word MARIGOLD. On every launch, first inspect the steering inbox. If there is a pending message, read it, reply with MARIGOLD and its requested token, and acknowledge it by moving it into handled. If no message exists, reply P03-READY and wait. Do not do other work or ask questions.').replace('{CAPTAIN_REQUIREMENTS}', '1. Exercise automatic parking and resumption.').replace('{FIRSTMATE_SPEC}', 'No implementation; only one short reply and wait. Do not initialize a presentation. The enclosing test owns all status updates.');p.write_text(s)
PY
 if [ "$harness" = codex ]; then model=gpt-6.1-sol; else model=haiku; fi
 bash "$ROOT/bin/fm-spawn.sh" "$id" --host --harness "$harness" --model "$model" --effort low --backend herdr
 meta="$FM_HOME/state/$id.meta"
 target=$(sed -n 's/^window=//p' "$meta" | tail -1)
 pane=${target#*:}
 printf 'pilot started %s pane=%s\n' "$harness" "$pane"
 for n in $(seq 1 120); do
  screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --lines 60 --source recent-unwrapped 2>/dev/null || true)
  # Codex's qualified normal-final callback survives a scrolled TUI viewport.
  if { [ "$harness" = codex ] && [ -f "$FM_HOME/state/$id.turn-ended" ]; } \
    || { [ "$harness" = claude ] && printf '%s' "$screen" | grep -q 'P03-READY'; }; then break; fi
  if [ "$n" = 120 ]; then printf '%s\n' "$screen"; exit 1; fi
  sleep 1
 done
 printf '%s\n' "$screen"
 printf 'needs-decision [at=%s]: waiting for pilot answer\n' "$(date +%s)" >> "$FM_HOME/state/$id.status"
 bash "$ROOT/bin/fm-capacity.sh" --json | jq -e --arg id "$id" '.lanes.ids | index($id) != null' >/dev/null || fail 'live worker did not occupy a lane'
 scope=$(sed -n 's/^process_scope=//p' "$meta")
 env FM_WORKER_PROCESS_SCOPE="$scope" sleep 120 &
 background_pid=$!
 for n in $(seq 1 120); do
  if python3 - "$ROOT/bin/fm-worker-processes.py" "$scope" "$background_pid" <<'CHECK_CHILD'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('worker_processes',sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
sys.exit(0 if int(sys.argv[3]) in module.owned(sys.argv[2]) else 1)
CHECK_CHILD
  then break; fi
  [ "$n" -lt 120 ] || fail 'scoped process was not observed'
  sleep 1
 done
 bash -c '. "$1"; worker_completion_tick' _ "$ROOT/bin/fm-watch.sh"
 kill -0 "$background_pid" 2>/dev/null || fail 'parking interrupted the scoped process'
 [ ! -f "$FM_HOME/state/$id.parked" ] || fail 'worker was parked with scoped work running'
 kill "$background_pid"; wait "$background_pid" 2>/dev/null || true
 background_pid=
 for n in $(seq 1 120); do
  bash -c '. "$1"; worker_completion_tick' _ "$ROOT/bin/fm-watch.sh"
  [ ! -f "$FM_HOME/state/$id.parked" ] || break
  [ "$n" -lt 120 ] || fail 'idle worker was not automatically parked'
  sleep 1
 done
 python3 - "$ROOT/bin/fm-worker-processes.py" "$scope" <<'CHECK_SCOPE'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('worker_processes',sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
assert not module.owned(sys.argv[2]), 'park left worker processes alive'
CHECK_SCOPE
 bash "$ROOT/bin/fm-capacity.sh" --json | jq -e --arg id "$id" '.lanes.ids | index($id) == null' >/dev/null || fail 'parked worker still occupies a lane'
 bash "$ROOT/bin/fm-crew-state.sh" "$id" --json
 original_session=$(python3 "$ROOT/bin/fm_task_sessions.py" resume-id "$FM_HOME/state" "$id" || true)
 printf claude > "$FM_HOME/config/crew-harness"
 if [ "$harness" = claude ]; then printf codex > "$FM_HOME/config/crew-harness"; fi
 if bash "$ROOT/bin/fm-send.sh" "$id" 'What was the remembered word? Reply with it and P03-RESUMED. Read and acknowledge this inbox message.'; then
  fail 'policy change resumed without captain choice'
 fi
 jq -e '.call | .recommended == "current" and (.options | length == 2)' "$FM_HOME/data/$id/captain-call.json" >/dev/null
 [ -f "$FM_HOME/state/$id.parked" ] || fail 'policy choice lost saved launch'
 [ -f "$FM_HOME/state/$id.inbox/001.msg" ] || fail 'policy choice lost pending message'
 selected=$harness
 if [ "$harness" = claude ]; then selected=codex; fi
 printf 'Pilot answer: continue with %s.\n' "$selected" > "$TMP_ROOT/decision.txt"
 bash "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$TMP_ROOT/decision.txt" --release-in-flight
 if [ "$selected" = codex ]; then model=gpt-6.1-sol; else model=haiku; fi
 bash "$ROOT/bin/fm-control.sh" "$id" resume --harness "$selected" --model "$model" --effort low
 newtarget=$(sed -n 's/^window=//p' "$meta" | tail -1)
 newpane=${newtarget#*:}
 for n in $(seq 1 120); do
  screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$newpane" --lines 60 --source recent-unwrapped 2>/dev/null || true)
  if printf '%s' "$screen" | grep -q 'MARIGOLD.*P03-RESUMED' || resumed_reply_seen; then break; fi
  if [ "$n" = 120 ]; then printf '%s\n' "$screen"; exit 1; fi
  sleep 1
 done
 printf '%s\n' "$screen"
 python3 - "$FM_HOME/data/$id/sessions.jsonl" "$original_session" "$selected" "$harness" <<'CHECK'
import json,sys
from pathlib import Path
rows=[json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(rows)==2 and rows[0]['status']=='archived' and rows[1]['status']=='active', rows
assert rows[1]['harness']==sys.argv[3], rows
if sys.argv[3]!=sys.argv[4]:
    assert rows[0]['session'] != rows[1]['session'], rows
    print('takeover preserved progress and switched harness: '+sys.argv[4]+' -> '+sys.argv[3])
elif sys.argv[2]:
    assert rows[0]['session'] and rows[0]['session']==rows[1]['session'], rows
    print('same transcript preserved across park/resume: '+sys.argv[2])
else:
    status=(Path(sys.argv[1]).parents[2]/'state'/('pilot-'+rows[1]['harness']+'.status')).read_text()
    assert 'chat=fresh-with-progress-note' in status and 'no readable native session identity' in status, status
    print('explicit fresh-chat fallback: saved launch has no readable native session identity')
CHECK
 [ -f "$FM_HOME/state/$id.inbox/handled/001.msg" ] || fail 'resumed worker did not acknowledge its response'
 printf 'PILOT PASSED %s continuation and acknowledged response\n' "$harness"
 bash "$ROOT/bin/fm-control.sh" "$id" exit
 # Teardown closes only the isolated named Herdr session, after the loop.
done

[ "$checked" -gt 0 ] || fail "no installed harness was checked"
