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
    overseer = len(sys.argv) == 4 and sys.argv[1] == '--overseer'
    if len(sys.argv) != 3 and not overseer:
        sys.exit('usage: fm-diag-export.py [--overseer] LOG-DIRECTORY OUTPUT.zip')
    source, destination = map(Path, sys.argv[2:] if overseer else sys.argv[1:])
    schema = {'overseer.intervention': 'category observed task action root_task'} if overseer else SCHEMA
    salt = secrets.token_bytes(32)
    records = []
    for name in (('interventions.jsonl',) if overseer else ('events.1.jsonl', 'events.jsonl')):
        try:
            lines = (source / name).read_text(encoding='utf-8').splitlines()
        except FileNotFoundError:
            continue
        for line in lines:
            try:
                item = json.loads(line)
                event = item['e']
                if item['c'] != 'firstmate' or event not in schema:
                    if overseer:
                        raise ValueError('invalid intervention')
                    continue
                stamp = item['t']
                datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                record = {'t': stamp, 'c': 'firstmate', 'e': event, 'v': 'unknown', 'r': 'unknown'}
                for key in schema[event].split():
                    value = item.get(key)
                    if key == 'task' and isinstance(value, str) and TASK.fullmatch(value):
                        record[key] = 't-' + hmac.new(salt, value.encode(), hashlib.sha256).hexdigest()[:16]
                    elif key != 'task' and (type(value) is int or isinstance(value, str) and TOKEN.fullmatch(value)):
                        record[key] = value
                if overseer and (item.get('root_task') not in (0, 1) or type(item.get('root_task')) is not int or any(not isinstance(item.get(key), str) for key in ('category', 'observed', 'task', 'action')) or any(key not in record for key in schema[event].split())):
                    raise ValueError('invalid intervention')
                records.append(record)
            except (ValueError, TypeError, KeyError, AttributeError):
                if overseer:
                    sys.exit('invalid intervention; export refused')
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
