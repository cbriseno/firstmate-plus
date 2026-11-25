#!/usr/bin/env python3
"""Optional notification command, disabled unless configured by the installation.

Usage: python3 bin/fm-notify.py --home HOME --event EVENT --text TEXT [--link URL]
config/notification-command.json is a JSON argv array. An explicit absolute
--command-file can select an installation adapter for this invocation only;
it changes no configuration and is never supplied by a model. No shell is involved.
The command receives EVENT and TEXT as its final arguments and a JSON record on
stdin; an optional absolute http(s) --link is passed only in that record.
It has a five-second deadline. For overseer-alert, the command must first record
delivery acceptance at its destination and then print one JSON object with
"event": "overseer-alert" and "receipt": a reference to that record (1 to 200
ASCII letters/digits and ._:-, starting with a letter or digit). No secrets.
Firstmate returns the validated object on stdout. A missing command, failed
command, or missing/invalid receipt for this event returns 1. For other events,
missing configuration is a successful no-op and command exit 0 is sufficient.
Exit 2 indicates invalid input/config. Receipt means destination acceptance.

Optional quiet hours: config/notification-quiet-hours holds one line HH:MM-HH:MM in
local time (for example 23:00-07:00, which may span midnight). While inside it, an
event sent with the configured command is held in state/notification-held.jsonl.
Held alerts return 1 with a pending-delivery message. On flush, each held alert
is sent intact and kept pending until it has a receipt. Other events keep their
existing quiet-digest behavior. `--home HOME --flush` delivers without a new
event; the overseer watch calls it when the window ends. A missing or invalid file
means no quiet hours. FM_NOTIFY_NOW=HH:MM replaces the clock for tests.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys

RECEIPT_EVENTS = {'overseer-alert'}


def quiet_now(home):
    try:
        start, end = (datetime.strptime(p, '%H:%M') for p in (home / 'config/notification-quiet-hours').read_text(encoding='utf-8').strip().split('-'))
        now = datetime.strptime(os.environ.get('FM_NOTIFY_NOW') or datetime.now().strftime('%H:%M'), '%H:%M')
    except (OSError, ValueError):
        return False
    return start <= now < end if start <= end else now >= start or now < end


def held_file(home):
    return Path(os.environ.get('FM_STATE_OVERRIDE') or home / 'state') / 'notification-held.jsonl'


def deliver(command, event, text, link=None, *, emit_receipt=True):
    requires_receipt = event in RECEIPT_EVENTS
    try:
        result = subprocess.run(
            command + [event, text], input=json.dumps(dict(event=event, text=text, **({'link': link} if link else {}))),
            text=True, timeout=5, stdout=subprocess.PIPE if requires_receipt else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            if not requires_receipt:
                return True
            response = json.loads(result.stdout)
            if isinstance(response, dict) and response.get('event') == event:
                receipt = response.get('receipt')
                if isinstance(receipt, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,199}', receipt):
                    if emit_receipt:
                        print(json.dumps(dict(event=event, receipt=receipt)))
                    return True
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    if requires_receipt:
        print(f'notification: {event} has no valid delivery receipt', file=sys.stderr)
    return False


def flush_held(home, command, *, emit_receipts):
    held, taken = held_file(home), held_file(home).with_suffix('.sending')
    try:
        os.replace(held, taken)
    except OSError:
        return True
    pending = []
    digest = []
    for line in taken.read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        if entry['event'] in RECEIPT_EVENTS:
            if not deliver(command, entry['event'], entry['text'], emit_receipt=emit_receipts):
                pending.append(entry)
        else:
            digest.append(entry)
    if digest:
        event, text = digest[0]['event'], digest[0]['text']
        if len(digest) > 1:
            os.environ['FM_HOME'] = str(home)
            from fm_progress import tr
            event = 'quiet-digest'
            text = '%d %s: ' % (len(digest), tr('held during quiet hours')) + ' | '.join(e['text'] for e in digest)
        if not deliver(command, event, text[:239] + '…' if len(text) > 240 else text):
            pending.extend(digest)
    if pending:
        with held.open('a', encoding='utf-8') as out:
            out.writelines(json.dumps(entry) + '\n' for entry in pending)
    taken.unlink()
    return not pending


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
        if args.event in RECEIPT_EVENTS:
            print(f'notification: {args.event} requires a configured delivery command', file=sys.stderr)
            return 1
        return 2 if args.command_file else 0
    except (OSError, ValueError):
        print('notification: invalid command configuration', file=sys.stderr)
        return 2
    if not isinstance(command, list) or not command or any(not isinstance(v, str) or not v or '\0' in v for v in command):
        print('notification: command must be a nonempty JSON argv array', file=sys.stderr)
        return 2
    if args.command_file is None:
        quiet = quiet_now(args.home)
        if quiet and not args.flush:
            held_file(args.home).parent.mkdir(parents=True, exist_ok=True)
            with held_file(args.home).open('a', encoding='utf-8') as out:
                out.write(json.dumps(dict(event=args.event, text=args.text)) + '\n')
            if args.event in RECEIPT_EVENTS:
                print(f'notification: {args.event} held during quiet hours; delivery pending', file=sys.stderr)
                return 1
            return 0
        if not quiet and not flush_held(args.home, command, emit_receipts=args.flush) and args.flush:
            return 1
    if args.flush:
        return 0
    return 0 if deliver(command, args.event, args.text, args.link) else 1


if __name__ == '__main__':
    sys.exit(main())
