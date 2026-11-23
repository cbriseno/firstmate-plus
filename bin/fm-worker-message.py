#!/usr/bin/env python3
"""Print an excerpt of the last complete assistant message in an active session.

Usage: fm-worker-message.py SESSIONS_FILE LAUNCH STARTED HARNESS MODEL EFFORT [--codex-idle]
The optional mode also requires a completed, not subsequently started, Codex turn.
Unreadable, partial, ambiguous, or superseded records produce no output.
"""
import json
from pathlib import Path
import sys
import unicodedata


def read_lines(path):
    with Path(path).open(encoding='utf-8') as stream:
        for line in stream:
            if not line.endswith('\n'):
                raise ValueError('partial record')
            yield json.loads(line)


def main(index, launch, started, harness, model, effort, require_codex_idle):
    rows = [r for r in read_lines(index) if isinstance(r, dict)]
    def matches_legacy(r):
        return (started and harness and r.get('started_at') == started
                and r.get('harness') == harness and (r.get('model') or '') == model
                and (r.get('effort') or '') == effort)
    active = [r for r in rows if r.get('status') == 'active']
    if not active and started and harness:
        active = [r for r in rows if r.get('status') in (None, 'unknown')
                  and matches_legacy(r)]
    if len(active) != 1 or not active[0].get('session'):
        return 1
    row = active[0]
    if launch and row.get('launch') != launch and not (
            not row.get('launch') and matches_legacy(row)):
        return 1
    if require_codex_idle and active[0].get('harness') != 'codex':
        return 1
    last = None
    turn, closed = None, False
    for row in read_lines(active[0]['session']):
        if not isinstance(row, dict) or row.get('isSidechain'):
            continue
        payload = row.get('payload')
        if row.get('type') == 'event_msg' and isinstance(payload, dict):
            event = payload.get('type')
            if event == 'task_started':
                if turn is not None and not closed:
                    return 1
                turn, closed = payload.get('turn_id'), False
            elif event == 'task_complete':
                if not turn or payload.get('turn_id') != turn:
                    return 1
                closed = True
            elif event in ('turn_aborted', 'error'):
                turn, closed = None, False
        message = None
        if row.get('type') in ('assistant', 'user'):
            message = row.get('message')
        elif row.get('type') == 'response_item' and isinstance(payload, dict) and payload.get('type') == 'message':
            message = payload
        if not isinstance(message, dict):
            continue
        role, content = message.get('role'), message.get('content')
        if role not in ('assistant', 'user'):
            continue
        if role == 'assistant' and message.get('phase') not in (None, 'final_answer'):
            last = None
            continue
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            if role == 'assistant' and any(isinstance(p, dict) and p.get('type') == 'tool_use' for p in content):
                last = None
                continue
            parts = [p.get('text', '') for p in content if isinstance(p, dict)
                     and p.get('type') in ('text', 'output_text', 'input_text')]
            text = '\n'.join(p for p in parts if isinstance(p, str))
        else:
            continue
        if text.strip():
            last = role, text
        elif role == 'assistant':
            last = None
    if not last or last[0] != 'assistant' or (require_codex_idle and not closed):
        return 1
    excerpt = ' '.join(''.join(' ' if unicodedata.category(c).startswith('C') else c
                                for c in last[1]).split())
    if not excerpt:
        return 1
    print(excerpt[:300] + ('…' if len(excerpt) > 300 else ''))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(*sys.argv[1:7], sys.argv[7:] == ['--codex-idle']))
    except (OSError, ValueError, TypeError, IndexError):
        sys.exit(1)
