#!/usr/bin/env bash
# Public argv notification interface and installation language behavior.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as tmp:
    home=pathlib.Path(tmp); (home/'config').mkdir()
    def run(*args):
        return subprocess.run([sys.executable,str(root/'bin/fm-notify.py'),'--home',str(home),'--event','ready','--text','literal $(touch unwanted); text',*args],capture_output=True)
    assert run().returncode==0
    consumer=home/'consumer.py'; receipt=home/'receipt.json'
    consumer.write_text('import json,sys; from pathlib import Path; Path(sys.argv[1]).write_text(json.dumps([sys.argv[2:], json.load(sys.stdin)]))')
    config=home/'config/notification-command.json'
    config.write_text(json.dumps([sys.executable,str(consumer),str(receipt)]))
    assert run().returncode==0
    args,event=json.loads(receipt.read_text()); assert args==['ready',event['text']]
    assert not (home/'unwanted').exists()
    override=home/'override.json';override.write_bytes(config.read_bytes())
    config.write_text('{'); assert run().returncode==2
    assert run('--command-file',str(override)).returncode==0
    assert run('--command-file','relative.json').returncode==2
    config.write_text(json.dumps(['missing-notification-executable'])); assert run().returncode==1
    config.write_text(json.dumps([sys.executable,'-c','import time; time.sleep(10)'])); assert run().returncode==1
    env=dict(os.environ,FM_HOME=str(home),PYTHONPATH=str(root/'bin')); env.pop('FM_LANGUAGE',None)
    command=[sys.executable,'-c',"from fm_delivery import receipt_message; print(receipt_message('answered'))"]
    assert subprocess.check_output(command,env=env,text=True).strip()=='Firstmate recorded an answer.'
    (home/'config/language').write_text('es\n')
    assert subprocess.check_output(command,env=env,text=True).strip()=='Firstmate registró una respuesta.'
    env['FM_LANGUAGE']='en'
    assert subprocess.check_output(command,env=env,text=True).strip()=='Firstmate recorded an answer.'
print('ok - disabled notifications, literal argv, failures, timeout and installation language')
PY

# Real disposable tmux panels exercise the watcher, including its primary path.
if ! command -v tmux >/dev/null 2>&1; then echo 'skip - login panels require tmux'; exit 0; fi
TASK_TMP=$(mktemp -d "${GOTMPDIR:-${TMPDIR:-/tmp}}/fm-login.XXXXXX")
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
export FM_HOME="$TASK_TMP/home"
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null
unset TMUX TMUX_PANE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
export TMUX_TMPDIR
TMUX_TMPDIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")
trap 'tmux kill-server 2>/dev/null || true; "$LAB_HOME_HELPER" teardown "$FM_HOME"; rm -rf -- "$TASK_TMP"' EXIT
python3 - "$FM_HOME" <<'PY'
import json, pathlib, sys
h=pathlib.Path(sys.argv[1]); (h/'config/notification-command.json').write_text(json.dumps([
    sys.executable, '-c', 'import sys; open(sys.argv[1],"a").write(sys.argv[-1]+"\\n")', str(h/'notices')]))
PY
tmux new-session -d -s auth -x 160 -y 40 'printf "Login expired · Please run /login\n"; exec sleep 300'
tmux new-window -d -t auth -n fm-worker 'printf "Your access token could not be refreshed because your refresh token has expired. Please log out and sign in again.\n"; exec sleep 300'
printf 'backend=tmux\nwindow=auth:fm-worker\n' > "$FM_HOME/state/worker.meta"
export FM_SUPERVISOR_TARGET=auth:0 FM_SUPERVISOR_BACKEND=tmux
# shellcheck source=/dev/null # Production watcher is linted separately.
. "$ROOT/bin/fm-watch.sh"
sleep 0.2
login_expiry_tick
login_expiry_tick
[ "$(grep -c 'login expired:' "$FM_HOME/notices")" = 2 ]
grep -q 'Claude.*primary.*run /login' "$FM_HOME/notices"
grep -q 'Codex.*worker.*codex logout, then codex login' "$FM_HOME/notices"
# Re-arm in a fresh shell preserves the episode marker.
bash -c '. "$1/bin/fm-watch.sh"; login_expiry_tick' _ "$ROOT"
[ "$(grep -c 'login expired:' "$FM_HOME/notices")" = 2 ]
login_expiry_notice tmux auth:0 primary 'Authenticated successfully'
login_expiry_tick
[ "$(grep -c 'login expired:' "$FM_HOME/notices")" = 3 ]
# A rejected delivery remains retryable.
rm -f -- "$STATE/.login-expired-tmux-auth_fm-worker"
printf '["false"]\n' > "$FM_HOME/config/notification-command.json"
login_expiry_tick
[ ! -e "$STATE/.login-expired-tmux-auth_fm-worker" ]
echo 'ok - real primary/worker panels, Claude/Codex, repeat/re-arm dedup, recovery and rejected delivery'
