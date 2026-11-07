#!/usr/bin/env bash
# Controlled public interface: worker authorship, bounded operations, outcome
# attention despite an empty wake queue, transition alarms, and owned cleanup.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 - "$ROOT" <<'PY'
import json,os,select,signal,subprocess,sys,tempfile,time
from pathlib import Path
root=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-coordinator-') as tmp:
    home=Path(tmp)
    for part in ('data/unit','state','config','projects/alpha','fakebin'):(home/part).mkdir(parents=True)
    (home/'fakebin/tmux').write_text('#!/bin/sh\nexit 1\n');(home/'fakebin/tmux').chmod(0o755)
    # No native client is stubbed or invoked: this tests the mechanical host.
    # The native Claude proof is separately recorded in runtime verification.
    (home/'state/unit.meta').write_text('project=alpha\nharness=claude\nbackend=tmux\nwindow=fixture\n')
    (home/'data/unit/report.md').write_text('WORKER_RESULT: preserve these exact bytes.\n')
    outcome=dict(seq=1,epoch=int(time.time())-600,task='unit',wake='fixture',verdict='captain',summary='A real queued obligation needs action.',silent=False)
    (home/'state/branch-outcomes.jsonl').write_text(json.dumps(outcome)+'\n')
    callback=home/'callback.py';events=home/'events.jsonl'
    callback.write_text('import json,sys\nwith open(sys.argv[1],"a") as f:f.write(json.dumps(sys.argv[2:])+"\\n")\n')
    command=home/'command.json';command.write_text(json.dumps([sys.executable,str(callback),str(events)]))
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))}
    env.update(FM_LIVE='0',FM_COORDINATOR_POLL='1',FM_POLL='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_NOTIFICATION_COMMAND_FILE=str(command),PATH=str(home/'fakebin')+':'+env['PATH'],PYTHONDONTWRITEBYTECODE='1')
    log=(home/'stderr').open('w')
    app=subprocess.Popen([sys.executable,str(root/'bin/fm-claude-coordinator.py'),'--home',tmp,'--task','unit','--repo','alpha','--project',str(home/'projects/alpha'),'--model','haiku'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True)
    def request(value):
        app.stdin.write(json.dumps(value)+'\n');app.stdin.flush()
        assert select.select([app.stdout],[],[],60)[0],'response timeout'
        line=app.stdout.readline();assert line, (home/'stderr').read_text()
        return json.loads(line)
    def until(predicate):
        for _ in range(1200):
            if predicate():return
            assert app.poll() is None,(home/'stderr').read_text()
            time.sleep(.1)
        raise AssertionError('condition timeout: '+(home/'stderr').read_text())
    def health():
        try:return json.loads((home/'state/.coordinator-health.json').read_text())
        except (FileNotFoundError,ValueError):return {}
    try:
        until(lambda:health().get('state') in ('healthy','degraded'))
        shown=request({'op':'status'})
        assert shown['attention'][0]['seq']==1
        if (home/'state/.wake-queue').exists():
            assert not (home/'state/.wake-queue').read_text().strip()
        assert request({'op':'result','text':'PRIMARY_RECIPE'})['text']=='WORKER_RESULT: preserve these exact bytes.\n'
        assert 'error' in request({'op':'result','path':'/arbitrary/report'})
        assert request({'op':'mkdir','name':'ordinary'})['exists']
        assert 'error' in request({'op':'mkdir','name':'../escape'})
        assert request({'op':'ack','outcome':1})['processed']==1
        until(lambda:health().get('state')=='healthy')
        until(lambda:events.exists() and len(events.read_text().splitlines())>=2)
        recorded=[json.loads(line)[0] for line in events.read_text().splitlines()]
        assert recorded==['supervision-degraded','supervision-recovered'],recorded
        request({'op':'status'});request({'op':'status'})
        assert len(events.read_text().splitlines())==2
        # Kill only this application's direct host child; the same owner repairs it.
        host=int(next(row.split('\t')[1] for row in (home/'state/.supervision-host').read_text().splitlines() if row.startswith('host\t')))
        assert int(subprocess.check_output(['ps','-o','ppid=','-p',str(host)],text=True))==app.pid
        started=time.monotonic();os.kill(host,signal.SIGKILL)
        until(lambda:events.exists() and len(events.read_text().splitlines())>=4 and health().get('state')=='healthy')
        assert [json.loads(line)[0] for line in events.read_text().splitlines()][2:]==['supervision-degraded','supervision-recovered']
        print('host failover seconds: %.2f'%(time.monotonic()-started))
        inbox=home/'state/unit.inbox';(inbox/'handled').mkdir(parents=True)
        message=inbox/'001.msg';message.write_text('Unread continuation');os.utime(message,(1,1))
        until(lambda:len(events.read_text().splitlines())>=5)
        message.rename(inbox/'handled/001.msg')
        until(lambda:len(events.read_text().splitlines())>=6 and health().get('state')=='healthy')
        assert len(events.read_text().splitlines())==6
        (home/'state/unit.meta').unlink()
        with (home/'state/branch-outcomes.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(outcome,seq=2))+'\n')
        until(lambda:health().get('pending') and health()['pending'][0]['seq']==2)
        assert request({'op':'status'})['attention'][0]['seq']==2 and health()['state']=='degraded'
        assert request({'op':'ack','outcome':2})['processed']==2
        until(lambda:health().get('state')=='idle' and len(events.read_text().splitlines())==8)
    finally:
        if app.poll() is None:
            app.stdin.write('{"op":"quit"}\n');app.stdin.flush();app.wait(timeout=150)
        log.close()
    assert app.returncode==0,(home/'stderr').read_text()
    print('PASS: controlled routing, exact worker report, bounded operation, pending outcome, transition alarms, host recovery, unread continuation and cleanup')
PY
