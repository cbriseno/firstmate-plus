#!/usr/bin/env bash
# Exercises «Mi orden» as the work order through the public work wrapper with
# real tasks-axi: the unplaced order equals priority, a request move saves the
# visible order, sigue follows it, a new request enters by priority, yields only
# names work giving way to a request the captain placed higher, and queued
# resumes leave in that order without overtaking higher placed ready work.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-work-order-') as tmp:
    home = pathlib.Path(tmp)
    for name in ('data','state','config','fakebin','wt'):
        (home/name).mkdir()
    (home/'data/projects.md').write_text('- alpha [local-only] - Example\n')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_')}
    env.update(FM_HOME=str(home), FM_LIVE='0', PATH=str(home/'fakebin')+os.pathsep+os.environ['PATH'])
    # The endpoint fixture never reaches a real server: one live worker window.
    fake = home/'fakebin/tmux'
    fake.write_text('#!/usr/bin/env bash\ncase "$1" in list-windows) echo fm-brun ;; display-message) echo codex ;; *) exit 1 ;; esac\n')
    fake.chmod(0o755)
    # Isolate host CPU pressure; capacity resources have their own coverage.
    cores = home/'fakebin/getconf'
    cores.write_text('#!/usr/bin/env bash\nif [ "$1" = _NPROCESSORS_ONLN ]; then echo 1024; else /usr/bin/getconf "$@"; fi\n')
    cores.chmod(0o755)
    wrapper = ['bash', str(root/'bin/fm-tasks-axi.sh')]
    checks = 0
    counter = 0
    def cli(*args, payload=None, raw=False):
        p = subprocess.run(wrapper+list(args), input=json.dumps(payload) if payload is not None else None, env=env, text=True, capture_output=True)
        assert p.returncode == 0, (args, p.stdout, p.stderr)
        return p.stdout if raw else json.loads(p.stdout)
    def check(value, message):
        global checks
        assert value, message
        checks += 1
    def snapshot(): return cli('work','snapshot','--order','manual')
    def requests(s): return [g['id'] for g in s['requests']]
    def move(target, **kw):
        global counter
        counter += 1
        return cli('work','apply',payload=dict(op='move',target=target,expected_rev=snapshot()['rev'],actor='captain',request_id='order-request-%08d'%counter,**kw))
    def signal(verb, scope):
        global counter
        counter += 1
        return cli('work',verb,payload=dict(scope=scope,rev=snapshot()['rev'],request_id='order-signal-%08d'%counter))
    def add(key, request, priority):
        cli('add',key,key+' task','--repo','alpha','--priority',str(priority),raw=True)
        pf = home/'presentation.json'
        pf.write_text(json.dumps({'request':{'id':request,'label':'Request '+request,'project':'alpha'}}))
        cli('presentation',key,'--presentation-file',str(pf),raw=True)
    add('a1','A',1); add('c1','C',2); add('b1','B',3); add('brun','B',3)
    add('p','A',1); add('q','C',2); add('a2','A',4)
    cli('start','brun',raw=True)
    (home/'state/brun.meta').write_text(f'window=example:fm-brun\nworktree={home}/wt\nproject={home}/wt\nkind=ship\nbackend=tmux\nmode=local-only\n')
    s = snapshot()
    check(next(t for t in s['tasks'] if t['key']=='task:brun')['state']=='running','fixture worker is running')
    check(requests(s)==['A','C','B'] and s['sigue'][:3]==['task:a1','task:p','task:c1'],'unplaced work order equals priority order')
    check(s['sigue'][-1]=='task:a2','unplaced work keeps each task at its own priority')
    check(s['yields'] is None,'the automatic order never asks anyone to give way')
    check(move('request:B',before='request:A',adopt_priority=1)['code']=='invalid_value','a request move never rewrites priorities')
    check(move('request:B',before='request:A')['state']=='applied','captain places a request')
    s = snapshot()
    check(requests(s)==['B','A','C'],'the move saves the visible order with the move applied')
    check(s['sigue'][0]=='task:b1' and s['yields'] is None,'sigue follows the placed request; running work already on top gives no way')
    (home/'config/lane-capacity').write_text('1\n')
    move('request:C',before='request:B')
    s = snapshot()
    check(requests(s)==['C','B','A'] and s['sigue'][0] in ('task:c1','task:q'),'ready work of the top request is dispatched first')
    check(s['yields'] and s['yields']['pause']=='task:brun' and s['yields']['for_request']=='request:C' and s['yields']['room'] is False,
          'the lowest running request gives way to a request placed higher when there is no room')
    # Queued resumes leave in «Mi orden», not arrival order.
    signal('pause.request','task:p'); signal('pause.request','task:q')
    (home/'state/other.meta').write_text('kind=ship\n')
    first = signal('resume.request','task:p'); second = signal('resume.request','task:q')
    check(first['pause_state']=='queued' and second['pause_state']=='queued','both resumes wait without room')
    queue = {p['scope']: p['queue_position'] for p in snapshot()['pause_controls'] if p['queue_position']}
    check(queue=={'task:q':1,'task:p':2},'the resume queue is shown in «Mi orden»')
    (home/'state/other.meta').unlink(); (home/'config/lane-capacity').unlink()
    results = cli('work','reconcile')['results']
    check([r['request_id'] for r in results]==[second['request_id']],'the higher resume leaves first and the lower one waits behind ready placed work')
    check(next(p for p in snapshot()['pause_controls'] if p['scope']=='task:p')['state']=='queued','the lower resume stays queued')
    # A new request enters by priority, before the first placed request it outranks.
    add('d1','D',0)
    s = snapshot()
    check(requests(s)[0]=='D' and s['sigue'][0]=='task:d1','an urgent new request enters by its priority')
    check(s['yields'] is None,'an unplaced request never makes running work give way')
    check(json.loads((home/'data/work-structure.json').read_text())['order'][:3]==['request:C','request:B','request:A'],'placed requests keep the captain order')
    print('PASS: %d work order assertions' % checks)
PY
