"""Mechanical v11b migration; CLI and storage contract: fm-migrate-v11b.sh."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from fm_delivery import canonical_read, home_path, read_text, read_presentation, retained_history

BIN = Path(__file__).resolve().parent
UNKNOWN = 'Proyecto sin registrar'


def publish(home, task, patch, folder):
    source = folder / 'input.json'
    source.write_text(json.dumps(patch, ensure_ascii=False), encoding='utf-8')
    run = subprocess.run(['bash', str(BIN / 'fm-tasks-axi.sh'), 'presentation', task,
                          '--presentation-file', str(source)],
                         env=dict(os.environ, FM_HOME=str(home)),
                         capture_output=True, text=True, timeout=60)
    result = json.loads(run.stdout) if run.stdout.strip().startswith('{') else {}
    if (run.returncode or not result.get('ok') or result.get('state') != 'published'
            or not (result.get('evidence') or {}).get('available')
            or any(result['presentation'].get(k) != v for k, v in patch.items())):
        raise ValueError('%s: publication failed; rerun after resolving: %s %s' %
                         (task, run.stdout[-500:], run.stderr[-500:]))


def migrate(home, mode):
    folder = home / 'data/migration-v11b'
    if mode == 'rollback':
        restored = 0
        for saved in sorted(folder.glob('*.backup.json')):
            record = json.loads(saved.read_text(encoding='utf-8'))
            current = read_presentation(home, record['id'], verify=False)
            if (current.get('evidence') or {}).get('available') is False:
                raise ValueError('%s: invalid declaration' % record['id'])
            patch = {k: record['before'].get(k) for k, v in record['patch'].items()
                     if current['presentation'].get(k) == v}
            if patch:
                publish(home, record['id'], patch, folder)
                restored += 1
        return dict(restored=restored)

    history = retained_history(home, include_non_deliveries=True)
    missing_archive = any(s['kind'] == 'archive' and s.get('available') is False
                          and not (home / s['path']).exists() and not (home / s['path']).is_symlink()
                          for s in history['sources'])
    failures = [s for s in history['sources'] if s.get('available') is False and not s.get('defaults')
                and not (s['kind'] == 'archive' and missing_archive)]
    if not history['complete'] and (failures or not missing_archive):
        raise ValueError('incomplete history: ' + json.dumps(history['sources']))
    try:
        config = canonical_read({'config': read_text(home, '.tasks.toml', 65536)})
    except FileNotFoundError:
        config = {}
    backlog = home / ((config.get('markdown') or {}).get('path') or 'data/backlog.md')
    rows = {r['id']: r for r in history['records']}
    rows.update({r['id']: r for r in canonical_read({'text': read_text(home, str(backlog))})})
    registry = home / 'data/projects.md'
    projects = set(re.findall(r'^- ([A-Za-z0-9_.-]+) \[',
                             read_text(home, 'data/projects.md') if registry.exists() else '', re.M))
    declarations = {task: read_presentation(home, task, verify=False) for task in rows}
    request_repos = {}
    for task, declaration in declarations.items():
        request = declaration['presentation'].get('request')
        if request:
            request_repos.setdefault(request['id'], set()).add(rows[task].get('repo'))
    changes, unresolved = [], []
    for task, row in sorted(rows.items()):
        current = declarations[task]
        if (current.get('evidence') or {}).get('available') is False:
            raise ValueError('%s: invalid declaration; repair separately' % task)
        before = current['presentation']
        patch = {}
        if row['state'] == 'done' and (home / 'data' / task / 'report.md').is_file() and not before.get('outcome'):
            patch['outcome'] = dict(role='final', review=None)
            if not before.get('summary'):
                patch['summary'] = ' '.join(row['title'].split())[:2000]
        request = before.get('request')
        if not request:
            unresolved.append(dict(id=task, reason='missing request'))
        elif request['project'] == UNKNOWN:
            if len(request_repos[request['id']]) == 1 and row.get('repo') in projects:
                patch['request'] = dict(request, project=row['repo'])
            else:
                unresolved.append(dict(id=task, reason='project needs documented evidence'))
        if patch:
            changes.append(dict(id=task, patch=patch))
    if mode == 'apply':
        folder.mkdir(parents=True, exist_ok=True)
        for item in changes:
            task, patch = item['id'], item['patch']
            target = home / 'data' / task / 'presentation.json'
            saved = folder / (task + '.backup.json')
            before = read_presentation(home, task, verify=False)['presentation']
            record = json.loads(saved.read_text(encoding='utf-8')) if saved.exists() else dict(
                id=task, original=json.loads(target.read_text(encoding='utf-8')) if target.exists() else None,
                before={}, patch={})
            for key, value in patch.items():
                record['before'].setdefault(key, before.get(key))
                record['patch'][key] = value
            saved.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            publish(home, task, patch, folder)
    return dict(mode=mode, count=len(changes), changes=changes, unresolved=unresolved)


def main():
    parser = argparse.ArgumentParser(
        description='Migrate historical Deck outcomes and explicit projects in FM_HOME.',
        epilog='Backups: FM_HOME/data/migration-v11b/*.backup.json. '
               'Unresolved projects and request grouping need a worker; see '
               'docs/configuration.md (v11b migration).')
    mode = parser.add_mutually_exclusive_group(required=True)
    for option, help_text in [('plan', 'preview without writing'),
                              ('apply', 'back up and publish missing historical fields'),
                              ('rollback', 'restore migrated fields that still match; keep later edits')]:
        mode.add_argument('--' + option, action='store_true', help=help_text)
    args = parser.parse_args()
    if not os.environ.get('FM_HOME'):
        parser.error('FM_HOME must name the home to migrate')
    if any(os.environ.get(k) for k in ('FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE')):
        parser.error('unset directory overrides; this command migrates FM_HOME')
    try:
        home = home_path()
        result = migrate(home, 'apply' if args.apply else 'rollback' if args.rollback else 'plan')
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
