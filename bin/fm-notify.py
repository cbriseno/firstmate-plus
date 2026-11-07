#!/usr/bin/env python3
"""Optional notification command, disabled unless configured by the installation.

Usage: python3 bin/fm-notify.py --home HOME --event EVENT --text TEXT
config/notification-command.json is a JSON argv array. An explicit absolute
--command-file can select an installation adapter for this invocation only;
it changes no configuration and is never supplied by a model. No shell is involved.
The command receives EVENT and TEXT as its final arguments and a JSON record on
stdin. It has a five-second deadline. Missing configuration is a successful no-op.
Exit 0: disabled or command accepted; 1: failed command; 2: invalid input/config.
Success never asserts delivery to a device. No hooks or services are installed.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--command-file', type=Path)
    parser.add_argument('--event', required=True)
    parser.add_argument('--text', required=True)
    args = parser.parse_args()
    if not args.home.is_absolute() or not args.event or len(args.event) > 80 or not args.text or len(args.text) > 240 or any(ord(c) < 32 for c in args.event + args.text):
        parser.error('absolute home and bounded single-line event/text are required')
    if args.command_file is not None and not args.command_file.is_absolute():
        parser.error('command file must be absolute')
    try:
        command = json.loads((args.command_file or args.home / 'config/notification-command.json').read_text(encoding='utf-8'))
    except FileNotFoundError:
        return 2 if args.command_file else 0
    except (OSError, ValueError):
        print('notification: invalid command configuration', file=sys.stderr)
        return 2
    if not isinstance(command, list) or not command or any(not isinstance(v, str) or not v or '\0' in v for v in command):
        print('notification: command must be a nonempty JSON argv array', file=sys.stderr)
        return 2
    try:
        result = subprocess.run(command + [args.event, args.text], input=json.dumps(dict(event=args.event, text=args.text)), text=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 0 if result.returncode == 0 else 1
    except (OSError, subprocess.TimeoutExpired):
        return 1


if __name__ == '__main__':
    sys.exit(main())
