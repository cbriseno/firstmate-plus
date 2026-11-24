#!/usr/bin/env python3
"""Optional notification command, disabled unless configured by the installation.

Usage: python3 bin/fm-notify.py --home HOME --event EVENT --text TEXT [--link URL]
config/notification-command.json is a JSON argv array. An explicit absolute
--command-file can select an installation adapter for this invocation only;
it changes no configuration and is never supplied by a model. No shell is involved.
The command receives EVENT and TEXT as its final arguments and a JSON record on
stdin; an optional absolute http(s) --link is passed only in that record.
It has a five-second deadline. Missing configuration is a successful no-op.
Exit 0: disabled or command accepted; 1: failed command; 2: invalid input/config.
Success never asserts delivery to a device. No hooks or services are installed.

Optional quiet hours: config/notification-quiet-hours holds one line HH:MM-HH:MM in
local time (for example 23:00-07:00, which may span midnight). While inside it, an
event sent with the configured command is held in state/notification-held.jsonl
(exit 0) and delivered once, as one quiet-digest event, by the next call outside the
window. `--home HOME --flush` delivers it without a new event; the overseer watch
calls that, so the digest arrives when the window ends. A missing or invalid file
means no quiet hours. FM_NOTIFY_NOW=HH:MM replaces the clock for tests.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys


def quiet_now(home):
    try:
        start, end = (datetime.strptime(p, '%H:%M') for p in (home / 'config/notification-quiet-hours').read_text(encoding='utf-8').strip().split('-'))
        now = datetime.strptime(os.environ.get('FM_NOTIFY_NOW') or datetime.now().strftime('%H:%M'), '%H:%M')
    except (OSError, ValueError):
        return False
    return start <= now < end if start <= end else now >= start or now < end


def held_file(home):
    return Path(os.environ.get('FM_STATE_OVERRIDE') or home / 'state') / 'notification-held.jsonl'


def deliver(command, event, text, link=None):
    try:
        result = subprocess.run(command + [event, text], input=json.dumps(dict(event=event, text=text, **({'link': link} if link else {}))), text=True, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def flush_held(home, command):
    held, taken = held_file(home), held_file(home).with_suffix('.sending')
    try:
        os.replace(held, taken)
    except OSError:
        return True
    raw = taken.read_text(encoding='utf-8')
    held_events = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if len(held_events) == 1:
        # One notice needs no digest: deliver it whole, under its own event.
        event, text = held_events[0]['event'], held_events[0]['text']
    else:
        os.environ['FM_HOME'] = str(home)
        from fm_progress import tr
        event = 'quiet-digest'
        text = '%d %s: ' % (len(held_events), tr('held during quiet hours')) + ' | '.join(e['text'] for e in held_events)
    if deliver(command, event, text[:239] + '…' if len(text) > 240 else text):
        taken.unlink()
        return True
    with held.open('a', encoding='utf-8') as out:
        out.write(raw)
    taken.unlink()
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--command-file', type=Path)
    parser.add_argument('--event')
    parser.add_argument('--text')
    parser.add_argument('--flush', action='store_true')
    parser.add_argument('--link')
    args = parser.parse_args()
    if args.flush and (args.event or args.text or args.command_file):
        parser.error('--flush takes only --home')
    if not args.flush and not (args.event and args.text):
        parser.error('--event and --text are required')
    args.event, args.text = args.event or '', args.text or ''
    if not args.home.is_absolute() or len(args.event) > 80 or len(args.text) > 240 or any(ord(c) < 32 for c in args.event + args.text):
        parser.error('absolute home and bounded single-line event/text are required')
    if args.link is not None and (not args.link.startswith(('http://', 'https://')) or len(args.link) > 500 or any(c.isspace() or ord(c) < 32 for c in args.link)):
        parser.error('link must be one absolute http(s) URL without spaces')
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
    if args.command_file is None:
        if quiet_now(args.home) and not args.flush:
            held_file(args.home).parent.mkdir(parents=True, exist_ok=True)
            with held_file(args.home).open('a', encoding='utf-8') as out:
                out.write(json.dumps(dict(event=args.event, text=args.text)) + '\n')
            return 0
        if not quiet_now(args.home) and not flush_held(args.home, command) and args.flush:
            return 1
    if args.flush:
        return 0
    return 0 if deliver(command, args.event, args.text, args.link) else 1


if __name__ == '__main__':
    sys.exit(main())
