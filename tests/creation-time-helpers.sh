#!/usr/bin/env bash
# Shared disposable-home fixture and creation-time cases, selected by the
# independent *.test.sh entries so the runner can pack their measured weights.
# Each entry drives real owners; no service or shared operator state is used.
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_creation_case() {
  command -v tasks-axi >/dev/null || { printf 'skip: tasks-axi required\n'; return 0; }
  FM_LIVE=0 python3 - "$ROOT" "$1" <<'PY'
import copy, datetime as dt, json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
case = sys.argv[2]
sys.path.insert(0, str(root / 'bin'))
from fm_delivery import task_creation
with tempfile.TemporaryDirectory(prefix='fm-creation-time-') as folder:
    home = pathlib.Path(folder)
    for name in ('data', 'state', 'config'):
        (home / name).mkdir()
    (home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (home / 'data/projects.md').write_text('- alpha [local-only] - Alpha\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    wrapper = ['bash', str(root / 'bin/fm-tasks-axi.sh')]
    def run(command, *args, payload=None, raw=False, success=True):
        p = subprocess.run(command + list(args), env=env, cwd=home, text=True, capture_output=True,
                           input=json.dumps(payload) if payload is not None else None, timeout=30)
        if success:
            assert p.returncode == 0, (args,p.stdout,p.stderr)
        return p if not success else p.stdout if raw else json.loads(p.stdout)
    def cli(*args, **kwargs): return run(wrapper,*args,**kwargs)
    def snap(): return cli('work','snapshot')
    def task(value, key): return next(t for t in value['tasks'] if t['key']=='task:'+key)
    def receipt(key): return home / 'data' / key / 'creation.json'
    def task_created(key): return task_creation(home/'data',dict(id=key))
    def instant(value):
        assert value['precision']=='instant' and value['value'].endswith('Z'), value
        parsed=dt.datetime.fromisoformat(value['value'].replace('Z','+00:00'))
        assert parsed.utcoffset()==dt.timedelta(0), value
        return value['value']
    def public_case():
        context=home/'request.json'; context.write_text(json.dumps(dict(request_id='req-creation',platform='discord',
            context_binding=dict(version='ctx1',value='ctx1_creation'),public_safe_summary='Controlled private creation fixture',
            received_at='2026-01-01T00:00:00Z',followup_expires_at='2027-01-01T00:00:00Z',reservation_expires_at='2027-01-01T00:00:00Z')))
        expected=home/'expected.json'; expected.write_text(json.dumps(dict(type='pr-merged',project='alpha',required_deliverables=['pr_url'],completion_policy='all-required')))
        args=('public-followup','add','public-card','--request-context-file',str(context),'--expected-final-file',str(expected),
              '--purpose','promised-final','--expires-at','2027-01-01T00:00:00Z')
        assert cli(*args,raw=True).startswith('ok: public-followup add public-card ->')
        public_creation=receipt('public-card').read_bytes()
        assert cli(*args,'--json')['already'] is True
        assert receipt('public-card').read_bytes()==public_creation
        instant(task_creation(home/'data',dict(id='public-card')))

    if case == 'tasks':
        # The old backend has only a calendar date; observation/repeated add must
        # not fabricate an instant for an already existing card.
        run(['tasks-axi'],'add','legacy','Legacy card','--repo','alpha',raw=True)
        run(['tasks-axi'],'add','unknown','Unknown card','--repo','alpha',raw=True)
        text=(home/'data/backlog.md').read_text()
        import re
        text=re.sub(r'(^- \[ \] unknown - .*?) \(since [0-9-]+\)',r'\1',text,flags=re.M)
        (home/'data/backlog.md').write_text(text)
        before=(home/'data/backlog.md').read_bytes()
        old=snap()
        assert task(old,'legacy')['created']['precision']=='date', old
        assert task(old,'unknown')['created']['precision']=='unknown', old
        cli('add','legacy','Legacy card','--repo','alpha',raw=True)
        assert not receipt('legacy').exists() and (home/'data/backlog.md').read_bytes()==before
        start=dt.datetime.now(dt.timezone.utc)
        output=cli('add','new-','New card','--repo','alpha',raw=True)
        assert output.startswith('ok: added new- '), output
        value=task_created('new-'); stamp=instant(value)
        assert value['source']=='task.creation-receipt' and start <= dt.datetime.fromisoformat(stamp.replace('Z','+00:00')) <= dt.datetime.now(dt.timezone.utc)
        original=receipt('new-').read_bytes()
        cli('add','new-','Already exists','--json')
        cli('update','new-','--priority','1','--title','Renamed card',raw=True)
        cli('hold','new-','--kind','parked','--reason','Pause it',raw=True)
        cli('unhold','new-',raw=True)
        assert receipt('new-').read_bytes()==original
        minted=cli('create','A minted card','--mint','--repo','alpha','--json')['task']['id']
        instant(task_created(minted))
        plain=cli('add','Another minted card','--mint','--repo','alpha',raw=True)
        minted_plain=re.match(r'^ok: added (\S+)',plain)[1]
        final=snap()
        assert task(final,'new-')['created']==value
        for key in (minted,minted_plain):
            assert task(final,key)['created']==task_created(key)
            instant(task(final,key)['created'])
        print('ok - ordinary and minted creation retain original UTC instants; legacy and retries stay honest',flush=True)
    if case == 'calls':
        # Probe the real binary once, then reuse its verified one-hop verdict.
        # Capability compatibility is not the subject of these receipt cases.
        probe='. "$1/fm-tasks-axi-lib.sh"; fm_tasks_axi_compatible || exit; printf "%s\\n" "$FM_TASKS_AXI_COMPATIBLE_MEMO" "$(fm_tasks_axi_check_reason)"'
        verdict=run(['bash','-c',probe,'fm-created',str(root/'bin')],raw=True).splitlines()
        env.update(FM_TASKS_AXI_COMPATIBLE=verdict[0],FM_TASKS_AXI_CHECK_REASON=verdict[1])
        captain=['bash',str(root/'bin/fm-captain-hold.sh')]
        run(captain,'hold','call','--title','A question','--reason','Choose','--repo','alpha',
            '--question','Proceed?','--option','yes=Yes','--option','no=No',raw=True)
        original_call=receipt('call').read_bytes(); call_created=task_created('call'); instant(call_created)
        run(captain,'hold','call','--reason','Choose',raw=True)
        run(captain,'hold','call','--reason','Act in chat','--call-kind','action','--instruction','Record the requested instruction in chat.','--where','chat',raw=True)
        assert receipt('call').read_bytes()==original_call
        run(captain,'hold','action','--title','Action required','--reason','Chat action','--repo','alpha',
            '--call-kind','action','--instruction','Act in chat.','--where','chat',raw=True)
        action_created=task_created('action'); instant(action_created)
        # Internal residual/follow-up creation uses the same timestamp writer.
        script='. "$1/fm-tasks-axi-lib.sh"\n. "$1/fm-backlog-transition-lib.sh"\nfm_backlog_mutate "$2/data" add internal "Internal card" --repo alpha\n'
        run(['bash','-c',script,'fm-created',str(root/'bin'),str(home)],raw=True)
        final=snap()
        assert task(final,'call')['created']==call_created
        assert task(final,'action')['created']==action_created
        instant(task(final,'internal')['created'])
        print('ok - question/action/rehold/conversion and internal creation share immutable task receipts',flush=True)
    if case == 'groups':
        cli('add','new-','Group scope','--repo','alpha',raw=True)
        value=task_created('new-')
        # A real new logical project/subproject commit timestamps only the actual
        # write; preview and an old null/date group stay unchanged.
        structure=dict(schema='fm-work-structure.v1',groups={
            'subproject:alpha/legacy':dict(kind='subproject',repo='alpha',label='Legacy',priority=None,pause=None,blocked_by=[],created_at=None),
            'subproject:alpha/dated':dict(kind='subproject',repo='alpha',label='Dated',priority=None,pause=None,blocked_by=[],created_at='2020-01-02')},
            membership={},order=[],edge_meta={})
        (home/'data/work-structure.json').write_text(json.dumps(structure))
        source=dict(schema='fm-work-normalization.v1',captured_at='2000-01-01T00:00:00Z',groups=[
            dict(key='project:alpha',kind='project',repo='alpha',label='Alpha'),
            dict(key='subproject:alpha/new',kind='subproject',repo='alpha',label='New')],tasks=[])
        additions=dict(active=['new-'],groups=[],membership={})
        mapping=home/'map.json'; mapping.write_text(json.dumps(source))
        extra=home/'additions.json'; extra.write_text(json.dumps(additions))
        plan=cli('work','normalize-plan','--map',str(mapping),'--additions',str(extra))
        assert not plan['conflicts'] and plan['structure']['groups']['subproject:alpha/new']['created_at'] is None
        assert json.loads((home/'data/work-structure.json').read_text())==structure, 'preview wrote creation data'
        created=cli('work','normalize-apply','--request-id','creation-normalize-0001',payload=plan)
        assert created['state']=='applied', created
        assert cli('work','normalize-apply','--request-id','creation-normalize-0001',payload=plan)==created
        current=snap()
        groups={g['key']:g for field in ('projects','subprojects') for g in current[field]}
        for key in ('project:alpha','subproject:alpha/new'): instant(groups[key]['created'])
        assert groups['subproject:alpha/legacy']['created']['precision']=='unknown'
        assert groups['subproject:alpha/dated']['created']['precision']=='date'
        original_group=copy.deepcopy(created['after']['structure']['groups']['subproject:alpha/new'])
        operation=dict(op='set_priority',target='subproject:alpha/new',value=2,actor='captain',expected_rev=current['rev'],request_id='creation-priority-0001')
        assert cli('work','apply',payload=operation)['state']=='applied'
        group=json.loads((home/'data/work-structure.json').read_text())['groups']['subproject:alpha/new']
        assert group['created_at']==original_group['created_at']
        topology=dict(schema='fm-work-hierarchy.v1',groups=[dict(key='subproject:alpha/new',
            before=dict(kind='subproject',parent='project:alpha',label='New'),
            after=dict(kind='project',parent=None,label='New'))])
        mapping.write_text(json.dumps(topology))
        promotion=cli('work','normalize-plan','--hierarchy-only','--map',str(mapping))
        promoted=cli('work','normalize-apply','--request-id','creation-promotion-0001',payload=promotion)
        assert promoted['state']=='applied', promoted
        final=snap()
        groups={g['key']:g for g in final['projects']}
        assert groups['subproject:alpha/new']['created']['value']==original_group['created_at'], 'promotion replaced creation time'
        assert task(final,'new-')['created']==value, 'group operations changed task creation'
        native='2001-02-03T04:05:06+02:00'
        assert task_creation(home/'data',dict(id='new-',created=native))['value']==native, 'receipt hid an original backend instant'
        print('ok - logical creation occurs at commit and survives edits and promotion',flush=True)
    if case == 'recovery':
        public_case()
        # An unsafe receipt destination cannot degrade to successful timestamp-free
        # creation; the durable original journal remains for explicit recovery.
        (home/'data/unsafe').symlink_to(home/'state',target_is_directory=True)
        failure=cli('add','unsafe','Unsafe receipt target','--repo','alpha',raw=True,success=False)
        assert failure.returncode!=0 and list((home/'data').glob('.task-creation-*.json')), failure
        assert not (home/'state/creation.json').exists(), 'creation traversed a symlink'
        pending=json.loads((home/'data/.task-creation-unsafe.json').read_text())
        (home/'data/unsafe').unlink()
        (home/'data/unsafe').mkdir()
        repaired=cli('add','unsafe','Unsafe receipt target','--repo','alpha','--json')
        assert repaired['already'] is True and json.loads(receipt('unsafe').read_text())==pending, 'retry replaced or lost the original creation instant'
        if os.geteuid() != 0:
            before=(home/'data/backlog.md').read_bytes()
            (home/'data').chmod(0o500)
            try:
                failure=cli('add','no-space','No journal can be reserved','--repo','alpha',raw=True,success=False)
                assert failure.returncode!=0 and (home/'data/backlog.md').read_bytes()==before, 'failed preflight mutated the backlog'
            finally:
                (home/'data').chmod(0o700)
        print('ok - public follow-ups retain their first instant; failed publication and preflight retain durable evidence',flush=True)
PY
}
