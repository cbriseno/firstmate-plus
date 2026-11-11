"""Upgrade actions; CLI and records are owned by fm-upgrade.sh."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


BIN = Path(__file__).resolve().parent


def run():
    parser = argparse.ArgumentParser(description='Offer or apply UPGRADING.md actions.',
                                     epilog=(BIN / 'fm-upgrade.sh').read_text().split('set -eu')[0])
    parser.add_argument('mode', choices=('check', 'apply'))
    args = parser.parse_args()
    home = Path(os.environ.get('FM_HOME', ''))
    if not os.environ.get('FM_HOME') or not home.is_absolute():
        parser.error('FM_HOME must name an absolute home')
    if any(os.environ.get(k) for k in ('FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE')):
        parser.error('unset directory overrides; this command addresses FM_HOME')
    root = Path(os.environ.get('FM_ROOT_OVERRIDE') or BIN.parent)
    notes = root / 'UPGRADING.md'
    if not notes.exists() and args.mode == 'check':
        return 0
    entries = []
    for section in re.split(r'^## ', notes.read_text(encoding='utf-8'), flags=re.M)[1:]:
        heading = re.match(r'([a-z0-9-]+) - \d{4}-\d{2}-\d{2}\n', section)
        command = re.search(r'^Command: `([^`]+)`$', section, re.M)
        if command:
            action = re.search(r'^Action: (.+)$', section, re.M)
            if not heading or not action:
                raise ValueError('upgrade command needs a dated id and Action')
            entries.append((heading[1], action[1], command[1]))
    folder = home / 'data/upgrades'

    def recorded(name):
        path = folder / name
        return set(path.read_text().splitlines()) if path.exists() else set()

    def record(name, ids):
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / name).open('a', encoding='utf-8') as stream:
            stream.write(''.join(i + '\n' for i in ids))

    pending = [e for e in entries if e[0] not in recorded('applied')]
    env = dict(os.environ, FM_HOME=str(home))
    if args.mode == 'check':
        fresh = [e for e in pending if e[0] not in recorded('offered')]
        if not fresh:
            return 0
        task = 'upgrade-' + fresh[-1][0]
        labels = '; '.join(e[1] for e in pending)
        question = ('Hay 1 acción de actualización. ¿La aplico?' if len(pending) == 1 else
                    'Hay %d acciones de actualización. ¿Las aplico?' % len(pending))
        command = ['bash', str(BIN / 'fm-captain-hold.sh'), 'hold', task,
                   '--title', 'Acciones pendientes de actualización',
                   '--reason', 'Aceptar o posponer las acciones de actualización',
                   '--category', 'product-design',
                   '--question', question, '--context', labels[:200],
                   '--option', 'apply=Aplicarlas', '--option', 'skip=Dejarlas pendientes',
                   '--recommended', 'apply', '--link', str(notes)]
        subprocess.run(command, env=env, check=True)
        record('offered', [e[0] for e in fresh])
        print('UPDATE_ACTIONS: %s %s Read UPGRADING.md; relay this existing hold once; '
              'record the answer before apply. Command: FM_HOME=%s bash %s apply'
              % (task, question, shlex.quote(str(home)), shlex.quote(str(BIN / 'fm-upgrade.sh'))))
        return 0
    for identity, label, command in pending:
        print('%s: %s' % (identity, label), flush=True)
        result = subprocess.run(shlex.split(command), cwd=root, env=env, check=True,
                                text=True, stdout=subprocess.PIPE)
        print(result.stdout, end='', flush=True)
        if identity == 'v11b':
            if json.loads(result.stdout)['unresolved']:
                print('v11b remains pending: dispatch its documented evidence migration, '
                      'then rerun apply.', file=sys.stderr)
                return 2
        record('applied', [identity])
    return 0


if __name__ == '__main__':
    try:
        sys.exit(run())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print('upgrade actions: %s' % exc, file=sys.stderr)
        sys.exit(1)
