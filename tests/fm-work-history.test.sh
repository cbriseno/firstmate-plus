#!/usr/bin/env bash
# Regression: canonical archived records can have a null body. The work snapshot
# must retain their identity/date without inventing progress or question origins.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
TASK_HOME=$(fm_test_tmproot fm-work-history)
mkdir -p "$TASK_HOME/data" "$TASK_HOME/state" "$TASK_HOME/config"
printf '%s\n' '- alpha [local-only] - Test project' > "$TASK_HOME/data/projects.md"
printf '%s\n' '## Queued' '- [ ] next - Next task (repo: alpha) (since 2026-10-31)' > "$TASK_HOME/data/backlog.md"
printf '%s\n' '## Archived 2026-10-31' '- [x] previous - Previous task (repo: alpha) (since 2026-10-29) (done 2026-10-30)' > "$TASK_HOME/data/done-archive.md"
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_BACKEND TASKS_AXI_FILE
FM_HOME="$TASK_HOME" bash "$ROOT/bin/fm-tasks-axi.sh" work snapshot | python3 -c '
import json,sys
s=json.load(sys.stdin)
assert s["schema"]=="fm-work-snapshot.v1",s
assert len(s["tasks"])==2,s
previous=next(t for t in s["tasks"] if t["key"]=="task:previous")
assert previous["state"]=="done",previous
assert previous["completed"]["value"]=="2026-10-30",previous
assert previous["completed"]["precision"]=="date",previous
assert previous["question"]["origin_task"] is None,previous
assert previous["progress"] is None,previous
assert s["sigue"]==["task:next"],s
print("PASS: archived null-body snapshot preserves completion date and unknown fields")
'

# Migrate historical declarations through their real owner, including Undo.
python3 - "$ROOT" "$TASK_HOME" <<'PY'
import json, os, pathlib, subprocess, sys
root, home = map(pathlib.Path, sys.argv[1:])
env = dict(os.environ, FM_HOME=str(home))
(home/'data/projects.md').write_text('- alpha [local-only] - A\n- beta [local-only] - B\n')
(home/'.tasks.toml').write_text('[markdown]\npath="data/backlog.md"\narchive="data/older.md"\n')
(home/'data/done-archive.md').rename(home/'data/older.md')
with (home/'data/older.md').open('a') as f:
    f.write('- [x] reopened - Old closed task (repo: alpha) (done 2026-10-29)\n')
with (home/'data/backlog.md').open('a') as f:
    f.write('- [ ] reopened - Open again (repo: alpha)\n\n## Done\n'
            '- [x] declared - Explicit result (repo: alpha)\n'
            '- [x] unknown - Ambiguous project\n'
            '- [x] cross-a - Shared request (repo: alpha)\n'
            '- [x] cross-b - Shared request (repo: beta)\n'
            '- [x] silent - Completed without report (repo: alpha)\n')
for tid in ('previous','reopened','declared','unknown'):
    (home/'data'/tid).mkdir(exist_ok=True)
    (home/'data'/tid/'report.md').write_text('# Report\n')
def call(script, *args):
    p = subprocess.run(['bash',str(root/'bin'/script),*args], env=env, capture_output=True, text=True)
    assert p.returncode == 0, (args,p.stdout,p.stderr)
    return json.loads(p.stdout)
def patch(tid, value):
    source = home/'patch.json'; source.write_text(json.dumps(value))
    return call('fm-tasks-axi.sh','presentation',tid,'--presentation-file',str(source))
def read(tid):
    return call('fm-tasks-axi.sh','presentation',tid)['presentation']
patch('previous',dict(request=dict(id='previous',label='Earlier request',project='Proyecto sin registrar')))
patch('unknown',dict(request=dict(id='unknown',label='Unknown origin',project='Proyecto sin registrar')))
for tid in ('cross-a','cross-b'):
    patch(tid,dict(request=dict(id='cross-a',label='Spans two projects',project='Proyecto sin registrar')))
patch('declared',dict(summary='Reviewed result',outcome=dict(role='final',review='done')))
migrate = lambda mode: call('fm-migrate-v11b.sh','--'+mode)
original = (home/'data/previous/presentation.json').read_bytes()
plan = migrate('plan')
assert plan['count'] == 2, plan
assert (home/'data/previous/presentation.json').read_bytes() == original
assert not (home/'data/migration-v11b').exists()
assert migrate('apply')['count'] == 2
assert read('previous')['outcome'] == dict(role='final',review=None)
assert read('previous')['summary'] == 'Previous task'
assert read('previous')['request']['project'] == 'alpha'
assert read('unknown')['request']['project'] == 'Proyecto sin registrar'
assert read('cross-a')['request']['project'] == read('cross-b')['request']['project'] == 'Proyecto sin registrar'
assert read('reopened')['outcome'] is None
assert read('declared')['outcome']['review'] == 'done'
assert read('declared')['summary'] == 'Reviewed result'
assert read('silent')['outcome'] is None
files = {p:p.read_bytes() for p in (home/'data').glob('*/presentation.json')}
assert migrate('apply')['count'] == 0
assert all(p.read_bytes() == value for p,value in files.items())
patch('previous',dict(summary='Later owner edit'))
assert migrate('rollback')['restored'] == 2
assert read('previous')['outcome'] is None
assert read('previous')['summary'] == 'Later owner edit'
assert read('previous')['request']['project'] == 'Proyecto sin registrar'
assert migrate('rollback')['restored'] == 0
assert migrate('apply')['count'] == 2
snapshot = call('fm-tasks-axi.sh','work','snapshot')
assert not any((t.get('outcome') or {}).get('review') == 'needed' for t in snapshot['tasks'])
assert next(t for t in snapshot['tasks'] if t['key']=='task:previous')['outcome']['role']=='final'
# An unarchived home needs no archive file just to preview an empty migration.
(home/'data/older.md').unlink()
assert migrate('plan')['count'] == 0
print('PASS: v11b plan, apply, archive, reopened tasks, ambiguity, idempotence and guarded rollback')
PY

# Upgrade notes offer a real hold once, and only mark successful migrations.
python3 - "$ROOT" "$TASK_HOME" <<'PYTHON'
import json, os, pathlib, subprocess, sys
root, base = map(pathlib.Path, sys.argv[1:])
home = base/'upgrade-home'; code = base/'upgrade-release'
for name in ('data', 'state', 'config'):
    (home/name).mkdir(parents=True)
code.mkdir(); (code/'bin').symlink_to(root/'bin', target_is_directory=True)
notes = code/'UPGRADING.md'
notes.write_text('## v11b - 2026-11-10\n\nAction: Migrate historical results.\n\n'
                 'Command: `bash bin/fm-migrate-v11b.sh --apply`\n')
(home/'data/backlog.md').write_text('## Queued\n\n## In flight\n\n## Done\n')
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(code))
def call(script, *args, status=0):
    p = subprocess.run(['bash',str(root/'bin'/script),*args],env=env,capture_output=True,text=True)
    assert p.returncode == status, (args,p.stdout,p.stderr)
    return p.stdout
assert 'UPDATE_ACTIONS:' in call('fm-upgrade.sh','check')
assert call('fm-upgrade.sh','check') == ''
assert not (home/'data/upgrades/applied').exists()
card = json.loads((home/'data/upgrade-v11b/captain-call.json').read_text())['call']
assert card['recommended'] == 'apply', card
assert len(card['options']) == 2, card
answer = base/'upgrade-answer.txt'; answer.write_text('Aplicarlas - fixture acceptance\n')
call('fm-captain-hold.sh','answer','upgrade-v11b','--decision-file',str(answer))
call('fm-upgrade.sh','apply')
assert (home/'data/upgrades/applied').read_text() == 'v11b\n'
assert call('fm-upgrade.sh','apply') == call('fm-upgrade.sh','check') == ''
# No repeated prompt on decline, and no applied id for a failed command.
with notes.open('a') as stream:
    stream.write('\n## fixture - 2026-11-10\n\nAction: Fixture action.\n\n'
                 'Command: `bash -c "exit 7"`\n')
assert 'upgrade-fixture' in call('fm-upgrade.sh','check')
answer.write_text('Dejarlas pendientes - fixture decline\n')
call('fm-captain-hold.sh','answer','upgrade-fixture','--decision-file',str(answer))
assert call('fm-upgrade.sh','check') == ''
call('fm-upgrade.sh','apply',status=1)
assert (home/'data/upgrades/applied').read_text() == 'v11b\n'
notes.write_text(notes.read_text().replace('exit 7','exit 0'))
call('fm-upgrade.sh','apply')
assert (home/'data/upgrades/applied').read_text() == 'v11b\nfixture\n'
print('PASS: upgrade hold, no implicit migration, acceptance, decline, command failure and successful ids')
PYTHON
