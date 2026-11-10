#!/usr/bin/env bash
# Bootstrap and incremental activity through the real owner and busy writer.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
python3 - <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
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
    run(*writer, 'apply', str(home / 'state'), 'activity', 'idle', '--gen', gen, '--source', 'claude-hook', '--event', 'Stop')
    event = json.loads((home / 'state/fleet-ledger.jsonl').read_text().splitlines()[-1])
    assert model.apply(event)
    assert model.activity['activity']['state'] == 'idle'
    assert model.value['tasks'][0]['backlog_state'] == 'in_flight'
    assert not model.apply(dict(event, value=dict(event['value'], seq=1, state='busy')))
    (home / 'state/activity.busy-gen').write_text('other-generation\n')
    assert 'activity' not in json.loads(run('fm-tasks-axi.sh', 'work', 'bootstrap'))['activity']
print('ok - bootstrap activity, turn end, old sequence and generation mismatch')
PY
