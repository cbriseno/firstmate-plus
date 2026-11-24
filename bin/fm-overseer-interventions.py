#!/usr/bin/env python3
"""Record overseer interventions using the diagnostic export schema."""
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', required=True)
    sub = parser.add_subparsers(dest='command', required=True)
    record = sub.add_parser('record')
    for field in ('category', 'observed', 'evidence', 'action'):
        record.add_argument('--' + field, required=True)
    record.add_argument('--root-task', choices=('yes', 'no'), required=True)
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
    task = subprocess.check_output(['bash', str(Path(__file__).with_name('fm-diag.sh')),
                                    'id', args.evidence], text=True).strip()
    item = {'t': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'c': 'firstmate',
            'e': 'overseer.intervention', 'category': args.category, 'observed': args.observed,
            'task': task, 'action': args.action, 'root_task': int(args.root_task == 'yes')}
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'interventions.jsonl').open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(item, separators=(',', ':')) + '\n')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)
