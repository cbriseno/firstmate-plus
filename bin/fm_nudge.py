#!/usr/bin/env python3
"""Record every correction or push at every level, grouped by general cause.

Every correction is a Firstmate defect: the captain correcting the overseer or
the primary (level captain), the overseer correcting the primary (overseer),
and the primary correcting a worker (primary). Each row names the general
cause, not the symptom, and every cause is linked to one open root-cause task
in this home's backlog. A cause recorded again after its root task closed is a
recurrence: the row is flagged and the cause needs a new or reopened root task.
State/nudges.jsonl is the one ledger; the overseer's intervention record and
fm-send --correction write through this module. Causes without an open root
task, and recurred causes, are the budget measure correction_causes_unrooted.
Link causes that share one general root to the same task; causes then lists
them together.
Categories mirror the primary's eight mechanisms; new-orders is not a correction.
"""
import argparse
import datetime
import json
import os
from collections import Counter
from pathlib import Path
import re
import subprocess

CATEGORIES = {
    'integrate': True, 'new-orders': False, 'dispatch': True, 'restart': True,
    'root-cause': True, 'resources': True, 'model-effort': True, 'prior-rules': True,
}
LEVELS = ('captain', 'overseer', 'primary')
CAUSE = re.compile(r'[a-z0-9][a-z0-9._-]{0,59}\Z')
TASK = re.compile(r'[A-Za-z0-9_][A-Za-z0-9._-]*\Z')


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


def append(path, added):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a', encoding='utf-8') as stream:
        stream.write(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in added))


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


def intervention_row(item):
    """Map one overseer intervention onto a ledger row."""
    captain = item.get('category') == 'captain-correction'
    level = 'captain' if captain else item.get('level') or 'overseer'
    return dict(time=item.get('t'), level=level,
                cause=str(item.get('observed') if captain else item.get('category')).lower(),
                text=f"{item.get('observed')} / {item.get('action')}", task=None,
                target=None, category=None, intervention_t=item.get('t'))


def import_legacy(state, data):
    """Import the historical table and overseer interventions once each."""
    path = state / 'nudges.jsonl'
    existing = rows(path)
    added = []
    source = data / 'cero-empujones-20261120' / 'empujones.md'
    if source.is_file() and not any(row.get('legacy_import') for row in existing):
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
    seen = {row.get('intervention_t') for row in existing}
    for item in rows(state / 'overseer' / 'interventions.jsonl'):
        if item.get('e') == 'overseer.intervention' and item.get('t') and item['t'] not in seen:
            seen.add(item['t'])
            added.append(intervention_row(item))
    if added:
        append(path, added)


def root_state(task, home=None):
    """Return open, closed, missing (not in the backlog), or unknown."""
    env = dict(os.environ, **({'FM_HOME': str(home)} if home else {}))
    try:
        out = subprocess.run(['bash', str(Path(__file__).with_name('fm-tasks-axi.sh')), 'show', task],
                             capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return 'unknown'
    found = re.search(r'^\s*state:\s*(\S+)', out.stdout, re.M)
    if out.returncode == 0 and found:
        return 'closed' if found.group(1) == 'done' else 'open'
    return 'missing' if 'NOT_FOUND' in out.stdout + out.stderr else 'unknown'


def cause_of(row):
    if row.get('legacy_category') is not None or row.get('category') == 'new-orders':
        return None
    return row.get('cause') or row.get('gap')


def causes(ledger):
    """Group corrections by cause, without querying the backlog."""
    out = {}
    for row in ledger:
        name = cause_of(row)
        if not name:
            continue
        item = out.setdefault(name, dict(count=0, levels=Counter(), last=None, root=None, recurred=False))
        if not row.get('link'):
            item['count'] += 1
            item['levels'][row.get('level') or 'overseer'] += 1
            item['last'] = row.get('time')
        if row.get('task') and not row.get('recurred'):
            item.update(root=row['task'], recurred=False)
        elif row.get('recurred'):
            item['recurred'] = True
    return out


def unrooted(ledger):
    """Causes that need a root task: never linked, or recurred after closure."""
    return {name: item for name, item in causes(ledger).items() if not item['root'] or item['recurred']}


def check_task(task, home=None):
    if not TASK.fullmatch(task or ''):
        raise ValueError(f'invalid root task id: {task!r}')
    state = root_state(task, home)
    if state == 'missing':
        raise ValueError(f'root task {task} is not in this backlog; open it first with bin/fm-tasks-axi.sh add')
    if state == 'closed':
        raise ValueError(f'root task {task} is already closed; a cause that recurs needs an open task: reopen it or open a new one')
    return [] if state == 'open' else [f'warning: could not read root task {task} from the backlog; linked unverified']


def record(state, level, cause, text, task=None, target=None, category=None, extra=None, home=None):
    """Append one correction; return (row, notes). Raises ValueError when invalid."""
    if level not in LEVELS:
        raise ValueError('level must be one of ' + ', '.join(LEVELS))
    if not str(text or '').strip():
        raise ValueError('the correction text must not be empty')
    if category is not None and category not in CATEGORIES:
        raise ValueError('unknown category')
    if category == 'new-orders':
        cause = None
    elif not CAUSE.fullmatch(cause or ''):
        raise ValueError('name the general cause as a short lowercase slug (--cause)')
    path = state / 'nudges.jsonl'
    notes, recurred, closed = [], False, None
    if task:
        notes += check_task(task, home)
    elif cause:
        root = causes(rows(path)).get(cause, {}).get('root')
        if not root:
            notes.append(f'cause {cause} has no root task: open one and link it with '
                         f'bin/fm-nudge.sh link --cause {cause} --task <id>')
        elif root_state(root, home) in ('closed', 'missing'):
            recurred, closed = True, root
            notes.append(f'RECURRENCE: cause {cause} came back after root task {root} closed; '
                         f'reopen it or open a new root task and link it')
        else:
            task = root
    row = dict(time=datetime.datetime.now().astimezone().isoformat(timespec='seconds'), level=level,
               cause=cause, text=text, task=task, target=target, category=category)
    if recurred:
        row.update(recurred=True, closed_root=closed)
    row.update(extra or {})
    append(path, [row])
    return row, notes


def link(state, cause, task, home=None):
    if not CAUSE.fullmatch(cause or ''):
        raise ValueError('invalid cause')
    notes = check_task(task, home)
    append(state / 'nudges.jsonl', [dict(time=datetime.datetime.now().astimezone().isoformat(timespec='seconds'),
                                         cause=cause, task=task, link=True)])
    return notes


def print_causes(ledger):
    print(f'{"cause":40} {"n":>3} {"levels":28} {"root task":44} status')
    for name, item in sorted(causes(ledger).items(), key=lambda kv: (str(kv[1]['root'] or ''), str(kv[1]['last']))):
        if item['recurred']:
            status = 'recurred'
        elif not item['root']:
            status = 'no root task'
        else:
            status = {'open': 'open', 'closed': 'fixed, no recurrence since',
                      'missing': 'fixed, no recurrence since'}.get(root_state(item['root']), 'linked (backlog unreadable)')
        levels = ' '.join(f'{key}:{value}' for key, value in sorted(item['levels'].items()))
        print(f'{name:40} {item["count"]:>3} {levels:28} {str(item["root"] or "-"):44} {status}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, epilog=(
        'Categories: integrate (integrate, install, publish); new-orders (new captain orders, '
        'not a correction); dispatch (free lanes); restart (stalled work); root-cause (gaps); '
        'resources (memory, load, orphans); model-effort; prior-rules (existing rules).'))
    sub = parser.add_subparsers(dest='command', required=True)
    rec = sub.add_parser('record', help='record one correction')
    rec.add_argument('--level', required=True, choices=LEVELS,
                     help='who corrected: captain (of overseer or primary), overseer (of primary), primary (of a worker)')
    rec.add_argument('--cause', help='general cause as a lowercase slug, shared by every correction it explains')
    rec.add_argument('--text', required=True)
    rec.add_argument('--task', help='open root-cause task to link; omitted, the cause keeps its linked one')
    rec.add_argument('--target', help='task id of the corrected worker, when there is one')
    rec.add_argument('--category', choices=CATEGORIES)
    lnk = sub.add_parser('link', help='link a cause to its open root-cause task')
    lnk.add_argument('--cause', required=True)
    lnk.add_argument('--task', required=True)
    sub.add_parser('causes', help='list causes with their root task and recurrence status')
    sub.add_parser('import-legacy', help='import historical records once')
    args = parser.parse_args()
    state, data = paths()
    import_legacy(state, data)
    try:
        if args.command == 'record':
            _, notes = record(state, args.level, args.cause, args.text, args.task, args.target, args.category)
        elif args.command == 'link':
            notes = link(state, args.cause, args.task)
        else:
            notes = []
            if args.command == 'causes':
                print_causes(rows(state / 'nudges.jsonl'))
    except ValueError as exc:
        parser.error(str(exc))
    for note in notes:
        print(note)


if __name__ == '__main__':
    main()
