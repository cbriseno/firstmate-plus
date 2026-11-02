"""Offline pair check against real producer endpoints in disposable clones only."""
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

firstmate = Path('/work/repos/firstmate')
deck = Path('/work/repos/deck')
tools = Path('/work/tool-bin')
tools.mkdir(exist_ok=True)
cli = tools / 'tasks-axi'
cli.symlink_to('/opt/runtime/tasks-axi/dist/bin/tasks-axi.js')
os.environ['PATH'] = str(tools) + os.pathsep + os.environ['PATH']
os.environ['FM_LIVE'] = '0'
sys.path.insert(0, str(deck / 'scripts'))
sys.path.insert(0, str(deck / 'web'))
from deck_control import DeckControls

(firstmate / 'data').mkdir(exist_ok=True)
(firstmate / 'data/projects.md').write_text('- example [local-only] - Example project\n')
(firstmate / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n- [ ] example-task - Example task (repo: example) (kind: ship) (priority: 2)\n\n## Done\n')
home = SimpleNamespace(path=str(firstmate))
controls = DeckControls(lambda home: dict(os.environ, FM_HOME=home.path))
capabilities = controls.invoke(home, 'capabilities')
assert capabilities['schema'] == 'fm-work-capabilities.v1'
assert capabilities['contract_major'] == 1
assert 'set_priority' in capabilities['ops']


def snapshot():
    return controls.invoke(home, 'snapshot')


def task(value):
    return next(row for row in value['tasks'] if row['key'] == 'task:example-task')


before = snapshot()
assert task(before)['priority']['own'] == 2
operation = dict(op='set_priority', target='task:example-task', value=1,
                 expected_rev=before['rev'], request_id='example-priority-0001', actor='captain')
preview = controls.invoke(home, 'preview', operation)
assert 'impact' in preview
assert task(snapshot())['priority']['own'] == 2
receipt = controls.invoke(home, 'apply', operation)
assert receipt['state'] == 'applied', receipt
assert task(snapshot())['priority']['own'] == 1
assert controls.invoke(home, 'apply', operation)['state'] == 'applied'
undo = dict(receipt['undo'], request_id='example-priority-undo-0001')
assert controls.invoke(home, 'apply', undo)['state'] == 'applied'
assert task(snapshot())['priority']['own'] == 2
source = controls.source(home)
assert source['available'] is True
assert any(node['id'] == 'task:example-task' for node in source['snapshot']['nodes'])
absent = controls.source(SimpleNamespace(path='/work/absent-producer'))
assert absent['available'] is False and absent['code'] == 'unsupported_op'
print(json.dumps(dict(capabilities=True, snapshot=True, preview=True, apply=True, idempotence=True, undo=True, absent_producer=True)))
