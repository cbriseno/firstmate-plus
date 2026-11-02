#!/usr/bin/env python3
"""Shared mutation lock for the work owner and its existing backlog wrapper."""
import argparse
import fcntl
import os
from pathlib import Path
import sys
import time


def acquire(data, wait_seconds=0):
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
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise
                time.sleep(min(0.05, remaining))
    except BaseException:
        os.close(fd)
        raise
    return fd


if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--wait-seconds', type=float, default=0)
        parser.add_argument('data')
        parser.add_argument('command', nargs=argparse.REMAINDER)
        args = parser.parse_args()
        if not 0 <= args.wait_seconds <= 5 or not args.command:
            raise ValueError('work lock requires a command and wait of 0..5 seconds')
        fd = acquire(args.data, args.wait_seconds)
        os.set_inheritable(fd, True)
        env = dict(os.environ, FM_WORK_OWNER_FD=str(fd))
        os.execvpe(args.command[0], args.command, env)
    except (OSError, ValueError) as exc:
        print('work mutation busy or unsafe: ' + str(exc), file=sys.stderr)
        sys.exit(1)
