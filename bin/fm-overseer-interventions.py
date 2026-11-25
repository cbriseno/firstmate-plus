#!/usr/bin/env python3
"""Record overseer interventions using the diagnostic export schema.

Each intervention is also one correction in the home's correction ledger
(bin/fm_nudge.py): its category is the general cause, --level captain records
a captain correction, and --root-task names the cause's open root-cause task
(yes or no keep the cause's existing link).
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys
import importlib.util
spec = importlib.util.spec_from_file_location('diag_export', Path(__file__).with_name('fm-diag-export.py'))
diag_export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diag_export)
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fm_nudge  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    record = sub.add_parser('record')
    for field in ('category', 'observed', 'evidence', 'action'):
        record.add_argument('--' + field, required=True)
    record.add_argument('--root-task', default='no', help='open root-cause task id; yes or no keep the existing link')
    record.add_argument('--level', choices=('overseer', 'captain'), default='overseer')
    export = sub.add_parser('export')
    export.add_argument('output')
    args = parser.parse_args()
    directory = Path(args.home) / 'state' / 'overseer'
    if args.command == 'export':
        subprocess.run([sys.executable, str(Path(__file__).with_name('fm-diag-export.py')),
                        '--overseer', str(directory), args.output], check=True)
        return
    for name in ('category', 'observed', 'action'):
        if not diag_export.TOKEN.fullmatch(getattr(args, name)):
            parser.error(name + ' must be a short anonymous token')
    root = None if args.root_task in ('yes', 'no') else args.root_task
    item = dict(t=datetime.datetime.now(datetime.timezone.utc).isoformat(), category=args.category,
                observed=args.observed, action=args.action, level=args.level)
    row = fm_nudge.intervention_row(item)
    state = Path(args.home) / 'state'
    fm_nudge.import_legacy(state, Path(args.home) / 'data')
    try:
        row, notes = fm_nudge.record(state, row['level'], row['cause'], row['text'], root,
                                     extra=dict(intervention_t=item['t']), home=args.home)
    except ValueError as exc:
        parser.error(str(exc))
    task = subprocess.check_output(['bash', str(Path(__file__).with_name('fm-diag.sh')),
                                    'id', args.evidence], text=True).strip()
    item = {'t': item['t'], 'c': 'firstmate', 'e': 'overseer.intervention', 'category': args.category,
            'observed': args.observed, 'task': task, 'action': args.action, 'root_task': int(bool(row['task']))}
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'interventions.jsonl').open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(item, separators=(',', ':')) + '\n')
    for note in notes:
        print(note)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)
