#!/usr/bin/env bash
# Actionable progress notices respect the existing work owner's holds while
# active workers and ordinary paused validation/background waits still report.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile, time
root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='fm-progress-holds-') as tmp:
    home = pathlib.Path(tmp)
    for name in ('data', 'state', 'config'):
        (home / name).mkdir()
    names = ['active', 'background', 'parked', 'inherited', 'layered', 'resumed', 'captain']
    (home / 'data/projects.md').write_text('- alpha [local-only] - Fixture\n- held [local-only] - Held group\n')
    (home / 'data/backlog.md').write_text('## Queued\n' + ''.join(
        '- [ ] ' + name + ' - Fixture ' + name + ' (repo: ' + ('held' if name == 'inherited' else 'alpha') + ')\n'
        for name in names))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_'))}
    env.update(FM_HOME=str(home), FM_SIGNAL_GRACE='0', FM_LIVE='0')
    wrapper = ['bash', str(root / 'bin/fm-tasks-axi.sh')]
    checks = 0
    def check(value, message):
        global checks
        assert value, message
        checks += 1
    def execute(argv, body=None):
        # File capture avoids waiting on pipe descriptors inherited by an
        # optional short-lived helper after the public command has returned.
        with tempfile.TemporaryFile(mode='w+') as out, tempfile.TemporaryFile(mode='w+') as err:
            p = subprocess.run(argv, env=env, input=json.dumps(body) if body else None,
                text=True, stdout=out, stderr=err, timeout=25)
            out.seek(0); err.seek(0)
            text = out.read()
            check(p.returncode == 0, (argv, text, err.read()))
            return text
    def cli(*args, body=None):
        text = execute(wrapper + list(args), body)
        return json.loads(text) if text.lstrip().startswith('{') else text
    def apply(name, target):
        snap = cli('work', 'snapshot')
        payload = dict(op=name, target=target, expected_rev=snap['rev'], actor='captain',
                       request_id='hold-progress-' + name + '-' + target.replace(':', '-'))
        if name == 'set_pause':
            payload['reason'] = 'Authorized fixture pause'
        result = cli('work', 'apply', body=payload)
        check(result.get('state') == 'applied', result)
    def notices():
        text = cli('progress-check')
        check(isinstance(text, str), text)
        return {line.split(':', 1)[0]:line for line in text.splitlines()}
    (home / 'state/startup.meta').write_text('kind=scout\n')
    (home / 'state/startup.status').touch()
    check('startup' not in notices(), 'startup dialog with empty status owes no worker checkpoint')
    prior = 'working: previous worker attempt\n'
    (home / 'state/relaunch.meta').write_text('kind=scout\nstatus_start_bytes=%d\n' % len(prior))
    (home / 'state/relaunch.status').write_text(prior)
    check('relaunch' not in notices(), 'relaunch dialog does not inherit the prior attempt reporting obligation')
    for name in names:
        (home / 'state' / (name + '.meta')).write_text('kind=scout\n')
        (home / 'state' / (name + '.status')).write_text(
            'paused [at=1793510000]: ordinary validation/background wait\n' if name == 'background'
            else 'working [at=1793510000]: fixture work\n')
    for name in ('parked', 'resumed'):
        cli('hold', name, '--kind', 'parked', '--reason', 'Parked by owner')
    cli('hold', 'layered', '--kind', 'external', '--reason', 'Retained external condition')
    execute(['bash', str(root / 'bin/fm-captain-hold.sh'), 'hold', 'captain', '--title', 'Fixture captain',
        '--reason', 'Deliberately held', '--question', 'Keep this paused?', '--option', 'yes=Keep', '--option', 'no=Release'])
    apply('set_pause', 'project:held')
    apply('set_pause', 'task:layered')
    seed = home / 'aliases.json'
    seed.write_text(json.dumps(dict(schema='fm-work-alias-seed.v1', home=str(home),
        entries=[dict(key='task:active', alias='T-ABC', primary=True)])))
    cli('work', 'aliases-init', '--map', str(seed), '--request-id', 'progress-holds-aliases-01')
    protected = ['data/backlog.md', 'data/work-structure.json', 'data/work-aliases.json']
    baseline = {path:(home / path).read_bytes() for path in protected}
    first = notices()
    check(set(first) == {'active', 'background'}, ('held records suppressed; active/waiting kept', first))
    check(all((home / path).read_bytes() == value for path,value in baseline.items()),
          'notice read preserves all holds, groups, aliases and backlog bytes')
    check(all(not (home / 'data' / name / 'presentation.json').exists() for name in names),
          'notice filtering never fabricates a legacy checkpoint')
    # A real owner resume removes the hold. The obligation now resurfaces,
    # without sending anything to a worker or altering the remaining holds.
    apply('clear_pause', 'task:resumed')
    check(set(notices()) == {'active', 'background', 'resumed'}, 'legitimate resumed task owes its initial checkpoint')
    apply('clear_pause', 'project:held')
    check('inherited' in notices(), 'cleared inherited hold restores reporting obligation')
    draft = home / 'current-input.json'
    draft.write_text(json.dumps(dict(phase='investigation', progress=dict(steps=[dict(label='Inspect', state='active')]))))
    for name in ('active', 'background', 'resumed', 'inherited'):
        receipt = cli('presentation', name, '--presentation-file', str(draft))
        check(receipt.get('ok') and receipt['lifecycle']['evidence']['current'], 'explicit checkpoint accepted')
    check(notices() == {}, 'legitimate current checkpoints clear notices without lifting other holds')
    for name, verb in (('active', 'working'), ('background', 'paused')):
        with (home / 'state' / (name + '.status')).open('a') as stream:
            stream.write(verb + ' [at=1793511000]: next real reporting boundary\n')
    current = notices()
    check(set(current) == {'active', 'background'} and all('stale' in line for line in current.values()),
          'active and paused-background missed checkpoints remain actionable')
    check(all(not (home / 'data' / name / 'presentation.json').exists() for name in ('parked', 'captain', 'layered')),
          'held legacy declarations remain unmeasured and untouched')
    status = home / 'state/active.status'
    with status.open('a') as stream:
        stream.write('needs-decision [key=review]: captain reviews the board\n')
    check('active' not in notices(), 'open captain decision owes no progress wake')
    with status.open('a') as stream:
        stream.write('resolved [key=review]: approved\nworking: resumed\n')
    check('active' in notices(), 'resolved decision restores missed-checkpoint wake')
    cli('presentation', 'active', '--presentation-file', str(draft))
    with status.open('a') as stream:
        stream.write('working: next boundary just after publication\n')
    old = time.time() - 60
    for path in (status, home / 'state/active.meta'):
        os.utime(path, (old, old))
    env['FM_SIGNAL_GRACE'] = '30'
    check('active' not in notices(), 'just-published checkpoint retains existing grace')
    (home / 'state/new.meta').write_text('kind=scout\n')
    (home / 'state/new.status').write_text('working: just launched\n')
    check('new' not in notices(), 'just-launched worker retains existing grace')
    env['FM_SIGNAL_GRACE'] = '0'
    check('active' in notices() and 'new' in notices(), 'expired grace preserves real reporting obligations')
    print('PASS: %d progress hold public-path assertions' % checks)
PY
