#!/usr/bin/env python3
"""Tell the captain, through the optional notification command, that something waits on them.

Usage:
  fm-captain-notice.py --home HOME --kind question|approval|action|review|board (--task ID | --title TEXT)
                       [--title TEXT] [--detail TEXT] [--occurrence ID] [--link URL]
  fm-captain-notice.py --home HOME --kind reminder

The owners of each waiting state call it at the transition that creates that state:
bin/fm-captain-hold.sh when a new hold opens (question, approval, action),
bin/fm_delivery.py when a result is newly declared outcome.review=needed (review),
and bin/fm-procevent-lavish.sh when a board is first armed for a task (board).
The watcher runs `--kind reminder` once a day; it reads the work snapshot's
needs-you set, the same set the Deck shows, and sends one summary while it is not empty.
The text uses the installation language (config/language, bin/fm_progress.py tr).
Without --title the task's declared card title or summary is used. Without
--link the Deck (config/deck-url) is linked when configured: the call view for
a hold, the review occurrence for a result, otherwise the task's card.
Delivery belongs to bin/fm-notify.py (FM_NOTIFICATION_COMMAND_FILE selects an
installation adapter as it does for the watcher); a missing notification
command is a silent no-op. Always exits 0: a notice never fails its caller.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlencode

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
from fm_progress import tr  # noqa: E402

KINDS = ('question', 'approval', 'action', 'review', 'board', 'reminder')
PREFIX = {'question': 'Needs your answer', 'approval': 'Needs your approval',
          'action': 'Needs you to act', 'review': 'Ready for your review',
          'board': 'Review board waiting for you'}


def one_line(text, limit):
    text = ' '.join(str(text or '').split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + '…'


def deck_link(home, **query):
    try:
        deck = (Path(os.environ.get('FM_CONFIG_OVERRIDE') or home / 'config') / 'deck-url').read_text(encoding='utf-8').strip()
    except OSError:
        return None
    if not deck.startswith(('http://', 'https://')):
        return None
    return deck.rstrip('/') + '/' + ('?' + urlencode(query) if query else '')


def declared_title(home, task):
    try:
        fields = json.loads((home / 'data' / task / 'presentation.json').read_text(encoding='utf-8'))['presentation']
        return fields.get('card_title') or fields.get('summary') or task
    except (OSError, ValueError, KeyError, TypeError):
        return task


def reminder_text(home):
    env = dict(os.environ, FM_HOME=str(home))
    out = subprocess.run(['bash', str(BIN / 'fm-tasks-axi.sh'), 'work', 'snapshot'], env=env,
                         capture_output=True, text=True, timeout=600, check=True).stdout
    snapshot = json.loads(out)
    keys = set(snapshot['counts']['needs_you']['keys'])
    if not keys:
        return None
    waiting = sorted((t for t in snapshot['tasks'] if t['key'] in keys),
                     key=lambda t: str((t.get('updated') or {}).get('value') or ''), reverse=True)
    # Backlog titles may end with their report path; the phone shows words only.
    names = [one_line(' '.join(w for w in str(t.get('title') or t['key'][5:]).split() if '/' not in w), 60)
             for t in waiting[:3]]
    return tr('{count} items wait for you. Newest: {names}').format(count=len(keys), names='; '.join(names))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--kind', choices=KINDS, required=True)
    parser.add_argument('--task')
    parser.add_argument('--title')
    parser.add_argument('--detail')
    parser.add_argument('--occurrence')
    parser.add_argument('--link')
    args = parser.parse_args()
    home = args.home.resolve()
    os.environ.setdefault('FM_HOME', str(home))
    try:
        if args.kind == 'reminder':
            text, link = reminder_text(home), deck_link(home)
            if text is None:
                return 0
        else:
            if not args.task and not (args.kind == 'board' and args.title):
                parser.error('--task is required for ' + args.kind + ' (a board without a task needs --title)')
            title = args.title or declared_title(home, args.task)
            text = tr(PREFIX[args.kind]) + ': ' + one_line(title, 120)
            if args.detail:
                text += ' - ' + one_line(args.detail, 200)
            view = dict(view='call') if args.kind in ('question', 'approval', 'action') else \
                dict(view='delivery', item=args.occurrence) if args.occurrence else {}
            link = args.link or (deck_link(home, task=args.task, **view) if args.task else deck_link(home))
        command = [sys.executable, str(BIN / 'fm-notify.py'), '--home', str(home),
                   '--event', 'captain-' + args.kind, '--text', one_line(text, 240)]
        if os.environ.get('FM_NOTIFICATION_COMMAND_FILE'):
            command += ['--command-file', os.environ['FM_NOTIFICATION_COMMAND_FILE']]
        if link:
            command += ['--link', link]
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        if result.returncode != 0:
            print('captain notice not delivered: ' + args.kind + ' ' + (args.task or ''), file=sys.stderr)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print('captain notice unavailable: ' + type(error).__name__, file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
