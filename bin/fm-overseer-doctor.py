#!/usr/bin/env python3
"""Read local Firstmate evidence and identify leads for an overseer."""
import collections
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get('FM_HOME') or ROOT)
STATE = Path(os.environ.get('FM_STATE_OVERRIDE') or HOME / 'state')


def command(label, argv):
    print('\n' + label, flush=True)
    try:
        result = subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=120, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f'Unknown: {exc}. Action: run the underlying command separately.')
        return ''
    print(result.stdout, end='')
    if result.returncode:
        print(f'Unknown: command exited {result.returncode}. Action: inspect its error above.')
    return result.stdout


def diagnostic_events():
    if os.environ.get('FM_DIAGNOSTICS') == '0':
        print('Diagnostic recording: disabled in this environment. Action: remove FM_DIAGNOSTICS=0 to record events.')
    base = os.environ.get('FM_DIAGNOSTICS_HOME')
    if base:
        path = Path(base) / 'firstmate' / 'events.jsonl'
    elif sys.platform == 'darwin':
        path = Path.home() / 'Library/Logs/Firstmate/Diagnostics/firstmate/events.jsonl'
    else:
        path = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'firstmate/diagnostics/firstmate/events.jsonl'
    counts = collections.Counter()
    newest = None
    try:
        with path.open(encoding='utf-8') as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                    stamp = datetime.datetime.fromisoformat(event['t'].replace('Z', '+00:00'))
                    if stamp.tzinfo is None:
                        continue
                    newest = max(newest, stamp) if newest else stamp
                    if (datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds() <= 86400:
                        counts[event.get('e', 'unknown')] += 1
                except (ValueError, TypeError, KeyError, AttributeError):
                    continue
    except OSError:
        print('Diagnostic events: unavailable. Action: check that diagnostics are enabled and the installation has produced activity.')
        return
    if newest is None:
        print('Diagnostic events: no readable events. Action: check recording after real activity.')
    else:
        print(f'Diagnostic events (machine-wide): {sum(counts.values())} in the last 24 hours; latest {newest.isoformat()}.')
        if (datetime.datetime.now(datetime.timezone.utc) - newest).total_seconds() > 86400:
            print('Recording is not verified by recent events. Action: check again after real activity.')
        for name in ('session.start', 'session.stage', 'hook.run', 'wake.ack', 'work.snapshot', 'worker.procs'):
            print(f'  {name}: {counts[name]}')
        print('Action: inspect slow stages, hook durations and wake ages in the diagnostic events; counts alone do not establish a cause.')


def waits():
    counts = collections.Counter()
    if not STATE.is_dir() or not os.access(STATE, os.R_OK | os.X_OK):
        print('Waits: unavailable. Action: check the configured state directory.')
        return
    try:
        for path in STATE.glob('*.status'):
            try:
                lines = path.read_text(encoding='utf-8').splitlines()
            except (OSError, UnicodeError):
                continue
            for line in reversed(lines):
                state = line.split(' ', 1)[0].rstrip(':')
                if state in ('working', 'resolved', 'paused', 'blocked', 'needs-decision', 'failed', 'done'):
                    counts[state] += 1
                    break
    except OSError:
        print('Waits: unavailable. Action: inspect the state directory permissions.')
        return
    print('Latest task states: ' + ', '.join(f'{key}={counts[key]}' for key in ('paused', 'blocked', 'needs-decision', 'failed', 'working')))
    print('Action: inspect each open wait and its owner; a declared wait is not itself proof of a fault.')


def main():
    print('Firstmate overseer doctor (read only)')
    print('The diagnostic log and some budgets are machine-wide; correlate their samples before attributing them to this home.')
    command('Prerequisites', ['bash', str(ROOT / 'bin/fm-doctor.sh')])
    capacity = command('Capacity', ['bash', str(ROOT / 'bin/fm-capacity.sh')])
    first_line = capacity.splitlines()[0] if capacity.splitlines() else ''
    reason = next((part.partition('=')[2] for part in first_line.split() if part.startswith('reason=')), '')
    reasons = set(reason.split(','))
    if reasons.intersection(('load', 'cpu')):
        print('Lead: CPU load is limiting admission. Action: inspect active work and compare load with the configured limit; do not assume a single process caused it.')
    if reasons.intersection(('memory', 'disk')):
        print('Lead: host resources are limiting admission. Action: inspect the capacity report and the measured resource before changing limits.')
    budget = command('Budgets, test turns and wake measurements', [sys.executable, str(ROOT / 'bin/fm-budgets.py'), 'table'])
    for line in budget.splitlines():
        if line.startswith('Test runs: ') and line.partition('oldest wait (s): ')[2].split(',')[0].isdecimal():
            print('Lead: Test runs are queued for host slots. Action: inspect the oldest wait and reuse the active run for the same change.')
            break
    if 'EXCEEDED' in budget:
        leads = {
            'wake_attention_p95_s': 'Wake attention is delayed; compare wake timestamps with primary activity and open waits.',
            'primary_quiet_wakes_per_h': 'Routine wakes are frequent; inspect their reasons before changing the wake source.',
            'hook_run_p95_ms': 'Hooks are slow; inspect hook.run durations and their harness and role.',
            'work_snapshot_p95_ms': 'Work snapshots are slow; inspect work.snapshot durations and lock waits.',
            'obligations_overdue_per_day': 'Obligations are overdue; inspect their owners and next actions.',
            'worker_zombies_sustained_max': 'Worker processes remain unreaped; inspect process ownership before cleanup.',
        }
        for line in budget.splitlines():
            key = line.split(None, 1)[0] if line.split() else ''
            if 'EXCEEDED' in line:
                print('Lead: ' + leads.get(key, f'{key} exceeds its limit; inspect its samples and owner.'))
        print('These are leads, not proven causes; correlate the samples before attributing a cause.')
    if 'unmeasured' in budget:
        print('Some measures have no samples. Action: collect real activity before drawing a conclusion.')
    print('\nAlways-on diagnostic record')
    diagnostic_events()
    print('\nWaits')
    waits()
    return 0


if __name__ == '__main__':
    sys.exit(main())
