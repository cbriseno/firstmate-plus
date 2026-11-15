#!/usr/bin/env bash
# Host tasks use disposable non-Git scratch and preserve authorized host files.
# shellcheck disable=SC1091
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-task)
TASK_HOME="$TMP_ROOT/home"
TASK_ID="host-test-$$"
fm_test_spawn_home "$TASK_HOME" codex
printf 'manual\n' > "$TASK_HOME/config/backlog-backend"
mkdir -p "$TASK_HOME/user-home"
FAKEBIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
TARGET="$TMP_ROOT/host-file"
printf 'preserve\n' > "$TARGET"
run_brief() {
  FM_HOME="$TASK_HOME" HOME="$TASK_HOME/user-home" bash "$ROOT/bin/fm-brief.sh" "$@"
}
run_brief "$TASK_ID" --host --path "$TARGET"
python3 - "$TASK_HOME/data/$TASK_ID/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Set up a host file.').replace('{FIRSTMATE_SPEC}','Verify the operation.'))
PY
export FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log"
export FM_FAKE_PANE_LOG="$TMP_ROOT/pane.log"
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/$TASK_ID/work" "$FAKEBIN" "$TASK_ID" --host --harness 'git rev-parse --show-toplevel > git-output 2>/dev/null && exit 99; printf fake-harness > harness-ran' --backend tmux) || fail "host spawn failed: $OUT"
LAUNCH=$(cat "$FM_FAKE_LAUNCH_LOG")
(cd "$TASK_HOME/data/$TASK_ID/work" && HOME="$TASK_HOME/user-home" /bin/sh -c "$LAUNCH") || fail 'fake harness command failed'
[ -f "$TASK_HOME/data/$TASK_ID/work/harness-ran" ] || fail 'host harness did not run'
[ ! -s "$TASK_HOME/data/$TASK_ID/work/git-output" ] || fail 'host Git discovery escaped scratch'
assert_contains "$OUT" 'kind=host' 'host kind recorded'
[ -d "$TASK_HOME/data/$TASK_ID/work" ] || fail 'host scratch missing'
[ ! -e "$TASK_HOME/data/$TASK_ID/work/.git" ] || fail 'host scratch must not be a Git repository'
[ "$(sed -n "s/^kind=//p" "$TASK_HOME/state/$TASK_ID.meta")" = host ] || fail 'host metadata kind missing'
[ -z "$(sed -n "s/^mode=//p" "$TASK_HOME/state/$TASK_ID.meta")" ] || fail 'host has a delivery mode'
[ -z "$(sed -n "s/^branch=//p" "$TASK_HOME/state/$TASK_ID.meta")" ] || fail 'host has a branch'
jq -e '.project == null and .status == "active" and .reason == "awaiting-transcript"' \
  "$TASK_HOME/data/$TASK_ID/sessions.jsonl" >/dev/null || fail 'host session invented a project'
printf 'done [at=100]: host operation verified\n' >> "$TASK_HOME/state/$TASK_ID.status"
touch "$TASK_HOME/state/$TASK_ID.relay-ready" "$TASK_HOME/state/$TASK_ID.relay-result"
OUT=$(FM_HOME="$TASK_HOME" HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 \
  FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
  FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_PROJECTS_OVERRIDE="$TASK_HOME/projects" \
  bash "$ROOT/bin/fm-teardown.sh" "$TASK_ID" 2>&1) || fail "host teardown failed: $OUT"
[ ! -e "$TASK_HOME/data/$TASK_ID/work" ] || fail 'teardown left host scratch'
[ ! -e "$TASK_HOME/state/$TASK_ID.relay-ready" ] && [ ! -e "$TASK_HOME/state/$TASK_ID.relay-result" ] || fail 'teardown left relay signals'
[ "$(cat "$TARGET")" = preserve ] || fail 'teardown changed host target'
pass 'first host assignment launches and tears down without a project or commit'

# Run the emitted Claude command: a host grant must not swallow --settings.
run_brief claude-host --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/claude-host/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Check Claude host launch.').replace('{FIRSTMATE_SPEC}','Preserve hooks.'))
PY
export FM_HOST_ARGV="$TMP_ROOT/claude-argv.json"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '2.1.325\n'; exit 0; fi
python3 -c 'import json,sys;json.dump(sys.argv[2:],open(sys.argv[1],"w"))' "$FM_HOST_ARGV" "$@"
SH
chmod +x "$FAKEBIN/claude"
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/claude-host/work" "$FAKEBIN" claude-host --host --harness claude --backend tmux) || fail "Claude host spawn failed: $OUT"
LAUNCH=$(cat "$FM_FAKE_LAUNCH_LOG")
(cd "$TASK_HOME/data/claude-host/work" && HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" /bin/sh -c "$LAUNCH") || fail 'Claude host command failed'
jq -e --arg settings "$TASK_HOME/state/claude-host.claude-settings.json" \
  'index("--settings") as $i | $i != null and .[$i+1] == $settings' \
  "$FM_HOST_ARGV" >/dev/null || fail 'Claude host launch lost its hook settings argument'
pass 'Claude host launch delivers hook settings as a separate argument'
# Exercise the relay adapter through its executable interface with a checker
# fixture. Real Codex/Claude callback and lifecycle evidence belongs to the lab.
python3 - "$ROOT" "$TMP_ROOT" <<'PYRELAY'
import json, os, pathlib, shutil, subprocess, sys, time
root, tmp = map(pathlib.Path, sys.argv[1:])
lab = tmp / 'relay'
bin_dir = lab / 'bin'
state, data = lab / 'state', lab / 'data' / 'worker'
for path in (bin_dir, state, data, lab / 'config'):
    path.mkdir(parents=True, exist_ok=True)
for name in ('fm-worker-relay.py', 'fm-redact-log.py'):
    shutil.copy(root / 'bin' / name, bin_dir / name)
for name, body in {
    'fm-send.sh': 'printf requested >> "$FM_HOME/requests"',
    'fm-control.sh': 'printf "%s\\n" "$@"; exit "${RELAY_FAIL:-0}"',
    'fm-diag.sh': 'exit 0',
}.items():
    (bin_dir / name).write_text('#!/usr/bin/env bash\n' + body + '\n')
checker = lab / 'checker'
checker.write_text('import json,os; print(json.dumps({"schema":"relay-lite.check.v1","state":os.environ.get("RELAY_STATE","reached")}))')
(lab / 'config/relay-lite.json').write_text('{}')
(data / 'sessions.jsonl').write_text(json.dumps({'status':'active','session':'old-session'})+'\n')
(state / 'worker.meta').write_text('kind=host\nbusy_gen=launch1\nworktree='+str(data)+'\nsessions_file='+str(data/'sessions.jsonl')+'\nharness=codex\nmodel=chosen\neffort=high\n')
args = [sys.executable, str(bin_dir/'fm-worker-relay.py'), str(lab), str(state), 'worker', 'launch1', str(checker)]
def run(extra=(), **env):
    subprocess.run(args+list(extra), env=dict(os.environ, **env), check=True)
def wait(path):
    for _ in range(100):
        if path.exists(): return
        time.sleep(.05)
    raise AssertionError('missing '+str(path))
run(RELAY_STATE='unknown')
assert not (lab/'requests').exists()
native={'session_id':'one','transcript_path':'old-session','model':{'id':'claude-opus-5-5'},
        'context_window':{'context_window_size':1000000}}
(state/'worker.launch1.claude-context.json').write_text(json.dumps(native))
record=state/'worker.meta'
record.write_text(record.read_text().replace('harness=codex','harness=claude'))
checker.write_text('import json,os,pathlib,sys; p=json.load(sys.stdin); pathlib.Path(os.environ["RELAY_PAYLOAD"]).write_text(json.dumps(p)); print(json.dumps({"schema":"relay-lite.check.v1","state":"unknown"}))')
run(RELAY_PAYLOAD=str(lab/'payload'))
assert json.loads((lab/'payload').read_text())['statusline']==native
record.write_text(record.read_text().replace('harness=claude','harness=codex'))
checker.write_text('import json,os; print(json.dumps({"schema":"relay-lite.check.v1","state":os.environ.get("RELAY_STATE","reached")}))')
subprocess.run(args[:5]+['stale',str(checker)], check=True)
run()
wait(lab/'requests')
run()  # Replayed completion must not queue another handoff request.
time.sleep(.2)
assert (lab/'requests').read_text() == 'requested'
note=data/'relay-note-launch1.md'
note.write_text('Finished ONCE. Continue pending inbox; never repeat ONCE.')
run()
ready=state/'worker.relay-ready'
assert ready.exists()
subprocess.run([sys.executable,str(bin_dir/'fm-worker-relay.py'),'--dispatch',str(lab),str(state)],check=True)
result=state/'worker.relay-result'
wait(result)
assert 'replacement launched' in result.read_text()
control=(data/'relay-control-launch1.log').read_text()
assert '--note-file\n'+str(note) in control
assert '--harness\ncodex\n--model\nchosen\n--effort\nhigh' in control
result.unlink()
run()
subprocess.run([sys.executable,str(bin_dir/'fm-worker-relay.py'),'--dispatch',str(lab),str(state)],env=dict(os.environ,RELAY_FAIL='1'),check=True)
wait(result)
assert 'incomplete' in result.read_text() and note.exists()
result.unlink()
(state/'worker.status').write_text('done [at=1]: complete\n')
run()
assert not ready.exists() and not result.exists()
# A legitimate slow delivery must finish through fm-send's own bounded protocol,
# rather than disappearing at an unrelated 90-second wrapper deadline.
(state/'worker.status').unlink()
(data/'relay-request-launch1').unlink()
(bin_dir/'fm-send.sh').write_text('#!/usr/bin/env bash\nsleep 91\nprintf delivered > "$FM_HOME/slow-delivered"\n')
run(('--request','999999999'))
assert (lab/'slow-delivered').read_text() == 'delivered'
assert (data/'relay-request-launch1').read_text() == 'requested\n'
assert 'handoff requested' in (state/'worker.status').read_text()
print('ok - relay checker gates requests, duplicate callbacks, note/profile preservation, owner control, failure and terminal work')
PYRELAY
# Feed the native vendor statusline through the public wrapper. Existing display
# receives unchanged JSON, local overrides user settings, and only native fields persist.
python3 - "$ROOT" "$TMP_ROOT" <<'PYCONTEXT'
import json, pathlib, shlex, subprocess, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
lab=tmp/'native-context'
store, project = lab/'store', lab/'project'
for p in (store, project/'.claude'): p.mkdir(parents=True)
settings=lab/'settings.json'; settings.write_text('{"feedbackDrafts":"off"}')
(store/'settings.json').write_text(json.dumps({'statusLine':{'type':'command','command':'printf user'}}))
display=shlex.join([sys.executable,'-c','import json,sys; print(json.load(sys.stdin)["model"]["id"])'])
(project/'.claude/settings.local.json').write_text(json.dumps({'statusLine':{'type':'command','command':display,'padding':2}}))
snapshot=lab/'launch1.claude-context.json'
subprocess.run([sys.executable,str(root/'bin/fm-claude-context.py'),'setup',str(settings),str(project),str(store),str(snapshot)],check=True)
configured=json.loads(settings.read_text())
assert configured['feedbackDrafts']=='off' and configured['statusLine']['padding']==2
native={'session_id':'one','transcript_path':'/one.jsonl','model':{'id':'claude-opus-5-5'},
        'context_window':{'context_window_size':1000000,'used_percentage':26},'unrelated':'omit'}
result=subprocess.run(configured['statusLine']['command'],shell=True,input=json.dumps(native),text=True,capture_output=True,check=True)
assert result.stdout.strip()=='claude-opus-5-5',result
assert json.loads(snapshot.read_text())=={k:v for k,v in native.items() if k!='unrelated'}
native.update(session_id='two',transcript_path='/two.jsonl')
subprocess.run(configured['statusLine']['command'],shell=True,input=json.dumps(native),text=True,capture_output=True,check=True)
assert json.loads(snapshot.read_text())['session_id']=='two'
print('ok - Claude native window capture preserves effective display, payload, settings and session identity')
PYCONTEXT
for target in relative/path "$ROOT/AGENTS.md" "$TASK_HOME/projects/new/file"; do
  if run_brief "bad-$RANDOM" --host --path "$target" >/dev/null 2>&1; then fail "unsafe host path accepted: $target"; fi
done
# A pre-existing scratch or a forged cleanup path must never be reused/deleted.
run_brief occupied --host --path "$TARGET" >/dev/null
mkdir "$TASK_HOME/data/occupied/work"
if fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/occupied/work" "$FAKEBIN" occupied --host --harness 'echo fake' >/dev/null; then fail 'existing scratch was reused'; fi
printf 'off\n' > "$TASK_HOME/config/primary-direct-ops"
if run_brief disabled --host --path "$TARGET" >/dev/null 2>&1; then fail 'off must disable host tasks'; fi
pass 'host paths and disabled configuration refuse unsafe launch contracts'
