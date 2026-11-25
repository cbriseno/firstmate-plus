"""Live demand from the host test-slot owners, including runs waiting for a slot."""
import fcntl
import math
import os
from pathlib import Path
import stat
import time


def prefix():
    return f'firstmate-test-{os.getuid()}-'


def locked_text(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'rb') as stream:
            info = os.fstat(descriptor)
            if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
                return []
            try:
                fcntl.flock(stream, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BlockingIOError:
                return stream.read(128).decode('ascii').split()
    except (OSError, UnicodeError):
        pass
    return []


def sample():
    directory = Path(os.environ.get('FM_TEST_LOCK_DIR', '/tmp'))
    running, capacities, priority = set(), {}, set()
    waiting_since = {}
    occupied = 0
    for path in directory.glob(prefix() + '[0-9]*.lock'):
        if (owner := locked_text(path)) and owner[0].isdecimal():
            running.add(owner[0])
            occupied += 1
    for path in directory.glob(prefix() + 'run-*'):
        record = locked_text(path)
        if len(record) in (4, 5) and record[0].isdecimal() and record[1].isdecimal():
            runner, slots, started, published = record[:4]
            try:
                started = float(started)
            except ValueError:
                continue
            if not math.isfinite(started) or int(slots) < 1:
                continue
            capacities[runner] = int(slots)
            # Legacy records infer from host locks. New holders also report
            # borrowed nested slots and waiting turns from already active runs.
            waiting = record[4] == '0' if len(record) == 5 else runner not in running
            if waiting:
                waiting_since[runner] = min(waiting_since.get(runner, started), started)
            if published == '1':
                priority.add(runner)
    if not capacities:
        return None
    now = time.time()
    waiting = {runner: max(0, int(now - started)) for runner, started in waiting_since.items()}
    return dict(runs=len(capacities.keys() | running), slots=max(capacities.values()),
                occupied=occupied, waiting_runs=len(waiting),
                oldest_wait_s=max(waiting.values(), default=None),
                priority_wait_s=max((waiting[runner] for runner in waiting.keys() & priority), default=None))


if __name__ == '__main__':
    if state := sample():
        print(state['slots'], state['occupied'], state['waiting_runs'])
