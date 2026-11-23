#!/usr/bin/env python3
"""Shared mutation lock for the work owner and its existing backlog wrapper."""
import argparse
import fcntl
import os
from pathlib import Path
import random
import sys
import time


def acquire(data, wait_seconds=5, *, read_only=False):
    path = Path(data) / '.work.lock'
    if Path(data).is_symlink() or path.is_symlink():
        raise ValueError('unsafe work lock path')
    inherited = os.environ.get('FM_WORK_OWNER_FD', '')
    if inherited.isdigit():
        fd = int(inherited)
        try:
            actual, expected = os.fstat(fd), path.stat()
            if (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino):
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return os.dup(fd)
        except OSError:
            pass
        raise ValueError('invalid inherited work lock')
    access = os.O_RDONLY if read_only else os.O_WRONLY
    mode = fcntl.LOCK_SH if read_only else fcntl.LOCK_EX
    fd = os.open(path, os.O_CREAT | access | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + (0 if read_only else wait_seconds)
        while True:
            try:
                fcntl.flock(fd, mode | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise
                time.sleep(min(random.uniform(0.025, 0.075), remaining))
    except BaseException:
        os.close(fd)
        raise
    return fd


if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--wait-seconds', type=float, default=5)
        parser.add_argument('data')
        parser.add_argument('command', nargs=argparse.REMAINDER)
        args = parser.parse_args()
        if not 0 <= args.wait_seconds <= 5 or not args.command:
            raise ValueError('work lock requires a command and wait of 0..5 seconds')
        fd = acquire(args.data, args.wait_seconds)
        os.set_inheritable(fd, True)
        env = dict(os.environ, FM_WORK_OWNER_FD=str(fd))
        os.execvpe(args.command[0], args.command, env)
    except BlockingIOError as exc:
        print('work mutation busy: ' + str(exc), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError) as exc:
        print('work mutation unsafe: ' + str(exc), file=sys.stderr)
        sys.exit(1)
