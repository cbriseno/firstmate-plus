#!/usr/bin/env bash
# Progress publication through the public owner wrapper: transient snapshot
# contention, bounded refusal, safe input/repair, and generated worker command.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
python3 - "$ROOT" <<'PY'
import fcntl, json, os, pathlib, re, signal, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-progress-reporting-') as tmp:
    home = pathlib.Path(tmp)
    for name in ('data', 'state', 'config'):
        (home / name).mkdir()
    (home / 'data/projects.md').write_text('- alpha [local-only +yolo] - Test project\n')
    backlog = home / 'data/backlog.md'
    backlog.write_text('## In flight\n\n## Queued\n\n- [ ] proof - Proof (repo: alpha)\n\n## Done\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), FM_LIVE='0')
    wrapper = ['bash', str(root / 'bin/fm-tasks-axi.sh')]
    checks = 0
    def execute(argv, **kwargs):
        # A public lifecycle command may launch a short detached helper. File
        # captures cannot be held open by an inherited pipe after its parent
        # exits. Bound only this private fixture command/process group.
        timeout = kwargs.pop('timeout', 20)
        kwargs.pop('capture_output', None)
        with tempfile.TemporaryFile(mode='w+') as out, tempfile.TemporaryFile(mode='w+') as err:
            p = subprocess.Popen(argv, stdout=out, stderr=err, start_new_session=True, **kwargs)
            try:
                rc = p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=5)
                out.seek(0); err.seek(0)
                raise AssertionError(('public command timed out', argv, out.read(), err.read()))
            out.seek(0); err.seek(0)
            return subprocess.CompletedProcess(argv, rc, out.read(), err.read())
    def check(value, message):
        global checks
        assert value, message
        checks += 1
    def run(*args, ok=True, extra_env=None, fds=()):
        p = execute(wrapper + list(args), env=env | (extra_env or {}), text=True, capture_output=True, timeout=20, pass_fds=fds)
        check((p.returncode == 0) == ok, (args, p.stdout, p.stderr))
        return json.loads(p.stdout) if ok else p
    def task():
        s = run('work', 'snapshot')
        check(s.get('schema') == 'fm-work-snapshot.v1', s)
        return next(t for t in s['tasks'] if t['key'] == 'task:proof')
    progress = {'steps': [{'label': label, 'state': state} for label, state in
        [('Code', 'done'), ('Checks', 'active'), ('Branch ready', 'todo'), ('Activation', 'todo')]]}
    draft = home / 'data/progress-input.json'
    draft.write_text(json.dumps({'progress': progress}))
    lock = home / 'data/.work.lock'
    lock.touch()
    run('presentation', 'proof', '--presentation-file', str(draft))
    check(task()['progress']['done'] == 1, 'uncontended known matching path')
    output = home / 'data/proof/presentation.json'
    progress['steps'][1]['state'] = 'done'
    draft.write_text(json.dumps({'progress': progress}))
    baseline = backlog.read_bytes()
    with lock.open('r') as reader:
        fcntl.flock(reader, fcntl.LOCK_SH)
        p = subprocess.Popen(wrapper + ['presentation', 'proof', '--presentation-file', str(draft)],
                             env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.4)
        check(p.poll() is None, 'transient shared snapshot reader must not lose a milestone write')
        fcntl.flock(reader, fcntl.LOCK_UN)
        out, err = p.communicate(timeout=15)
        check(p.returncode == 0 and json.loads(out)['presentation']['progress'] == progress, (out, err))
    check(task()['progress']['done'] == 2 and task()['progress']['total'] == 4, 'public snapshot carries completed steps exactly')
    run('presentation', 'proof', '--card-status', 'Comprobaciones cerradas')
    check(task()['progress']['done'] == 2, 'status-only write preserves steps')
    with lock.open('w') as owner:
        fcntl.flock(owner, fcntl.LOCK_EX)
        result = run('presentation', 'proof', '--card-status', 'Dueño heredado',
                     extra_env={'FM_WORK_OWNER_FD': str(owner.fileno())}, fds=(owner.fileno(),))
        check(result['presentation']['progress'] == progress, 'validated inherited lock remains usable without re-acquisition')
    with lock.open('w') as owner:
        fcntl.flock(owner, fcntl.LOCK_EX)
        result = run('work', 'snapshot')
        check(result.get('state') == 'rejected' and result.get('code') == 'busy' and result.get('schema') != 'fm-work-snapshot.v1',
              'exit0 busy is a refusal, not a published measurement or valid snapshot')
    saved = output.read_bytes()
    with lock.open('r') as reader:
        fcntl.flock(reader, fcntl.LOCK_SH)
        began = time.monotonic()
        run('presentation', 'proof', '--card-status', 'No debe escribirse', ok=False)
        elapsed = time.monotonic() - began
        check(4.8 <= elapsed < 12 and output.read_bytes() == saved, 'bounded contention refuses without write')
        began = time.monotonic()
        run('update', 'proof', '--priority', '0', ok=False)
        check(4.8 <= time.monotonic() - began < 12 and backlog.read_bytes() == baseline, 'other writers bound contention without changing backlog')
    run('presentation', 'proof', '--card-status', 'No heredado', ok=False, extra_env={'FM_WORK_OWNER_FD': '98765'})
    check(output.read_bytes() == saved, 'invalid inherited lock refuses instead of silently falling back')
    # The same input-as-output mistake seen in the real worker stays invalid
    # until explicitly repaired; backup keeps the exact original bytes.
    raw = (json.dumps({'progress': progress}, ensure_ascii=False) + '\n').encode()
    output.write_bytes(raw)
    check(run('presentation', 'proof')['evidence']['available'] is False, 'raw patch is not a valid declaration')
    run('presentation', 'proof', '--presentation-file', str(output), ok=False)
    run('presentation', 'proof', '--presentation-file', str(draft), ok=False)
    check(output.read_bytes() == raw, 'ordinary writes never silently accept invalid declaration')
    result = run('presentation', 'proof', '--repair', '--presentation-file', str(draft))
    check((home / result['repair_backup']).read_bytes() == raw, 'explicit repair retains exact invalid bytes')
    check(result['evidence']['available'] and task()['progress']['done'] == 2, 'repair restores verified public projection')
    saved = output.read_bytes()
    run('presentation', 'proof', '--repair', '--presentation-file', str(draft), ok=False)
    check(output.read_bytes() == saved, 'repair cannot reset valid declaration')
    output.unlink()
    outside = home / 'untouched.json'
    outside.write_bytes(raw)
    output.symlink_to(outside)
    run('presentation', 'proof', '--repair', '--presentation-file', str(draft), ok=False)
    check(output.is_symlink() and outside.read_bytes() == raw, 'repair cannot bypass symlink guard')
    output.unlink()
    # Precise semantic replay: the observed Deck declaration was 4/7; two
    # manually verified milestones later closed, then an old draft replayed.
    labels = ['Revisión', 'Propuesta', 'Implementation', 'Módulos',
              'Conectores y rebase', 'Navegador y rama', 'Activación instalada']
    def publish(states, phase='implementation', gates=None, **kwargs):
        steps = [dict(label=label, state=state) for label, state in zip(labels, states)]
        for index, gate in (gates or {}).items():
            steps[index]['gate'] = gate
        draft.write_text(json.dumps(dict(phase=phase, progress=dict(steps=steps))))
        return run('presentation', 'proof', '--presentation-file', str(draft), **kwargs)
    baseline = backlog.read_bytes()
    status = home / 'state/proof.status'
    status.write_text('working [at=1793511394]: integration in progress\n')
    publish(['done'] * 4 + ['active', 'todo', 'todo'])
    check(task()['progress']['done'] == 4, 'precise initial 4/7 declaration')
    status.write_text(status.read_text() + 'working [at=1793511996]: modules reconciled\n')
    run('presentation', 'proof', '--card-status', 'Conectores integrados')
    t = task()
    check(t['progress'] is None and t['declared_progress']['done'] == 4
          and t['progress_evidence']['freshness'] == 'stale', 'card-only patch cannot mask old 4/7')
    publish(['done'] * 6 + ['active'])
    publish(['done'] * 4 + ['active', 'todo', 'todo'])
    check(task()['progress']['done'] == 6, 'old 4/7 replay cannot undo two explicitly closed milestones')
    before_clock = run('presentation', 'proof')['lifecycle']['evidence']['reported_at']
    run('presentation', 'proof', '--card-status', 'La comprobación sigue activa')
    check(run('presentation', 'proof')['lifecycle']['evidence']['reported_at'] == before_clock,
          'card text preserves the separate measurement clock')
    status.write_text(status.read_text() + 'paused [at=1793512718]: awaiting a check\n')
    publish(['done'] * 6 + ['active'], phase='validation')
    t = task()
    check(t['progress']['done'] == 6 and t['phase'] == 'validation',
          'working or waiting may checkpoint without fabricating advancement')
    run('presentation', 'proof', '--clear')
    check(task()['progress'] is None and task()['progress_evidence']['freshness'] == 'missing',
          'explicit clear exposes genuinely missing measurement')
    # A new isolated local project, not a lane worktree/pool. Actual ready gate
    # and guarded local landing exercise authoritative Git facts end to end.
    project, worker = home / 'project', home / 'worker'
    def git(path, *args):
        p = execute(['git', '-C', str(path), *args], env=env, text=True, capture_output=True, timeout=10)
        check(p.returncode == 0, (args, p.stdout, p.stderr))
        return p.stdout.strip()
    project.mkdir()
    git(project, 'init', '-q', '-b', 'main')
    git(project, 'config', 'user.name', 'Test')
    git(project, 'config', 'user.email', 'test@example.invalid')
    git(project, 'commit', '-q', '--allow-empty', '-m', 'base')
    git(home, 'clone', '-q', str(project), str(worker))
    git(worker, 'config', 'user.name', 'Test')
    git(worker, 'config', 'user.email', 'test@example.invalid')
    git(worker, 'checkout', '-q', '-b', 'fm/proof')
    git(worker, 'commit', '-q', '--allow-empty', '-m', 'implementation')
    head = git(worker, 'rev-parse', 'HEAD')
    meta = home / 'state/proof.meta'
    meta.write_text(f'kind=ship\nmode=local-only\nyolo=on\nproject={project}\nworktree={worker}\nbranch=fm/proof\n')
    status.write_text('done [at=1793512718]: ready in branch fm/proof\n')
    # The worker copy alone is not ready. Copy only its commit objects into
    # the shared project, then publish the named local branch as the owner needs.
    publish(['done'] * 4 + ['todo', 'todo', 'active'], gates={4:'branch-ready', 5:'integrated'})
    check(task()['progress']['done'] == 4, 'unshared disposable head cannot close readiness')
    git(project, 'fetch', '-q', str(worker), 'HEAD')
    git(project, 'update-ref', 'refs/heads/fm/proof', head)
    run('presentation', 'proof', '--reconcile')
    t = task()
    check(t['progress']['done'] == 5 and t['phase'] == 'branch-ready'
          and 'integrated' not in t['verified_gates'], 'verified readiness advances its bound gate only')
    legacy = json.loads(output.read_text())
    del legacy['progress_record']
    output.write_text(json.dumps(legacy))
    result = run('presentation', 'proof', '--reconcile')
    check(result['evidence']['available'] and result['lifecycle']['evidence']['freshness'] == 'unknown'
          and result['lifecycle']['gates']['branch-ready']['head'] == head,
          'legacy gate reconciliation retains proof without inventing a checkpoint clock')
    run('presentation', 'proof', '--card-status', 'Declaración anterior preservada')
    publish(['done'] * 4 + ['todo', 'todo', 'active'], gates={4:'branch-ready', 5:'integrated'})
    check(task()['progress']['done'] == 5, 'legacy declaration upgrades by explicit checkpoint without repair')
    p = execute(['bash', str(root / 'bin/fm-merge-local.sh'), 'proof'],
                       env=env, capture_output=True, text=True, timeout=25)
    check(p.returncode == 0, ('guarded local landing', p.stdout, p.stderr))
    t = task()
    check(t['progress']['done'] == 6 and t['phase'] == 'integration',
          'guarded landing advances integration separately from installed activation')
    publish(['done'] * 4 + ['todo', 'todo', 'active'], phase='activation', gates={4:'branch-ready', 5:'integrated'})
    check(task()['phase'] == 'activation' and task()['progress']['done'] == 6,
          'activation declaration stays active until explicitly verified')
    publish(['done'] * 7, phase='complete', gates={4:'branch-ready', 5:'integrated'})
    check(task()['phase'] == 'complete' and task()['progress']['done'] == 7,
          'explicit installed acceptance may close its own fine step')
    # Restart/replay is a new public process every time. Code changes after a
    # ready event invalidate applicability, never reattribute that old event.
    git(worker, 'commit', '-q', '--allow-empty', '-m', 'follow-up')
    t = task()
    check(t['progress'] is None and t['phase'] == 'implementation'
          and t['verified_gates']['branch-ready']['head'] == head,
          'new head requires checkpoint and retains the original verified head')
    draft.write_text(json.dumps(dict(phase='rebase', progress=dict(steps=[dict(label=label, state='done' if i < 4 else 'todo', **({'gate': 'branch-ready'} if i == 4 else {'gate':'integrated'} if i == 5 else {})) for i,label in enumerate(labels)]))))
    run('presentation', 'proof', '--presentation-file', str(draft), '--replan', 'New code needs affected acceptance')
    t = task()
    check(t['phase'] == 'rebase' and t['progress']['done'] == 4,
          'rebase records current phase; old gate proofs cannot close new-head gates')
    check(backlog.read_bytes() == baseline, 'progress does not change user holds or backlog data')
    # Promotion contract change is visible even if a presentation publication
    # was missed. Titles survive; no prose is used to invent a replacement title.
    meta.write_text(meta.read_text().replace('kind=ship', 'kind=scout'))
    publish(['active'] + ['todo'] * 6, phase='investigation')
    run('presentation', 'proof', '--card-title', 'Investigación preservada')
    meta.write_text(meta.read_text().replace('kind=scout', 'kind=ship'))
    t = task()
    check(t['progress'] is None and t['phase'] == 'implementation'
          and t['title'] == 'Investigación preservada'
          and 'task-contract-changed' in t['progress_evidence']['reasons'],
          'missed promotion checkpoint exposes ship phase and preserves authored title')
    # Exercise actual promotion, not merely a handcrafted context change.
    meta.write_text(meta.read_text().replace('kind=ship', 'kind=scout'))
    p = execute(['bash', str(root / 'bin/fm-brief.sh'), 'proof', 'alpha', '--scout'],
                       env=env, text=True, capture_output=True, timeout=15)
    check(p.returncode == 0, ('promotion scaffold', p.stdout, p.stderr))
    brief = home / 'data/proof/brief.md'
    brief.write_text(brief.read_text().replace('{TASK}', 'Investigate progress reporting')
                     .replace('{FIRSTMATE_SPEC}', 'Bounded local report'))
    publish(['active'] + ['todo'] * 6, phase='investigation')
    p = execute(['bash', str(root / 'bin/fm-promote.sh'), 'proof', '--mode', 'local-only',
                        '--yolo', 'on', '--card-title', 'Implementar ciclo de progreso'],
                       env=env, text=True, capture_output=True, timeout=20)
    check(p.returncode == 0, ('actual promotion', p.stdout, p.stderr))
    check(task()['title'] == 'Implementar ciclo de progreso' and task()['phase'] == 'implementation'
          and task()['progress_evidence']['freshness'] == 'stale',
          'actual promotion refreshes explicit title and requires implementation checkpoint')
    # Age every grace input so the public mechanical scan sees the missed
    # checkpoint without a supervisor, model invocation or a new timing policy.
    old = time.time() - 31
    os.utime(meta, (old, old)); os.utime(status, (old, old))
    declaration = json.loads(output.read_text())
    declaration['progress_record']['reported_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(old))
    output.write_text(json.dumps(declaration))
    p = execute(wrapper + ['progress-check'], env=env, text=True, capture_output=True, timeout=15)
    check(p.returncode == 0 and 'proof: stale' in p.stdout, 'existing supervision input surfaces missed checkpoint')
    # The ordinary drain exposes the same obligation when no supervisor is
    # running; it does not answer holds, resume a task, or invent a completion.
    p = execute(['bash', str(root / 'bin/fm-wake-drain.sh')],
                       env=env | {'FM_SIGNAL_GRACE':'0'}, text=True, capture_output=True, timeout=20)
    check(p.returncode == 0 and 'PROGRESS RECONCILIATION' in p.stdout,
          ('ordinary drain carries reporting reconciliation', p.stdout, p.stderr))
    fakebin = home / 'fakebin'
    fakebin.mkdir()
    tmux = fakebin / 'tmux'
    tmux.write_text('#!/usr/bin/env bash\nexit 0\n'); tmux.chmod(0o755)
    p = execute(['bash', str(root / 'bin/fm-watch.sh')],
                       env=env | {'PATH':str(fakebin) + ':' + env['PATH'], 'FM_SIGNAL_GRACE':'0',
                                  'FM_CHECK_INTERVAL':'1', 'FM_POLL':'1'},
                       text=True, capture_output=True, timeout=20)
    check(p.returncode == 0 and 'progress reconciliation required' in p.stdout,
          ('ordinary watcher queues the existing check wake', p.stdout, p.stderr))
    publish(['done'] * 4 + ['todo', 'todo', 'active'], gates={4:'branch-ready', 5:'integrated'})
    p = execute(wrapper + ['progress-check'], env=env, text=True, capture_output=True, timeout=15)
    check(p.returncode == 0 and p.stdout == '', 'unchanged honest checkpoint clears the reporting obligation')
    # A hermetic run instrument feeds the real attribution owner. No live
    # pipeline, daemon or harness is invoked. Completion alone is not a pass.
    nm = fakebin / 'no-mistakes'
    run_data = home / 'run.toon'
    nm.write_text('#!/usr/bin/env bash\ncase "${1:-}" in\n  daemon) echo "daemon running" ;;\n  axi) cat "' + str(run_data) + '" ;;\n  runs) : ;;\n  *) exit 1 ;;\nesac\n')
    nm.chmod(0o755)
    test_path = str(fakebin) + ':' + env['PATH']
    meta.write_text(meta.read_text().replace('mode=local-only', 'mode=no-mistakes'))
    status.write_text('working [at=1793512999]: validation checkpoint\n')
    current_head = git(worker, 'rev-parse', 'HEAD')
    def instrument(state, outcome=''):
        run_data.write_text('run:\n  id: "01RUN"\n  branch: fm/proof\n  status: ' + state
                           + '\n  head: "' + current_head + '"\n  pr: ""\n  findings: none\n'
                           + ('outcome: ' + outcome + '\n' if outcome else ''))
    instrument('running')
    publish(['done'] * 4 + ['todo', 'todo', 'todo'], phase='validation', gates={4:'pipeline-passed', 5:'integrated'})
    result = run('presentation', 'proof', '--reconcile', extra_env={'PATH':test_path})
    check('pipeline-passed' not in result['lifecycle']['gates'], 'active validation does not fabricate a passing gate')
    instrument('completed')
    result = run('presentation', 'proof', '--reconcile', extra_env={'PATH':test_path})
    check('pipeline-passed' not in result['lifecycle']['gates'], 'completed run without a passing outcome is not validation proof')
    instrument('completed', 'passed')
    result = run('presentation', 'proof', '--reconcile', extra_env={'PATH':test_path})
    check(result['lifecycle']['gates']['pipeline-passed']['head'] == current_head
          and result['presentation']['progress']['steps'][4]['state'] == 'done',
          'real run attribution advances a bound passing gate for the actual run head')
    check(run('presentation', 'proof')['lifecycle']['gates']['pipeline-passed']['head'] == current_head,
          'verified run receipt survives a new process without polling the instrument')
    # Execute the actual generated ship AND scout commands, from another cwd
    # without ambient home, including a home/data path containing spaces.
    space_home = home / 'other home'
    (space_home / 'data').mkdir(parents=True)
    (space_home / 'config').mkdir()
    (space_home / 'data/backlog.md').write_text('## Queued\n- [ ] ship - Ship (repo: alpha)\n- [ ] scout - Scout (repo: alpha)\n')
    brief_env = env | {'FM_HOME': str(space_home)}
    for kind in ('ship', 'scout'):
        flags = ['--mode', 'local-only'] if kind == 'ship' else ['--scout']
        p = execute(['bash', str(root / 'bin/fm-brief.sh'), kind, 'alpha', *flags],
                           env=brief_env, text=True, capture_output=True, timeout=15)
        check(p.returncode == 0, (p.stdout, p.stderr))
        text = (space_home / 'data' / kind / 'brief.md').read_text()
        section = text.split('# Declared progress and safe pauses\n', 1)[1].split('# Firstmate instruction inbox', 1)[0]
        command = re.search(r'^`(.*--presentation-file.*)`$', section, re.M).group(1)
        input_path = space_home / 'data' / kind / 'progress-input.json'
        input_path.write_text(json.dumps({'progress': progress}))
        clean = {k:v for k,v in env.items() if not k.startswith('FM_')}
        p = execute(['bash', '-c', command], cwd=home, env=clean, text=True, capture_output=True, timeout=15)
        check(p.returncode == 0 and json.loads(p.stdout)['presentation']['progress'] == progress,
              ('generated reporting command', kind, p.stdout, p.stderr))
        check(json.loads(input_path.read_text()) == {'progress': progress}, 'scratch input not overwritten by owner envelope')
    # All row probes share one budget. Deliberately leave a child holding
    # captured pipes so a per-process-only timeout would silently become 60s.
    bench = home / 'bounded-home'
    for name in ('data', 'state', 'config', 'fakebin'):
        (bench / name).mkdir(parents=True)
    (bench / 'data/backlog.md').write_text('## Queued\n' + ''.join(
        f'- [ ] row{i} - Task {i} (repo: fixture)\n' for i in range(280)))
    for i in range(20):
        (bench / f'state/row{i}.meta').write_text(f'kind=ship\nmode=local-only\nworktree={bench}/repo-{i}\n')
    slow_git = bench / 'fakebin/git'
    slow_git.write_text('#!/usr/bin/env bash\nsleep 60 &\nwait\n'); slow_git.chmod(0o755)
    started = time.monotonic()
    p = execute(wrapper + ['work', 'snapshot'], env=env | {'FM_HOME':str(bench),
        'PATH':str(bench / 'fakebin') + ':' + env['PATH']}, text=True, timeout=25)
    result = json.loads(p.stdout)
    check(p.returncode == 0 and result.get('schema') == 'fm-work-snapshot.v1'
          and len(result['tasks']) == 280 and time.monotonic() - started < 20,
          '280-row snapshot bounds all slow Git facts together, including child pipe holders')
    check(all(t['progress'] is None for t in result['tasks']) and any(
        'progress-evidence-budget-exhausted' in t['progress_evidence']['reasons'] for t in result['tasks']),
        'instrument budget exhaustion exposes unknown evidence without invented steps')
    print('PASS: %d progress reporting public-path assertions' % checks)
PY
