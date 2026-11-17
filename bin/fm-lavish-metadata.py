#!/usr/bin/env python3
"""Print the replying task's available identity for Lavish."""
import json
import sys
import uuid
from pathlib import Path

state, task = Path(sys.argv[1]), sys.argv[2]
meta = dict(line.split('=', 1) for line in (state / (task + '.meta')).read_text().splitlines() if '=' in line)
result = {'task': task}
for key in ('model', 'effort', 'harness', 'herdr_pane_id', 'project'):
    if meta.get(key):
        result[key] = meta[key]
try:
    rows = [json.loads(line) for line in Path(meta['sessions_file']).read_text().splitlines()]
    row = next(row for row in reversed(rows) if row.get('launch') == meta.get('spawn_gen')
               and row.get('status') == 'active' and row.get('session'))
    with Path(row['session']).open() as transcript:
        for _, line in zip(range(60), transcript):
            entry = json.loads(line)
            identity = (entry.get('payload', {}).get('id') if entry.get('type') == 'session_meta'
                        else entry.get('sessionId') if meta.get('harness') == 'claude' else None)
            if identity:
                result['chat_id'] = str(uuid.UUID(identity))
                break
except (OSError, KeyError, ValueError, StopIteration, TypeError):
    pass
flags = {'model': '--model', 'effort': '--reasoning', 'harness': '--harness',
         'chat_id': '--chat-id', 'herdr_pane_id': '--herdr-pane',
         'project': '--project', 'task': '--task'}
for key, flag in flags.items():
    if key in result:
        sys.stdout.buffer.write(flag.encode() + b'\0' + result[key].encode() + b'\0')
