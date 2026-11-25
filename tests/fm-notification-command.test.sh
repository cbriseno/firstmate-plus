#!/usr/bin/env bash
# Public argv notification interface and installation language behavior.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as tmp:
    home=pathlib.Path(tmp); (home/'config').mkdir()
    os.environ['FM_STATE_OVERRIDE'] = str(home/'state')
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
    (home/'config/language').write_text('es-MX\n'); env.pop('FM_LANGUAGE')
    assert subprocess.check_output(command,env=env,text=True).strip()=='Firstmate registró una respuesta.'
    # The link travels only in the JSON record and must be one absolute URL.
    config.write_text(json.dumps([sys.executable,str(consumer),str(receipt)]))
    assert run('--link','https://deck.example/?task=t').returncode==0
    assert json.loads(receipt.read_text())[1]['link']=='https://deck.example/?task=t'
    assert run('--link','file:///etc/passwd').returncode==2
    # Captain notices: localized text and the Deck target for each waiting kind.
    (home/'config/deck-url').write_text('https://deck.example/\n')
    (home/'data/t1').mkdir(parents=True)
    (home/'data/t1/presentation.json').write_text(json.dumps(dict(presentation=dict(card_title='Mi tarea'))))
    def notice(*args):
        receipt.unlink(missing_ok=True)
        subprocess.run([sys.executable,str(root/'bin/fm-captain-notice.py'),'--home',str(home),*args],check=True,env=env)
        return json.loads(receipt.read_text()) if receipt.exists() else None
    argv,record=notice('--kind','question','--task','t1','--detail','¿Sí o no?')
    assert argv==['captain-question','Falta tu respuesta: Mi tarea - ¿Sí o no?'] and record['link']=='https://deck.example/?task=t1&view=call'
    argv,record=notice('--kind','review','--task','t1','--occurrence','o1')
    assert argv[0]=='captain-review' and argv[1].startswith('Listo para tu revisión') and record['link'].endswith('?task=t1&view=delivery&item=o1')
    argv,record=notice('--kind','board','--title','tablero','--link','http://lavish.example/session/1')
    assert argv[0]=='captain-board' and record['link']=='http://lavish.example/session/1'
    (home/'config/language').write_text('en\n')
    assert notice('--kind','approval','--task','t1')[0][1]=='Needs your approval: Mi tarea'
    config.write_text(json.dumps(['false']))
    assert notice('--kind','review','--task','t1') is None  # a failed delivery never fails its caller
    # Quiet hours hold notices, then deliver one digest; the overseer alert and published notice use the same path.
    sink=home/'sink.log'; consumer2=home/'consumer2.py'
    consumer2.write_text('import sys; open(sys.argv[1],"a").write(sys.argv[2]+"|"+sys.argv[3]+"\\n")')
    config.write_text(json.dumps([sys.executable,str(consumer2),str(sink)]))
    (home/'config/notification-quiet-hours').write_text('23:00-07:00\n')
    def at(clock,*args,tool='fm-notify.py'):
        return subprocess.run([sys.executable,str(root/'bin'/tool),'--home',str(home),*args],env=dict(os.environ,FM_NOTIFY_NOW=clock,FM_HOME=str(home),FM_LANGUAGE='en'),capture_output=True)
    def alert(clock, message):
        env = dict(os.environ, FM_NOTIFY_NOW=clock, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home/'state'))
        return subprocess.run(['bash', str(root/'bin/fm-overseer.sh'), 'alert', message], env=env, capture_output=True)
    config.unlink()
    unconfigured = alert('07:04', 'no adapter')
    assert unconfigured.returncode == 1, unconfigured
    for response, rc in (
        ('', 0),
        ('accepted by publisher', 0),
        ('{"event":"captain-review","receipt":"accepted-18"}', 0),
        ('{"event":"overseer-alert","receipt":""}', 0),
        ('{"event":"overseer-alert","receipt":"accepted-18"}', 1),
    ):
        # An adapter with a plausible receipt still has to exit successfully.
        config.write_text(json.dumps([sys.executable, '-c', 'import json, sys; print(json.loads(sys.argv[1])); sys.exit(int(sys.argv[2]))', json.dumps(response), str(rc)]))
        rejected = alert('07:04', 'no valid evidence')
        assert rejected.returncode == 1 and not rejected.stdout and b'no valid delivery receipt' in rejected.stderr, rejected
    config.write_text(json.dumps([sys.executable,str(consumer2),str(sink)]))
    assert at('23:30','--event','captain-published','--text','one').returncode==0
    assert at('02:00','--event','captain-review','--text','two').returncode==0
    assert at('03:00','--flush').returncode==0 and not sink.exists()
    assert at('08:00','--flush').returncode==0
    assert sink.read_text()=='quiet-digest|2 held during quiet hours: one | two\n'
    assert at('09:00','--flush').returncode==0 and sink.read_text().count('\n')==1
    sink.unlink()
    # A held alert returns pending and keeps its full text across a failed flush.
    full='x'*236+' end'
    pending = alert('23:30', full)
    assert pending.returncode == 1 and not pending.stdout and b'delivery pending' in pending.stderr
    held = home/'state/notification-held.jsonl'
    original = held.read_text()
    assert json.loads(original) == dict(event='overseer-alert', text=full)
    config.write_text(json.dumps([sys.executable, '-c', 'pass']))
    assert at('08:00', '--flush').returncode == 1 and held.read_text() == original
    config.write_text(json.dumps([sys.executable, '-c', '''
import json, pathlib, sys
path, event, text = sys.argv[1:]
with pathlib.Path(path).open('a', encoding='utf-8') as log:
    print(event + '|' + text, file=log)
print(json.dumps(dict(event=event, receipt='accepted-' + text[-3:])))
''', str(sink)]))
    assert at('23:45','--event','captain-review','--text','ordinary').returncode == 0
    confirmed = alert('08:00', 'now')
    assert confirmed.returncode == 0 and json.loads(confirmed.stdout) == dict(event='overseer-alert', receipt='accepted-now')
    assert sink.read_text().splitlines() == ['overseer-alert|' + full, 'captain-review|ordinary', 'overseer-alert|now']
    assert not held.exists()
    sink.unlink()
    config.write_text(json.dumps([sys.executable,str(consumer2),str(sink)]))
    # The digest prefix follows the installation language.
    assert at('23:30','--event','captain-published','--text','uno').returncode==0
    assert at('23:40','--event','captain-review','--text','dos').returncode==0
    spanish=subprocess.run([sys.executable,str(root/'bin/fm-notify.py'),'--home',str(home),'--flush'],env=dict(os.environ,FM_NOTIFY_NOW='08:00',FM_HOME=str(home),FM_LANGUAGE='es-MX'),capture_output=True)
    assert spanish.returncode==0 and sink.read_text()=='quiet-digest|2 avisos retenidos en horario de silencio: uno | dos\n', sink.read_text()
    sink.unlink()
    assert at('12:00','--event','captain-review','--text','now').returncode==0 and sink.read_text()=='captain-review|now\n'
    sink.unlink()
    assert at('12:00','--kind','published','--title','repo refs/heads/main',tool='fm-captain-notice.py').returncode==0
    assert sink.read_text()=='captain-published|Published: repo refs/heads/main\n'
print('ok - receipt enforcement, quiet hours, optional notifications, literal argv, failures, timeout, installation language, link and captain notices')
PY

# The presentation owner tells the captain once per newly reviewable result.
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as tmp:
    home=pathlib.Path(tmp); (home/'config').mkdir(); (home/'data').mkdir()
    (home/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n- [ ] t1 - Mi tarea\n\n## Queued\n\n## Done\n')
    sink=home/'notices'
    (home/'config/notification-command.json').write_text(json.dumps([sys.executable,'-c','import sys; open(sys.argv[1],"a").write(sys.argv[-2]+"\\n")',str(sink)]))
    env=dict(os.environ,FM_HOME=str(home)); env.pop('FM_LANGUAGE',None)
    def publish(value):
        source=home/'input.json'; source.write_text(json.dumps(value))
        result=subprocess.run(['bash',str(root/'bin/fm-tasks-axi.sh'),'presentation','t1','--presentation-file',str(source)],env=env,capture_output=True,text=True)
        assert result.returncode==0, result.stderr
    def count():
        return sink.read_text().count('captain-review') if sink.exists() else 0
    publish(dict(card_status='Working'))
    assert count()==0
    publish(dict(outcome=dict(role='final',review='needed')))
    assert count()==1
    publish(dict(summary='Done in one sentence.'))
    assert count()==1  # a summary-only change keeps the outcome and stays silent
    publish(dict(outcome=dict(role='partial',review='needed')))
    assert count()==2
print('ok - presentation owner notifies once per newly reviewable outcome')
PY

# Real disposable tmux panels exercise the watcher, including its primary path.
if ! command -v tmux >/dev/null 2>&1; then echo 'skip - login panels require tmux'; exit 0; fi
TASK_TMP=$(mktemp -d "${GOTMPDIR:-${TMPDIR:-/tmp}}/fm-login.XXXXXX") || exit 1
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
# Generic connector failures share the existing episode/delivery path without
# copying the captured error (which may contain credentials) into the notice.
for error in 'refresh token invalid: synthetic-private-value' 'invalid_grant: synthetic-private-value' 'Refresh token is INVALID: synthetic-private-value'; do
  login_expiry_notice tmux connector service 'access restored'
  login_expiry_notice tmux connector service "$error"
  login_expiry_notice tmux connector service "$error"
done
[ "$(grep -c 'Connector login expired:' "$FM_HOME/notices")" = 3 ]
grep -q 'renew the affected service login' "$FM_HOME/notices"
if grep -q synthetic-private-value "$FM_HOME/notices"; then exit 1; fi
# A rejected delivery remains retryable.
rm -f -- "$STATE/.login-expired-tmux-auth_fm-worker"
printf '["false"]\n' > "$FM_HOME/config/notification-command.json"
login_expiry_tick
[ ! -e "$STATE/.login-expired-tmux-auth_fm-worker" ]
echo 'ok - real primary/worker panels, Claude/Codex, repeat/re-arm dedup, recovery and rejected delivery'
