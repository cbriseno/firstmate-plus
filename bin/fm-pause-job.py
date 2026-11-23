#!/usr/bin/env python3
"""Check a pause's [wait-job=NAME] or [wait-pid=PID] references.

Exit 0 when a referenced job has stopped or is missing, 1 when all references
are live or no job is identified, 2 for an unstructured legacy pause. Durable
job names appearing in old declarations are recognized without migration.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

state, task, line = sys.argv[1:]
directory = Path(state) / (task + '.jobs')
names = re.findall(r'\[wait-job=([A-Za-z0-9_.-]+)\]', line)
pids = re.findall(r'\[wait-pid=([1-9][0-9]*)\]', line)
if not names and not pids and directory.is_dir():
    names = [p.stem for p in directory.glob('*.json') if p.stem in line]
if not names and not pids:
    sys.exit(2)

def live(pid):
    try:
        os.kill(int(pid), 0)
        result = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)],
                                capture_output=True, text=True, check=False)
        return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')
    except (OSError, ValueError, TypeError):
        return False

for name in names:
    try:
        path = directory / (name + '.json')
        item = json.loads(path.read_text())
        status = item.get('state')
        if status in ('pending', 'starting'):
            if time.time() - path.stat().st_mtime < 60:
                continue
            sys.exit(0)
        if status != 'running' or not live(item.get('pid')):
            sys.exit(0)
    except (OSError, ValueError, TypeError):
        sys.exit(0)
for pid in pids:
    if not live(pid):
        sys.exit(0)
sys.exit(1)
