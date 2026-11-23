#!/usr/bin/env python3
"""Export Firstmate's structural diagnostic records as a shareable ZIP."""
import datetime
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import zipfile

SCHEMA = {
    'hook.run': 'hook harness role session run ms rc',
    'operation.stage': 'operation stage run ms rc',
    'session.stage': 'stage ms',
    'session.start': 'ms rc last_stage budget_s source harness session',
    'wake.ack': 'kind age_s',
    'work.snapshot': 'caller ms lock_ms result tasks',
    'worker.procs': 'task harness procs zombies rss_mb',
}
TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,39}\Z')
TASK = re.compile(r'live-[0-9a-f]{16}\Z')


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: fm-diag-export.py LOG-DIRECTORY OUTPUT.zip')
    source, destination = map(Path, sys.argv[1:])
    salt = secrets.token_bytes(32)
    records = []
    for name in ('events.1.jsonl', 'events.jsonl'):
        try:
            lines = (source / name).read_text(encoding='utf-8').splitlines()
        except FileNotFoundError:
            continue
        for line in lines:
            try:
                item = json.loads(line)
                event = item['e']
                if item['c'] != 'firstmate' or event not in SCHEMA:
                    continue
                stamp = item['t']
                datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                record = {'t': stamp, 'c': 'firstmate', 'e': event, 'v': 'unknown', 'r': 'unknown'}
                for key in SCHEMA[event].split():
                    value = item.get(key)
                    if key == 'task' and isinstance(value, str) and TASK.fullmatch(value):
                        record[key] = 't-' + hmac.new(salt, value.encode(), hashlib.sha256).hexdigest()[:16]
                    elif key != 'task' and (type(value) is int or isinstance(value, str) and TOKEN.fullmatch(value)):
                        record[key] = value
                records.append(record)
            except (ValueError, TypeError, KeyError, AttributeError):
                continue
    try:
        version = subprocess.check_output(['git', '-C', str(Path(__file__).resolve().parent.parent),
                                           'describe', '--always', '--dirty'], stderr=subprocess.DEVNULL,
                                          text=True).strip() or 'desconocido'
    except (OSError, subprocess.CalledProcessError):
        version = 'desconocido'
    # Exclusive creation prevents replacing an existing export.
    with destination.open('xb') as output:
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('events.jsonl', ''.join(json.dumps(r, separators=(',', ':')) + '\n' for r in records))
            archive.writestr('manifest.json', json.dumps({'component': 'firstmate', 'installed_version': version}) + '\n')
    print(f'{destination}: {len(records)} events')


if __name__ == '__main__':
    main()
