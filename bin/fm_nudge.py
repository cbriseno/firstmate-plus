#!/usr/bin/env python3
"""Record and import supervisor nudges; categories mirror the eight mechanisms."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re

CATEGORIES = {
    'integrate': True, 'new-orders': False, 'dispatch': True, 'restart': True,
    'root-cause': True, 'resources': True, 'model-effort': True, 'prior-rules': True,
}


def paths():
    home = Path(os.environ.get('FM_HOME') or Path(__file__).resolve().parent.parent)
    return (Path(os.environ.get('FM_STATE_OVERRIDE') or home / 'state'),
            Path(os.environ.get('FM_DATA_OVERRIDE') or home / 'data'))


def rows(path):
    try:
        lines = path.read_text(encoding='utf-8').splitlines()
    except FileNotFoundError:
        return []
    result = []
    for line in lines:
        try:
            item = json.loads(line)
            if isinstance(item, dict):
                result.append(item)
        except ValueError:
            continue
    return result


def legacy_category(label):
    # Historical labels are free text; only classify clear category names.
    patterns = (
        ('prior-rules', r'reglas'),
        ('model-effort', r'modelo|esfuerzo'),
        ('restart', r'relanzar|atorad|detenid|pausa vencida'),
        ('dispatch', r'despach|carriles libres'),
        ('resources', r'memoria|disco|carga|huérfan|copias|carriles llenos'),
        ('integrate', r'integrar|instalar|publicar'),
        ('new-orders', r'órdenes nuevas'),
        ('root-cause', r'raíz|huecos'),
    )
    matches = [key for key, pattern in patterns if re.search(pattern, label.lower())]
    return matches[0] if len(matches) == 1 else None


def import_legacy(state, data):
    path = state / 'nudges.jsonl'
    source = data / 'cero-empujones-20261120' / 'empujones.md'
    if not source.is_file() or any(row.get('legacy_import') for row in rows(path)):
        return
    added = []
    for line in source.read_text(encoding='utf-8').splitlines():
        fields = [field.strip() for field in line.strip().strip('|').split('|')]
        if len(fields) != 4 or not re.fullmatch(r'\d{4}-\d\d-\d\d \d\d:\d\d', fields[0]):
            continue
        if 'no cuenta' in fields[1].lower():
            continue
        timestamp = datetime.datetime.strptime(fields[0], '%Y-%m-%d %H:%M').astimezone().isoformat(timespec='seconds')
        added.append(dict(time=timestamp, category=legacy_category(fields[1]), legacy_category=fields[1],
                          text=fields[2], task=fields[3]))
    added.append(dict(legacy_import=True))
    state.mkdir(parents=True, exist_ok=True)
    with path.open('a', encoding='utf-8') as stream:
        stream.write(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in added))


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'Categories: integrate (integrate, install, publish); new-orders (new captain orders, '
        'non-mechanical); dispatch (free lanes); restart (stalled work); root-cause (gaps); '
        'resources (memory, load, orphans); model-effort; prior-rules (existing rules).'))
    sub = parser.add_subparsers(dest='command', required=True)
    record = sub.add_parser('record')
    record.add_argument('--category', required=True, choices=CATEGORIES)
    record.add_argument('--text', required=True)
    record.add_argument('--task')
    sub.add_parser('import-legacy')
    args = parser.parse_args()
    state, data = paths()
    path = state / 'nudges.jsonl'
    if args.command == 'record':
        if not args.text.strip():
            parser.error('--text must not be empty')
        added = [dict(time=datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
                      category=args.category, text=args.text, task=args.task)]
    else:
        import_legacy(state, data)
        return
    state.mkdir(parents=True, exist_ok=True)
    with path.open('a', encoding='utf-8') as stream:
        stream.write(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in added))


if __name__ == '__main__':
    main()
