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
