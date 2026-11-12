#!/usr/bin/env bash
# Bootstrap and incremental activity through the real owner and busy writer.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
python3 - <<'PY'
import copy, gc, json, os, pathlib, shlex, signal, subprocess, sys, tempfile, time, weakref
root = pathlib.Path(os.environ['ROOT'])
sys.path.insert(0, str(root / 'bin'))
from fm_work_projection import Projection
with tempfile.TemporaryDirectory(prefix='fm-work-activity-') as directory:
    home = pathlib.Path(directory)
    for part in ('data', 'state', 'config'): (home / part).mkdir()
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    (home / 'data/backlog.md').write_text('# Tasks\n\n## In flight\n\n- [ ] activity - Turn activity (repo: firstmate)\n\n## Queued\n\n## Done\n')
    (home / 'config/fleet-ledger').touch()
    env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    def run(script, *args):
        return subprocess.check_output(['bash', str(root / 'bin' / script), *args], env=env, text=True)
    writer = ('fm-busy-event.sh',)
    gen = run(*writer, 'arm', str(home / 'state'), 'activity', '--source', 'claude-hook', '--event', 'UserPromptSubmit').strip()
    base = json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))
    assert base['activity']['activity']['state'] == 'busy', base['activity']
    # Real snapshot reports the orphan instead of inventing a worker.
    assert base['snapshot']['main_inventory']['valid'] is False
    assert 'activity' in base['snapshot']['main_inventory']['orphan_in_flight']
    model = Projection(base)
    observed = dict(main_inventory=dict(valid=True, reason=None), tasks=[dict(
        id='activity', wait_until='2026-11-20T15:00:00Z', run_step=dict(
            phase='validation', state='running', source='no-mistakes.attributed-run',
            observed_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), ttl_seconds=60))])
    observation_event = dict(event='task.presentation', task='activity', ts=int(time.time()),
                             value=copy.deepcopy(base['empty_presentation']), observation=observed)
    assert model.apply(observation_event)
    task = model.value['tasks'][0]
    assert model.value['main_inventory']['valid'] is True
    assert task['wait_until'] == '2026-11-20T15:00:00Z'
    assert task['run_step']['state'] == 'running' and task['run_step']['freshness'] == 'fresh'
    short_lived = copy.deepcopy(observation_event)
    short_lived['observation']['tasks'][0]['run_step']['ttl_seconds'] = 1
    assert model.apply(short_lived)
    time.sleep(1.1)
    assert model.value['tasks'][0]['run_step']['freshness'] == 'stale'
    assert model.apply(observation_event)
    assert model.apply(dict(event='agent.activity', task='activity', ts=int(time.time()),
                            value=dict(gen='probe', seq=1, state='busy')))
    assert model.value['tasks'][0]['wait_until'] is None
    assert model.apply(observation_event)
    observed['tasks'][0]['run_step']['observed_at'] = '2000-01-01T00:00:00Z'
    assert model.apply(dict(observation_event, observation=observed))
    assert model.value['tasks'][0]['run_step']['state'] == 'unknown'
    assert model.value['tasks'][0]['run_step']['freshness'] == 'stale'
    (home / 'state/activity.status').write_text('paused [at=1792921938]: waiting\n')
    run('fm-fleet-ledger.sh', 'appended', str(home / 'config'), str(home / 'state/activity.status'))
    status_event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert status_event['declared_at'] == 1792921938
    assert status_event['observation']['main_inventory']['valid'] is False
    assert model.apply(status_event)
    assert model.value['tasks'][0]['wait_until'] is None
    assert '[at=1792921938]' in model.status['activity']
    assert model.apply(dict(event='task.status', task='activity', ts=1234567890,
                            state='working', text='legacy', declared_at='invalid'))
    assert '[at=' not in model.status['activity'].splitlines()[-1]
    assert model.capacity()['agents_running'] is None
    run('fm-fleet-ledger.sh', 'dispatched', 'activity', 'ship', 'firstmate', 'codex', '')
    event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert model.apply(event)
    assert model.capacity()['agents_running'] == 1
    assert model.apply(event)  # A repeated launch replaces membership.
    assert model.capacity()['agents_running'] == 1
    restarted = Projection(json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap')))
    assert restarted.capacity()['agents_running'] == 1
    assert restarted.capacity()['source'] == 'fleet-ledger'
    run(*writer, 'apply', str(home / 'state'), 'activity', 'idle', '--gen', gen, '--source', 'claude-hook', '--event', 'Stop')
    event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert model.apply(event)
    assert model.activity['activity']['state'] == 'idle'
    assert model.capacity()['agents_running'] == 1  # Turn end keeps the worker.
    assert model.value['tasks'][0]['backlog_state'] == 'in_flight'
    assert not model.apply(dict(event, value=dict(event['value'], seq=1, state='busy')))
    # Replacing a presentation must release the previous task snapshot without
    # waiting for a cyclic collection that pauses the event reader.
    class Evidence(dict):
        pass
    gc.collect()
    gc.disable()
    try:
        value = copy.deepcopy(base['empty_presentation'])
        value['lifecycle']['evidence'] = Evidence(value['lifecycle']['evidence'])
        previous_evidence = weakref.ref(value['lifecycle']['evidence'])
        assert model.apply(dict(event='task.presentation', task='activity', ts=1, value=value))
        del value
        assert model.apply(dict(event='task.presentation', task='activity', ts=2,
                                value=copy.deepcopy(base['empty_presentation'])))
        assert previous_evidence() is None, 'old snapshot retained until cyclic garbage collection'
    finally:
        gc.enable()
    (home / 'state/activity.busy-gen').write_text('other-generation\n')
    assert 'activity' not in json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))['activity']
    run('fm-fleet-ledger.sh', 'cleaned_up', 'activity')
    event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert model.apply(event)
    assert model.capacity()['agents_running'] == 0
    assert model.apply(event)
    assert model.capacity()['agents_running'] == 0
    assert Projection(json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))).capacity()['agents_running'] == 0
print('ok - lifecycle counts, duplicate launch/close, recovery, bootstrap activity, turn end, old sequence, generation mismatch and snapshot release')
with tempfile.TemporaryDirectory(prefix='prueba-worker-death-') as directory:
    home = pathlib.Path(directory)
    for part in ('data', 'state', 'config'): (home / part).mkdir()
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    task = 'prueba-worker.dotted'
    (home / 'data/backlog.md').write_text('# Tasks\n\n## In flight\n\n- [ ] ' + task + ' - Process death (repo: firstmate)\n\n## Queued\n\n## Done\n')
    (home / 'config/fleet-ledger').touch()
    env['FM_HOME'] = str(home)
    run('fm-fleet-ledger.sh', 'dispatched', task, 'ship', 'firstmate', 'codex', '')
    model = Projection(json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap')))
    ledger = home / 'state/fleet-ledger.jsonl'
    offset = len(ledger.read_text().splitlines())
    def consume():
        global offset
        events = [json.loads(s) for s in ledger.read_text().splitlines()[offset:]]
        offset += len(events)
        for event in events: assert model.apply(event), event
        return events
    def launch(gen):
        scope = f'{home}/state/{task}:{gen}'
        (home / 'state' / (task + '.meta')).write_text(f'process_scope={scope}\nspawn_gen={gen}\n')
        pidfile = home / gen
        code = 'import os,time; from pathlib import Path; Path(' + repr(str(pidfile)) + ').write_text(str(os.getpid())); time.sleep(60)'
        worker = subprocess.Popen([sys.executable, str(root / 'bin/fm-worker-processes.py'), 'run', scope,
                                   'exec ' + shlex.join([sys.executable, '-c', code])],
                                  env=dict(env, FM_WORKER_PROCESS_SCOPE=scope))
        try:
            for _ in range(100):
                if pidfile.exists() and any(e['event'] == 'agent.liveness' and e['value']['gen'] == gen
                                          for e in map(json.loads, ledger.read_text().splitlines())):
                    return worker, int(pidfile.read_text())
                time.sleep(.1)
            raise AssertionError('worker did not start and publish')
        except BaseException:
            worker.terminate(); worker.wait(timeout=15)
            raise
    worker, pid = launch('first')
    try:
        consume()
        assert model.worker_liveness(task)['state'] == 'alive'
        assert model.capacity()['agents_running'] == 1
        os.kill(pid, signal.SIGKILL)
        assert worker.wait(timeout=15) != 0
        events = consume()
        assert [e['value']['state'] for e in events] == ['dead'], events
        assert model.worker_liveness(task)['state'] == 'dead'
        assert model.capacity()['agents_running'] == 0
        assert model.apply(events[0])
        assert model.capacity()['agents_running'] == 0
        assert model.apply(dict(event='agent.activity', task=task, ts=1,
                                value=dict(gen='late-turn', seq=1, state='idle')))
        assert model.worker_liveness(task)['state'] == 'dead'
        assert model.capacity()['agents_running'] == 0
        assert model.value['tasks'][0]['state'] == 'ready'
        assert model.value['tasks'][0]['backlog_state'] == 'in_flight'
        # Late dispatch and normal turn activity cannot resurrect a dead process.
        run('fm-fleet-ledger.sh', 'dispatched', task, 'ship', 'firstmate', 'codex', '')
        consume()
        assert model.capacity()['agents_running'] == 0
        restored = Projection(json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap')))
        assert restored.capacity()['agents_running'] == 0
        assert restored.worker_liveness(task)['state'] == 'dead'
    finally:
        if worker.poll() is None:
            worker.terminate(); worker.wait(timeout=15)
    worker, pid = launch('relaunch')
    try:
        consume()
        assert model.capacity()['agents_running'] == 1
        assert model.worker_liveness(task)['state'] == 'alive'
        restored = Projection(json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap')))
        assert restored.capacity()['agents_running'] == 1
        assert restored.worker_liveness(task)['state'] == 'alive'
        worker.terminate()
        assert worker.wait(timeout=15) == 143
        consume()
        assert model.capacity()['agents_running'] == 0
    finally:
        if worker.poll() is None:
            worker.terminate(); worker.wait(timeout=15)
    # An older wrapper may finish after a new incarnation has taken ownership.
    before = ledger.read_bytes()
    scope = f'{home}/state/{task}:first'
    subprocess.run([sys.executable, str(root / 'bin/fm-worker-processes.py'), 'run', scope, 'exit 0'],
                   env=dict(env, FM_WORKER_PROCESS_SCOPE=scope), check=True, timeout=15)
    assert ledger.read_bytes() == before, 'old incarnation published against new metadata'
    (home / 'config/fleet-ledger').unlink()
    scope = f'{home}/state/{task}:relaunch'
    subprocess.run([sys.executable, str(root / 'bin/fm-worker-processes.py'), 'run', scope, 'exit 0'],
                   env=dict(env, FM_WORKER_PROCESS_SCOPE=scope), check=True, timeout=15)
    assert ledger.read_bytes() == before, 'disabled publication changed the ledger'
print('ok - real worker kill and wrapper stop publish death; count, row, recovery, relaunch and incarnation isolation')
with tempfile.TemporaryDirectory(prefix='prueba-liveness-paths-') as directory:
    folder = pathlib.Path(directory).resolve()
    home, state, config = [folder / p for p in ('home', 'external-state', 'external-config')]
    for p in (home, state, config): p.mkdir()
    (config / 'fleet-ledger').touch()
    scope = f'{state}/prueba-worker:test'
    (state / 'prueba-worker.meta').write_text(f'process_scope={scope}\nspawn_gen=test\n')
    subprocess.run([sys.executable, str(root / 'bin/fm-worker-processes.py'), 'run', scope, 'exit 0',
                    str(home), str(config)], env=dict(env, FM_WORKER_PROCESS_SCOPE=scope), check=True, timeout=15)
    events = list(map(json.loads, (state / 'fleet-ledger.jsonl').read_text().splitlines()))
    assert [e['value']['state'] for e in events] == ['alive', 'dead']
    assert all(e['home'] == str(home) and e['task'] == 'prueba-worker' for e in events)
print('ok - explicit home and config preserve liveness with external state paths')
PY
