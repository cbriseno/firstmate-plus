#!/usr/bin/env python3
"""Own a session's background watch and retire watches from the old Stop hook.

Usage: fm-overseer-arm.py watch [RELAY --ready DIRECTORY START_FILE] | stop |
                          stop-legacy | status | locked | remove-hook FILE [--check]
"""
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get('FM_HOME') or ROOT)
STATE = Path(os.environ.get('FM_STATE_OVERRIDE') or HOME / 'state') / 'overseer'
LOCK = STATE / 'watch.lock'


def lock_file():
    STATE.mkdir(parents=True, exist_ok=True)
    return LOCK.open('a+')


def watch(ready):
    with lock_file() as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('overseer watch already running', file=sys.stderr)
            return 1
        if (STATE / 'stopping').exists():
            return 1
        lock.truncate(0)
        lock.write(f'{os.getpid()}\nsession-watch\n')
        lock.flush()

        def terminate(_signum, _frame):
            raise SystemExit(143)

        signal.signal(signal.SIGTERM, terminate)
        child = subprocess.Popen(['bash', str(ROOT / 'bin/fm-overseer-watch.sh')],
                                 env={**os.environ, 'FM_OVERSEER_WATCH_OWNER': str(os.getpid())},
                                 start_new_session=True)
        try:
            if ready:
                subprocess.run([*ready, str(os.getpid())], stdout=sys.stderr, check=True, timeout=30)
            return child.wait()
        finally:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                child.wait()


def stop(legacy_only=False):
    if not LOCK.exists():
        return 0
    lock = lock_file()
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return 0
        except BlockingIOError:
            lock.seek(0)
            raw = lock.readline().strip()
        if not raw.isdecimal():
            print('overseer watch identity is unreadable', file=sys.stderr)
            return 1
        pid = int(raw)
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'args='], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        # Old processes say 'run FD'; the native background task says 'watch'.
        match = re.fullmatch(r'\S+ (.+?) (run [0-9]+|watch(?: .*)?)', result.stdout.strip())
        if (result.returncode or not match or
                Path(match[1]).resolve() != Path(__file__).resolve()):
            print('overseer watch identity cannot be verified', file=sys.stderr)
            return 1
        if legacy_only and not match[2].startswith("run "):
            return 0
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        for _ in range(100):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return 0
            except BlockingIOError:
                time.sleep(0.1)
        print('overseer watch did not stop', file=sys.stderr)
        return 1
    finally:
        lock.close()


def locked():
    if not LOCK.exists():
        return False
    with LOCK.open('r') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return False
        except BlockingIOError:
            return True


def status():
    if (STATE / 'pending-event').exists():
        print('event: pending acknowledgement')
    if LOCK.exists():
        with LOCK.open('r') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                lines = lock.read().splitlines()
                if lines[1:2] == ['session-watch']:
                    print('watch: armed')
                else:
                    print('watch: legacy (run setup to retire it)')
                return
    print('watch: not armed')


def remove_hook(path, check):
    """Remove only the generated Stop command, preserving adjacent settings."""
    if path.is_symlink():
        raise ValueError(f'{path} is a symlink')
    if not path.exists():
        return
    mode = path.stat().st_mode
    if not stat.S_ISREG(mode):
        raise ValueError(f'{path} is not a regular file')
    data = json.loads(path.read_text(encoding='utf-8'))
    mapping = data.get('hooks', {})
    if 'Stop' not in mapping:
        return

    def legacy(hook):
        if hook.get('type') != 'command':
            return False
        try:
            args = shlex.split(hook.get('command', ''))
        except ValueError:
            return False
        return (len(args) >= 5 and args[0] == 'env' and args[1].startswith('FM_HOME=')
                and args[-3] == 'python3' and args[-2].endswith('/bin/fm-overseer-arm.py')
                and args[-1] == 'guard')

    entries = []
    for group in mapping['Stop']:
        hooks = [hook for hook in group['hooks'] if not legacy(hook)]
        if hooks:
            entries.append({**group, 'hooks': hooks})
    if entries == mapping['Stop'] or check:
        return
    if entries:
        mapping['Stop'] = entries
    else:
        del mapping['Stop']
        if not mapping:
            del data['hooks']
    if not data:
        path.unlink()
        return
    with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(data, stream, indent=2)
            stream.write('\n')
            stream.close()
            temporary.chmod(stat.S_IMODE(mode))
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    action, *args = sys.argv[1:] or ['help']
    try:
        if action == 'watch':
            sys.exit(watch(args))
        if action in ('stop', 'stop-legacy'):
            sys.exit(stop(legacy_only=action == 'stop-legacy'))
        if action == 'locked':
            sys.exit(0 if locked() else 3)
        if action == 'status':
            status()
        elif action == 'remove-hook':
            remove_hook(Path(args[0]), args[1:] == ['--check'])
        elif action == 'guard':
            # Already open Claude and Codex sessions may still invoke this hook.
            pass
        else:
            sys.exit(__doc__)
    except (OSError, AttributeError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
