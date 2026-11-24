#!/usr/bin/env python3
"""Arm one overseer event wait, deliver its event, and stop it on request."""
import fcntl
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get('FM_HOME') or ROOT)
STATE = Path(os.environ.get('FM_STATE_OVERRIDE') or HOME / 'state') / 'overseer'
LOCK = STATE / 'watch.lock'
CONNECTION_KEYS = ('PATH', 'TMUX', 'TMUX_TMPDIR', 'HERDR_SESSION', 'FM_BACKEND',
                   'FM_OVERSEER_POLL', 'FM_OVERSEER_WAIT')


def lock_file():
    STATE.mkdir(parents=True, exist_ok=True)
    return LOCK.open('a+')


def run(ready):
    lock = lock_file()
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            lock.seek(0)
            lines = lock.read().splitlines()
            if len(lines) > 1 and lines[1] == 'watching':
                os.write(ready, b'already\n')
                os.close(ready)
                return 0
            time.sleep(0.2)
    def phase(value):
        lock.seek(0)
        lock.truncate()
        lock.write(str(os.getpid()) + '\n' + value + '\n')
        lock.flush()
    phase('watching')
    try:
        current_session = (STATE / 'session').read_text(encoding='utf-8').strip()
    except OSError:
        current_session = ''
    if (STATE / 'stopping').exists() or current_session != os.environ.get('FM_OVERSEER_SESSION'):
        os.write(ready, b'failed\n')
        os.close(ready)
        lock.close()
        return 1
    watcher = None
    def terminate(_signum, _frame):
        raise SystemExit(143)
    signal.signal(signal.SIGTERM, terminate)
    try:
        watcher = subprocess.Popen(['bash', str(ROOT / 'bin/fm-overseer-watch.sh')],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True, start_new_session=True)
        if watcher.poll() is not None:
            os.write(ready, b'failed\n')
            return 1
        os.write(ready, b'armed\n')
        os.close(ready)
        output, _ = watcher.communicate()
        lines = output.splitlines()
        if watcher.returncode or len(lines) < 2 or not lines[0].startswith('event_id='):
            return 1
        event_id = lines[0][len('event_id='):]
        if not re.fullmatch(r'[A-Za-z0-9._-]+', event_id):
            return 1
        phase('delivering')
        try:
            backend, target = (STATE / 'session').read_text().split()
        except (OSError, ValueError):
            return 1
        message = 'Overseer event: read state/overseer/pending-event in firstmate-home.'
        command = '. "$1/fm-backend.sh"; fm_backend_send_text_submit "$2" "$3" "$4" 3 0.5 1'
        while True:
            sender = subprocess.Popen(['bash', '-c', command, 'overseer-event', str(ROOT / 'bin'),
                                       backend, target, message], stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                output, _ = sender.communicate()
            finally:
                if sender.poll() is None:
                    try:
                        os.killpg(sender.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    sender.wait()
            verdict = output.strip()
            if sender.returncode == 0 and verdict == 'empty':
                return 0
            if sender.returncode == 0 and verdict == 'send-failed':
                time.sleep(30)
                continue
            # The text may already be in the composer or in a queued turn.
            # Never type it a second time without resolving that uncertainty.
            (STATE / 'unconfirmed-event').write_text(event_id + '\n', encoding='utf-8')
            return 1
    finally:
        if watcher and watcher.poll() is None:
            try:
                os.killpg(watcher.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            watcher.wait()
        lock.close()


def arm(quiet=False):
    if (STATE / 'stopping').exists():
        print('overseer session is stopping', file=sys.stderr)
        return 1
    if (STATE / 'unconfirmed-event').exists():
        print('event delivery is unconfirmed; inspect the recorded session before any retry', file=sys.stderr)
        return 1
    if not (ROOT / 'bin/fm-overseer-watch.sh').is_file():
        print('overseer watch is unavailable', file=sys.stderr)
        return 1
    try:
        connection = json.loads((STATE / 'session-env.json').read_text(encoding='utf-8'))
        if not isinstance(connection, dict) or any(not isinstance(connection.get(key), str) for key in CONNECTION_KEYS):
            raise ValueError('invalid connection context')
    except (OSError, ValueError, TypeError):
        print('overseer session connection context is unavailable', file=sys.stderr)
        return 1
    try:
        session = (STATE / 'session').read_text(encoding='utf-8').strip()
    except OSError:
        print('overseer session is unavailable', file=sys.stderr)
        return 1
    if not session:
        print('overseer session is unavailable', file=sys.stderr)
        return 1
    for key in CONNECTION_KEYS:
        os.environ[key] = connection[key]
    os.environ['FM_OVERSEER_SESSION'] = session
    read_fd, write_fd = os.pipe()
    try:
        child = subprocess.Popen([sys.executable, __file__, 'run', str(write_fd)],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True,
                                 pass_fds=(write_fd,))
        os.close(write_fd)
        write_fd = -1
        ready, _, _ = select.select([read_fd], [], [], 75)
        response = os.read(read_fd, 32).decode().strip() if ready else ''
        if response in ('armed', 'already'):
            if not quiet:
                print('overseer watch ' + response)
            return 0
        if not ready:
            child.terminate()
            child.wait()
        print('overseer watch did not confirm readiness', file=sys.stderr)
        return 1
    finally:
        os.close(read_fd)
        if write_fd >= 0:
            os.close(write_fd)


def stop():
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
        prefix, separator, _ = result.stdout.strip().rpartition(' run ')
        interpreter, space, script = prefix.partition(' ')
        if (result.returncode or not separator or not space or not interpreter or
                Path(script.strip()).resolve() != Path(__file__).resolve()):
            print('overseer watch identity cannot be verified', file=sys.stderr)
            return 1
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


def status():
    if (STATE / 'unconfirmed-event').exists():
        print('event: delivery unconfirmed; inspect the recorded session before any retry')
    if (STATE / 'pending-event').exists():
        print('event: pending delivery or acknowledgement')
    if not LOCK.exists():
        print('watch: not armed')
        return
    with LOCK.open('r') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock.seek(0)
            lines = lock.read().splitlines()
            print('watch: delivering' if len(lines) > 1 and lines[1] == 'delivering' else 'watch: armed')
        else:
            print('watch: not armed')


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == 'arm':
        sys.exit(arm())
    if len(sys.argv) == 2 and sys.argv[1] == 'stop':
        sys.exit(stop())
    if len(sys.argv) == 2 and sys.argv[1] == 'guard':
        if (STATE / 'pending-event').exists():
            print('A watch event is pending; read and handle it, then acknowledge its ID before ending the turn.', file=sys.stderr)
            sys.exit(2)
        try:
            (STATE / 'unconfirmed-event').unlink(missing_ok=True)
        except OSError:
            print('Could not clear the resolved delivery state.', file=sys.stderr)
            sys.exit(2)
        if arm(quiet=True):
            print('Overseer watch could not be armed; inspect the installation before ending this turn.', file=sys.stderr)
            sys.exit(2)
        sys.exit(0)
    if len(sys.argv) == 2 and sys.argv[1] == 'status':
        status()
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == 'run':
        sys.exit(run(int(sys.argv[2])))
    sys.exit('usage: fm-overseer-arm.py arm|stop')
