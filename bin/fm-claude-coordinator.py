#!/usr/bin/env python3
"""Opt-in controlled Claude coordinator pilot (Linux/macOS; no configuration edits).

Usage: fm-claude-coordinator.py --home ABS --task ID --repo NAME --project ABS
JSON lines on stdin: {op: dispatch|correct|result|status|mkdir|ack|quit, text?: string}.
mkdir additionally requires name (one literal leaf under data/ID/operations).
ack additionally requires outcome (a shown sequence already acted on); the existing
outcome owner performs its read/processed transition.
A pre-existing backlog item and concrete --model/--effort are required for Claude.
The pilot ships local-only, yolo off; it grants no merge or discard authority.
The coordinator is mechanical; technical content goes only to the Claude worker.
Only this application publishes the worker's report, without a primary model rewrite.
Corrections go verbatim to the existing brief and task inbox. Restart uses meta.
No free shell, helper argv, result paths, slash commands, or primary-model resume channel.
The application's lifetime bounds supervision; closing it ends this pilot.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BIN = Path(__file__).resolve().parent
VERBS = ('dispatch', 'correct', 'result', 'status', 'mkdir', 'ack', 'quit')
ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('home', 'task', 'repo', 'project'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--scout', action='store_true', help='Explicit knowledge-only task, without project edits.')
    p.add_argument('--model', required=True)
    p.add_argument('--effort', default='low', choices=['low', 'medium', 'high', 'xhigh'])
    a = p.parse_args()
    if not Path(a.home).is_absolute() or not Path(a.project).is_absolute() or not ID.fullmatch(a.task) or not ID.fullmatch(a.repo):
        p.error('absolute home/project and literal task/repository IDs required')
    home = Path(a.home).resolve()
    data, state = home / 'data' / a.task, home / 'state'
    brief, meta = data / 'brief.md', state / (a.task + '.meta')
    if any(path.is_symlink() for path in (home / 'data', state, data, brief, meta)):
        p.error('pilot paths must be local regular task paths')
    env = os.environ | {'FM_HOME': str(home), 'FM_SUPERVISION_HOST_PRIMARY': 'claude'}
    # The child model cannot inherit the enclosing worker's identity or inbox.
    for key in ('FM_TASK_ID', 'FM_TASK_INBOX', 'CLAUDECODE', 'CLAUDE_CODE_SESSION_ID'):
        env.pop(key, None)
    env['FM_PRIMARY_HARNESS'] = 'claude'

    def publish(value):
        value['supervision'] = health.status
        value['attention'] = health.pending
        print(json.dumps(value), flush=True)

    def command(script, *args, text=None):
        r = subprocess.run(['bash', str(BIN / script), *args], input=text, text=True,
                           capture_output=True, env=env, timeout=180)
        if r.returncode:
            raise RuntimeError(r.stderr.strip() or r.stdout.strip() or script + ' failed')
        return r.stdout

    data.mkdir(parents=True, exist_ok=True)
    command('fm-lock.sh')
    from fm_coordinator_health import Health
    health = Health(home, env)
    try:
        health.start()
        for line in sys.stdin:
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError('request must be an object')
                op = request.get('op')
                if op not in VERBS or set(request) - {'op', 'text', 'name', 'outcome'}:
                    raise ValueError('unsupported request; use the documented verbs')
                if op == 'quit':
                    break
                # Routing is mechanical: there is no primary model to design a solution
                # or rewrite the worker's result. Technical content goes only to its owner.
                if op in ('dispatch', 'correct'):
                    text = request.get('text')
                    if not isinstance(text, str) or not text.strip() or len(text) > 32768:
                        raise ValueError('nonempty original text up to 32768 characters required')
                    if '\n## Firstmate spec' in text or '\n## Captain' in text:
                        raise ValueError('request contains a reserved brief delimiter; preserve it outside this pilot')
                    command('fm-host-mirror.sh', 'hook', 'claude', text=json.dumps(
                        {'hook_event_name': 'UserPromptSubmit', 'prompt': text}))
                    if op == 'dispatch':
                        if meta.exists() or brief.exists():
                            raise ValueError('task already has instructions; use correct or result')
                        command('fm-brief.sh', a.task, a.repo, *(['--scout'] if a.scout else ['--project', a.project, '--mode', 'local-only']))
                        scaffold = brief.read_text()
                        brief.write_text(scaffold.replace('{FIRSTMATE_SPEC}',
                            ('Investigate the original request without project edits. ' if a.scout else 'Implement the original request. ') +
                            'Choose the technical approach yourself.\n'
                            'Write the technical result to this task\'s report.md before reporting readiness.').replace('{TASK}', text))
                        command('fm-spawn.sh', a.task, a.project, *(['--scout'] if a.scout else ['--mode', 'local-only', '--yolo', 'off']),
                                '--harness', 'claude', '--model', a.model, '--effort', a.effort)
                    else:
                        if not meta.exists():
                            raise ValueError('task has not been dispatched')
                        body = brief.read_text()
                        marker = '\n## Firstmate spec'
                        if body.count(marker) != 1:
                            raise ValueError('ambiguous brief; preserve it for its owner')
                        brief.write_text(body.replace(marker, '\n' + text + '\n' + marker, 1))
                        command('fm-send.sh', a.task, text)
                    publish({'op': op, 'recorded': True})
                elif op == 'ack':
                    seq = request.get('outcome')
                    if type(seq) is not int or not any(row['seq'] == seq for row in health.pending):
                        raise ValueError('one shown outcome sequence required, after acting on it')
                    command('fm-branch-outcome.sh', 'mark-read', '--through', str(seq))
                    command('fm-branch-outcome.sh', 'mark-processed', '--through', str(seq))
                    publish({'op': op, 'processed': seq})
                elif op == 'mkdir':
                    name = request.get('name', '')
                    if not isinstance(name, str) or not ID.fullmatch(name) or name in ('.', '..'):
                        raise ValueError('one literal directory name required')
                    directory = data / 'operations'
                    directory.mkdir(exist_ok=True)
                    if directory.is_symlink():
                        raise ValueError('operations directory must belong to this task')
                    (directory / name).mkdir(exist_ok=True)
                    publish({'op': op, 'exists': (directory / name).is_dir()})
                elif op == 'result':
                    if not meta.exists():
                        raise ValueError('task has not been dispatched')
                    from fm_delivery import read_text
                    report = read_text(home, 'data/' + a.task + '/report.md', 262144)
                    publish({'op': op, 'author': 'worker', 'text': report})
                else:
                    publish({'op': op, 'dispatched': meta.exists()})
            except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as e:
                publish({'error': str(e)})
    finally:
        health.close()


if __name__ == '__main__':
    main()
