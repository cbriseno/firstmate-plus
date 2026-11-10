#!/usr/bin/env bash
# Bootstrap and incremental activity through the real owner and busy writer.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
python3 - <<'PY'
import copy, gc, json, os, pathlib, subprocess, sys, tempfile, weakref
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
    model = Projection(base)
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
PY
