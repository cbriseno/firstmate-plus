#!/usr/bin/env bash
# Client backfill through the public CLI: dry review, corroboration, selective
# apply, unique sessions versus model buckets, cache re-read and exact restore.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot usage-recovery)
export FM_LIVE=0
python3 -B - "$ROOT" "$TMP_ROOT" <<'PY'
import copy, json, os, pathlib, subprocess, sys
root, base = map(pathlib.Path, sys.argv[1:])
home = base/'client'; claude = base/'claude/project'; codex = base/'sessions/day'
for path in (home/'state', home/'data', claude, codex): path.mkdir(parents=True)
cmd = [sys.executable, '-B', str(root/'bin/fm_task_sessions.py'), 'backfill', str(home), str(claude.parent), str(codex.parent)]
def cli(*args, ok=True):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    env.pop('FM_FLEET_LEDGER', None)
    p = subprocess.run(cmd+list(args), env=env, capture_output=True, text=True)
    assert (p.returncode == 0) == ok, (p.returncode, p.stdout, p.stderr)
    return json.loads(p.stdout) if ok else p.stderr

def lines(path, rows): path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
def contract(task, owner=home):
    return f'Your steering inbox is `{owner}/state/{task}.inbox`; this exact path belongs to your current task'
def transcript(name, minute, link=None, model='gpt-6.1-sol'):
    path = codex/('rollout-'+name+'.jsonl')
    rows = [dict(type='session_meta', timestamp=f'2026-11-01T00:{minute:02d}:00Z', payload=dict(session_id=name, cwd='/tmp/unrelated')),
        dict(type='turn_context', payload=dict(model=model, effort='high')),
        dict(type='token_usage_record', payload=dict(usage=dict(input_tokens=100,cached_input_tokens=80,output_tokens=10)))]
    if link: rows.append(dict(type='response_item', payload=dict(text=link)))
    lines(path, rows)
    return path
for task, minute in [('explicit',0), ('inferred',15), ('ambiguous',30), ('missing',50), ('rejected',40)]:
    folder=home/'data'/task; folder.mkdir()
    lines(folder/'sessions.jsonl', [dict(harness='codex', model=None, effort=None, started_at=f'2026-11-01T00:{minute:02d}:00Z', session=None)])
    (folder/'usage.json').write_text('{"legacy": "retain exact bytes"}\n')
# Exercise P02 lifecycle preservation and P08 pinned prices during apply.
folder=home/'data/explicit'
row=json.loads((folder/'sessions.jsonl').read_text())
row.update(project='/local/project',status='archived',launch='historical-launch',reason='awaiting-transcript')
lines(folder/'sessions.jsonl',[row])
pricing=json.loads((root/'bin/fm_task_prices.json').read_text())
pricing.update(version='fixture-pinned',verified='2000-01-01')
(folder/'usage.json').write_text(json.dumps(dict(by=[],unknown=['no-session'],estimated=False,pricing=pricing)))
explicit=transcript('explicit',0,contract('explicit'))
# A single transcript with two models is one unique session and two buckets.
with explicit.open('a') as f:
    for row in [dict(type='turn_context', payload=dict(model='gpt-6.1-terra',effort='low')),
                dict(type='token_usage_record', payload=dict(usage=dict(input_tokens=200,cached_input_tokens=0,output_tokens=10)))]:
        f.write(json.dumps(row)+'\n')
inferred=transcript('inferred',15)
inferred.write_text(inferred.read_text().replace('00:15:00Z','00:15:05Z'))
transcript('ambiguous-a',30); transcript('ambiguous-b',31)
transcript('rejected',40); transcript('foreign',50,contract('missing',base/'other-home'))
# Claude uses its existing assistant/API request format and task cwd evidence.
lines(claude/'main.jsonl', [dict(type='user',timestamp='2026-11-01T02:00:00Z',cwd='/tmp/claude-task'),
    dict(type='api-request',params=dict(model='sonnet',output_config=dict(effort='medium'))),
    dict(type='assistant',message=dict(id='one',model='claude-sonnet-5-5',usage=dict(input_tokens=100,output_tokens=10)))])
(home/'data/claude-task').mkdir()
lines(home/'data/claude-task/sessions.jsonl', [dict(harness='claude',model='sonnet',effort='medium',started_at='2026-11-01T02:00:00Z',session=None)])
(home/'data/no-anchor').mkdir()
def snapshot(): return {str(p.relative_to(home)):p.read_bytes() for p in home.rglob('*') if p.is_file()}
before=snapshot(); review=cli(); assert snapshot()==before, 'dry run wrote files'
by={t['task_id']: t for t in review['tasks']}
assert {k:v['confidence'] for k,v in by.items()} == dict(explicit='explicit',inferred='inferred',ambiguous='ambiguous',missing='unknown',rejected='inferred',**{'claude-task':'explicit','no-anchor':'unknown'})
assert by['missing']['missing_reason']=='no-nearby-transcript'
assert by['no-anchor']['missing_reason']=='no-recorded-anchor-or-explicit-link'
assert by['claude-task']['candidates'][0]['session']['model']=='claude-sonnet-5-5'
session_cli=[sys.executable, '-B', str(root/'bin/fm_task_sessions.py')]
launch=home/'data/launch'; launch.mkdir()
(home/'state/launch.meta').write_text('\n'.join([
    'harness=claude', 'model=sonnet', 'effort=medium', 'spawned_at=2026-11-01T02:00:00Z',
    'busy_gen=gen', 'sessions_file='+str(launch/'sessions.jsonl')])+'\n')
subprocess.run(session_cli+['start',str(home/'state'),'launch'], check=True)
subprocess.run(session_cli+['bind',str(home/'state'),'launch','gen'],
               input=json.dumps(dict(transcript_path=str(claude/'main.jsonl'))), text=True, check=True)
record=json.loads((launch/'sessions.jsonl').read_text())
assert (record['model'],record['observed_model'],record['observed_effort']) == ('sonnet','claude-sonnet-5-5','medium')
saved=(launch/'sessions.jsonl').read_bytes()
subprocess.run(session_cli+['bind',str(home/'state'),'launch','gen'],
               input=json.dumps(dict(transcript_path=str(claude/'main.jsonl'))), text=True, check=True)
assert (launch/'sessions.jsonl').read_bytes()==saved
legacy=home/'data/legacy'; legacy.mkdir()
lines(legacy/'sessions.jsonl',[dict(harness='claude',model='sonnet',effort='high',session=None)])
listed=json.loads(subprocess.check_output(session_cli+['list',str(home),'--task','legacy'],text=True))
assert listed['model']=='sonnet' and listed['observed_model'] is None and listed['observed_effort'] is None
(home/'state/launch.meta').unlink()
(launch/'sessions.jsonl').unlink(); launch.rmdir()
(legacy/'sessions.jsonl').unlink(); legacy.rmdir()
assert by['inferred']['candidates'][0]['evidence']==['session-start']
review_path=base/'review.json'; backup=base/'before.json'
by['inferred']['candidates'][0]['decision']='accept'
review_path.write_text(json.dumps(review))
assert 'corroboration required' in cli('--apply',str(review_path),'--backup',str(backup),ok=False)
assert snapshot()==before and not backup.exists(), 'failed review changed files'
by['inferred']['candidates'][0]['corroboration']='Local dispatch note names this worktree and brief.'
by['explicit']['candidates'][0]['decision']='accept'
by['claude-task']['candidates'][0]['decision']='accept'
by['rejected']['candidates'][0]['decision']='reject'
review_path.write_text(json.dumps(review))
applied=cli('--apply',str(review_path),'--backup',str(backup))
assert set(applied['applied'])=={'explicit','inferred','claude-task'}
for task in ('rejected','ambiguous','missing'):
    for file in ('sessions.jsonl','usage.json'):
        assert (home/'data'/task/file).read_bytes()==before[f'data/{task}/{file}']
usage=applied['usage']['explicit']
assert usage['unique_sessions']==1 and sum(r['sessions'] for r in usage['by'])==2
assert not usage['unknown'] and len(usage['by'])==2
assert usage['pricing']['version']=='fixture-pinned' and usage['pricing_stale']
row=json.loads((home/'data/explicit/sessions.jsonl').read_text())
assert row['project']=='/local/project' and row['status']=='archived' and row['launch']=='historical-launch' and row['reason'] is None
assert abs(sum(r['usd'] for r in usage['by'])-.000398)<1e-12
assert all(r['effort'] for r in usage['by'])
assert json.loads((home/'data/inferred/sessions.jsonl').read_text())['recovery']['confidence']=='inferred'
assert json.loads((home/'data/inferred/sessions.jsonl').read_text())['started_at']=='2026-11-01T00:15:00Z'
claude_record=json.loads((home/'data/claude-task/sessions.jsonl').read_text())
assert claude_record['model']=='claude-sonnet-5-5' and claude_record['requested_model']=='sonnet'
assert not applied['usage']['inferred']['unknown'], 'accepted nearby launch left an unbound placeholder'
after=snapshot(); assert cli('--apply',str(review_path),'--backup',str(backup))['applied']==[]
assert snapshot()==after, 'repeat changed rows'
# Unknown model retains tokens, never converts missing cost into a priced zero.
unknown=transcript('unpriced',55,contract('unpriced'),model='unknown-model')
(home/'data/unpriced').mkdir()
r=cli('--tasks','unpriced'); r['tasks'][0]['candidates'][0]['decision']='accept'
review_path.write_text(json.dumps(r))
u=cli('--apply',str(review_path),'--backup',str(base/'unpriced-before.json'))['usage']['unpriced']['by'][0]
assert u['tokens']==110 and not u['usd_known']
cli('--restore',str(base/'unpriced-before.json'))
cli('--restore',str(backup)); assert snapshot()==before, 'restore lost bytes or original absence'
assert cli('--tasks','missing')['tasks'][0]['confidence']=='unknown'
print('ok - synthetic client dry/review/apply/re-read/restore; explicit, inferred, ambiguous, rejected, unknown; unique sessions')
PY
