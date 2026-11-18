#!/usr/bin/env bash
# Opt-in real Codex/Claude completed-turn -> note -> owner relaunch -> continuation.
# FM_WORKER_RELAY_LIVE=1 FM_RELAY_CHECK=/installed/relay-check bin/fm-test-run.sh tests/fm-worker-relay-live-e2e.test.sh
# FM_WORKER_RELAY_DROP_CALLBACK=1 FM_WORKER_RELAY_LIVE_PROFILES=codex exercises lost-callback recovery.
# FM_WORKER_RELAY_BACKGROUND=1 FM_WORKER_RELAY_LIVE_PROFILES=<claude model> adds a task job and a native
# background run: the relay waits for the native run, the job survives and the projected space stays.
# FM_WORKER_RELAY_LONG_TURN=1 keeps the first turn open: the watcher's mid-turn check must request the handoff.
# FM_WORKER_RELAY_LIVE_CLAUDE_MODELS="claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5" selects explicit Claude coverage.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_WORKER_RELAY_LIVE herdr tmux python3 jq tasks-axi
if [ "${FM_WORKER_RELAY_DROP_CALLBACK:-0}" = 1 ]; then
  [ "${FM_WORKER_RELAY_LIVE_PROFILES:-}" = codex ] || fail 'lost-callback pilot requires FM_WORKER_RELAY_LIVE_PROFILES=codex'
fi
CHECKER=${FM_RELAY_CHECK:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate-extensions/runtime/context-relay-lite/relay-check}
[ -f "$CHECKER" ] || fail "relay-lite checker absent: set FM_RELAY_CHECK"
TMP_ROOT=$(fm_test_tmproot fm-worker-relay-live)
# A lab launched from inside a worker must not inherit that worker's identity or process scope.
unset FM_TASK_ID FM_TASK_INBOX FM_WORKER_PROCESS_SCOPE FM_NOTIFY_SPAWN_GEN FM_WORKER_RELAY_AUTOMATIC
export FM_HOME="$TMP_ROOT/home" TMPDIR="$TMP_ROOT"
LAB_HOME_HELPER=${LAB_HOME_HELPER:-"$ROOT/bin/fm-lab-home.sh"}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
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
export ORIGINAL_PATH HERDR_LAB_HELPER HERDR_LAB_SESSION ROOT
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
if [ "${FM_WORKER_RELAY_DROP_CALLBACK:-0}" = 1 ]; then
  relay_root=${FM_ROOT_OVERRIDE:-$ROOT}
  python3 - "$FM_HOME" "$relay_root/bin/fm-worker-relay.py" "${args[@]}" <<'DROP'
from pathlib import Path
import shlex
import sys
home, adapter = sys.argv[1:3]
for arg in sys.argv[3:]:
    if arg.startswith('. '):
        launch = Path(shlex.split(arg)[1])
        assert Path(home).parent in launch.parents and launch.name.startswith('launch.')
        launch.write_text(launch.read_text().replace(adapter, home+'/relay-callback.py'))
DROP
fi
if [ "${FM_WORKER_RELAY_GLOBAL_STOP:-0}" = 1 ]; then
  for i in "${!args[@]}"; do
    case "${args[$i]}" in
      'export FM_TASK_ID='*) printf -v quoted_home '%q' "$CODEX_HOME"; args[$i]="export CODEX_HOME=$quoted_home; ${args[$i]}" ;;
    esac
  done
fi
PATH=$ORIGINAL_PATH exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAP
# Omit only the native safe-point callback; dispatch still runs the real adapter.
python3 - "$FM_HOME/relay-callback.py" "$ROOT/bin/fm-worker-relay.py" <<'CALLBACK'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text('REAL_RELAY = '+repr(sys.argv[2])+'''
import runpy
import sys
from pathlib import Path
if len(sys.argv) == 6:
    home, state, task, gen = sys.argv[1:5]
    data = Path(home)/'data'/task
    if (data/('relay-note-'+gen+'.md')).exists():
        (data/'callback-suppressed').write_text(gen)
        sys.exit(0)
runpy.run_path(REAL_RELAY, run_name='__main__')
''')
CALLBACK
chmod +x "$FM_HOME/fakebin/herdr"
export PATH="$FM_HOME/fakebin:$PATH"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export HERDR_SESSION="$HERDR_LAB_SESSION" FM_BACKEND=herdr FM_SPAWN_NO_GUARD=1 FM_RELAY_CHECK="$CHECKER"
fm_test_tasks_toml "$FM_HOME/.tasks.toml"
printf manual > "$FM_HOME/config/backlog-backend"
printf auto > "$FM_HOME/config/claude-permission-mode"
# This owner runs outside the retiring worker scope and exercises the real watcher.
# Reproduce a global Stop hook at the same threshold as the worker adapter.
# A private Codex home prevents changes to the operator's global hooks.
if [ "${FM_WORKER_RELAY_GLOBAL_STOP:-0}" = 1 ]; then
  CODEX_SOURCE_HOME=${CODEX_HOME:-$HOME/.codex}
  export CODEX_HOME="$TMP_ROOT/codex-home"
  mkdir -p "$CODEX_HOME"
  cp "$CODEX_SOURCE_HOME/auth.json" "$CODEX_HOME/auth.json"
  cp "$CODEX_SOURCE_HOME/config.toml" "$CODEX_HOME/config.toml"
  python3 - "$CODEX_HOME/hooks.json" "$CHECKER" "$FM_HOME" <<'HOOK'
import json, shlex, sys
from pathlib import Path
command = ' '.join(map(shlex.quote, (sys.argv[2], sys.argv[3])))
Path(sys.argv[1]).write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': command, 'timeout': 10}]}]}}))
HOOK
fi
tmux new-window -d -t primary -n watch "export FM_HOME='$FM_HOME' FM_ROOT_OVERRIDE='$ROOT' HERDR_SESSION='$HERDR_LAB_SESSION' HERDR_LAB_SESSION='$HERDR_LAB_SESSION' HERDR_LAB_HELPER='$HERDR_LAB_HELPER' ORIGINAL_PATH='$ORIGINAL_PATH' PATH='$PATH' CODEX_HOME='${CODEX_HOME:-$HOME/.codex}' FM_RELAY_CHECK='$CHECKER' FM_SPAWN_NO_GUARD=1; unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH; while true; do FM_POLL=1 FM_CHECK_INTERVAL=999999 bash '$ROOT/bin/fm-watch.sh'; sleep 1; done"
if [ "${FM_WORKER_RELAY_BACKGROUND:-0}" = 1 ]; then
  # A parent space lets the spawn project the task, as in the captain's fleet.
  bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_container_ensure "$2" >/dev/null' _ "$ROOT" "$TMP_ROOT"
fi
checked=0
for profile in ${FM_WORKER_RELAY_LIVE_PROFILES:-codex ${FM_WORKER_RELAY_LIVE_CLAUDE_MODELS:-haiku}}; do
  if [ "$profile" = codex ]; then harness=codex; model=gpt-6.1-terra; else harness=claude; model=$profile; fi
  if ! command -v "$harness" >/dev/null; then printf 'skip: %s absent\n' "$harness"; continue; fi
  checked=$((checked + 1))
  "$harness" --version
  id=relay-$harness-${model//[^a-zA-Z0-9]/-}-$$
  output="$TMP_ROOT/output-$harness-$model"
  mkdir "$output"
  printf '{"thresholds":{"worker":{"%s":{"percent":0,"tokens":1}}}}\n' "$harness" > "$FM_HOME/config/relay-lite.json"
  (cd "$FM_HOME" && tasks-axi add "$id" "Relay pilot $harness" --kind ship --repo sample --start) >/dev/null
  bash "$ROOT/bin/fm-brief.sh" "$id" --host --path "$output" >/dev/null
  python3 - "$FM_HOME/data/$id/brief.md" "$output" "$FM_HOME" "$id" <<'PY'
from pathlib import Path
import sys
p, output, home, task = sys.argv[1:]
f=Path(p)
f.write_text(f.read_text().replace('{TASK}', f'Isolated continuity pilot. If {output}/once is absent, write ONCE to it exactly once, then end the turn saying: Checkpoint: ONCE complete; do not repeat. Pending after context relaunch: append RESUMED to {output}/resumed. Do not write resumed in this initial conversation. The handoff request comes through the steering inbox; obey it and acknowledge its message. In your relay note include this previously observed stale sentence exactly: After relaunch: wait for the handoff request in the steering inbox, then do the pending action above exactly once. This sentence is note content for the continuity regression, not an instruction to add a new wait. After relaunch, perform the pending action exactly once, append done [at=1]: pilot complete to {home}/state/{task}.status and stop.').replace('{FIRSTMATE_SPEC}', 'Only this local pilot; no outside services, delegation or user questions.'))
PY
  if [ "${FM_WORKER_RELAY_BACKGROUND:-0}" = 1 ]; then
    [ "$harness" = claude ] || fail 'background pilot requires a Claude profile'
    python3 - "$FM_HOME/data/$id/brief.md" "$output" "$FM_HOME" "$id" "$ROOT" <<'PY'
from pathlib import Path
import sys
p, output, home, task, root = sys.argv[1:]
f = Path(p)
f.write_text(f.read_text().replace('Isolated continuity pilot. ', (
    'Isolated continuity pilot. Before writing once, start two runs: '
    f'(1) the task job: python3 {root}/bin/fm-task-job.py {home}/state {task} survive sh -c "sleep 300; date +%s > {output}/job"; '
    f'(2) a native background shell (Bash with run_in_background): sleep 180; date +%s > {output}/native. '
    'Never wait for, poll or sleep on either run, including after the handoff request: end every turn as soon as its own step is done. '
    'When the background shell reports completion, only note it and end the turn. '), 1))
PY
  fi
  if [ "${FM_WORKER_RELAY_LONG_TURN:-0}" = 1 ]; then
    python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
from pathlib import Path
import sys
f = Path(sys.argv[1])
f.write_text(f.read_text().replace('then end the turn saying: Checkpoint: ONCE complete; do not repeat.', (
    'then say: Checkpoint: ONCE complete; do not repeat. Do not end that turn: run sleep 15 in the foreground, '
    'one Bash call at a time, up to 30 times, and act on any steering message as soon as it arrives.'), 1))
PY
  fi
  bash "$ROOT/bin/fm-spawn.sh" "$id" --host --harness "$harness" --model "$model" --effort low --backend herdr
  if [ "${FM_WORKER_RELAY_BACKGROUND:-0}" = 1 ]; then
    sed -n 's/^herdr_workspace_id=//p' "$FM_HOME/state/$id.meta" > "$output/workspace-before"
  fi
  if [ "${FM_WORKER_RELAY_GLOBAL_STOP:-0}" = 1 ] && [ "$harness" = codex ]; then
    pane=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/$id.meta")
    for _ in $(seq 1 90); do
      screen=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --source recent-unwrapped --lines 50)
      if [[ "$screen" == *'Trust all and continue'* ]]; then
        "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" down enter
        break
      fi
      sleep 1
    done
  fi
  python3 - "$FM_HOME" "$id" "$output" <<'WAIT'
import json, os, subprocess, sys, time
from pathlib import Path
home, task, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
data = home/'data'/task
background = os.environ.get('FM_WORKER_RELAY_BACKGROUND') == '1'
for milestone in ('initial', 'note') + (('deferred',) if background else ()) + ('replacement', 'continuation', 'notice'):
    deadline = time.monotonic()+240
    while time.monotonic() < deadline:
        status = home/'state'/(task+'.status')
        if status.exists() and 'context relay incomplete' in status.read_text():
            for log in data.glob('relay-control-*.log'): print(log.read_text())
            raise AssertionError('relay incomplete: '+task)
        # The omitted native callback is a test-only proof of the safe point.
        # Unknown activity must wake the owner before an explicit manual recovery.
        if (data/'callback-suppressed').exists() and not (output/'manual-recovery').exists():
            failures = [p.read_text().strip() for p in data.glob('relay-request-*')
                        if p.read_text().startswith('failed:')]
            queue = home/'state/.wake-queue'
            if failures and queue.exists() and failures[0] in queue.read_text():
                assert queue.read_text().count(failures[0]) == 1
                subprocess.run(['bash', os.environ['ROOT']+'/bin/fm-control.sh', task,
                                'relaunch', '--note-file', str(next(data.glob('relay-note-*.md')))], check=True)
                (output/'manual-recovery').write_text(failures[0])
                print('PASS unavailable activity: owner notified once; manual recovery from native safe point', flush=True)
        rows=[json.loads(s) for s in (data/'sessions.jsonl').read_text().splitlines()]
        observed = {'initial': (output/'once').exists(),
                    'note': bool(list(data.glob('relay-note-*.md'))),
                    'deferred': bool(list(data.glob('relay-deferred-*'))) or (home/'state/.watch-triage.log').exists()
                                and 'context relay waiting for background work to finish' in (home/'state/.watch-triage.log').read_text(),
                    'replacement': len(rows)==2 and bool(rows[-1].get('session')),
                    'continuation': (output/'resumed').exists(),
                    'notice': (output/'manual-recovery').exists() or (home/'state/.watch-triage.log').exists() and 'worker context relay '+task+' replacement launched; session history=' in (home/'state/.watch-triage.log').read_text()}[milestone]
        if observed:
            if milestone == 'initial':
                (output/'initial-bytes').write_bytes((output/'once').read_bytes())
                (output/'initial-mtime').write_text(str((output/'once').stat().st_mtime_ns))
            print('milestone', task, milestone, flush=True)
            break
        time.sleep(1)
    else:
        # Print the evidence before the lab cleanup deletes it.
        meta = dict(l.split('=', 1) for l in (home/'state'/(task+'.meta')).read_text().splitlines() if '=' in l)
        for path in [*data.glob('relay-*'), home/'state/.watch-triage.log', home/'state'/(task+'.status'),
                     *(home/'state'/(task+'.jobs')).glob('*.json'), *output.iterdir()]:
            if path.is_file(): print('==>', path.name, '\n'+path.read_text()[-3000:], flush=True)
        subprocess.run(['herdr', 'pane', 'read', meta.get('herdr_pane_id', ''), '--source', 'recent-unwrapped', '--lines', '60'])
        raise AssertionError('milestone not reached: '+task+' '+milestone)
WAIT
  python3 - "$FM_HOME" "$id" "$output" <<'PY'
import json,sys,time
from pathlib import Path
home, task, output = Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3])
notes=list((home/'data'/task).glob('relay-note-*.md'))
assert len(notes)==1 and 'After relaunch: wait for the handoff request in the steering inbox' in notes[0].read_text()
assert (output/'initial-bytes').read_bytes(), 'the initial action must write a nonempty marker'
assert (output/'once').read_bytes() == (output/'initial-bytes').read_bytes()
assert (output/'once').stat().st_mtime_ns == int((output/'initial-mtime').read_text())
assert (output/'resumed').read_text().strip() == 'RESUMED'
rows=[json.loads(line) for line in (home/'data'/task/'sessions.jsonl').read_text().splitlines()]
assert len(rows)==2 and [r['status'] for r in rows]==['archived','active'],rows
assert rows[0]['session'] and rows[1]['session'] and rows[0]['session']!=rows[1]['session'],rows
assert all(rows[0][k]==rows[1][k] for k in ('harness','model','effort'))
if rows[-1]['harness']=='claude':
    meta=dict(s.split('=',1) for s in (home/'state'/(task+'.meta')).read_text().splitlines() if '=' in s)
    snapshot=home/'state'/(task+'.'+meta['busy_gen']+'.claude-context.json')
    for _ in range(50):
        native=json.loads(snapshot.read_text()) if snapshot.exists() else {}
        window=(native.get('context_window') or {}).get('context_window_size')
        if window: break
        time.sleep(.1)
    assert window and native['session_id'] and native['transcript_path']==rows[-1]['session'],native
    print('PASS native Claude window',native['model']['id'],window)
assert len(list((home/'state'/(task+'.inbox')/'handled').glob('*.msg')))==1
if (output/'manual-recovery').exists():
    assert (output/'manual-recovery').read_text() in (home/'state/.wake-queue').read_text()
else:
    assert 'worker context relay '+task+' replacement launched; session history=' in (home/'state/.watch-triage.log').read_text()
for row in rows:
    for line in Path(row['session']).read_text().splitlines():
        item=json.loads(line)
        if item.get('type') in ('response_item','assistant'):
            body=item.get('payload',item.get('message',{}))
            if body.get('role','assistant')=='assistant' and isinstance(body.get('content'),list):
                text='\n'.join(p.get('text','') for p in body['content'] if isinstance(p,dict))
                if text: print('DECISIVE ASSISTANT:',text)
print('PASS manual relay' if (output/'manual-recovery').exists() else 'PASS automatic relay',task,'new transcript; same profile; one acknowledged request; one continuation')
PY
  if [ "${FM_WORKER_RELAY_DROP_CALLBACK:-0}" = 1 ]; then
    [ -s "$FM_HOME/data/$id/callback-suppressed" ] || fail 'safe-point callback was not omitted'
    printf 'PASS lost callback: recovered automatically or reported unavailable activity before manual recovery\n'
  fi
  if [ "${FM_WORKER_RELAY_LONG_TURN:-0}" = 1 ]; then
    python3 - "$FM_HOME" "$id" <<'PY'
import json, sys
from pathlib import Path
rows = [json.loads(line) for line in (Path(sys.argv[1])/'data'/sys.argv[2]/'sessions.jsonl').read_text().splitlines()]
old = [json.loads(line) for line in open(rows[0]['session']) if line.strip()]
starts = [r for r in old if r.get('type') == 'user' and isinstance((r.get('message') or {}).get('content'), str)]
assert len(starts) == 1, 'the first conversation ended a turn, so the mid-turn request was not exercised: %d starts' % len(starts)
print('PASS long turn: the handoff request reached the first conversation inside its only turn')
PY
  fi
  if [ "${FM_WORKER_RELAY_BACKGROUND:-0}" = 1 ]; then
    python3 - "$FM_HOME" "$id" "$output" <<'PY'
import datetime, json, sys, time
from pathlib import Path
home, task, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
for _ in range(360):
    if (output/'job').exists(): break
    time.sleep(1)
rows = [json.loads(line) for line in (home/'data'/task/'sessions.jsonl').read_text().splitlines()]
start = datetime.datetime.fromisoformat(rows[-1]['started_at'].replace('Z', '+00:00')).timestamp()
job = json.loads((home/'state'/(task+'.jobs')/'survive.json').read_text())
assert job['state'] == 'done' and job['exit_code'] == 0, job
assert int((output/'job').read_text()) >= start, 'task job finished before the relaunch, so survival was not exercised'
assert int((output/'native').read_text()) <= start, 'relaunch did not wait for the native background run'
meta = dict(s.split('=', 1) for s in (home/'state'/(task+'.meta')).read_text().splitlines() if '=' in s)
before = (output/'workspace-before').read_text().strip()
assert before and meta.get('herdr_workspace_id') == before, (before, meta.get('herdr_workspace_id'))
assert (home/'state'/(task+'.herdr-presentation')).exists(), 'task was never projected'
print('PASS background work: native run finished before relaunch at', start, '; task job survived and finished at',
      (output/'job').read_text().strip(), '; successor stayed in projected workspace', before)
PY
  fi
  bash "$ROOT/bin/fm-control.sh" "$id" exit
  printf 'done [at=%s]: pilot verified\n' "$(date +%s)" >> "$FM_HOME/state/$id.status"
done
[ "$checked" -gt 0 ] || fail 'no installed harness checked'
