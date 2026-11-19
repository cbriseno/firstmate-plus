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
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Set up a host file.').replace('{FIRSTMATE_SPEC}','Verify the operation.').replace('{CAPTAIN_REQUIREMENTS}','1. Fixture requirement.'))
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

# A status publication must wake its owner without relying on a running watcher
# or a later turn-end. Routine appends cannot requeue an already published span.
publish_status() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" bash "$ROOT/bin/fm-task-status.sh" "$@"
}
publish_status instant working setup
[ ! -s "$TASK_HOME/state/.wake-queue" ] || fail 'routine setup queued a wake'
for event in needs-decision blocked 'done' failed; do
  publish_status instant "$event" "event $event"
  count=$(wc -l < "$TASK_HOME/state/.wake-queue")
  publish_status instant working cleanup
  [ "$(wc -l < "$TASK_HOME/state/.wake-queue")" = "$count" ] \
    || fail 'routine progress requeued an old event'
done
[ "$(wc -l < "$TASK_HOME/state/.wake-queue")" -eq 4 ] || fail 'missing immediate status wake'
grep -F 'needs-decision:' "$TASK_HOME/state/.wake-queue" >/dev/null \
  || fail 'waiting status lost its decision routing'
grep -Eq '^done \[at=[0-9]+\]: event done$' "$TASK_HOME/state/instant.status" \
  || fail 'publication lost the timestamp or status text'
count=$(wc -l < "$TASK_HOME/state/.wake-queue")
publish_status instant paused 'intentional wait'
[ "$(wc -l < "$TASK_HOME/state/.wake-queue")" = "$count" ] || fail 'a pause queued an immediate wake'
pass 'decisions and terminal statuses queue immediately; progress and pauses stay informational'

# Detection is unchanged; inject its verified-idle verdict and drive the real
# close policy and teardown against the same disposable host fixture.
run_completion_tick() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" \
    FM_DATA_OVERRIDE="$TASK_HOME/data" FM_CONFIG_OVERRIDE="$TASK_HOME/config" \
    HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" bash -c '
      . "$1"
      fm_busy_classify_meta() { printf "idle fixture"; }
      wake() { printf "%s\n" "$1"; }
      worker_completion_tick
    ' _ "$ROOT/bin/fm-watch.sh"
}
run_brief auto-close --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/auto-close/brief.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Finish host work.').replace('{FIRSTMATE_SPEC}', 'Close safely.').replace('{CAPTAIN_REQUIREMENTS}', '1. Fixture requirement.'))
PY
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/auto-close/work" "$FAKEBIN" auto-close --host --harness 'printf fixture' --backend tmux) || fail "auto-close spawn failed: $OUT"
publish_status auto-close 'done' verified
OUT=$(run_completion_tick) || fail "completion tick failed: $OUT"
[ ! -e "$TASK_HOME/state/auto-close.meta" ] || fail "completed host remained open: $OUT"
[ ! -e "$TASK_HOME/data/auto-close/work" ] || fail 'completed host scratch remained'
[ "$(cat "$TARGET")" = preserve ] || fail 'automatic close changed the host target'
pass 'a verified idle done host closes through ordinary teardown and preserves its target'

printf 'kind=host\n' > "$TASK_HOME/state/unexplained.meta"
printf 'working: started\n' > "$TASK_HOME/state/unexplained.status"
run_completion_tick >/dev/null
python3 - "$TASK_HOME/state/.worker-idle-unexplained" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time() - 1801, time.time() - 1801))
PY
OUT=$(run_completion_tick) || fail "idle tick failed: $OUT"
assert_contains "$OUT" 'idle without a result or declared wait for over 30 minutes' 'unexplained idle individual wake'
assert_contains "$(cat "$TASK_HOME/state/.wake-queue")" 'worker-idle:unexplained' 'unexplained idle queued individually'
[ -e "$TASK_HOME/state/unexplained.meta" ] || fail 'idle alert discarded unfinished work'
printf 'blocked: needs an owner answer\n' >> "$TASK_HOME/state/unexplained.status"
run_completion_tick >/dev/null
[ ! -e "$TASK_HOME/state/.worker-idle-unexplained" ] || fail 'a declared wait kept the unexplained-idle timer'
rm "$TASK_HOME/state/unexplained.meta"
pass 'unexplained idle wakes individually without discarding work; a declared wait resets it'

printf 'kind=host\n' > "$TASK_HOME/state/kept.meta"
printf 'done: finished\n' > "$TASK_HOME/state/kept.status"
mkdir -p "$TASK_HOME/state/kept.inbox"
printf 'read me\n' > "$TASK_HOME/state/kept.inbox/001.msg"
run_completion_tick >/dev/null
run_completion_tick >/dev/null
[ "$(grep -c 'worker done but kept open: kept; unread steering 001.msg' "$TASK_HOME/state/.watch-triage.log")" = 1 ] \
  || fail 'a done worker kept open by unread steering was not explained exactly once'
[ -e "$TASK_HOME/state/kept.meta" ] || fail 'the kept-open explanation closed the worker'
rm -rf "$TASK_HOME/state/kept.meta" "$TASK_HOME/state/kept.inbox"
pass 'a done worker kept open by unread steering is explained once'

backdate() {  # <path>: 31 minutes old
  python3 -c 'import os,sys,time; t=time.time()-1860; os.utime(sys.argv[1],(t,t))' "$1"
}
printf 'kind=host\n' > "$TASK_HOME/state/waiting.meta"
printf 'needs-decision [key=name]: which name\n' > "$TASK_HOME/state/waiting.status"
OUT=$(run_completion_tick) || fail "waiting tick failed: $OUT"
[ -e "$TASK_HOME/state/.worker-wait-waiting" ] || fail 'an idle open decision started no wait timer'
case "$OUT" in *park*) fail "a fresh wait was parked at once: $OUT" ;; esac
backdate "$TASK_HOME/state/.worker-wait-waiting"
OUT=$(run_completion_tick) || fail "waiting tick failed: $OUT"
assert_contains "$OUT" 'worker automatic park refused: waiting' 'a 30-minute idle open decision attempts park'
[ -e "$TASK_HOME/state/waiting.meta" ] || fail 'the park attempt discarded the waiting worker'
rm -f "$TASK_HOME/state/.worker-wait-waiting"
printf 'paused: own test run until %s\n' "$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -v+10M +%Y-%m-%dT%H:%MZ)" > "$TASK_HOME/state/waiting.status"
run_completion_tick >/dev/null
[ ! -e "$TASK_HOME/state/.worker-wait-waiting" ] || fail 'a short pause for the worker own job was timed for parking'
rm -f "$TASK_HOME/state/waiting.meta" "$TASK_HOME/state/waiting.status"
pass 'a worker idle 30 minutes on an open decision is parked, never one pausing for its own short job'

# A delivered worker that owns an open review board stays open until the board ends.
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-store"
mkdir -p "$LAVISH_AXI_STATE_DIR" "$TASK_HOME/data/hosting"
: > "$TASK_HOME/data/hosting/report.html"
printf 'kind=host\n' > "$TASK_HOME/state/hosting.meta"
printf 'done: finished\n' > "$TASK_HOME/state/hosting.status"
jq -n --arg f "$(realpath "$TASK_HOME/data/hosting/report.html")" \
  '{sessions:{one:{key:"one",file:$f,status:"open",url:"http://127.0.0.1:1/session/0123456789abcdef"}}}' \
  > "$LAVISH_AXI_STATE_DIR/state.json"
run_completion_tick >/dev/null
run_completion_tick >/dev/null
[ "$(grep -c 'worker done but kept open: hosting; it owns an open review board' "$TASK_HOME/state/.watch-triage.log")" = 1 ] \
  || fail 'a done worker owning an open board was not explained exactly once'
[ -e "$TASK_HOME/state/hosting.meta" ] || fail 'a worker owning an open board was closed'
rm -f "$TASK_HOME/state/hosting.meta" "$TASK_HOME/state/hosting.status" "$LAVISH_AXI_STATE_DIR/state.json"
unset LAVISH_AXI_STATE_DIR
pass 'a done worker that owns an open review board stays open and is explained once'

# The batch close runs the real snapshot, board list and teardown on a delivered host.
run_brief batch-close --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/batch-close/brief.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Finish host work.').replace('{FIRSTMATE_SPEC}', 'Close in a batch.').replace('{CAPTAIN_REQUIREMENTS}', '1. Fixture requirement.'))
PY
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/batch-close/work" "$FAKEBIN" batch-close --host --harness 'printf fixture' --backend tmux) || fail "batch-close spawn failed: $OUT"
publish_status batch-close 'done' verified
run_batch() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_PROJECTS_OVERRIDE="$TASK_HOME/projects" \
    HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 bash "$ROOT/bin/fm-close-delivered.sh" "$@"
}
OUT=$(run_batch list 2>&1) || fail "close list failed: $OUT"
assert_contains "$OUT" 'batch-close | host | delivered' 'the view lists the delivered host'
OUT=$(run_batch close batch-close 2>&1) || fail "batch close failed: $OUT"
assert_contains "$OUT" '[1/1] batch-close: closed' 'the batch close reports progress'
[ ! -e "$TASK_HOME/state/batch-close.meta" ] || fail 'the batch close left the worker open'
[ "$(cat "$TARGET")" = preserve ] || fail 'the batch close changed the host target'
pass 'the batch close closes a delivered host through the real snapshot and teardown'

# Run the emitted Claude command: a host grant must not swallow --settings.
run_brief claude-host --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/claude-host/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Check Claude host launch.').replace('{FIRSTMATE_SPEC}','Preserve hooks.').replace('{CAPTAIN_REQUIREMENTS}','1. Fixture requirement.'))
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
def wait(path, contains=''):
    for _ in range(100):
        if path.exists() and contains in path.read_text(): return
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
wait(result, 'replacement launched')
assert 'replacement launched' in result.read_text()
control=(data/'relay-control-launch1.log').read_text()
assert '--note-file\n'+str(note) in control
assert '--harness\ncodex\n--model\nchosen\n--effort\nhigh' in control
result.unlink()
run()
subprocess.run([sys.executable,str(bin_dir/'fm-worker-relay.py'),'--dispatch',str(lab),str(state)],env=dict(os.environ,RELAY_FAIL='1'),check=True)
wait(result, 'incomplete')
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
assert 'handoff requested' in (state/'worker.relay-result').read_text()
# A turn that never ends never reaches the native callback; the watcher checks it mid-turn.
(bin_dir/'fm-send.sh').write_text('#!/usr/bin/env bash\nprintf requested >> "$FM_HOME/requests"\n')
for path in (data/'relay-request-launch1', lab/'requests', state/'worker.relay-result'): path.unlink()
(state/'worker.busy-state').write_text('v1 gen=launch1 seq=3 state=busy source=claude-hook event=user-prompt-submit ts=1\n')
dispatch = [sys.executable, str(bin_dir/'fm-worker-relay.py'), '--dispatch', str(lab), str(state)]
watcher = dict(os.environ, FM_RELAY_CHECK=str(checker))
subprocess.run(dispatch, env=watcher, check=True)  # A note written mid-turn is not a safe point.
time.sleep(1.5)
assert not ready.exists() and not (lab/'requests').exists()
os.utime(data/'relay-midturn-launch1', (0, 0))
note.unlink()
subprocess.run(dispatch, env=watcher, check=True)
wait(lab/'requests')
subprocess.run(dispatch, env=watcher, check=True)
time.sleep(.5)
assert (lab/'requests').read_text() == 'requested' and not ready.exists()
print('ok - relay checker gates requests, duplicate callbacks, note/profile preservation, owner control, failure, terminal work and mid-turn thresholds')
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
