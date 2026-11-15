#!/usr/bin/env python3
"""Capture Claude's native statusline window, preserving the existing display.

Usage: fm-claude-context.py setup SETTINGS WORKTREE CLAUDE_STORE SNAPSHOT
       fm-claude-context.py capture SNAPSHOT DISPLAY_COMMAND
setup wraps the effective user/project/local statusLine in worker --settings.
capture stores only session/model/context fields; no transcript content or auth.
SNAPSHOT belongs to one launch generation; relay-check validates its transcript
and model before using the measured window. Python 3.9/stdlib, Linux/macOS.
"""
import json
from pathlib import Path
import shlex
import subprocess
import sys


def main():
    if sys.argv[1] == 'setup':
        settings, worktree, store, snapshot = map(Path, sys.argv[2:6])
        display = {}
        for file in (store / 'settings.json', worktree / '.claude/settings.json',
                     worktree / '.claude/settings.local.json'):
            if file.exists():
                value = json.loads(file.read_text())
                if 'statusLine' in value:
                    display = value['statusLine'] or {}
        value = json.loads(settings.read_text())
        wrapped = dict(display)
        wrapped.update(type='command', command=shlex.join([
            sys.executable, str(Path(__file__).resolve()), 'capture', str(snapshot),
            display.get('command', '')]))
        value['statusLine'] = wrapped
        settings.write_text(json.dumps(value) + '\n')
        return
    snapshot, display = Path(sys.argv[2]), sys.argv[3]
    raw = sys.stdin.read()
    value = json.loads(raw)
    fields = {key: value.get(key) for key in
              ('session_id', 'transcript_path', 'model', 'context_window')}
    temporary = snapshot.with_suffix('.tmp')
    temporary.write_text(json.dumps(fields) + '\n')
    temporary.replace(snapshot)
    if display:
        subprocess.run(display, shell=True, input=raw, text=True, timeout=5, check=False)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, TypeError, IndexError, subprocess.SubprocessError) as error:
        print('Claude context unavailable: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1 if sys.argv[1:2] == ['setup'] else 0)
