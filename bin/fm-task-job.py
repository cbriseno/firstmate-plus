#!/usr/bin/env python3
"""Run an explicit task job outside its worker conversation (Python 3.9+).

Submit: python3 fm-task-job.py STATE TASK NAME COMMAND [ARG...]
The current directory and PATH/HOME/temporary-directory settings are captured.
Other environment comes from the owning watcher, excluding the retiring
process scope and private session bus. Do not put credentials in arguments.
The owning watcher starts the command; NAME must be unique within this task.
STATE/TASK.jobs/NAME.json records pending/starting/running/done/failed, PID and exit code;
NAME.log holds redacted combined output. Poll the record before taking a safe
point, record it in the relay note, and wait for completion before task teardown.
Jobs survive conversation relaunch, not machine restart or task teardown;
--dispatch removes TASK.jobs once TASK.meta is gone and no autodispatch
retry (the one job submitted before TASK.meta exists) is pending or running.
Temporary children should continue using the normal worker process scope.
Internal: --dispatch STATE (owning watcher), --run RECORD (outside worker scope),
--autodispatch STATE TASK HOME CONFIG (queued allocation retry).
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def write(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value))
    tmp.replace(path)


def main():
    if sys.argv[1] == '--autodispatch':
        _, _, state, task, home, config = sys.argv
        if not re.fullmatch(r'[a-zA-Z0-9_-][a-zA-Z0-9._-]*', task):
            raise ValueError('invalid task name')
        directory = Path(state) / (task + '.jobs')
        directory.mkdir(exist_ok=True)
        for path in directory.glob('autodispatch-*.json'):
            previous = json.loads(path.read_text())
            if previous.get('kind') == 'autodispatch' and previous.get('state') in ('pending', 'starting', 'running'):
                return
        env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'GOTMPDIR', 'LANG') if k in os.environ}
        item = dict(kind='autodispatch', state='pending',
                    argv=['bash', str(ROOT / 'fm-autodispatch-retry.sh'), task, home, state, config],
                    cwd=str(ROOT.parent), env=env)
        fd, stage = tempfile.mkstemp(prefix='.autodispatch-', suffix='.submit', dir=directory)
        path = directory / (Path(stage).name[1:-len('.submit')] + '.json')
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(item, stream)
            os.link(stage, path)
        finally:
            os.unlink(stage)
        return
    if sys.argv[1] == '--dispatch':
        for directory in Path(sys.argv[2]).glob('*.jobs'):
            # Only a queued autodispatch retry runs before TASK.meta exists, so
            # without TASK.meta and without a live retry the task was torn down.
            if not (directory.parent / (directory.name[:-5] + '.meta')).exists() and not any(
                    item.get('kind') == 'autodispatch' and item.get('state') in ('pending', 'starting', 'running')
                    for item in (json.loads(path.read_text()) for path in directory.glob('*.json'))):
                shutil.rmtree(directory)
        for path in Path(sys.argv[2]).glob('*.jobs/*.json'):
            item = json.loads(path.read_text())
            if item['state'] != 'pending':
                continue
            if os.environ.get('FM_WORKER_PROCESS_SCOPE'):
                raise RuntimeError('job dispatch must run outside a worker scope')
            item['state'] = 'starting'
            write(path, item)
            try:
                subprocess.Popen([sys.executable, __file__, '--run', str(path)],
                                 start_new_session=True, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError as error:
                item.update(state='failed', error=str(error))
                write(path, item)
        return
    if sys.argv[1] == '--run':
        path = Path(sys.argv[2])
        item = json.loads(path.read_text())
        try:
            with path.with_suffix('.log').open('w') as log:
                redact = subprocess.Popen([sys.executable, str(ROOT / 'fm-redact-log.py')],
                                          stdin=subprocess.PIPE, stdout=log)
                try:
                    child = subprocess.Popen(item['argv'], cwd=item['cwd'], env=dict(os.environ, **item['env']),
                                             stdin=subprocess.DEVNULL, stdout=redact.stdin,
                                             stderr=subprocess.STDOUT)
                    item.update(state='running', pid=child.pid)
                    write(path, item)
                    rc = child.wait()
                finally:
                    redact.stdin.close()
                    redact.wait()
            item.update(state='done' if rc == 0 else 'failed', exit_code=rc)
        except OSError as error:
            item.update(state='failed', error=str(error))
        write(path, item)
        return
    state, task, name, *argv = sys.argv[1:]
    if not argv or not all(re.fullmatch(r'[a-zA-Z0-9_-][a-zA-Z0-9._-]*', s) for s in (task, name)):
        raise ValueError('task, unique job name and command required')
    record = dict(line.split('=', 1) for line in (Path(state) / (task + '.meta')).read_text().splitlines() if '=' in line)
    if record.get('kind') not in ('ship', 'scout', 'host'):
        raise ValueError('job requires a worker task')
    scope = os.environ.get('FM_WORKER_PROCESS_SCOPE')
    if scope and scope != record.get('process_scope'):
        raise ValueError('job scope differs from task metadata')
    directory = Path(state) / (task + '.jobs')
    directory.mkdir(exist_ok=True)
    path = directory / (name + '.json')
    env = {k: os.environ[k] for k in ('PATH', 'HOME', 'TMPDIR', 'GOTMPDIR', 'LANG') if k in os.environ}
    stage = directory / (name + '.submit')
    fd = os.open(stage, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(dict(state='pending', argv=argv, cwd=os.getcwd(), env=env), stream)
        os.link(stage, path)
    finally:
        stage.unlink()
    print(path)


if __name__ == '__main__':
    main()
