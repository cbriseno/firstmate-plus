#!/usr/bin/env bash
# Bootstrap and activity through the real owner and busy writer.
# Covers bin/fm_work_projection.py and bin/fm_work_state.py through public events.
# FM_WORK_TEST_STATE=1 runs the P12 state cases; FM_WORK_TEST_RESOURCES=1 runs resource waits.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
if [ "${FM_WORK_TEST_STATE:-0}" != 1 ] && [ "${FM_WORK_TEST_RESOURCES:-0}" != 1 ]; then
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
    record_ts = int((home / 'state/activity.busy-state').read_text().split('ts=')[1])
    assert base['activity']['activity']['ts'] == record_ts
    first_event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert first_event['value']['ts'] == record_ts
    assert base['activity']['activity']['native_activity'] is None  # no declared worker
    assert first_event['value']['native_activity']['state'] == 'unknown'

    # Both producer interfaces use the same declared harness and native verdict.
    (home / 'state/activity.meta').write_text('kind=host\nharness=claude\nbackend=tmux\nwindow=missing\n')
    run(*writer, 'apply', str(home / 'state'), 'activity', 'busy', '--gen', gen,
        '--source', 'claude-hook', '--event', 'UserPromptSubmit')
    published = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])['value']
    refreshed = json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))
    assert published['native_activity']['state'] == 'busy' and published['native_activity']['verified']
    assert published['native_activity']['source'] == 'claude-hook'
    assert refreshed['activity']['activity']['native_activity']['state'] == 'unknown'  # endpoint not confirmed
    assert refreshed['activity']['activity']['native_activity'] == refreshed['snapshot']['tasks'][0]['native_activity']
    assert refreshed['snapshot']['tasks'][0]['execution_context'] == 'host'
    old_record = (home / 'state/activity.busy-state').read_text()
    (home / 'state/activity.busy-state').write_text(old_record.rsplit('ts=', 1)[0] + 'ts=946684800\n')
    assert json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))['activity']['activity']['ts'] == 946684800
    (home / 'state/activity.busy-state').write_text(old_record)
    # Codex keeps its existing bound rollout requirement; another hook is not proof.
    (home / 'state/activity.meta').write_text('kind=host\nharness=codex\nbackend=tmux\nwindow=missing\n')
    run(*writer, 'apply', str(home / 'state'), 'activity', 'busy', '--gen', gen,
        '--source', 'claude-hook', '--event', 'UserPromptSubmit')
    unsupported = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])['value']['native_activity']
    assert unsupported['state'] == 'unknown' and unsupported['source'] == 'codex-unverified'
    # Explicit context never comes from a missing repo or a living endpoint.
    (home / 'state/activity.meta').unlink()
    (home / 'data/projects.md').write_text('- firstmate [local-only] - Test project\n')
    for task_id, options, warning in [('unresolved', ['--repo', 'typo'], 'unregistered project'),
                                       ('decision', ['--repo=firstmate', '--kind', 'captain'], 'fm-captain-hold.sh hold'),
                                       ('projectless', [], 'no --repo'),
                                       ('registered', ['--repo', 'firstmate'], None)]:
        result = subprocess.run(['bash', str(root / 'bin/fm-tasks-axi.sh'), 'add', task_id, task_id, *options],
                                env=env, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert (warning in result.stderr) if warning else not result.stderr, result.stderr
    rows = {t['key']:t for t in json.loads(run('fm-tasks-axi.sh', 'work', 'snapshot'))['tasks']}
    assert rows['task:decision']['question']['filing_required']
    assert not rows['task:decision']['question']['open'] and rows['task:decision']['question']['call'] is None
    assert rows['task:projectless']['execution_context'] == 'unknown'
    assert rows['task:registered']['execution_context'] == 'project'
    assert rows['task:unresolved']['repository_project'] == 'project:typo'
    run('fm-captain-hold.sh', 'hold', 'decision', '--reason', 'Fixture', '--category', 'product-design', '--challenge', 'fixture',
        '--question', 'Choose?', '--option', 'yes=Proceed', '--option', 'no=Wait')
    filed = next(t['question'] for t in json.loads(run('fm-tasks-axi.sh', 'work', 'snapshot'))['tasks'] if t['key'] == 'task:decision')
    assert filed['open'] and not filed['filing_required'] and filed['call'] is not None
    # R1-11/12: an absent or invalid card belongs to owner repair, not a
    # question the user can answer. Exercise the producer and event replay.
    record = home / 'data/decision/captain-call.json'
    original = json.loads(record.read_text())
    for damage in (None, '{broken', json.dumps(dict(original, call={'options': original['call']['options']})),
                   json.dumps(dict(original, call=dict(original['call'], options=original['call']['options'][:1])))):
        if damage is None:
            record.unlink()
        else:
            record.write_text(damage)
        broken = json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))
        question = next(t['question'] for t in broken['snapshot']['tasks'] if t['key'] == 'task:decision')
        assert question['filing_required'] and not question['open'] and question['call'] is None, question
        broken_task = next(t for t in broken['snapshot']['tasks'] if t['key'] == 'task:decision')
        assert broken_task['placement']['code'] == 'call_record_required' and broken_task['placement']['attention'] == []
        replay = Projection(broken)
        assert next(t['question'] for t in replay.value['tasks'] if t['key'] == 'task:decision') == question
        run('fm-captain-hold.sh', 'hold', 'decision', '--reason', 'Fixture', '--category', 'product-design', '--challenge', 'fixture',
            '--repair-call', '--question', 'Choose?', '--option', 'yes=Proceed', '--option', 'no=Wait')
        repaired = json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))
        question = next(t['question'] for t in repaired['snapshot']['tasks'] if t['key'] == 'task:decision')
        assert question['open'] and not question['filing_required'] and question['answer'] is None
        assert question['call'] == original['call'] and json.loads(record.read_text())['hold_set'] == original['hold_set']
        for line in (home / 'state/fleet-ledger.jsonl').read_text().splitlines():
            replay.apply(json.loads(line))
        assert next(t['question'] for t in replay.value['tasks'] if t['key'] == 'task:decision')['open']
    # An intentional no-options wait is supported even without a question.
    run('fm-captain-hold.sh', 'hold', 'decision', '--reason', 'Fixture login', '--category', 'credentials-security', '--challenge', 'fixture',
        '--no-options', 'The user must log in')
    freeform = json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))
    question = next(t['question'] for t in freeform['snapshot']['tasks'] if t['key'] == 'task:decision')
    assert question['open'] and not question['filing_required'] and question['call'] is None, question
    replay = Projection(freeform)
    replay.apply(json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1]))
    assert next(t['question'] for t in replay.value['tasks'] if t['key'] == 'task:decision')['open']
    # Explicit recovery must not turn a known human action into a question.
    run('fm-captain-hold.sh', 'hold', 'action', '--title', 'Synthetic login action', '--repo', 'firstmate',
        '--reason', 'Login', '--category', 'credentials-security', '--challenge', 'fixture', '--call-kind', 'action',
        '--instruction', 'Complete the login in chat', '--where', 'chat')
    action_record = (home / 'data/action/captain-call.json').read_bytes()
    refused = subprocess.run(['bash', str(root / 'bin/fm-captain-hold.sh'), 'hold', 'action', '--repair-call',
        '--reason', 'Fixture', '--category', 'product-design', '--challenge', 'fixture', '--question', 'Choose?',
        '--option', 'yes=Proceed', '--option', 'no=Wait'], env=env, capture_output=True, text=True)
    assert refused.returncode != 0 and 'outstanding action cannot become a question' in refused.stderr
    assert (home / 'data/action/captain-call.json').read_bytes() == action_record
    # Keep the remaining lifecycle fixture focused on its original row.
    (home / 'data/backlog.md').write_text('# Tasks\n\n## In flight\n\n- [ ] activity - Turn activity (repo: firstmate)\n\n## Queued\n\n## Done\n')
    # Real snapshot reports the orphan instead of inventing a worker.
    assert base['snapshot']['main_inventory']['valid'] is False
    # Direct users of the bootstrap function receive the same observed facts.
    direct_code = 'import json,sys; sys.path.insert(0,sys.argv[1]); from fm_work import Owner; from fm_work_projection import bootstrap,position; owner=Owner(); owner.ledger_start=position(owner.home); owner.load(); print(json.dumps(bootstrap(owner)))'
    direct = json.loads(subprocess.check_output([sys.executable, '-c', direct_code, str(root / 'bin')], env=env, text=True))
    assert direct['snapshot']['main_inventory']['valid'] is False
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
    run('fm-fleet-ledger.sh', 'dispatched', 'activity', 'host', '', 'codex', '')
    event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert model.apply(event)
    assert model.capacity()['agents_running'] == 1
    assert model.apply(event)  # A repeated launch replaces membership.
    assert model.capacity()['agents_running'] == 1
    restarted = Projection(json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap')))
    assert restarted.capacity()['agents_running'] == 1
    assert restarted.value['tasks'][0]['execution_context'] == 'host'
    assert model.value['tasks'][0]['execution_context'] == 'host'
    assert restarted.capacity()['source'] == 'fleet-ledger'
    run(*writer, 'apply', str(home / 'state'), 'activity', 'idle', '--gen', gen, '--source', 'claude-hook', '--event', 'Stop')
    event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert model.apply(event)
    assert model.activity['activity']['state'] == 'idle'
    assert model.activity['activity']['ts'] == event['value']['ts']
    assert model.value['tasks'][0]['native_activity'] == event['value']['native_activity']
    assert model.capacity()['agents_running'] == 1  # Turn end keeps the worker.
    assert model.value['tasks'][0]['backlog_state'] == 'in_flight'
    assert model.apply(observation_event)  # a later runtime sample does not forget dispatch context
    assert model.value['tasks'][0]['execution_context'] == 'host'
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
    assert model.value['tasks'][0]['native_activity'] is None
    assert 'activity' not in model.activity
    assert model.apply(event)
    assert model.capacity()['agents_running'] == 0
    assert Projection(json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))).capacity()['agents_running'] == 0

    # A checkpoint covers exact canonical prefixes, regardless of capture order.
    # Use the real writers: presentation publication deliberately precedes capture.
    (home / 'state/activity.meta').write_text('kind=scout\n')
    checkpoint_base = json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))
    run('fm-fleet-ledger.sh', 'capture')  # Cleanup retired the old capture offset.
    status = home / 'state/activity.status'
    with status.open('a') as stream:
        stream.write('working [key=precise] [at=1792921939]:  unicode é, tabs\tand "quotes"  \n')
        stream.write('working [at=1792921939]: ' + 'long ' * 420 + 'different ending\n')
    draft = home / 'data/checkpoint-input.json'
    draft.write_text(json.dumps(dict(phase='investigation', progress=dict(steps=[
        dict(label='Observe', state='done'), dict(label='Fix', state='active'), dict(label='Verify', state='todo')]))))
    offset = len((home / 'state/fleet-ledger.jsonl').read_text().splitlines())
    receipt = json.loads(run('fm-tasks-axi.sh', 'presentation', 'activity', '--presentation-file', str(draft)))
    assert receipt['ok'] and receipt['lifecycle']['evidence']['current']
    run('fm-fleet-ledger.sh', 'capture')
    captured = [json.loads(s) for s in (home / 'state/fleet-ledger.jsonl').read_text().splitlines()[offset:]]
    publication = next(e for e in captured if e['event'] == 'task.presentation')
    covered = [e for e in captured if e['event'] == 'task.status']
    assert len(covered) == 2
    projections = []
    for events in ([publication] + covered, covered + [publication]):
        projection = Projection(checkpoint_base)
        for event in events: assert projection.apply(event)
        result = projection.value['tasks'][0]
        assert result['progress_evidence']['current'], result['progress_evidence']
        assert result['progress']['done'] == 1 and result['progress']['total'] == 3
        assert result['phase'] == 'investigation'
        projections.append(projection)
    projection = projections[0]
    assert projection.value['tasks'][0]['progress'] == projections[1].value['tasks'][0]['progress']
    assert projection.apply(covered[0])  # An older prefix replay remains covered.
    assert projection.value['tasks'][0]['progress_evidence']['current']
    assert projection.value['tasks'][0]['progress_evidence']['status_boundary']['reason'] == 'covered-status'
    with status.open('a') as stream:
        stream.write('resolved [at=1792921940] [key=precise]: no new reporting boundary\n')
    run('fm-fleet-ledger.sh', 'capture')
    resolved_event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert projection.apply(resolved_event)
    assert projection.value['tasks'][0]['progress_evidence']['current']
    assert projection.value['tasks'][0]['progress_evidence']['status_boundary']['reason'] == 'non-reporting-status'
    with status.open('a') as stream:
        # Same second and the same displayed 2000 characters, different boundary.
        stream.write('working [at=1792921939]: ' + 'long ' * 420 + 'new ending\n')
    run('fm-fleet-ledger.sh', 'capture')
    newer = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert projection.apply(newer)
    result = projection.value['tasks'][0]
    canonical = next(t for t in json.loads(run('fm-tasks-axi.sh', 'work', 'snapshot'))['tasks'] if t['key'] == 'task:activity')
    assert result['progress'] is None and canonical['progress'] is None
    assert result['progress_evidence']['reasons'] == canonical['progress_evidence']['reasons'] == ['status-checkpoint-required']
    assert result['declared_progress']['done'] == 1
    assert projection.apply(publication)
    assert not projection.value['tasks'][0]['progress_evidence']['current'], 'old checkpoint revived newer status'
    for event in (covered[-1], resolved_event):
        assert projection.apply(event)
        assert not projection.value['tasks'][0]['progress_evidence']['current'], 'old replay revived stale evidence'
    refreshed = json.loads(run('fm-tasks-axi.sh', 'presentation', 'activity', '--presentation-file', str(draft)))
    assert refreshed['ok'] and refreshed['lifecycle']['evidence']['current']
    refresh_event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert projection.apply(refresh_event)
    assert projection.value['tasks'][0]['progress_evidence']['current'], 'fresh checkpoint must cover the new boundary'
    # Existing non-status invalidity also survives a covered status.
    invalid = copy.deepcopy(publication)
    invalid['value']['lifecycle']['evidence'].update(current=False, freshness='stale', reasons=['code-head-changed'])
    other = Projection(checkpoint_base)
    assert other.apply(invalid) and other.apply(covered[-1])
    assert other.value['tasks'][0]['progress_evidence']['reasons'] == ['code-head-changed']
    # Legacy statuses have no exact boundary proof; reporting stays conservative.
    projection = Projection(checkpoint_base)
    assert projection.apply(publication)
    assert projection.apply(dict(event='task.status', task='activity', ts=1792921950, state='resolved', text='legacy'))
    assert projection.value['tasks'][0]['progress_evidence']['current']
    assert projection.apply(dict(event='task.status', task='activity', ts=1792921951, state='working', text='legacy'))
    assert not projection.value['tasks'][0]['progress_evidence']['current']
    print('ok - checkpoint/status in both orders, exact prefixes, duplicate, resolved, newer, stale and legacy boundaries')
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

# A real-sized backlog must retain observation and capacity when those reads
# depend on overlapping. The fake readers make a serial regression deterministic.
python3 - <<'PY'
import json, os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
with tempfile.TemporaryDirectory(prefix='fm-work-large-') as directory:
    tmp = pathlib.Path(directory)
    home, bin_dir = tmp / 'home', tmp / 'bin'
    for part in ('data', 'state', 'config'): (home / part).mkdir(parents=True)
    shutil.copytree(root / 'bin', bin_dir)
    (home / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    rows = ''.join(f'- [ ] task-{i} - Task {i} (repo: sample)\n' for i in range(730))
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n' + rows + '\n## Done\n')
    observation = bin_dir / 'fm-fleet-snapshot.sh'
    observation.write_text('''#!/usr/bin/env bash
for ((i=0; i<200; i++)); do
  [ ! -e "$FM_HOME/capacity-started" ] || { echo '{"main_inventory":{"valid":true},"tasks":[]}'; exit 0; }
  sleep 0.1
done
exit 1
''')
    capacity = bin_dir / 'fm-capacity.sh'
    capacity.write_text('''#!/usr/bin/env bash
touch "$FM_HOME/capacity-started"
echo '{"lanes":{"count":0},"cap":{"target":3,"status":"ok"},"verdict":{"reasons":[]}}'
''')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    output = subprocess.check_output(['bash', str(bin_dir / 'fm-tasks-axi.sh'), 'work', 'snapshot'], env=env, text=True, timeout=60)
    snapshot = json.loads(output)
    assert len(snapshot['tasks']) == 730
    assert snapshot['main_inventory'] == {'valid': True}, snapshot['main_inventory']
    assert snapshot['crew']['agents_cap'] == 3
print('ok - 730-task snapshot overlaps observation and capacity without losing either')
PY

# Recency is meaningful work time; usage and liveness still refresh independently.
python3 - <<'PY'
import copy, json, os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(os.environ['ROOT'])
sys.path.insert(0, str(root / 'bin'))
from fm_work_projection import Projection
with tempfile.TemporaryDirectory(prefix='fm-work-recency-') as directory:
    home = pathlib.Path(directory)
    for part in ('data', 'state', 'config'): (home / part).mkdir()
    (home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n' + ''.join(
        f'- [ ] {i} - Task {i} (repo: sample) (since 2026-01-01)\n' for i in ('c', 'b', 'a')) + '\n## Done\n')
    (home / 'config/fleet-ledger').touch()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    def cli(*args):
        return json.loads(subprocess.check_output(['bash', str(root / 'bin/fm-tasks-axi.sh'), *args], env=env, text=True))
    for task in ('a', 'b', 'c'):
        source = home / 'declaration.json'
        source.write_text(json.dumps(dict(request=dict(id=task, label=task, project='sample'))))
        result = cli('presentation', task, '--presentation-file', str(source))
        assert result['ok'] and result['state'] == 'published', result
    base = cli('work', 'bootstrap')
    model = Projection(base)
    model.request_sort = 'recent'
    def task_rows(): return {t['key']:t for t in model.value['tasks']}
    def recent(): return [r['id'] for r in model.value['requests']]
    def replay(event):
        assert model.apply(event), event
        with (home / 'state/fleet-ledger.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(event, home=str(home))) + '\n')
        if event['event'] == 'task.status':
            with (home / 'state' / (event['task'] + '.status')).open('a') as stream:
                stream.write(f"{event['state']} [at={event['declared_at']}]: {event['text']}\n")
    stamp = int(time.time()) + 1000
    # Same meaningful date for all three requests, opposite row insertion order.
    for task in ('c', 'b', 'a'):
        value = copy.deepcopy(base['presentations'][task])
        replay(dict(event='task.presentation', task=task, ts=stamp, value=value))
    assert recent() == ['a', 'b', 'c'], recent()
    before = {k:v['updated'] for k,v in task_rows().items()}
    for index, task in enumerate(('c', 'b', 'a')):
        usage = dict(by=[dict(harness='codex', model='fixture', effort='high', usd=index+1,
                             tokens=(index+1)*100, output_tokens=10, sessions=1, usd_known=True)])
        replay(dict(event='task.usage', task=task, ts=stamp+10+index, value=usage))
        assert model.facts['usage'][task] == usage
        assert next(r for r in model.value['requests'] if r['id'] == task)['usage']['tokens'] == (index+1)*100
    for index, state in enumerate(('alive', 'dead', 'alive')):
        value = dict(state=state, source='worker.process', verdict='fixture')
        replay(dict(event='agent.liveness', task='c', ts=stamp+20+index, value=value))
        assert task_rows()['task:c']['worker_liveness'] is None  # queued, presence is not running
        assert model.workers['c']['state'] == state
    replay(dict(event='agent.activity', task='c', ts=stamp+30,
                value=dict(gen='g', seq=1, state='idle', native_activity=dict(state='idle'))))
    replay(dict(event='agent.retired', task='c', ts=stamp+31, value=dict(gen='g')))
    assert recent() == ['a', 'b', 'c'], recent()
    assert {k:v['updated'] for k,v in task_rows().items()} == before
    assert task_rows()['task:c']['observed']['value'] > before['task:c']['value']
    # Substantive edit and new delivery move the request, with their event reason.
    row = copy.deepcopy(base['rows']['c']); row['title'] = 'Changed task'
    replay(dict(event='task.changed', task='c', ts=stamp+40, value=dict(task=row)))
    assert recent()[0] == 'c' and task_rows()['task:c']['title'] == 'Changed task'
    assert task_rows()['task:c']['updated']['source'] == 'fleet.entity:task.changed'
    value = copy.deepcopy(base['presentations']['b'])
    value['presentation']['summary'] = 'New result'
    replay(dict(event='task.presentation', task='b', ts=stamp+50, value=value))
    assert recent() == ['b', 'c', 'a'], recent()
    # Delayed telemetry and older substantive events cannot masquerade as a new delivery.
    replay(dict(event='task.usage', task='a', ts=stamp+500, value={}))
    replay(dict(event='task.usage', task='b', ts=stamp+1, value={}))
    replay(dict(event='task.review', task='b', ts=stamp+2, value=value))
    assert recent() == ['b', 'c', 'a'], recent()
    expected = {k:v['updated'] for k,v in task_rows().items()}
    recovered = cli('work', 'bootstrap')
    assert {t['key']:t['updated'] for t in recovered['snapshot']['tasks']} == expected
    restored = Projection(recovered)
    assert {t['key']:t['updated'] for t in restored.value['tasks']} == expected
    # Date of a status is its original declaration, never its late capture time.
    replay(dict(event='task.status', task='a', ts=stamp+900, declared_at=stamp-1,
                state='working', text='Earlier work'))
    assert recent() == ['b', 'c', 'a'], recent()
    replay(dict(event='task.status', task='a', ts=stamp+901, declared_at=stamp+60,
                state='needs-decision', text='New decision'))
    assert recent() == ['a', 'b', 'c'], recent()
    recovered = cli('work', 'bootstrap')['snapshot']
    for row in recovered['tasks']:
        assert row['updated'] == task_rows()[row['key']]['updated']
        assert row['observed'] == task_rows()[row['key']]['observed']
print('ok - meaningful recency, three usage events, liveness, stable ties, late telemetry, delivery, decision and bootstrap recovery')
PY
fi
if [ "${FM_WORK_TEST_RESOURCES:-0}" != 1 ]; then
python3 - <<'PY'
import copy,json,os,pathlib,subprocess,sys,tempfile,time
root=pathlib.Path(os.environ['ROOT'])
sys.path.insert(0,str(root/'bin'))
from fm_work_projection import Projection
# Five manual cases through real owners, then incremental telemetry at one cursor.
with tempfile.TemporaryDirectory(prefix='fm-work-state-') as directory:
    home = pathlib.Path(directory)
    for part in ('data', 'state', 'config'): (home / part).mkdir()
    (home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
    (home / 'data/projects.md').write_text('- alpha [local-only] - Example\n')
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (home / 'config/fleet-ledger').touch()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    def cli(script, *args, payload=None):
        p = subprocess.run(['bash', str(root / 'bin' / script), *args], env=env, text=True,
                           input=json.dumps(payload) if payload is not None else None, capture_output=True)
        assert p.returncode == 0, (args, p.stdout, p.stderr)
        return p.stdout
    def work(*args, **kw): return json.loads(cli('fm-tasks-axi.sh', 'work', *args, **kw))
    for key in ('ready', 'dependency', 'capacity', 'human', 'parked', 'action', 'approval', 'running'):
        cli('fm-tasks-axi.sh', 'add', key, key, '--repo', 'alpha', *(['--kind', 'captain'] if key == 'action' else []))
    cli('fm-tasks-axi.sh', 'hold', 'parked', '--kind', 'parked', '--reason', 'Parked deliberately')
    for key, options in [('human', ['--question', 'Choose?', '--option', 'yes=Proceed', '--option', 'no=Wait']),
                         ('action', ['--call-kind', 'action', '--instruction', 'Inspect the result', '--where', 'chat']),
                         ('approval', ['--call-kind', 'approval', '--question', 'Approve?', '--option', 'yes=Approve', '--option', 'no=Wait'])]:
        cli('fm-captain-hold.sh', 'hold', key, '--reason', 'Human response', '--category', 'product-design', '--challenge', 'fixture', *options)
    draft = home / 'data/draft.json'
    draft.write_text(json.dumps(dict(outcome=dict(role='final', review='needed'))))
    cli('fm-tasks-axi.sh', 'presentation', 'human', '--presentation-file', str(draft))
    work('apply', payload=dict(op='add_dep', target='task:dependency', on='task:ready',
        expected_rev=work('snapshot')['rev'], actor='captain', request_id='state-dependency-0001'))
    cli('fm-tasks-axi.sh', 'start', 'running')
    (home / 'state/running.status').write_text('paused [at=1794614400]: Waiting for my command\n')
    (home / 'config/lane-capacity').write_text('1\n')
    (home / 'state/occupied.meta').write_text('kind=ship\n')
    folder = home / 'data/work-requests'; folder.mkdir(exist_ok=True)
    queued = dict(at='2026-11-14T00:00:00Z', at_ns=1, scope='task:capacity', signal='resume.request',
        pause_state='queued', candidates=['capacity'], safe_tasks=[], operation=dict(op='clear_pause',
        target='task:capacity', request_id='state-capacity-0001'), result=dict(state='received', reason='cap', running=1, cap=1))
    (folder / 'capacity.json').write_text(json.dumps(queued))
    base = work('bootstrap'); model = Projection(base)
    def rows(): return {t['key'][5:]:t for t in model.value['tasks']}
    assert all(t.get('placement') for t in rows().values()), 'missing placement explanation'
    expected = dict(ready='ready', dependency='dependency', capacity='capacity', human='needs_you',
                    parked='paused', action='needs_you', approval='needs_you', running='waiting')
    assert {k:t['placement']['section'] for k,t in rows().items()} == expected
    counts = model.value['counts']
    assert counts['needs_you']['count'] == 3
    assert {k:v['count'] for k,v in counts['needs_you']['by_kind'].items()} == dict(questions=1, actions=1, reports=1, approvals=1)
    keys = [k for s in counts['sections'].values() for k in s['keys']]
    assert len(keys) == len(set(keys)) == counts['tasks']['count'] == 8
    stamp = int(time.time())
    blocked_action = copy.deepcopy(model.rows['action'])
    blocked_action['deps'] = [dict(type='blocked-by', id='ready')]
    assert model.apply(dict(event='task.changed', task='action', ts=stamp, value=dict(task=blocked_action)))
    assert rows()['action']['placement']['section'] == 'dependency' and rows()['action']['placement']['attention'] == []
    assert model.value['counts']['needs_you']['count'] == 2
    assert model.apply(dict(event='agent.liveness', task='running', ts=stamp,
        value=dict(state='alive', source='worker.process', gen='worker-1', observed_at='2026-11-14T00:00:00Z')))
    t = rows()['running']
    assert t['placement']['section'] == 'waiting' and t['worker_liveness']['state'] == 'alive'
    assert t['worker_liveness']['generation'] == 'worker-1' and t['worker_liveness']['age_seconds'] >= 0
    # Launches are not cards or confirmed living workers.
    assert model.apply(dict(event='task.dispatched', task='unfiled-launch', ts=stamp, kind='ship', value={}))
    assert model.value['counts']['tasks']['count'] == 8 and model.value['counts']['workers']['alive']['count'] == 1
    assert model.apply(dict(event='home.configuration', ts=stamp, value=dict(lane_capacity='', projects=base['registry_text'])))
    assert model.value['counts']['capacity']['state'] == 'unknown' and model.value['counts']['capacity']['limit'] is None
    assert rows()['capacity']['placement']['section'] == 'ready'
    for value, section in [(dict(source='spawn-deferred', project_limit=1), 'capacity'), ({}, 'ready')]:
        cli('fm-fleet-ledger.sh', 'entity', 'task.dispatch_wait', 'ready', payload=value)
        event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
        assert model.apply(event) and rows()['ready']['placement']['section'] == section
    assert model.apply(dict(event='task.status', task='running', ts=stamp, declared_at=stamp, state='working', text='paused waiting capacity approval'))
    assert rows()['running']['placement']['section'] == 'running'  # prose has no classification power
    decision = home / 'data/answer.txt'; decision.write_text('yes\n')
    cli('fm-captain-hold.sh', 'answer', 'approval', '--decision-file', str(decision), '--release')
    answered = next(t for t in work('snapshot')['tasks'] if t['key'] == 'task:approval')
    assert not answered['question']['open'] and answered['placement']['attention'] == []
    (home / 'config/lane-capacity').unlink()
    (home / 'config/project-capacity').write_text('alpha 1\n')
    (home / 'state/ready.spawn-deferred').write_text(str(home / 'projects/alpha') + '\n')
    deferred = next(t for t in work('snapshot')['tasks'] if t['key'] == 'task:ready')
    assert deferred['placement']['code'] == 'capacity_dispatch'
    assert deferred['dispatch_wait']['project_limit'] == 1
    (home / 'config/project-capacity').unlink()
    unconfigured = next(t for t in work('snapshot')['tasks'] if t['key'] == 'task:ready')
    assert unconfigured['placement']['section'] == 'ready' and unconfigured['dispatch_wait']['project_limit'] is None
print('ok - five explained states, disjoint task counts, overlapping attention, worker generation and unknown capacity')
PY
fi
if [ "${FM_WORK_TEST_STATE:-0}" != 1 ]; then
python3 - <<'PY'
import copy,json,os,pathlib,subprocess,sys,tempfile,time
root=pathlib.Path(os.environ['ROOT']);sys.path.insert(0,str(root/'bin'))
from fm_work_projection import Projection
with tempfile.TemporaryDirectory(prefix='fm-resource-wait-') as directory:
    home=pathlib.Path(directory)
    for part in ('data','state','config'): (home/part).mkdir()
    (home/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (home/'config/fleet-ledger').touch()
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_'))}
    env.update(FM_HOME=str(home),FM_LIVE='0')
    def cli(script,*args,payload=None):
        p=subprocess.run(['bash',str(root/'bin'/script),*args],env=env,text=True,capture_output=True,
                         input=json.dumps(payload) if payload is not None else None)
        assert p.returncode==0,(args,p.stdout,p.stderr)
        return p.stdout
    def work(verb): return json.loads(cli('fm-tasks-axi.sh','work',verb))
    cli('fm-tasks-axi.sh','add','resource','Resource wait')
    cli('fm-tasks-axi.sh','hold','resource','--kind','parked','--reason','Held')
    (home/'reserve').touch()
    folder=home/'data/work-requests';folder.mkdir(exist_ok=True)
    path=folder/'resource.json';config=home/'config/lane-capacity'
    failures=[];checked=[]
    def check(snapshot,label,cap,waiting):
        task=next(t for t in snapshot['tasks'] if t['key']=='task:resource')
        place=task.get('placement');checked.append(label)
        print(label,json.dumps(dict(crew=snapshot['crew'],placement=place)),flush=True)
        if place is None:
            failures.append((label,'missing placement explanation'));return
        wait=place['inputs']['capacity_wait'] or {}
        expected=('capacity','capacity_resources') if waiting else ('paused','parked')
        checks=[task['state']=='paused_own',task['pause']['own']['reason']=='Held',
                snapshot['counts']['capacity']['limit']==cap,(place['section'],place['code'])==expected]
        checks += [place['reason']=='resources',wait.get('reason')=='resources',wait.get('cap')==cap] if waiting else [place['inputs']['capacity_wait'] is None]
        if not all(checks): failures.append((label,checks))
    for mode,text,cap in [('invalid','invalid\n',None),('limited',f'2\nreserve-flag {home}/reserve\n',2),('unknown',None,None)]:
        if path.exists(): path.unlink()
        if text is None: config.unlink()
        else: config.write_text(text)
        # A typed queue record is the owner's explicit wait, not inferred prose.
        base=work('bootstrap');model=Projection(base)
        record=dict(at='2026-11-15T00:00:00Z',at_ns=1,scope='task:resource',signal='resume.request',
            pause_state='queued',candidates=['resource'],safe_tasks=[],operation=dict(op='clear_pause',
            target='task:resource',request_id='resource-case-'+mode),result=dict(state='received',reason='resources',running=0,cap=cap))
        path.write_text(json.dumps(record))
        cli('fm-fleet-ledger.sh','entity','work.control','resource',payload=record)
        event=json.loads((home/'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
        assert model.apply(event)
        check(work('snapshot'),mode+' snapshot',cap,True)
        check(work('bootstrap')['snapshot'],mode+' bootstrap',cap,True)
        check(model.value,mode+' replay',cap,True)
        record['cancelled']=True;path.write_text(json.dumps(record))
        cli('fm-fleet-ledger.sh','entity','work.control','resource',payload=record)
        assert model.apply(json.loads((home/'state/fleet-ledger.jsonl').read_text().splitlines()[-1]))
        check(work('snapshot'),mode+' cleared snapshot',cap,False)
        check(work('bootstrap')['snapshot'],mode+' cleared bootstrap',cap,False)
        check(model.value,mode+' cleared replay',cap,False)
    assert len(checked)==18,checked
    assert not failures,failures
print('ok - resource queue and withdrawal: 18 checks across snapshot, bootstrap and replay with invalid, known and unknown limits')
PY
fi
