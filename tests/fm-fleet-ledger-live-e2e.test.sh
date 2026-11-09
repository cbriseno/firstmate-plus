#!/usr/bin/env bash
# Real primary final capture: Claude Stop and Codex notify, in private homes.
# Opt-in: FM_FLEET_LEDGER_LIVE_E2E=1 bash tests/fm-fleet-ledger-live-e2e.test.sh
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_FLEET_LEDGER_LIVE_E2E python3 git tmux
export ROOT
python3 - <<'PY'
import json, os, pathlib, shutil, signal, subprocess, tempfile, time, shlex
root=pathlib.Path(os.environ['ROOT'])
checked=0
with tempfile.TemporaryDirectory(prefix='fm-ledger-live-') as folder:
    for harness in ('claude','codex'):
        binary=shutil.which(harness)
        if not binary:
            print('absent - '+harness,flush=True)
            continue
        version=subprocess.check_output([binary,'--version'],text=True).strip()
        home=pathlib.Path(folder)/harness
        for name in ('state','config','data'): (home/name).mkdir(parents=True,exist_ok=True)
        (home/'AGENTS.md').write_text('')
        (home/'bin').symlink_to(root/'bin',target_is_directory=True)
        (home/'config/fleet-ledger').touch()
        subprocess.run(['git','init','-q',str(home)],check=True)
        env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','CLAUDECODE','CLAUDE_PID','CLAUDE_SESSION_ID'))}
        env.update(FM_HOME=str(home),FM_ROOT_OVERRIDE=str(home))
        writer=['bash',str(root/'bin/fm-primary-final.sh'),harness]
        prompt='Reply with exactly ledger-final-ok. Do not call tools.'
        if harness=='claude':
            writer=['bash',str(root/'bin/fm-turnend-guard.sh'),'--claude']
            import shlex
            settings=home/'settings.json'
            settings.write_text(json.dumps(dict(hooks=dict(Stop=[dict(hooks=[dict(type='command',command=shlex.join(writer))])]))))
            command=[binary,'-p','--model','haiku','--effort','low','--setting-sources','','--settings',str(settings),prompt]
        else:
            # A primary remains alive at the composer. Exec can exit before its
            # asynchronous notify child proves ownership, so test the real TUI.
            auth=pathlib.Path(os.environ.get('CODEX_HOME',str(pathlib.Path.home()/'.codex')))/'auth.json'
            assert auth.is_file(), harness+' '+version+': readable auth.json required'
            codex_home=home/'codex'; codex_home.mkdir()
            shutil.copyfile(auth,codex_home/'auth.json'); (codex_home/'auth.json').chmod(0o600)
            (codex_home/'config.toml').write_text('[projects.'+json.dumps(str(home))+']\ntrust_level="trusted"\n')
            env['CODEX_HOME']=str(codex_home)
            command=[binary,'--no-daemon','--disable','hooks','--dangerously-bypass-approvals-and-sandbox',
                     '-c','model_reasoning_effort="low"','-c','notify='+json.dumps(writer),prompt]
        locked=['bash','-c','printf "%s\\n" "$$" > "$FM_HOME/state/.lock"; exec "$@"','lab',*command]
        ledger=home/'state/fleet-ledger.jsonl'
        stdout=stderr=''
        if harness=='codex':
            socket='fm-ledger-live-'+str(os.getpid())
            def tmux(*args):
                return subprocess.check_output(['tmux','-L',socket,*args],env=env,text=True,stderr=subprocess.STDOUT,timeout=10)
            try:
                tmux('new-session','-d','-s','proof','-x','160','-y','40','-c',str(home),shlex.join(locked))
                for _ in range(600):
                    if ledger.exists(): break
                    time.sleep(.2)
                stdout=tmux('capture-pane','-p','-t','proof')
            finally:
                subprocess.run(['tmux','-L',socket,'kill-server'],env=env,capture_output=True,timeout=10)
        else:
            process=subprocess.Popen(locked,cwd=home,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
            try:
                stdout,stderr=process.communicate(timeout=120)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL); process.communicate()
                raise AssertionError(harness+' '+version+': timed out')
            assert process.returncode==0, (harness,version,stdout,stderr)
        assert ledger.is_file(), (harness,version,'missing ledger',stdout,stderr)
        rows=[json.loads(line) for line in ledger.read_text().splitlines()]
        assert any(r['event']=='primary.final' and r['value']['harness']==harness
                   and r['value']['text']=='ledger-final-ok' and r['value']['session'] for r in rows), (harness,version,rows)
        checked+=1
        print('ok - '+harness+' '+version+': primary.final captured from the real final surface',flush=True)
assert checked, 'no installed harness checked'
PY
