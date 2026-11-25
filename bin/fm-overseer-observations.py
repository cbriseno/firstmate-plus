#!/usr/bin/env python3
"""Supply bounded filesystem and host observations to fm-overseer-watch.sh."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

from fm_test_slots import sample as test_slots

SLUG = re.compile(r'[a-zA-Z0-9][a-zA-Z0-9._-]*')
QUESTION = re.compile(r'acción requerida|dime si|me confirma|¿lo\b|please confirm|can you confirm|'
                      r'would you like|do you want me to|your decision', re.IGNORECASE)
BIN = Path(__file__).resolve().parent


def active_tasks(home):
    from fm_delivery import canonical_read
    config_path = home / '.tasks.toml'
    config = canonical_read({'config': config_path.read_text()}) if config_path.is_file() else {}
    path = (config.get('markdown') or {}).get('path') or 'data/backlog.md'
    data = os.environ.get('FM_DATA_OVERRIDE')
    backlog = Path(data) / 'backlog.md' if data and path == 'data/backlog.md' else home / path
    return {row['id']: (row.get('hold') or {}).get('kind', '')
            for row in canonical_read({'text': backlog.read_text()}) if row['state'] == 'in_flight'}


def status_rows(state, overseer, active):
    baseline = overseer / 'status-baseline'
    initialized = baseline.is_file()
    now = int(time.time())

    def observed(path):
        try:
            return path.read_text(encoding='ascii')
        except FileNotFoundError:
            return None

    for path in sorted(state.glob('*.status')):
        task = path.stem
        if not SLUG.fullmatch(task) or task not in active:
            continue
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode):
            continue
        version = f'{info.st_ino}:{info.st_size}:{info.st_mtime_ns}'
        marker = overseer / 'status' / task
        if not initialized:
            marker.write_text(version, encoding='ascii')
        elif observed(marker) != version:
            print('change', task, version, 0)
        elif (active[task] not in ('parked', 'captain')
              and now - int(info.st_mtime) >= 5400
              and any((state / f'{task}.{suffix}').is_file() for suffix in ('meta', 'parked'))
              and observed(overseer / 'stalled' / task) != version):
            print('stalled', task, version, (now - int(info.st_mtime)) // 60)
    if not initialized:
        baseline.touch()


def operations(home):
    now = int(time.time())
    try:
        selector = subprocess.check_output(
            ['git', '-C', str(home), 'reflog', '-1', '--format=%gD', '--date=unix', 'main'],
            text=True, stderr=subprocess.DEVNULL, timeout=5)
        stamp = re.search(r'@\{([0-9]+)\}', selector)
        if stamp and now - int(stamp[1]) >= 7200:
            print(f'integration\tno integration: {(now - int(stamp[1])) // 60} minutes since main advanced')
    except (OSError, subprocess.SubprocessError):
        pass
    slots = test_slots()
    if slots and slots['runs'] > slots['slots']:
        print(f'test-slots\ttest slots saturated: {slots["runs"]} runs for {slots["slots"]} slots')


def context_pressure(config):
    session = os.environ.get('CLAUDE_CODE_SESSION_ID', '')
    if not SLUG.fullmatch(session):
        return
    threshold = 400_000
    settings = config / 'overseer'
    if settings.is_file():
        for line in settings.read_text(encoding='utf-8').splitlines():
            if line.startswith('relay_tokens='):
                threshold = int(line.partition('=')[2])
    claude = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude')
    project = re.sub(r'[^a-zA-Z0-9-]', '-', str(Path.cwd()))
    path = claude / 'projects' / project / (session + '.jsonl')
    with path.open('rb') as stream:
        size = stream.seek(0, os.SEEK_END)
        stream.seek(max(0, size - 1_048_576))
        for line in reversed(stream.read().splitlines()):
            try:
                message = json.loads(line).get('message', {})
                usage = message.get('usage')
                if not isinstance(usage, dict):
                    continue
                tokens = sum(int(usage.get(key, 0)) for key in
                             ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
                if tokens >= threshold > 0:
                    print('context-' + session, tokens)
                return
            except (AttributeError, ValueError, TypeError):
                continue


def captain_calls(data, observed):
    deadline = time.monotonic() + 8
    for path in sorted(data.glob('*/captain-call.json')):
        task = path.parent.name
        if not SLUG.fullmatch(task) or path.is_symlink() or path.parent.is_symlink():
            continue
        try:
            record = json.loads(path.read_text(encoding='utf-8'))
            call = record.get('call')
            if (record.get('schema') != 'fm-captain-call.v1' or record.get('id') != task
                    or not isinstance(call, dict) or not call.get('question')):
                continue
            version = hashlib.sha256(record['hold_set'].encode()).hexdigest()
            marker = observed / task
            if marker.is_file() and marker.read_text(encoding='ascii') == version:
                continue
            closed = observed / ('.closed.' + task)
            if closed.is_file() and closed.read_text(encoding='ascii') == version:
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            result = subprocess.run(['bash', str(BIN / 'fm-captain-hold.sh'), 'open', task],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=remaining)
            if result.returncode == 0:
                print(task, version)
                return
            if result.returncode == 1:
                closed.write_text(version, encoding='ascii')
        except (OSError, TypeError, AttributeError, ValueError, KeyError, subprocess.SubprocessError):
            continue


def mirrored_question(path, generation):
    """Use only the latest turn stored by the verified primary mirror writer."""
    if path.is_symlink():
        return
    with path.open('rb') as stream:
        size = stream.seek(0, os.SEEK_END)
        stream.seek(max(0, size - 65_536))
        for line in reversed(stream.read().splitlines()):
            try:
                row = json.loads(line)
                if row.get('key') != generation:
                    continue
                if row.get('tag') == 'main' and QUESTION.search(row['text']):
                    print(hashlib.sha256(line).hexdigest())
                return
            except (AttributeError, KeyError, ValueError, TypeError):
                continue


if __name__ == '__main__':
    mode, path, *args = sys.argv[1:]
    if mode == 'status':
        status_rows(Path(path), Path(args[0]), dict(line.split('\t', 1) for line in os.environ.get('FM_OVERSEER_ACTIVE_TASKS', '').splitlines()))
    elif mode == 'active':
        print('\n'.join(f'{task}\t{hold}' for task, hold in sorted(active_tasks(Path(path)).items())))
    elif mode == 'operations':
        operations(Path(path))
    elif mode == 'captain-calls':
        captain_calls(Path(path), Path(args[0]))
    elif mode == 'context':
        try:
            context_pressure(Path(path))
        except (OSError, ValueError):
            sys.exit(1)
    elif mode == 'mirror':
        try:
            mirrored_question(Path(path), args[0])
        except OSError:
            sys.exit(1)
