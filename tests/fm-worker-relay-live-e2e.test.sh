#!/usr/bin/env bash
# Opt-in real Codex/Claude completed-turn -> note -> owner relaunch -> continuation.
# FM_WORKER_RELAY_LIVE=1 FM_RELAY_CHECK=/installed/relay-check bin/fm-test-run.sh tests/fm-worker-relay-live-e2e.test.sh
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_WORKER_RELAY_LIVE herdr tmux python3 jq tasks-axi
CHECKER=${FM_RELAY_CHECK:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate-extensions/runtime/context-relay-lite/relay-check}
[ -f "$CHECKER" ] || fail "relay-lite checker absent: set FM_RELAY_CHECK"
TMP_ROOT=$(fm_test_tmproot fm-worker-relay-live)
export FM_HOME="$TMP_ROOT/home" TMPDIR="$TMP_ROOT"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name worker-relay)
LAB_TMUX_DIR=
ORIGINAL_PATH=$PATH
cleanup() {
  local rc=$?
  trap - EXIT
  export PATH="$ORIGINAL_PATH"
  if [ -n "$LAB_TMUX_DIR" ]; then TMUX_TMPDIR="$LAB_TMUX_DIR" tmux kill-server || true; fi
  "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$LAB_HOME_HELPER" create "$FM_HOME"
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")
export TMUX_TMPDIR="$LAB_TMUX_DIR"
tmux new-session -d -s primary
export TMUX
TMUX=$(tmux display-message -p '#{socket_path},#{pid},0')
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
"$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status
# Route backend calls through the same guarded lab helper as direct probes.
export ORIGINAL_PATH HERDR_LAB_HELPER HERDR_LAB_SESSION
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
export HERDR_SESSION="$HERDR_LAB_SESSION" FM_BACKEND=herdr FM_SPAWN_NO_GUARD=1 FM_RELAY_CHECK="$CHECKER"
fm_test_tasks_toml "$FM_HOME/.tasks.toml"
printf manual > "$FM_HOME/config/backlog-backend"
printf auto > "$FM_HOME/config/claude-permission-mode"
# This owner runs outside the retiring worker scope and exercises the real watcher.
tmux new-window -d -t primary -n watch "export FM_HOME='$FM_HOME' FM_ROOT_OVERRIDE='$ROOT' HERDR_SESSION='$HERDR_LAB_SESSION' HERDR_LAB_SESSION='$HERDR_LAB_SESSION' HERDR_LAB_HELPER='$HERDR_LAB_HELPER' ORIGINAL_PATH='$ORIGINAL_PATH' PATH='$PATH'; unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH; while true; do FM_POLL=1 FM_CHECK_INTERVAL=999999 bash '$ROOT/bin/fm-watch.sh'; sleep 1; done"
checked=0
for harness in codex claude; do
  if ! command -v "$harness" >/dev/null; then printf 'skip: %s absent\n' "$harness"; continue; fi
  checked=$((checked + 1))
  "$harness" --version
  id=relay-$harness-$$
  output="$TMP_ROOT/output-$harness"
  mkdir "$output"
  printf '{"thresholds":{"worker":{"%s":{"percent":0,"tokens":1}}}}\n' "$harness" > "$FM_HOME/config/relay-lite.json"
  (cd "$FM_HOME" && tasks-axi add "$id" "Relay pilot $harness" --kind ship --repo sample --start) >/dev/null
  bash "$ROOT/bin/fm-brief.sh" "$id" --host --path "$output" >/dev/null
  python3 - "$FM_HOME/data/$id/brief.md" "$output" "$FM_HOME" "$id" <<'PY'
from pathlib import Path
import sys
p, output, home, task = sys.argv[1:]
f=Path(p)
f.write_text(f.read_text().replace('{TASK}', f'Isolated continuity pilot. If {output}/once is absent, write ONCE to it exactly once, then end the turn saying: Checkpoint: ONCE complete; do not repeat. Pending after context relaunch: append RESUMED to {output}/resumed. Do not write resumed in this initial conversation. The handoff request comes through the steering inbox; obey it and acknowledge its message. After relaunch, perform the pending action exactly once, append done [at=1]: pilot complete to {home}/state/{task}.status and stop.').replace('{FIRSTMATE_SPEC}', 'Only this local pilot; no outside services, delegation or user questions.'))
PY
  if [ "$harness" = codex ]; then model=gpt-6.1-terra; else model=haiku; fi
  bash "$ROOT/bin/fm-spawn.sh" "$id" --host --harness "$harness" --model "$model" --effort low --backend herdr
  python3 - "$FM_HOME" "$id" "$output" <<'WAIT'
import json, sys, time
from pathlib import Path
home, task, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
data = home/'data'/task
for milestone in ('initial', 'note', 'replacement', 'continuation', 'notice'):
    deadline = time.monotonic()+240
    while time.monotonic() < deadline:
        status = home/'state'/(task+'.status')
        if status.exists() and 'context relay incomplete' in status.read_text():
            for log in data.glob('relay-control-*.log'): print(log.read_text())
            raise AssertionError('relay incomplete: '+task)
        rows=[json.loads(s) for s in (data/'sessions.jsonl').read_text().splitlines()]
        observed = {'initial': (output/'once').exists(),
                    'note': bool(list(data.glob('relay-note-*.md'))),
                    'replacement': len(rows)==2 and bool(rows[-1].get('session')),
                    'continuation': (output/'resumed').exists(),
                    'notice': (home/'state/.wake-queue').exists() and 'worker context relay '+task+' replacement launched; session history=' in (home/'state/.wake-queue').read_text()}[milestone]
        if observed:
            if milestone == 'initial':
                (output/'initial-bytes').write_bytes((output/'once').read_bytes())
                (output/'initial-mtime').write_text(str((output/'once').stat().st_mtime_ns))
            print('milestone', task, milestone, flush=True)
            break
        time.sleep(1)
    else: raise AssertionError('milestone not reached: '+task+' '+milestone)
WAIT
  python3 - "$FM_HOME" "$id" "$output" <<'PY'
import json,sys
from pathlib import Path
home, task, output = Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3])
assert b'ONCE' in (output/'once').read_bytes()
assert (output/'once').read_bytes() == (output/'initial-bytes').read_bytes()
assert (output/'once').stat().st_mtime_ns == int((output/'initial-mtime').read_text())
assert (output/'resumed').read_text().strip() == 'RESUMED'
rows=[json.loads(line) for line in (home/'data'/task/'sessions.jsonl').read_text().splitlines()]
assert len(rows)==2 and [r['status'] for r in rows]==['archived','active'],rows
assert rows[0]['session'] and rows[1]['session'] and rows[0]['session']!=rows[1]['session'],rows
assert all(rows[0][k]==rows[1][k] for k in ('harness','model','effort'))
assert len(list((home/'state'/(task+'.inbox')/'handled').glob('*.msg')))==1
assert 'worker context relay '+task+' replacement launched; session history=' in (home/'state/.wake-queue').read_text()
for row in rows:
    for line in Path(row['session']).read_text().splitlines():
        item=json.loads(line)
        if item.get('type') in ('response_item','assistant'):
            body=item.get('payload',item.get('message',{}))
            if body.get('role','assistant')=='assistant' and isinstance(body.get('content'),list):
                text='\n'.join(p.get('text','') for p in body['content'] if isinstance(p,dict))
                if text: print('DECISIVE ASSISTANT:',text)
print('PASS automatic relay',task,'new transcript; same profile; one acknowledged request; one continuation')
PY
  bash "$ROOT/bin/fm-control.sh" "$id" exit
  printf 'done [at=%s]: pilot verified\n' "$(date +%s)" >> "$FM_HOME/state/$id.status"
done
[ "$checked" -gt 0 ] || fail 'no installed harness checked'
