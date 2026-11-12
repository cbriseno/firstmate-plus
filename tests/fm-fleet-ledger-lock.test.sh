#!/usr/bin/env bash
# Locked card/backlog publications retain their resulting values without
# sampling the fleet; status and dispatch events retain their observations.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-fleet-ledger-lock-') as tmp:
    home = pathlib.Path(tmp)
    for name in ('data', 'state', 'config', 'code/bin'):
        (home / name).mkdir(parents=True)
    (home / 'config/fleet-ledger').touch()
    (home / 'data/.work.lock').touch()
    (home / 'data/backlog.md').write_text('## Queued\n\n- [ ] proof - Proof (repo: alpha)\n')
    # Isolate only the costly observation seam. Everything from the public
    # mutation wrapper to canonical parsing, locks and ledger append is real.
    code = home / 'code/bin'
    for source in (root / 'bin').iterdir():
        target = code / source.name
        if source.name in ('fm-tasks-axi.sh', 'fm_delivery.py', 'fm-fleet-ledger.sh'):
            shutil.copy2(source, target)
        elif source.name != 'fm-fleet-snapshot.sh':
            target.symlink_to(source)
    sampled = home / 'sampled'
    (code / 'fm-fleet-snapshot.sh').write_text(
        '#!/usr/bin/env bash\nprintf sampled >> "$FM_HOME/sampled"\n'
        'printf \'{"main_inventory":null,"tasks":[]}\\n\'\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    wrapper = ['bash', str(code / 'fm-tasks-axi.sh')]
    def execute(argv):
        result = subprocess.run(argv, env=env, text=True, capture_output=True, timeout=20)
        assert result.returncode == 0, (argv, result.stdout, result.stderr)
        return result.stdout
    def records():
        return [json.loads(line) for line in (home / 'state/fleet-ledger.jsonl').read_text().splitlines()]
    progress = {'steps': [{'label': 'Fix', 'state': 'done'}, {'label': 'Checks', 'state': 'active'}]}
    draft = home / 'input.json'
    draft.write_text(json.dumps({'phase': 'implementation', 'progress': progress}))
    value = json.loads(execute(wrapper + ['presentation', 'proof', '--presentation-file', str(draft)]))
    assert value['ok'] and value['state'] == 'published' and value['evidence']['available']
    assert value['lifecycle']['evidence']['current'] and value['presentation']['progress'] == progress
    execute(wrapper + ['update', 'proof', '--priority', '1'])
    entities = records()
    assert entities[-2]['event'] == 'task.presentation'
    assert entities[-2]['value']['presentation']['progress'] == progress
    assert entities[-1]['event'] == 'task.changed' and entities[-1]['value']['task']['priority'] == 1
    assert not sampled.exists(), 'card and backlog events must not sample the fleet under the work lock'
    status = home / 'state/proof.status'
    status.write_text('working [at=1793511394]: observation\n')
    ledger = ['bash', str(code / 'fm-fleet-ledger.sh')]
    execute(ledger + ['appended', str(home / 'config'), str(status)])
    assert sampled.read_text() == 'sampled', 'status publication still samples the fleet'
    assert records()[-1]['event'] == 'task.status' and records()[-1]['observation']['tasks'] == []
    execute(ledger + ['dispatched', 'proof', 'ship', 'alpha', 'codex', ''])
    assert sampled.read_text() == 'sampledsampled', 'dispatch publication still samples the fleet'
    assert records()[-1]['event'] == 'task.dispatched' and records()[-1]['observation']['tasks'] == []
    print('PASS: card/backlog values publish without fleet sampling; status/dispatch observations remain')
PY
