#!/usr/bin/env bash
# Exercises the home-owned work controls through the public wrapper with real
# tasks-axi, including hierarchy pause, graph expansion, retries, progress,
# manual order/Undo, normalization/rollback and lossless source preservation.
# FM_WORK_TEST_SNAPSHOT=1 selects snapshot contention and its setup checks.
# FM_WORK_TEST_SUPERVISION=1 selects bounded supervision and writer exclusion.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
python3 - "$ROOT" <<'PY'
import copy, json, os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-work-test-') as tmp:
    home = pathlib.Path(tmp)
    for name in ('data','state','config'):
        (home / name).mkdir()
    (home / 'data/projects.md').write_text('- alpha [local-only +yolo] - Private project\n- alpha-public [local-only +yolo install=alpha] - Public project\n- empty [local-only] - Empty project\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_')}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    wrapper = ['bash',str(root / 'bin/fm-tasks-axi.sh')]
    checks = 0
    def cli(*args, payload=None, raw=False):
        p = subprocess.run(wrapper+list(args), input=json.dumps(payload) if payload is not None else None, env=env, text=True, capture_output=True)
        assert p.returncode == 0, (args,p.stdout,p.stderr)
        return p.stdout if raw else json.loads(p.stdout)
    def check(value, message):
        global checks
        assert value, message
        checks += 1
    if os.environ.get('FM_WORK_TEST_SUPERVISION') == '1':
        import fcntl, shutil
        (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        cli('add','a','Task','--repo','alpha',raw=True)
        base = dict(schema='fm-work-structure.v1',groups={},membership={},order=[],edge_meta={})
        structure = home/'data/work-structure.json'
        def compare(expected):
            full = cli('work','snapshot')['tasks'][0]
            needed = not (full['state'] != 'stopping' and full['pause']['safe_point'] != 'pending'
                          and (full['pause']['own'] or full['pause']['inherited']))
            bounded = cli('work','supervision','--tasks','a','missing')['tasks']
            if (home/'state/a.meta').exists():
                count = subprocess.check_output(['bash','-uc','. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$FM_HOME/state"; printf "%s" "$FM_SUP_IN_FLIGHT"','test',str(root)], env=dict(env,LAVISH_AXI_STATE_DIR=str(home/'lavish')), text=True)
                check(count == str(int(expected)), 'shared shell predicate uses the bounded owner')
            check(bounded == [dict(id='a',needed=expected),dict(id='missing',needed=True)]
                  and needed == expected, 'bounded predicate agrees with full snapshot')
        compare(True)
        cli('hold','a','--kind','parked','--reason','Own pause',raw=True); compare(False)
        cli('unhold','a',raw=True)
        for patch in [dict(task_pauses={'a':dict(kind='parked',reason='Own')}),
                      dict(groups={'project:alpha':dict(kind='project',repo='alpha',label='Alpha',pause={'reason':'Parent'})}),
                      dict(groups={'req:a':dict(kind='request',label='Request',pause={'reason':'Request pause'})}),
                      dict(groups={'subproject:alpha/ui':dict(kind='subproject',repo='alpha',label='UI',pause={'reason':'Subproject'})},membership={'a':'subproject:alpha/ui'}),
                      dict(freeze=dict(reason='Freeze',except_=[],tasks=['a']))]:
            if 'freeze' in patch: patch['freeze']['except'] = patch['freeze'].pop('except_')
            structure.write_text(json.dumps(base|patch)); compare(False)
        fakebin=home/'fakebin'; fakebin.mkdir()
        tmux=fakebin/'tmux'
        tmux.write_text('#!/usr/bin/env bash\ncase "$1" in list-windows) echo fm-a ;; display-message) echo codex ;; *) exit 1 ;; esac\n')
        tmux.chmod(0o755); env['PATH']=str(fakebin)+os.pathsep+env['PATH']
        cli('start','a',raw=True)
        (home/'state/a.meta').write_text(f'window=example:fm-a\nworktree={home}\nproject={home}\nkind=ship\nbackend=tmux\nmode=local-only\n')
        structure.write_text(json.dumps(base|dict(task_pauses={'a':dict(kind='parked',reason='Own')})))
        compare(True)  # stopping, even without a request marker
        records=home/'data/work-requests'; records.mkdir()
        request=dict(at='2020-01-01T00:00:00Z',safe_tasks=['a'],phase='verified',result=dict(state='applied'),scope='task:a',
                     operation=dict(op='set_pause',target='task:a',request_id='safe-test-0000001'))
        (records/'safe-test.json').write_text(json.dumps(request)); compare(True)
        check(cli('work','snapshot')['tasks'][0]['pause']['safe_point']=='pending','live worker awaits safe point')
        (home/'state/a.status').write_text('paused [key=safe-point-safe-test-0000001] [at=1893456000]: saved\n')
        compare(False)
        (records/'safe-test.json').write_text(json.dumps(request|dict(signal='pause.request'))); compare(True)
        (records/'safe-test.json').write_text(json.dumps(request)); compare(False)
        structure.write_text('{invalid')
        invalid=subprocess.run(wrapper+['work','supervision','--tasks','a'],env=env,text=True,capture_output=True)
        check(invalid.returncode != 0 and json.loads(invalid.stdout)['state']=='failed','invalid structure refuses')
        structure.write_text(json.dumps(base))
        result_file=home/'result.json'
        result_file.write_text(json.dumps(dict(summary='Result',outcome=dict(role='final',review='needed'))))
        published=cli('presentation','a','--presentation-file',str(result_file))
        review=dict(target='task:a',occurrence=published['outcome_occurrence'],expected_review='needed',review='done')
        processes=[]
        with (home/'data/.work.lock').open('w') as held:
            fcntl.flock(held,fcntl.LOCK_EX)
            for args, body in [(['presentation','a','--card-status','Serialized'],None),(['work','outcome.review'],json.dumps(review)),(['presentation','a','--card-title','Concurrent title'],None)]:
                proc=subprocess.Popen(wrapper+args,env=env,text=True,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                if body: proc.stdin.write(body)
                proc.stdin.close(); proc.stdin=None; processes.append(proc)
            time.sleep(.2)
            check(all(p.poll() is None for p in processes),'publication and review wait for the global lock')
        for proc in processes:
            out,err=proc.communicate(timeout=20); check(proc.returncode==0 and json.loads(out)['state'] in ('published','applied'),err)
        saved=cli('presentation','a')['presentation']
        check(saved['card_status']=='Serialized' and saved['card_title']=='Concurrent title' and saved['outcome']['review']=='done','serialized writers preserve both changes')
        node=fakebin/'node'; real_node=shutil.which('node')
        node.write_text('#!/usr/bin/env bash\nbody=$(cat)\nif [ ! -e "$FM_HOME/node-entered" ]; then touch "$FM_HOME/node-entered"; while [ ! -e "$FM_HOME/release-node" ]; do sleep .01; done; fi\nexec '+real_node+' "$@" <<< "$body"\n')
        node.chmod(0o755)
        reading=subprocess.Popen(wrapper+['work','supervision','--tasks','a'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+10
            while not (home/'node-entered').exists() and time.monotonic()<deadline: time.sleep(.01)
            check((home/'node-entered').exists(),'canonical parser reached after source capture')
            check(cli('presentation','a','--card-status','During parsing')['state']=='published','writer proceeds while query parses')
        finally:
            (home/'release-node').touch(); out,err=reading.communicate(timeout=20)
        check(reading.returncode==0 and json.loads(out)['tasks'][0]['needed'],err)
        structure.write_text(json.dumps(base|dict(task_pauses={'a':dict(kind='parked',reason='Own')})))
        (home/'data/a/presentation.json').write_text('{invalid')
        check(cli('work','supervision','--tasks','a')['tasks'][0]['needed'],'invalid declaration needs supervision')
        print('PASS: %d bounded supervision and writer exclusion checks' % checks)
        sys.exit(0)
    # Historical graphs remain readable, including duplicates and invalid edges.
    # Usage readers run outside snapshots, which read only the saved caches.
    with tempfile.TemporaryDirectory(prefix='fm-usage-test-') as usage_tmp:
        uh = pathlib.Path(usage_tmp)
        ue = dict(env, FM_HOME=str(uh))
        for name in ('data','state','config'):
            (uh/name).mkdir()
        (uh/'data/projects.md').write_text('- alpha [local-only] - Fixture\n')
        (uh/'data/backlog.md').write_text('## Queued\n\n## In flight\n\n## Done\n')
        def ucli(*args):
            p = subprocess.run(wrapper+list(args), env=ue, text=True, capture_output=True)
            check(p.returncode == 0, p.stderr+p.stdout)
            return json.loads(p.stdout) if args[:2] == ('work','snapshot') else p.stdout
        for key in ('used','queued','decision','missing'):
            ucli('add',key,key,'--repo','alpha','--kind','captain' if key=='decision' else 'ship',*(['--request-from','used'] if key!='used' else []))
        ucli('hold','decision','--kind','external','--reason','Fixture')
        folder = uh/'data/used'
        claude_path, codex_path = uh/'claude.jsonl', uh/'sessions/day/rollout-main.jsonl'
        codex_path.parent.mkdir(parents=True)
        def write_lines(path, rows):
            path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        assistant = dict(type='assistant',message=dict(id='one',model='claude-haiku-5-5',usage=dict(input_tokens=100001,output_tokens=2)))
        write_lines(claude_path,[assistant,assistant])
        codex_rows = [dict(type='session_meta',payload=dict(session_id='shared')),
            dict(type='turn_context',payload=dict(model='gpt-6.1-sol',effort='high')),
            dict(type='token_usage_record',payload=dict(usage=dict(input_tokens=100,cached_input_tokens=80,output_tokens=10)))]
        write_lines(codex_path,codex_rows)
        write_lines(folder/'sessions.jsonl',[dict(harness=h,model=None,effort='low',session=str(p)) for h,p in [('claude',claude_path),('codex',codex_path)]])
        refresh = ['python3','-B',str(root/'bin/fm_task_usage.py'),'refresh',str(folder)]
        (folder/'usage.json').write_text('[{"legacy": true}]')
        subprocess.run(refresh,check=True)
        cache = folder/'usage.json'
        measured = json.loads(cache.read_text())
        haiku = next(r for r in measured['by'] if r['harness']=='claude')
        check(haiku['tokens']==100003 and abs(haiku['usd']-.0500055)<1e-9 and measured['estimated'], 'deduplication and Haiku long-prompt estimate')
        stamp = cache.stat().st_mtime_ns
        subprocess.run(refresh,check=True)
        check(cache.stat().st_mtime_ns==stamp, 'unchanged sizes preserve cache')
        write_lines(codex_path.parent/'rollout-child.jsonl',codex_rows)
        subprocess.run(refresh,check=True)
        check(next(r for r in json.loads(cache.read_text())['by'] if r['harness']=='codex')['tokens']==220, 'new sibling thread invalidates cache and is counted')
        with claude_path.open('a') as stream:
            stream.write(json.dumps(dict(type='cost-state',modelUsage={'claude-haiku-5-5':dict(costUSD=.77,inputTokens=100001,outputTokens=2)}))+'\n')
        subprocess.run(refresh,check=True)
        check(next(r for r in json.loads(cache.read_text())['by'] if r['harness']=='claude')['usd']==.77 and not json.loads(cache.read_text())['estimated'], 'closing cost-state supersedes estimate')
        with (folder/'sessions.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(harness='codex',model=None,effort='high',session=str(codex_path.parent/'rollout-child.jsonl')))+'\n')
        subprocess.run(refresh,check=True)
        check(next(r for r in json.loads(cache.read_text())['by'] if r['harness']=='codex')['tokens']==220, 'separately bound child thread is not counted twice')
        unknown_rows = copy.deepcopy(codex_rows); unknown_rows[1]['payload']['model'] = 'unpriced-model'
        write_lines(codex_path.parent/'rollout-child.jsonl',unknown_rows)
        subprocess.run(refresh,check=True)
        check(any(not r['usd_known'] for r in json.loads(cache.read_text())['by']), 'unpriced models preserve tokens with unknown USD')
        write_lines(codex_path.parent/'rollout-child.jsonl',codex_rows)
        subprocess.run(refresh,check=True)
        closed = claude_path.read_text(); resumed = copy.deepcopy(assistant); resumed['message']['id'] = 'resumed'
        claude_path.write_text(closed+json.dumps(resumed)+'\n')
        subprocess.run(refresh,check=True)
        check(json.loads(cache.read_text())['estimated'], 'resumed Claude session outgrows its previous closing cost-state')
        claude_path.write_text(closed)
        subprocess.run(refresh,check=True)
        claude_path.unlink(); codex_path.unlink()
        projected = ucli('work','snapshot')['requests'][0]['usage']
        check(projected['tokens']==100223 and projected['usd_complete'] and projected['tasks']['not_started']==2 and projected['tasks']['no_agent']==1, 'snapshot sums caches without readable transcripts')
        subprocess.run(refresh,check=True)
        check(not ucli('work','snapshot')['requests'][0]['usage']['usd_complete'], 'a missing source cannot make a partial task cache look complete')
        ucli('start','missing')
        saved = cache.read_bytes()
        cache.write_text(json.dumps(measured))
        bad_cache = uh/'data/missing/usage.json'
        valid_row = measured['by'][0]
        malformed = [[{'old': 'investigation'}], 'legacy', 7, True, None,
            {'by': {}}, {'by': [None]}, {'unknown': 'legacy'},
            {'unknown': [{}]}, {'by': [{}]}]
        for field, bad in [('harness', []), ('model', {}), ('effort', []),
                           ('usd', '1'), ('tokens', None), ('sessions', True),
                           ('output_tokens', -1), ('usd_known', 'yes'), ('usd', float('inf'))]:
            malformed.append({'by': [dict(valid_row, **{field: bad})]})
        for invalid in malformed:
            bad_cache.write_text(json.dumps(invalid))
            projected = ucli('work','snapshot')['requests'][0]['usage']
            check(projected['tokens']==sum(r['tokens'] for r in measured['by'])
                  and not projected['usd_complete']
                  and any(r['task']=='missing' for r in projected['unknown']),
                  'malformed cache stays unknown and preserves valid peer usage: '+repr(invalid))
        bad_cache.unlink()
        cache.write_bytes(saved)
        held = subprocess.run(['bash',str(root/'bin/fm-captain-hold.sh'),'hold','decision','--reason','Fixture','--question','Choose?', '--option','a=Yes','--option','b=No'], env=ue, text=True, capture_output=True)
        check(held.returncode==0, held.stderr+held.stdout)
        projected = ucli('work','snapshot')['requests'][0]['usage']
        check(not projected['usd_complete'] and projected['tasks']['no_agent']==1 and projected['tasks']['unknown']==1 and any(r['task']=='missing' for r in projected['unknown']), 'agent-free decisions and missing launched sessions are distinct')
        cache.unlink()
        check(ucli('work','snapshot')['requests'][0]['usage']['tasks']['not_started']==2, 'unstarted tasks are explicit when no cache exists')
        ucli('add','answered','Answered decision','--repo','alpha','--kind','captain','--request-from','used')
        ucli('done','answered')
        check(ucli('work','snapshot')['requests'][0]['usage']['tasks']['no_agent']==2, 'completed captain decisions retain their explicit agent-free kind')
    if os.environ.get('FM_WORK_TEST_USAGE') == '1':
        print('PASS: %d usage checks' % checks); raise SystemExit(0)
    with tempfile.TemporaryDirectory(prefix='fm-work-graph-') as graph_tmp:
        graph_home = pathlib.Path(graph_tmp)
        for name in ('data','state','config','data/work-requests'):
            (graph_home/name).mkdir(parents=True, exist_ok=True)
        (graph_home/'data/projects.md').write_text('- alpha [local-only] - Graph fixture\n')
        for n, (target, phase, operation) in enumerate([
                ('task:a','verified','set_priority'), ('project:alpha','verified','set_priority'),
                ('task:a','pending','set_priority'), ('task:a','verified','request_removal'),
                ('task:absent','verified','set_priority')]):
            record = dict(at='%d-01-01T00:00:00Z'%(2020+n), phase=phase,
                          operation=dict(target=target, op=operation))
            (graph_home/'data/work-requests'/('%d.json'%n)).write_text(json.dumps(record))
        for label, edges, expected in [
                ('chain', {'b':['a'], 'c':['b'], 'd':['a','c']}, {'a':(['b','d'],3), 'b':(['c'],2), 'c':(['d'],1)}),
                ('diamond', {'b':['a'], 'c':['a'], 'd':['b','c']}, {'a':(['b','c'],3), 'b':(['d'],1), 'c':(['d'],1)}),
                ('duplicates', {'b':['a','a'], 'c':['a','b','a']}, {'a':(['b','c'],2), 'b':(['c'],1)}),
                ('cycle', {'a':['b'], 'b':['a'], 'c':['b']}, {'a':(['b'],3), 'b':(['a','c'],3)}),
                ('unknown', {'a':['absent'], 'b':['a'], 'd':['absent']}, {'a':(['b'],1)}),
                ('closed', {'b':['a'], 'c':['b'], 'd':['a','c']}, {'a':(['b','d'],3), 'b':(['c'],2), 'c':(['d'],1)})]:
            (graph_home/'data/backlog.md').write_text('## Queued\n'+''.join(
                '- [ ] %s - Task %s (repo: alpha)\n'%(i,i) for i in 'abcd' if label!='closed' or i!='a')+
                '\n## Done\n'+('- [x] a - Task a (repo: alpha)\n' if label=='closed' else ''))
            structure = dict(schema='fm-work-structure.v1', groups={}, membership={}, order=[], edge_meta={},
                mixed_edges=[dict(target='task:'+i, ref='task:'+dep, by='firstmate') for i, deps in edges.items() for dep in deps])
            (graph_home/'data/work-structure.json').write_text(json.dumps(structure))
            result = subprocess.run(wrapper+['work','snapshot'], env=dict(env, FM_HOME=str(graph_home)), text=True, capture_output=True)
            check(result.returncode==0, label+': public snapshot succeeds: '+result.stderr)
            projected = {t['key'][5:]:t for t in json.loads(result.stdout)['tasks']}
            for i in 'abcd':
                direct, count = expected.get(i, ([],0))
                check(projected[i]['frees']==dict(direct=['task:'+d for d in direct],chain_count=count), label+': frees '+i)
                check(projected[i]['updated']['value']=='2021-01-01T00:00:00Z', label+': verified ancestor control timestamp '+i)
            if label=='closed':
                check(not projected['b']['blocked_by'][0]['open'] and projected['b']['root_blocker'] is None,
                      'closed dependencies still contribute to frees without blocking readiness')
            if label=='unknown':
                check(projected['b']['root_blocker']=='task:absent', 'missing blocker remains visible through chain')
    # Projects view: requests sit under their tasks' project, and open task
    # dependencies across projects become header relations no task inherits.
    with tempfile.TemporaryDirectory(prefix='fm-work-projects-') as projects_tmp:
        pe = dict(env, FM_HOME=projects_tmp)
        for name in ('data','state','config'):
            (pathlib.Path(projects_tmp)/name).mkdir()
        (pathlib.Path(projects_tmp)/'data/projects.md').write_text('- alpha [local-only] - A\n- beta [local-only] - B\n')
        (pathlib.Path(projects_tmp)/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        def pcli(*args):
            p = subprocess.run(wrapper+list(args), env=pe, text=True, capture_output=True)
            assert p.returncode == 0, (args, p.stdout, p.stderr)
            return p.stdout
        for key, repo in (('x','alpha'), ('y','beta'), ('z','beta')):
            pcli('add', key, key+' task', '--repo', repo)
        pcli('add', 'w', 'w task', '--repo', 'beta', '--request-from', 'x')
        pcli('block', 'y', '--by', 'x'); pcli('block', 'z', '--by', 'x'); pcli('block', 'z', '--by', 'y')
        s = json.loads(pcli('work', 'snapshot'))
        groups = {g['key']: g for g in s['projects']}
        check(sorted(groups['project:alpha']['requests']) == ['request:x'] and sorted(groups['project:beta']['requests']) == ['request:y', 'request:z']
              and {r['id']: (r['project'], r['project_key']) for r in s['requests']}['x'] == ('alpha', 'project:alpha'),
              'each project lists its requests; a tie keeps the declared repository')
        check(groups['project:beta']['derived_blocked_by'] == [dict(ref='project:alpha', open=True, via=[dict(task='task:y', blocker='task:x'), dict(task='task:z', blocker='task:x')])]
              and groups['project:alpha']['derived_blocked_by'] == [], 'open cross-project task dependencies aggregate per project pair')
        check(groups['project:beta']['blocked_by'] == [] and [b['ref'] for b in next(t for t in s['tasks'] if t['key'] == 'task:w')['blocked_by']] == [],
              'derived relations are not inherited dependencies')
        pcli('done', 'x')
        check(all(g['derived_blocked_by'] == [] for g in json.loads(pcli('work', 'snapshot'))['projects']), 'completed blockers leave no project relation')
    missing = subprocess.run(wrapper+['work','snapshot'], env=env, text=True, capture_output=True)
    check(json.loads(missing.stdout)['state'] == 'rejected' and 'backlog' in missing.stdout and 'create it' in missing.stdout, 'missing backlog gives actionable guidance')
    (home / 'data/backlog.md').symlink_to(home / 'missing')
    unsafe = subprocess.run(wrapper+['work','snapshot'], env=env, text=True, capture_output=True)
    check(json.loads(unsafe.stdout)['state'] in ('failed', 'rejected') and 'create it' not in unsafe.stdout, 'unsafe backlog is rejected')
    (home / 'data/backlog.md').unlink()
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    def snapshot(): return cli('work','snapshot')
    def task(s, key): return next(t for t in s['tasks'] if t['key']=='task:'+key)
    def op(name,target,**kw):
        return dict(op=name,target=target,expected_rev=snapshot()['rev'],actor='captain',**kw)
    counter = 0
    def apply(o):
        global counter
        counter += 1
        return cli('work','apply',payload=dict(o,request_id='test-request-%08d'%counter))
    for flag in ('--help', '-h'):
        help_result = subprocess.run(wrapper+['add','help-fixture',flag], env=env, text=True, capture_output=True)
        check(help_result.returncode == 0 and 'usage:' in help_result.stdout.lower(), 'add help succeeds')
        check(not list((home/'data').glob('.task-creation-*')), 'help creates no journal')
        check(not (home/'data/help-fixture').exists(), 'help creates no receipt')
    for key in ('a','b','c','unset'):
        cli('add',key,key+' task','--repo','alpha',raw=True)
    cli('update','a','--priority','1',raw=True)
    cli('update','b','--priority','2',raw=True)
    cli('hold','b','--kind','parked','--reason','Individual',raw=True)
    baseline=(home/'data/backlog.md').read_bytes()
    check(len(snapshot()['projects'])==3,'all registered including empty/public')
    (home/'config/lane-capacity').write_text('3\n')
    initial=snapshot()
    check(initial['pause_controls']==[] and initial['crew']['agents_running']==0 and initial['crew']['agents_cap']==3,
          'crew capacity is published before any signal record exists')
    (home/'config/lane-capacity').unlink()
    check(task(snapshot(),'unset')['priority']['own'] is None,'unset preserved')
    check(task(snapshot(),'a')['progress'] is None,'unknown progress')
    check(task(snapshot(),'a')['updated']['source']=='presentation','new request declaration supplies activity independently of creation time')
    check(not (home/'data/work-structure.json').exists(),'reads never create structure')
    # Review is a shared presentation mark, independent of task/decision closure.
    capabilities=cli('work','capabilities')
    check('outcome.review' in capabilities['outcome_controls'] and 'outcome_review' in capabilities['features'],
          'shared review is advertised')
    result_file=home/'result-input.json'
    result_file.write_text(json.dumps(dict(summary='Resultado listo',card_status='Para revisar',
        request=dict(id='review-request',label='Entregar resultado',project='alpha'),
        outcome=dict(role='partial',review='needed'),
        progress=dict(steps=[dict(label='Resultado',state='done')]),phase='implementation')))
    published=cli('presentation','a','--presentation-file',str(result_file))
    result_task=task(snapshot(),'a')
    occurrence=result_task['outcome_occurrence']
    check(occurrence==published['outcome_occurrence'],'publication and snapshot share occurrence')
    review=dict(target=result_task['alias'] or 'task:a',occurrence=occurrence,review='done',expected_review='needed')
    before=json.loads((home/'data/a/presentation.json').read_text())
    reviewed=cli('work','outcome.review',payload=review)
    check(reviewed['ok'] and reviewed['state']=='applied','review applies through public verb')
    after=json.loads((home/'data/a/presentation.json').read_text())
    expected=copy.deepcopy(before)
    expected['presentation']['outcome']['review']='done'
    expected['observed_at']=after['observed_at']
    check(after==expected,'only review and presentation timestamp change; checkpoint stays exact')
    check(task(snapshot(),'a')['outcome']['review']=='done','another client reads shared review')
    check((home/'data/backlog.md').read_bytes()==baseline,'review never changes task or hold')
    check(cli('work','outcome.review',payload=review)['code']=='review_conflict','stale review expectation refuses')
    check(cli('work','outcome.review',payload=reviewed['undo'])['state']=='applied','Undo restores needed')
    check(task(snapshot(),'a')['outcome']['review']=='needed','Undo is shared')
    cli('presentation','a','--card-status','Otra tarjeta')
    check(task(snapshot(),'a')['outcome_occurrence']==occurrence,'card patch preserves result identity')
    check(cli('presentation','a','--presentation-file',str(result_file))['outcome_occurrence']==occurrence,
          'identical result publication preserves occurrence')
    result_file.write_text(json.dumps(dict(progress=dict(steps=[dict(label='Resultado',state='done')]))))
    check(cli('presentation','a','--presentation-file',str(result_file))['outcome_occurrence']==occurrence,
          'progress checkpoint preserves result identity')
    result_file.write_text(json.dumps(dict(summary='Otro resultado')))
    next_result=cli('presentation','a','--presentation-file',str(result_file))
    check(next_result['outcome_occurrence']!=occurrence,'new result gets a new occurrence')
    check(cli('work','outcome.review',payload=review)['code']=='stale_occurrence','stale tab cannot mark another result')
    check(cli('work','outcome.review',payload=reviewed['undo'])['code']=='stale_occurrence','stale Undo cannot affect another result')
    review['occurrence']=next_result['outcome_occurrence']
    for bad in [review|dict(review='closed'), review|dict(expected_review=None),review|dict(target={}),
                review|dict(extra=True),{k:v for k,v in review.items() if k!='occurrence'}]:
        check(cli('work','outcome.review',payload=bad)['code']=='invalid_value','invalid review payload refuses')
    check(cli('work','outcome.review',payload=review|dict(target='task:missing'))['code']=='unknown_target','missing result task refuses')
    check(cli('work','outcome.review',payload=review|dict(target='project:alpha'))['code']=='unknown_target','review requires a task')
    # Existing declarations remain reviewable without a migration write.
    legacy=json.loads((home/'data/a/presentation.json').read_text())
    legacy.pop('outcome_occurrence')
    (home/'data/a/presentation.json').write_text(json.dumps(legacy))
    legacy_task=task(snapshot(),'a')
    legacy_review=review|dict(occurrence=legacy_task['outcome_occurrence'])
    check(cli('work','outcome.review',payload=legacy_review)['state']=='applied','legacy outcome can be reviewed')
    check(task(snapshot(),'a')['outcome_occurrence']==legacy_task['outcome_occurrence'],'review persists legacy identity')
    cli('presentation','a','--clear','--replan','Reset the review fixture')
    check(task(snapshot(),'a')['outcome_occurrence'] is None,'clear removes occurrence')
    check(cli('work','outcome.review',payload=review)['code']=='no_outcome','unclassified task cannot be reviewed')
    import fcntl
    import threading
    for args, body in [(['update','a','--priority','1'], None),
                       (['presentation','a','--card-status','Contention recovered'], None),
                       (['work','apply'], dict(op('set_priority','task:a',value=1),request_id='contention-retry-0001'))]:
        if body:
            body['expected_rev']=snapshot()['rev']
        with (home/'data/.work.lock').open('w') as held:
            fcntl.flock(held,fcntl.LOCK_EX)
            release=threading.Thread(target=lambda: (time.sleep(.3), fcntl.flock(held,fcntl.LOCK_UN)))
            release.start()
            result=cli(*args,payload=body,raw=body is None)
            release.join()
            check(body is None or result['state']=='applied','ordinary writers recover from short contention')
    baseline=(home/'data/backlog.md').read_bytes()
    busyop=op('set_priority','task:a',value=4)|{'request_id':'busy-test-00000001'}
    with (home/'data/.work.lock').open('w') as held:
        fcntl.flock(held,fcntl.LOCK_EX)
        blocked=subprocess.run(wrapper+['update','a','--priority','4'],env=env,text=True,capture_output=True)
        check(blocked.returncode!=0 and (home/'data/backlog.md').read_bytes()==baseline,'ordinary writer cannot race work transaction')
        blocked=cli('work','apply',payload=busyop)
        check(blocked['code']=='busy','work writer reports busy without mutation')
        check(cli('work','outcome.review',payload=review)['code']=='busy','review shares the owner mutation lock')
        check(cli('work','snapshot')['code']=='busy','snapshot cannot expose partial owner transaction')
    fakebin=home/'snapshot-bin'
    fakebin.mkdir()
    shim=fakebin/'bash'
    shim.write_text('''#!/bin/bash
if [ "$1" = -c ] && [ "${3:-}" = fm-work ]; then
  touch "$FM_HOME/rendering"
  while [ ! -e "$FM_HOME/release" ]; do sleep .1; done
fi
exec /bin/bash "$@"
''')
    shim.chmod(0o755)
    previous_path=env['PATH']
    env['PATH']=str(fakebin)+':'+previous_path
    reading=subprocess.Popen(wrapper+['work','snapshot'],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    try:
        for _ in range(600):
            if (home/'rendering').exists(): break
            check(reading.poll() is None,'snapshot reached rendering without failing')
            time.sleep(.1)
        check((home/'rendering').exists(),'snapshot rendering started')
        published=cli('presentation','a','--card-status','Escritura durante lectura')
        check(published['ok'] and published['state']=='published','presentation writer proceeds during snapshot rendering')
        cli('update','a','--priority','3',raw=True)
    finally:
        (home/'release').touch()
        output,error=reading.communicate(timeout=30)
        env['PATH']=previous_path
    check(reading.returncode==0,'concurrent snapshot succeeds: '+error)
    captured=json.loads(output)
    check(task(captured,'a')['priority']['own']==1,'snapshot retains canonical rows captured before concurrent mutation')
    check(task(snapshot(),'a')['priority']['own']==3,'next snapshot sees the completed mutation')
    cli('update','a','--priority','1',raw=True)
    if os.environ.get('FM_WORK_TEST_SNAPSHOT')=='1':
        print('PASS: snapshot setup, transaction exclusion and concurrent presentation/backlog writers')
        sys.exit(0)
    p=op('set_priority','task:a',value=0)
    preview=cli('work','preview',payload=p)
    check((home/'data/backlog.md').read_bytes()==baseline,'preview read only')
    r=apply(p)
    check(r['state']=='applied' and task(snapshot(),'a')['priority']['own']==0,'real priority owner')
    same=dict(p,request_id='test-request-00000001')
    check(cli('work','apply',payload=same)==r,'retry receipt stable')
    same['value']=3
    check(cli('work','apply',payload=same)['code']=='request_mismatch','mismatched retry refused')
    check(apply(p)['code']=='stale_revision','stale expected revision refused')
    null_before=(home/'data/backlog.md').read_bytes()
    null_change=apply(op('set_priority','task:unset',value=3))
    check(null_change['undo']['value'] is None,'undo retains missing priority distinction')
    apply(null_change['undo'])
    check(task(snapshot(),'unset')['priority']['own'] is None and (home/'data/backlog.md').read_bytes()==null_before,'lossless unset priority undo through shared canonical lock')
    s=dict(schema='fm-work-structure.v1',groups={'subproject:alpha/ui':dict(kind='subproject',repo='alpha',label='UI',priority=None,pause=None,blocked_by=[],aliases=[])},membership={'a':'subproject:alpha/ui','b':'subproject:alpha/ui'},order=[],edge_meta={})
    # Seed a disposable fixture only; production normalizes through owner.
    (home/'data/work-structure.json').write_text(json.dumps(s))
    r=apply(op('set_pause','subproject:alpha/ui',reason='Focus'))
    check(r['state']=='applied','idle group pause applied')
    ss=snapshot()
    check(task(ss,'a')['state']=='paused_inherited','inherited pause')
    gate=subprocess.run(wrapper+['work','dispatch-check','--task','a'],env=env,capture_output=True,text=True)
    check(gate.returncode!=0 and json.loads(gate.stdout)['state']=='rejected','dispatch refuses inherited pause')
    check(task(ss,'b')['state']=='paused_own' and task(ss,'b')['pause']['inherited'],'both pauses preserved')
    apply(op('clear_pause','subproject:alpha/ui'))
    check(task(snapshot(),'b')['state']=='paused_own' and task(snapshot(),'a')['state']=='ready','parent resume never resumes own pause')
    apply(op('set_priority','subproject:alpha/ui',value=1))
    check(task(snapshot(),'a')['priority']['own']==0,'parent priority never cascades')
    apply(op('add_dep','task:c',on='task:a'))
    check(task(snapshot(),'c')['state']=='waiting_dep','task dep gates readiness')
    apply(op('add_dep','task:a',on='task:unset'))
    check(task(snapshot(),'c')['root_blocker']=='task:unset','root blocker follows actual chain')
    apply(op('remove_dep','task:a',on='task:unset'))
    check(apply(op('add_dep','task:a',on='task:c'))['code']=='cycle','task cycle rejected')
    check(apply(op('add_dep','task:a',on='subproject:alpha/ui'))['code']=='cycle','own group cycle rejected')
    check(apply(op('add_dep','project:alpha',on='subproject:alpha/ui'))['code']=='cycle','ancestor cycle rejected')
    check(apply(op('add_dep','task:a',on='task:missing'))['code']=='unknown_target','unknown dependency rejected')
    apply(op('remove_dep','task:c',on='task:a'))
    apply(op('add_dep','subproject:alpha/ui',on='task:c'))
    check(task(snapshot(),'a')['state']=='waiting_dep','group dependency gates children')
    apply(op('remove_dep','subproject:alpha/ui',on='task:c'))
    cli('update','c','--priority','4',raw=True)
    r=apply(op('move','task:c',before='task:a',adopt_priority=0))
    check(r['state']=='applied' and snapshot()['sigue'][0]=='task:c','cross priority manual move')
    undo=r['undo']; r=apply(undo)
    check(r['state']=='applied' and task(snapshot(),'c')['priority']['own']==4,'undo restores task priority')
    # Missing priority cannot be losslessly undone; c defaults to 4 in current tasks-axi.
    pf=home/'progress.json'
    pf.write_text(json.dumps({'progress':{'steps':[{'label':'Data','state':'done'},{'label':'Controls','state':'active'}]}}))
    cli('presentation','a','--presentation-file',str(pf),raw=True)
    check(task(snapshot(),'a')['progress']['done']==1 and task(snapshot(),'a')['progress']['total']==2,'declared progress only')
    pf.write_text(json.dumps({'progress':{'steps':[{'label':'Bad','state':'estimated'}]}}))
    bad=subprocess.run(wrapper+['presentation','a','--presentation-file',str(pf)],env=env,capture_output=True)
    check(bad.returncode!=0,'invalid progress refused')
    # Exercise the executable guard against the actual work owner, not a stub.
    def guard():
        p = subprocess.run(['bash', str(root/'bin/fm-guard.sh')], env=dict(env, FM_ROOT_OVERRIDE=str(home), FM_GUARD_READ_ONLY='1'), text=True, capture_output=True)
        assert p.returncode == 0, (p.stdout, p.stderr)
        return p.stdout + p.stderr
    cli('start','a',raw=True)
    (home/'state/a.meta').write_text('')
    check('1 task(s) in flight' in guard(), 'running metadata requires supervision')
    # Running pause is received until the exact safe-point evidence appears.
    r=apply(op('set_pause','project:alpha',reason='Redirect'))
    check(r['state']=='received' and task(snapshot(),'a')['state']=='stopping','active pause awaits checkpoint')
    check('1 task(s) in flight' in guard(), 'pending safe point still requires supervision')
    req=r['request_id']
    early=cli('work','close','--request-id',req)
    check(early['state']=='received' and early['pending']==['a'] and early['event'] is None,'close waits for the worker safe point')
    (home/'state/a.status').write_text('paused [key=safe-point-'+req+'] [at='+str(int(time.time()))+']: saved\n')
    check(cli('work','request-status','--request-id',req)['state']=='applied','safe point receipt confirmed')
    failed=cli('work','close','--request-id',req)
    check(failed['state']=='received' and failed['failed']==['a'] and not failed['exited'] and failed['event'] is None,'reached worker that cannot be exited is not confirmed')
    check(cli('work','close','--request-id',req)['failed']==['a'],'repeated close retries only the unexited agent')
    check(task(snapshot(),'a')['pause']['safe_point']=='reached','safe evidence exposed')
    check('WATCHER DOWN' not in guard(), 'inherited pause at safe point does not require supervision')
    (home/'state/missing.meta').write_text('')
    check('1 task(s) in flight' in guard(), 'missing backlog row fails closed')
    (home/'state/missing.meta').unlink()
    (home/'state/procevent').mkdir(exist_ok=True)
    (home/'state/procevent/example.source').write_text('')
    check('process-event source(s) registered' in guard(), 'independent source still requires supervision')
    (home/'state/procevent/example.source').unlink()
    apply(op('clear_pause','project:alpha'))
    check('1 task(s) in flight' in guard(), 'resumed task requires supervision')
    cli('hold','a','--kind','parked','--reason','Individual pause',raw=True)
    check('WATCHER DOWN' not in guard(), 'own hold does not require supervision')
    structure_before = (home/'data/work-structure.json').read_bytes()
    (home/'data/work-structure.json').write_text('{invalid')
    check('1 task(s) in flight' in guard(), 'unreadable pause state fails closed')
    (home/'data/work-structure.json').write_bytes(structure_before)
    apply(op('clear_pause','task:a'))
    (home/'state/a.meta').unlink()
    cli('hold','c','--kind','external','--reason','Other owner',raw=True)
    check(apply(op('clear_pause','task:c'))['code']=='invalid_value','protected external hold')
    # Request removal never changes backlog and waits for a real reply.
    before=(home/'data/backlog.md').read_bytes()
    r=apply(op('request_removal','task:b',note='Review'))
    check(r['state']=='received' and (home/'data/backlog.md').read_bytes()==before,'removal is a note only')
    rec=json.loads((home/'data/work-requests'/ (r['request_id']+'.json')).read_text())
    note=rec['note']['id']
    subprocess.run(['bash',str(root/'bin/fm-inbox.sh'),'reply',note,'Reviewed'],env=env,check=True,capture_output=True)
    check(cli('work','request-status','--request-id',r['request_id'])['state']=='applied','removal acknowledged only after reply')
    # Normalize current tasks and preserve holds/body and dates; rollback losslessly.
    source={'schema':'fm-work-normalization.v1','captured_at':'2026-10-31T00:00:00Z','groups':[], 'tasks':[{'id':'b','subproject':'subproject:alpha/ui','captain_note':'Keep note','operations':[]},{'id':'unset','operations':[{'op':'set_priority','value':2,'expected':None}]}]}
    additions={'active':['a'], 'groups':[], 'membership':{'a':'subproject:alpha/ui'}}
    mp=home/'map.json';ap=home/'additions.json'
    mp.write_text(json.dumps(source));ap.write_text(json.dumps(additions))
    plan=cli('work','normalize-plan','--map',str(mp),'--additions',str(ap))
    check(not plan['conflicts'] and 'unset' in plan['unassigned'],'normalizer reports unassigned current tasks')
    before=(home/'data/backlog.md').read_bytes()
    nr=cli('work','normalize-apply','--request-id','normalize-test-0001',payload=plan)
    check(nr['state']=='applied' and task(snapshot(),'unset')['priority']['own']==2,'normalize applies only intended fields')
    check(task(snapshot(),'unset')['pause']['inherited'] is None,'normalization never invents a freeze')
    check(cli('work','normalize-apply','--request-id','normalize-test-0001',payload=plan)==nr,'normalization idempotency')
    rr=cli('work','normalize-rollback','--request-id','normalize-test-0001')
    check(rr['state']=='rolled_back' and task(snapshot(),'unset')['pause']['inherited'] is None and task(snapshot(),'unset')['priority']['own'] is None,'normalization rollback restores original missing priority')
    check((home/'data/backlog.md').read_bytes()==before,'rollback preserves body and holds')
    cli('add','new-normalized','New request','--repo','alpha',raw=True)
    check(cli('work','dispatch-check','--task','new-normalized')['allowed'],'new unrelated work never inherits normalization')
    plan=cli('work','normalize-plan','--map',str(mp),'--additions',str(ap))
    nr=cli('work','normalize-apply','--request-id','normalize-test-0002',payload=plan)
    legacy=json.loads((home/'data/work-structure.json').read_text())
    legacy['freeze']=dict(reason='Historical stop - original authority must be recovered',except_=['a'],resumed={})
    legacy['freeze']['except']=legacy['freeze'].pop('except_')
    (home/'data/work-structure.json').write_text(json.dumps(legacy))
    apply(op('clear_pause','subproject:alpha/ui'))
    check(task(snapshot(),'a')['pause']['inherited'] is None and task(snapshot(),'b')['pause']['own'],'explicit group resume preserves individual holds under freeze')
    check(task(snapshot(),'unset')['pause']['inherited']['from']=='freeze','resuming one group does not resume other frozen tasks')
    apply(op('set_priority','task:unset',value=0))
    check(task(snapshot(),'unset')['pause']['inherited']['from']=='freeze','priority never lifts freeze')
    cli('update','unset','--priority','1',raw=True)
    check(cli('work','normalize-rollback','--request-id','normalize-test-0002')['code']=='stale_revision','rollback never overwrites intervening edits')
    check(task(snapshot(),'unset')['priority']['own']==1,'later priority remains intact')
    check(not any(p.name.endswith('.tmp') for p in home.rglob('*')),'no leaked temporary files')
    print('work owner: existing controls verified; checking hierarchy and identities',flush=True)
    # New owner contract on isolated real records: display topology never rewrites
    # repository identities or resumes tasks, and aliases survive that topology.
    cli('add','public-unit','Public work','--repo','alpha-public',raw=True)
    cli('hold','public-unit','--kind','parked','--reason','Keep public work paused',raw=True)
    cli('block','public-unit','--by','b',raw=True)
    state=json.loads((home/'data/work-structure.json').read_text())
    state['groups']['subproject:alpha-public/relay']=dict(kind='subproject',repo='alpha-public',label='Relay',priority=1,pause=None,blocked_by=[],aliases=['Old relay name'])
    state['membership']['public-unit']='subproject:alpha-public/relay'
    (home/'data/work-structure.json').write_text(json.dumps(state))
    cli('add','origin','Completed investigation','--repo','alpha',raw=True)
    cli('done','origin',raw=True)
    for key in ('question-a','question-b','question-c'):
        p=subprocess.run(['bash',str(root/'bin/fm-captain-hold.sh'),'hold',key,'--title','Cache decision','--origin','origin',
                          '--reason','Decision unanswered','--question','Clean this cache?', '--option','yes=Clean','--option','no=Keep'],env=env,text=True,capture_output=True)
        check(p.returncode==0,('real unanswered call',p.stdout,p.stderr))
    original_backlog=(home/'data/backlog.md').read_bytes()
    original_registry=(home/'data/projects.md').read_bytes()
    before_snapshot=snapshot()
    def topology(key):
        n=next(n for field in ('projects','subprojects') for n in before_snapshot[field] if n['key']==key)
        return {k:n[k] for k in ('kind','parent','label')}
    hierarchy={'schema':'fm-work-hierarchy.v1','groups':[
        {'key':'project:alpha-public','before':topology('project:alpha-public'),'after':dict(kind='subproject',parent='project:alpha',label='Versión pública')},
        {'key':'subproject:alpha-public/relay','before':topology('subproject:alpha-public/relay'),'after':dict(kind='subproject',parent='project:alpha',label='Relay')}]}
    hp=home/'hierarchy.json';hp.write_text(json.dumps(hierarchy))
    plan=cli('work','normalize-plan','--hierarchy-only','--map',str(hp))
    check(plan['kind']=='hierarchy' and not plan['conflicts'] and not plan['operations'],'hierarchy is a field-only manifest')
    poisoned=copy.deepcopy(plan);poisoned['structure']['freeze']['except'].append('public-unit')
    check(cli('work','normalize-apply','--request-id','hierarchy-tamper-01',payload=poisoned)['code']=='invalid_value','hierarchy cannot unlock an initiative')
    result=cli('work','normalize-apply','--request-id','hierarchy-apply-001',payload=plan)
    check(result['state']=='applied','hierarchy owner apply')
    changed=snapshot()
    check('project:alpha-public' not in [n['key'] for n in changed['projects']],'public counterpart is no longer a root')
    public=next(n for n in changed['subprojects'] if n['key']=='project:alpha-public')
    check(public['parent']=='project:alpha' and public['label']=='Versión pública','ordinary public subproject retains canonical key')
    relay=next(n for n in changed['subprojects'] if n['key']=='subproject:alpha-public/relay')
    check(relay['parent']=='project:alpha','relay is a peer without fourth level')
    check(task(changed,'public-unit')['project']=='project:alpha' and task(changed,'public-unit')['subproject']==relay['key']
          and task(changed,'public-unit')['repository_project']=='project:alpha-public','display parent differs from canonical repository')
    preserved=('state','backlog_state','pause','priority','blocked_by','question','progress','completed','root_blocker','frees')
    for t in before_snapshot['tasks']:
        after=next(n for n in changed['tasks'] if n['key']==t['key'])
        check(all(t[field]==after[field] for field in preserved),'task semantics preserved: '+t['key'])
    check(before_snapshot['sigue']==changed['sigue'],'hierarchy preserves attack order')
    check((home/'data/backlog.md').read_bytes()==original_backlog and (home/'data/projects.md').read_bytes()==original_registry,'repository and task bytes unchanged')
    check(cli('work','normalize-rollback','--request-id','hierarchy-apply-001')['state']=='rolled_back','hierarchy rollback')
    check(json.loads((home/'data/work-structure.json').read_text())==state,'rollback retains exact owner structure')
    plan=cli('work','normalize-plan','--hierarchy-only','--map',str(hp))
    cli('work','normalize-apply','--request-id','hierarchy-apply-002',payload=plan)
    # Explicit seed precedes random extension; all reservations, including an
    # alternate history alias, have a durable reverse lookup in this home only.
    seed={'schema':'fm-work-alias-seed.v1','home':str(home),'entries':[
        {'key':'task:a','alias':'T-222','primary':True},
        {'key':'task:a','alias':'T-223','primary':False},
        {'key':'project:alpha-public','alias':'S-222','primary':True},
        {'key':'task:retired','alias':'T-224','primary':True}]}
    sp=home/'seed.json';sp.write_text(json.dumps(seed))
    init=cli('work','aliases-init','--map',str(sp),'--request-id','aliases-seed-0001')
    check(init['state']=='applied','alias activation backed up and applied')
    check(cli('work','aliases-init','--map',str(sp),'--request-id','aliases-seed-0001')==init,'alias activation idempotent')
    check(cli('work','resolve','--ref','T-222')['key']=='task:a' and cli('work','resolve','--ref','T-223')['key']=='task:a','primary and historical alias reverse to canonical owner')
    check(cli('work','resolve','--ref','T-224')['available'] is False,'retired identity remains reserved')
    seeded=snapshot()
    check(task(seeded,'a')['alias']=='T-222','approved alias displayed unchanged')
    print('work owner: hierarchy preservation and explicit alias activation verified',flush=True)
    aliases={n['key']:n['alias'] for field in ('projects','subprojects','tasks') for n in seeded[field]}
    check(None not in aliases.values() and len(set(aliases.values()))==len(aliases),'every projected identity gets a unique persistent alias')
    cli('add','extension','Later work','--repo','alpha',raw=True)
    extended=snapshot()
    check(all(next(n['alias'] for field in ('projects','subprojects','tasks') for n in extended[field] if n['key']==key)==alias for key,alias in aliases.items()),'extension never recomputes aliases')
    check(task(extended,'extension')['alias'] not in ('T-222','T-223','T-224'),'extension never reuses historical reservation')
    cli('presentation','a','--card-title','Renamed work',raw=True)
    check(task(snapshot(),'a')['alias']=='T-222','renaming preserves identity')
    cli('done','a',raw=True)
    check(cli('work','resolve','--ref','T-222')['key']=='task:a','closure preserves reverse lookup')
    check(apply(op('set_priority','T-222',value=2))['code']=='task_done','alias resolves before ordinary completed-task guard')
    check(cli('work','resolve','--ref','T-ZZZ')['code']=='unknown_target','unknown alias fails closed')
    questions=snapshot()
    for key in ('question-a','question-b','question-c'):
        q=task(questions,key)['question']
        check(q['open'] and q['origin_task']=='task:origin' and q['origin']['available'] and q['origin']['backlog_state']=='done'
              and q['origin']['alias'] and q['origin']['completed'],'unanswered decision stays open after delivered origin')
    preserved_call=(home/'data/question-a/captain-call.json').read_bytes()
    before=(home/'data/backlog.md').read_bytes()
    paused=apply(op('set_pause','task:question-a',reason='Review later'))
    q=task(snapshot(),'question-a')
    check(paused['state']=='applied' and q['state']=='paused_own' and q['question']['open'] and q['question']['call'],
          'waiting decision can pause without answering or hiding its real call')
    check(q['pause']['condition']['kind']=='captain','underlying decision condition is explicit')
    clear=apply(paused['undo'])
    q=task(snapshot(),'question-a')
    check(clear['state']=='applied' and q['state']=='captain' and q['question']['open'],'pause undo restores unanswered decision')
    check((home/'data/backlog.md').read_bytes()==before and (home/'data/question-a/captain-call.json').read_bytes()==preserved_call,
          'decision identity, hold, question and options remain byte-identical')
    p=apply(op('set_pause','task:c',reason='Pause external wait'))
    check(task(snapshot(),'c')['pause']['condition']['kind']=='external','external condition survives separate pause')
    apply(p['undo'])
    check(task(snapshot(),'c')['backlog_state']=='held' or task(snapshot(),'c')['pause']['own']['kind']=='external','resume never releases external hold')
    print('work owner: aliases and decision-preserving pauses verified; checking consultation',flush=True)
    # Removal consultation goes to the genuine primary inbox; it has no work effects.
    before_files={p:p.read_bytes() for p in (home/'data/backlog.md',home/'data/projects.md',home/'data/work-structure.json')}
    consultation=op('request_removal','project:alpha',note='Why now?\nPlease review the dependencies.')
    preview=cli('work','preview',payload=consultation)
    scope=preview['impact']['consultation']
    check(scope['advice'] is None and scope['deletion_authorized'] is False and scope['dependencies'],'real scope contains relationships without manufactured advice')
    check(any(t['key']=='task:public-unit' for t in scope['tasks']),'consultation includes displayed initiative descendants across repository identities')
    consulted=apply(consultation)
    check(consulted['state']=='received' and consulted['consultation']['status']=='pending','consultation accepted but review pending')
    check(all(p.read_bytes()==raw for p,raw in before_files.items()),'consultation never rewrites task or structure data')
    note=consulted['consultation']['note_id']
    receipt=json.loads((home/'data/work-requests'/(consulted['request_id']+'.json')).read_text())
    check(receipt['result']['impact']['consultation']==scope,'durable exact consulted scope')
    notes=list((home/'state/inbox').glob('*.note'))
    retry=dict(consultation,request_id=consulted['request_id'])
    check(cli('work','apply',payload=retry)['consultation']['note_id']==note and list((home/'state/inbox').glob('*.note'))==notes,'retry cannot enqueue a second consultation')
    p=subprocess.run(['bash',str(root/'bin/fm-inbox.sh'),'reply',note,'Review complete; separate concrete approval is still required.'],env=env,capture_output=True)
    check(p.returncode==0,'ordinary reply owner')
    answered=cli('work','request-status','--request-id',consulted['request_id'])
    check(answered['state']=='applied' and answered['consultation']['reply']['body'].startswith('Review complete'),'only real reply advances consultation')
    check(all(p.read_bytes()==raw for p,raw in before_files.items()),'reply never deletes or completes work')
    # A queue-write failure must retain the saved note and its repair identity.
    wake_queue=home/'state/.wake-queue'
    queue_backup=home/'state/.wake-queue.saved'
    wake_queue.rename(queue_backup)
    wake_queue.mkdir()
    repair=op('request_removal','project:alpha',note='Repair this same advisory request.')
    saved=apply(repair)
    check(saved['state']=='received' and 'was not confirmed' in saved['message'],'saved note is pending, never a lost failed receipt')
    repair_note=saved['consultation']['note_id']
    notes=list((home/'state/inbox').glob('*.note'))
    readback=cli('work','request-status','--request-id',saved['request_id'])
    check(readback==saved and wake_queue.is_dir(),'receipt observation does not repair or announce')
    wake_queue.rmdir()
    queue_backup.rename(wake_queue)
    repair=dict(repair,request_id=saved['request_id'])
    repaired=cli('work','apply',payload=repair)
    check(repaired['state']=='received' and repaired['consultation']['note_id']==repair_note,'explicit retry repairs original note without implying a reply')
    cli('work','apply',payload=repair)
    check(list((home/'state/inbox').glob('*.note'))==notes and wake_queue.read_text().count('\tinbox:'+repair_note+'\t')==1,'repaired retries retain one note and one wake')
    # An older failed receipt or a crash before the note receipt was persisted
    # is repaired only for this advisory operation, using its original scope.
    rp=home/'data/work-requests'/(saved['request_id']+'.json')
    legacy=json.loads(rp.read_text());legacy['phase']='written';legacy.pop('note')
    legacy['result'].update(state='failed',code='owner_failed');legacy['result'].pop('consultation')
    rp.write_text(json.dumps(legacy))
    check(cli('work','request-status','--request-id',saved['request_id'])['state']=='failed','interrupted receipt is not replayed by observation')
    restored=cli('work','apply',payload=repair)
    check(restored['state']=='received' and restored['code'] is None and restored['consultation']['note_id']==repair_note,'explicit legacy retry recovers saved note identity')
    check(json.loads(rp.read_text())['result']['impact']['consultation']==legacy['result']['impact']['consultation'],'repair preserves originally consulted scope')
    check(list((home/'state/inbox').glob('*.note'))==notes and wake_queue.read_text().count('\tinbox:'+repair_note+'\t')==1,'crash recovery cannot duplicate note or wake')
    p=subprocess.run(['bash',str(root/'bin/fm-inbox.sh'),'reply',repair_note,'Review complete after delivery repair.'],env=env,capture_output=True)
    check(p.returncode==0 and cli('work','request-status','--request-id',saved['request_id'])['state']=='applied','real answer completes repaired consultation')
    check(all(p.read_bytes()==raw for p,raw in before_files.items()),'repair and answer preserve work and structure')
    check(apply(op('request_removal','task:a',note='Done work question'))['state']=='received','completed work can be consulted without reopening')
    check(cli('work','preview',payload=op('request_removal','task:b',note='x'*2000)).get('impact') is not None,'2000 character reason accepted')
    check(cli('work','preview',payload=op('request_removal','task:b',note='x'*2001))['code']=='invalid_value','oversized reason rejected')
    check(cli('work','preview',payload=op('request_removal','task:b',note='bad\x00note'))['code']=='invalid_value','NUL rejected')
    conflict=copy.deepcopy(seed);conflict['entries'][0]['key']='task:b';sp.write_text(json.dumps(conflict))
    ledger=(home/'data/work-aliases.json').read_bytes()
    check(cli('work','aliases-init','--map',str(sp),'--request-id','aliases-conflict-001')['code']=='request_mismatch'
          and (home/'data/work-aliases.json').read_bytes()==ledger,'alias collisions fail without replacing existing assignments')
    print('work owner: consultation verified; checking logical project promotion',flush=True)
    for key,repo in [('logical-a','alpha'),('logical-b','alpha-public'),('logical-recovery','alpha-public'),('logical-blocker','empty')]:
        cli('add',key,'Logical scope acceptance','--repo',repo,raw=True)
    cli('hold','logical-b','--kind','external','--reason','Keep external condition',raw=True)
    state=json.loads((home/'data/work-structure.json').read_text())
    logical='subproject:alpha/logical'
    peer='subproject:alpha-public/logical'
    recovery='subproject:alpha-public/recovery'
    for key,repo,label,pause in [(logical,'alpha','Logical',None),(peer,'alpha-public','Other repository',None),
                                  (recovery,'alpha-public','Fault recovery',dict(reason='Keep recovery paused',by='captain',at=None))]:
        state['groups'][key]=dict(kind='subproject',repo=repo,label=label,priority=1,pause=pause,blocked_by=[],aliases=[])
    state['membership'].update({'logical-a':logical,'logical-b':peer,'logical-recovery':recovery})
    # The public repository was already demoted in the preceding acceptance:
    # new fixture subprojects need its effective root, not a fourth level.
    for key in (peer,recovery):
        state['hierarchy'][key]=dict(kind='subproject',parent='project:alpha',label=state['groups'][key]['label'])
    state['freeze']['except']+=['logical-a','logical-b','logical-recovery','logical-blocker']
    state['freeze']['resumed'].pop('project:alpha',None)
    (home/'data/work-structure.json').write_text(json.dumps(state))
    before_logical=snapshot()
    protected_files={p:p.read_bytes() for p in [home/'data/backlog.md',home/'data/projects.md',home/'data/work-aliases.json']}
    nodes={n['key']:n for field in ('projects','subprojects') for n in before_logical[field]}
    promotion={'schema':'fm-work-hierarchy.v1','groups':[
        dict(key=key,before={k:nodes[key][k] for k in ('kind','parent','label')},
             after=dict(kind='project' if key==logical else 'subproject',parent=None if key==logical else logical,label=nodes[key]['label']))
        for key in (logical,peer,recovery)]}
    hp.write_text(json.dumps(promotion))
    protected=copy.deepcopy(state);protected['groups']['project:alpha']['pause']=dict(reason='Source protection',by='captain',at=None)
    (home/'data/work-structure.json').write_text(json.dumps(protected))
    check(cli('work','normalize-plan','--hierarchy-only','--map',str(hp))['state']=='rejected','promotion refuses losing an existing source repository protection')
    check(json.loads((home/'data/work-structure.json').read_text())==protected,'protection refusal writes nothing')
    (home/'data/work-structure.json').write_text(json.dumps(state))
    plan=cli('work','normalize-plan','--hierarchy-only','--map',str(hp))
    check(not plan['conflicts'] and not plan['operations'],'logical root promotion is hierarchy-only')
    applied=cli('work','normalize-apply','--request-id','logical-promotion-001',payload=plan)
    check(applied['state']=='applied','logical root owner applies without registering a repository')
    check(cli('work','normalize-apply','--request-id','logical-promotion-001',payload=plan)==applied,'logical promotion retry is idempotent')
    after_logical=snapshot()
    check(sum(n['key']==logical for n in after_logical['projects'])==1 and all(n['key']!=logical for n in after_logical['subprojects']),
          'promoted root appears once with no old subproject duplicate')
    scope={'task:logical-a','task:logical-b','task:logical-recovery'}
    check({t['key'] for t in after_logical['tasks'] if t['project']==logical}==scope,'one coherent cross-repository selection')
    single=cli('work','preview',payload=op('set_pause','task:logical-a',reason='One task'))['impact']['affected']
    check(single['queued']+single['running']+single['stopping']==['task:logical-a'],
          'task identity selects exactly itself within a logical layout')
    check(task(after_logical,'logical-a')['parent']==logical and task(after_logical,'logical-a')['subproject'] is None,'root tasks have no redundant subproject')
    check(task(after_logical,'logical-recovery')['parent']==recovery,'fault recovery remains its own subproject')
    for old in before_logical['tasks']:
        new=next(n for n in after_logical['tasks'] if n['key']==old['key'])
        check(all(old[field]==new[field] for field in ('alias','repository_project','state','backlog_state','priority','pause','blocked_by','question')),
              'logical promotion preserves protected task semantics: '+old['key'])
    check(all(p.read_bytes()==raw for p,raw in protected_files.items()),'logical promotion preserves routing, holds and all alias reservation bytes')
    preview=cli('work','preview',payload=op('set_pause',logical,reason='Pause logical scope'))
    affected=preview['impact']['affected']
    check(set(affected['queued']+affected['running']+affected['stopping'])==scope,'logical root controls affect exactly its selected scope')
    source=cli('work','preview',payload=op('set_pause','project:alpha',reason='Source repository pause'))['impact']['affected']
    check(not scope.intersection(source['queued']+source['running']+source['stopping']),'former repository control no longer selects moved tasks')
    source_pause=apply(op('set_pause','project:alpha',reason='Source repository pause'))
    check(task(snapshot(),'logical-a')['pause']['inherited'] is None,'former repository pause cannot reach moved tasks')
    apply(source_pause['undo'])
    consultation=cli('work','preview',payload=op('request_removal',logical))['impact']['consultation']
    check({t['key'] for t in consultation['tasks']}==scope,'logical root consultation uses same scope')
    paused=apply(op('set_pause',logical,reason='Pause logical scope'))
    check(paused['state']=='applied' and all(task(snapshot(),i)['pause']['inherited'] for i in ('logical-a','logical-b','logical-recovery')),'root pause protects every repository')
    apply(paused['undo'])
    check(task(snapshot(),'logical-b')['pause']['own']['kind']=='external' and task(snapshot(),'logical-recovery')['pause']['inherited']['from']==recovery,
          'root resume preserves external hold and recovery subproject pause')
    dep=apply(op('add_dep',logical,on='task:logical-blocker'))
    check(dep['state']=='applied' and all(any(b['ref']=='task:logical-blocker' for b in task(snapshot(),i)['blocked_by']) for i in ('logical-a','logical-b','logical-recovery')),
          'logical-root dependency gates all displayed tasks')
    apply(dep['undo'])
    check(cli('work','normalize-rollback','--request-id','logical-promotion-001')['code']=='stale_revision','rollback refuses subsequent control edits')
    # Restore only disposable fixture data to exercise an uncontended rollback.
    (home/'data/work-structure.json').write_text(json.dumps(applied['after']['structure']))
    check(cli('work','normalize-rollback','--request-id','logical-promotion-001')['state']=='rolled_back','logical root rollback restores source topology')
    check(json.loads((home/'data/work-structure.json').read_text())==state,'logical rollback preserves the complete original overlay')
    fresh=cli('work','normalize-plan','--hierarchy-only','--map',str(hp))
    cli('presentation','logical-a','--card-title','Changed after dry run',raw=True)
    check(cli('work','normalize-apply','--request-id','logical-stale-source-01',payload=fresh)['code']=='stale_revision','logical apply refuses source drift')
    for bad in [dict(kind='project',parent='project:alpha',label='Invalid'),
                dict(kind='subproject',parent=logical,label='Self cycle'),
                dict(kind='subproject',parent=peer,label='Fourth level'),
                dict(kind='subproject',parent='task:logical-a',label='Task parent')]:
        invalid=copy.deepcopy(promotion);invalid['groups'][0]['after']=bad;hp.write_text(json.dumps(invalid))
        check(cli('work','normalize-plan','--hierarchy-only','--map',str(hp))['state']=='rejected','invalid logical topology refuses without writes')
    check(json.loads((home/'data/work-structure.json').read_text())==state,'invalid topology and stale source never mutate structure')
    print('work owner: checking pause and resume with dead, live and unknown endpoints',flush=True)
    # Separate disposable home; the endpoint fixture never reaches a real server.
    home = home/'pause-fixture'
    home.mkdir()
    for name in ('data','state','config','fakebin','wt'):
        (home/name).mkdir()
    env.update(FM_HOME=str(home),PATH=str(home/'fakebin')+os.pathsep+env['PATH'])
    (home/'data/projects.md').write_text('- alpha [local-only] - Example\n')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    mode=home/'endpoint-mode'
    fake=home/'fakebin/tmux'
    fake.write_text('''#!/usr/bin/env bash
case "$(cat "$FM_HOME/endpoint-mode"):$1" in
  missing:list-windows) exit 0 ;;
  *:list-windows) printf '%s\\n' 'fm-unit'; exit 0 ;;
  alive:display-message) printf 'codex\\n'; exit 0 ;;
  dead:display-message) printf 'bash\\n'; exit 0 ;;
esac
exit 1
''')
    fake.chmod(0o755)
    mode.write_text('missing')
    cli('add','unit','Example task','--repo','alpha',raw=True)
    cli('start','unit',raw=True)
    meta=home/'state/unit.meta'
    meta.write_text(f'window=example:fm-unit\nworktree={home}/wt\nproject={home}/wt\nkind=ship\nbackend=tmux\nmode=local-only\n')
    protected=home/'wt/saved-work'
    protected.write_text('Uncommitted work must survive\n')
    original_meta=meta.read_bytes()
    def receipt(request):
        return json.loads((home/'data/work-requests'/(request+'.json')).read_text())
    def pause():return apply(op('set_pause','task:unit',reason='Guardar el avance'))
    def resume():return apply(op('clear_pause','task:unit'))
    def note_for(request):
        record=receipt(request)
        note=home/'state/inbox'/(record['note']['id']+'.note')
        text=note.read_text()
        return json.loads(text[text.index('{'):])
    r=pause()
    check(r['state']=='applied' and r['pending_reason'] is None,'missing endpoint pause applies immediately')
    s=snapshot();unit=task(s,'unit')
    check(unit['state']=='paused_own' and unit['pause']['own']['kind']=='parked' and unit['backlog_state']=='in_flight','dead-worker pause is task-owned without moving or losing work')
    check(unit['worker_liveness']['state']=='dead' and receipt(r['request_id'])['worker_evidence']['unit']['verdict']=='missing','receipt retains positive absence evidence')
    check(unit['pause']['safe_point']=='no_worker','absence is distinct from a worker acknowledgement')
    original=r
    r=resume()
    check(r['state']=='applied' and task(snapshot(),'unit')['state']=='ready','resume of missing endpoint removes pause without claiming running')
    check(note_for(r['request_id'])['resume_candidates']==[],'dead endpoint is never a resume candidate')
    check(cli('work','request-status','--request-id',original['request_id'])['state']=='applied' and task(snapshot(),'unit')['pause']['own'] is None,'old completed pause cannot reapply after resume')
    mode.write_text('alive')
    r=pause();request=r['request_id']
    check(r['state']=='received' and r['pending_reason']=='Reaching a safe point.','live worker pause awaits acknowledgement')
    check(task(snapshot(),'unit')['state']=='stopping','live unacknowledged worker is never paused')
    # Unrelated terminal status does not acknowledge a safe point.
    (home/'state/unit.status').write_text('done [at='+str(int(time.time()))+']: unrelated\n')
    check(cli('work','request-status','--request-id',request)['state']=='received' and task(snapshot(),'unit')['state']=='stopping','terminal prose cannot pause a live worker')
    (home/'state/unit.status').write_text('paused [key=safe-point-'+request+'] [at='+str(int(time.time())-3600)+']: too old\n')
    check(cli('work','request-status','--request-id',request)['state']=='received','old acknowledgement rejected')
    (home/'state/unit.status').write_text('paused [key=safe-point-'+request+'] [at='+str(int(time.time()))+']: saved\n')
    s=snapshot()
    check(task(s,'unit')['state']=='paused_own' and receipt(request)['result']['state']=='applied','snapshot reconciles exact live acknowledgement')
    r=resume()
    check(note_for(r['request_id'])['resume_candidates']==['unit'],'confirmed live worker remains eligible for supervised resume')
    (home/'state/unit.status').write_text('')
    mode.write_text('unknown')
    r=pause();request=r['request_id']
    check(r['state']=='received' and 'Worker liveness cannot be confirmed.' in r['pending_reason'],'unknown liveness is explained plainly')
    check(task(snapshot(),'unit')['state']=='stopping' and receipt(request)['result']['state']=='received','snapshot never treats probe failure as death')
    mode.write_text('alive')
    check(cli('work','request-status','--request-id',request)['state']=='received','explicit fresh check refuses a live worker')
    mode.write_text('dead')
    check(cli('work','request-status','--request-id',request)['state']=='applied','explicit fresh check settles only after positive death evidence')
    check(task(snapshot(),'unit')['state']=='paused_own','shell-only endpoint no longer counts as running')
    r=resume()
    check(task(snapshot(),'unit')['state']=='ready' and note_for(r['request_id'])['resume_candidates']==[],'metadata with dead agent never implies resumed execution')
    mode.write_text('alive')
    r=pause();request=r['request_id']
    mode.write_text('missing')
    before_files={p:p.read_bytes() for p in (home/'data/backlog.md',home/'data/work-structure.json',meta,protected)}
    s=snapshot()
    check(task(s,'unit')['state']=='paused_own' and receipt(request)['result']['state']=='applied','worker death after request settles automatically on snapshot')
    check(all(p.read_bytes()==raw for p,raw in before_files.items()),'automatic reconciliation changes receipt only and preserves all work')
    r=resume()
    mode.write_text('unknown')
    r=pause();request=r['request_id']
    r=resume()
    snapshot()
    check(receipt(request).get('cancelled') and task(snapshot(),'unit')['pause']['own'] is None,'cleared pending pause is retired without replay')
    mode.write_text('missing')
    cli('hold','unit','--kind','external','--reason','Preserve condition',raw=True)
    r=pause()
    check(r['state']=='applied' and task(snapshot(),'unit')['pause']['condition']['kind']=='external','dead-worker pause preserves independent external wait')
    resume()
    check(task(snapshot(),'unit')['state']=='waiting_external','resume preserves independent wait')
    mode.write_text('unknown')
    r=pause();request=r['request_id']
    resume();snapshot()
    check(receipt(request).get('cancelled') and task(snapshot(),'unit')['pause']['own']['kind']=='external' and task(snapshot(),'unit')['state']=='waiting_external','clearing a pending layered pause retires only that request and preserves the external wait')
    check(meta.read_bytes()==original_meta and protected.read_text()=='Uncommitted work must survive\n','endpoint metadata and saved work stay untouched')
    cli('unhold','unit',raw=True)
    cli('add','peer','Another task','--repo','alpha',raw=True)
    cli('start','peer',raw=True)
    (home/'state/peer.meta').write_text(original_meta.decode().replace('fm-unit','fm-peer'))
    mode.write_text('alive')
    r=apply(op('set_pause','project:alpha',reason='Guardar ambos avances'));request=r['request_id']
    s=snapshot()
    check(r['state']=='received' and task(s,'unit')['state']=='stopping' and task(s,'peer')['state']=='paused_inherited','mixed group pause never declares its live worker paused')
    check(note_for(request)['safe_tasks']==['unit'],'safe-point note selects only workers still needing acknowledgement')
    mode.write_text('missing');snapshot()
    check(receipt(request)['result']['state']=='applied','mixed pause settles automatically after remaining worker disappears')
    apply(op('clear_pause','project:alpha'))
    # Unsupported and absent metadata are uncertainty, never positive death.
    meta.write_text(original_meta.decode().replace('backend=tmux','backend=orca'))
    r=pause()
    check(r['state']=='received' and 'Worker liveness cannot be confirmed.' in r['pending_reason'],'unverified backend cannot confirm pause')
    meta.unlink()
    check(cli('work','request-status','--request-id',r['request_id'])['state']=='received','missing metadata alone cannot prove worker death')
    for args, warning in [(['add','host-task','Host task'],True),
                          (['create','scoped-task','Project task','--repo=alpha'],False)]:
        added=subprocess.run(wrapper+args,env=env,text=True,capture_output=True)
        check(added.returncode==0 and (len(added.stderr.splitlines())==1 if warning else not added.stderr),'only projectless creation warns once')
    projectless=task(snapshot(),'host-task')
    check(all(projectless[k] is None for k in ('parent','project','subproject','repository_project')),'host task projects stay null')
    state=json.loads((home/'data/work-structure.json').read_text())
    if state.get('freeze'): state['freeze']['except'] += ['request-old','request-new']
    (home/'data/work-structure.json').write_text(json.dumps(state))
    for key, request in [('request-old','old'),('request-new','new with spaces')]:
        cli('add',key,key,'--repo','empty',raw=True)
        pf.write_text(json.dumps({'request':{'id':request,'label':request,'project':'empty'}}))
        cli('presentation',key,'--presentation-file',str(pf),raw=True)
        if request == 'old': time.sleep(1.05)
    check(snapshot()['requests'][0]['id']=='new with spaces','recent requests follow member activity')
    r=apply(op('move','request:old',before='request:new with spaces'))
    check(r['state']=='applied','explicit request can move without an execution identity')
    ordered=cli('work','snapshot','--order','manual')
    request_order=[g['id'] for g in ordered['requests']]
    check(request_order.index('old') < request_order.index('new with spaces'),'request order persists among default requests including spaced ids')
    check(snapshot()['requests'][0]['id']=='new with spaces','recent request sort preserves manual order')
    previous=json.loads((home/'data/work-structure.json').read_text())['order']
    moved=apply(op('move','task:request-old'))
    check(moved['state']=='applied','task moves coexist with request order')
    check(apply(moved['undo'])['state']=='applied','task move Undo accepts saved request keys')
    check(json.loads((home/'data/work-structure.json').read_text())['order']==previous,'task Undo restores the exact mixed order')
    check(apply(r['undo'])['state']=='applied','request move supports ordinary Undo')
    check(apply(op('set_pause','request:old',reason='Display only'))['code']=='unknown_target','request ordering does not create an execution scope')
    # Signal API uses explicit request membership and preserves all pause layers.
    home = home/'signals'
    home.mkdir()
    for name in ('data','state','config'):
        (home/name).mkdir()
    env.update(FM_HOME=str(home))
    (home/'data/projects.md').write_text('- alpha [local-only] - Example\n')
    (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    cli('add','idle','Saved task','--repo','alpha',raw=True)
    request_file=home/'request.json'
    request_file.write_text(json.dumps(dict(request=dict(id='demo',label='Demo',project='alpha'))))
    cli('presentation','idle','--presentation-file',str(request_file),raw=True)
    cli('add','subpeer','Same subproject, different request','--repo','alpha',raw=True)
    structure=dict(schema='fm-work-structure.v1',groups={'subproject:alpha/demo':dict(kind='subproject',repo='alpha',label='Demo',pause=None)},membership={'idle':'subproject:alpha/demo','subpeer':'subproject:alpha/demo'},order=[],edge_meta={})
    (home/'data/work-structure.json').write_text(json.dumps(structure))
    def signal(verb, scope='req:demo', **kw):
        global counter
        counter += 1
        return cli('work',verb,payload=dict(scope=scope,rev=snapshot()['rev'],request_id='signal-request-%08d'%counter,**kw))
    alias_seed=home/'alias-seed.json'
    alias_seed.write_text(json.dumps(dict(schema='fm-work-alias-seed.v1',home=str(home),entries=[])))
    cli('work','aliases-init','--map',str(alias_seed),'--request-id','signals-alias-init-0001')
    before=(home/'data/work-structure.json').read_bytes()
    preview=signal('pause.preview')
    check(preview['can_pause'] and preview['impact']['affected']['queued']==['task:idle'],'request scope preview selects existing membership')
    check((home/'data/work-structure.json').read_bytes()==before,'signal preview writes no controls')
    stale=snapshot()['rev']
    paused=signal('pause.request')
    check(paused['state']=='applied' and paused['events'][0]['event']=='pause.confirmed','idle scope pause confirms with zero agents closed')
    check(paused['events'][0]['scope']=='req:demo','events expose explicit request scope')
    check(task(snapshot(),'idle')['pause']['state']=='set_aside','pending task is set aside without launching it')
    check(task(snapshot(),'subpeer')['state']=='ready','request pause does not select unrelated tasks from the same subproject')
    check(signal('pause.cancel')['code']=='invalid_value','confirmed pause cannot be cancelled')
    conflict=cli('work','resume.request',payload=dict(scope='req:demo',rev=stale,request_id='stale-signal-00001'))
    check(conflict['code']=='stale_revision' and conflict['snapshot']['rev']==snapshot()['rev'],'stale signal returns fresh snapshot without acting')
    signal('pause.request','task:idle')
    preview=signal('resume.preview')
    check(preview['agents_needed']==0 and preview['impact']['still_paused']==['task:idle'],'resume preview preserves individual pause')
    resumed=signal('resume.request')
    check(resumed['state']=='applied' and resumed['agents_started']==0 and resumed['events'][0]['event']=='resume.confirmed','scope resumes without launching set-aside tasks')
    check(task(snapshot(),'idle')['pause']['own'] is not None,'request resume retains individual pause')
    signal('resume.request','task:idle')
    check(task(snapshot(),'idle')['state']=='ready','task resumes when every selected pause is removed')
    stable=snapshot()
    cli('work','reconcile')
    check(snapshot()['events']==stable['events'],'reconciliation does not repeat confirmation events')
    # A queued resume keeps its pause; dequeue neither launches nor clears it.
    signal('pause.request')
    signal('pause.request','project:alpha')
    signal('pause.request','task:idle')
    cli('start','idle',raw=True)
    request=paused['request_id']
    path=home/'data/work-requests'/(request+'.json')
    saved=json.loads(path.read_text());saved['exited']=['idle'];path.write_text(json.dumps(saved))
    # Isolate CPU probe pressure observed on the development host; capacity's
    # resource constraints have independent coverage in fm-capacity.test.sh.
    cores=home.parent/'fakebin/getconf'
    cores.write_text('#!/usr/bin/env bash\nif [ "$1" = _NPROCESSORS_ONLN ]; then echo 1024; else /usr/bin/getconf "$@"; fi\n')
    cores.chmod(0o755)
    # Capacity's existing recovery surface counts an unknown endpoint, preserving safety.
    (home/'state/other.meta').write_text('kind=ship\n')
    (home/'config/lane-capacity').write_text('1\n')
    signal('resume.request','project:alpha')
    signal('resume.request','task:idle')
    queued=signal('resume.request')
    check(queued['pause_state']=='queued' and queued['reason']=='cap','resume at capacity stays queued')
    check(task(snapshot(),'idle')['pause']['inherited'] is not None,'queued resume preserves selected pause')
    check(any(e['event']=='resume.refused' for e in snapshot()['events']),'queue refusal event is exposed')
    cli('add','aside','Another set-aside task','--repo','alpha',raw=True)
    signal('pause.request','task:aside')
    following=signal('resume.request','task:aside')
    check(following['pause_state']=='queued','later scope respects FIFO even when it needs no agents')
    check(next(p for p in snapshot()['pause_controls'] if p['scope']=='task:aside')['queue_position']==2,'queue position is exposed')
    signal('resume.dequeue')
    check(task(snapshot(),'idle')['pause']['inherited'] is not None,'dequeue leaves the work paused')
    cli('work','reconcile')
    check(task(snapshot(),'aside')['state']=='ready' and any(e['event']=='resume.started_from_queue' and e['scope']=='task:aside' for e in snapshot()['events']),'next queued scope resumes automatically after head is dequeued')
    (home/'config/lane-capacity').unlink()
    failed=signal('resume.request')
    check(failed['state']=='failed' and failed['reason']=='other' and not failed['agents_started'],'unknown endpoint cannot be relaunched or confirmed')
    check(task(snapshot(),'idle')['pause']['own'] is not None,'failed resume preserves saved work with an explicit pause')
    check(any(e['event']=='resume.refused' and e['reason']=='other' for e in failed['events']),'failed relaunch exposes refusal reason')
    print('PASS: %d work owner behavioral assertions'%checks)
PY
