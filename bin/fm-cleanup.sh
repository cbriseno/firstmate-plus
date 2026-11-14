#!/usr/bin/env bash
# Usage: fm-cleanup.sh --dry-run|--apply
# Measure df and du for data/<id>, temporary fm-* roots and ~/.treehouse.
# Only closed tasks (valid completion, no live meta) qualify. Keep unknown data,
# reports/logs/captures, dirty or unique Git history, and managed Treehouse slots.
# --apply reclassifies from current records; no saved deletion plan is executed.
# FM_HOME selects the home; default: script checkout. No network access.
# Ordinary fm/<id> worktrees must be clean and merged into their source main.
set -eu
case "${1:-}" in --dry-run|--apply) [ "$#" = 1 ] ;; *) head -n 6 "$0"; exit 2 ;; esac
export FM_HOME="${FM_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
python3 - "$1" <<'PY'
import json, os, pathlib, platform, shutil, subprocess, sys, tarfile, tempfile
P = pathlib.Path
home, apply = P(os.environ['FM_HOME']).resolve(), sys.argv[1] == '--apply'
data, state = home / 'data', home / 'state'
# POSIX units/flags shared by the GNU and BSD adapters; never parse human units.
df, du = {'Linux': (['df', '-Pk'], ['du', '-sk']),
          'Darwin': (['df', '-Pk'], ['du', '-sk'])}[platform.system()]
def run(args, env=None):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.DEVNULL, env=env)
def git(repo, *args):
    return run(['git', '-C', repo, *args]).decode().strip()
def closed(task):
    try:
        record = json.loads((data / task / 'completion.json').read_text())
        return record.get('valid') is True and record.get('id') == task and not (state / (task + '.meta')).exists()
    except (OSError, ValueError):
        return False

def measure(path):
    try:
        size = int(run(du + [path]).split()[0]); print('du_kib', size, str(path), flush=True)
        return size
    except (OSError, ValueError, subprocess.CalledProcessError):
        print('retain unreadable', str(path), flush=True); return 0

def remove(path, task, reason, source=None):
    if path.is_symlink() or not closed(task):
        return
    size = measure(path)
    print('apply' if apply else 'safe', reason, str(path), flush=True)
    if apply:
        if source:
            subprocess.check_call(['git', '-C', str(source), 'worktree', 'remove', str(path)])
        else:
            shutil.rmtree(path)
    totals[0] += size

roots = sorted(p for p in data.iterdir() if p.is_dir() and not p.is_symlink())
temps = sorted({p for base in {P('/tmp'), P(os.environ.get('TMPDIR', '/tmp'))} for p in base.glob('fm-*') if p.is_dir() and not p.is_symlink()})
print(run(df + [home]).decode(), end='', flush=True)
for path in roots + temps + [P.home() / '.treehouse']:
    measure(path)
repos = []
for repo in [home] + list((home / 'projects').glob('*')):
    try:
        origin = git(repo, 'remote', 'get-url', 'origin')
        objects = set(line.split()[0] for line in git(repo, 'rev-list', '--objects', '--all').splitlines())
        repos.append((repo, origin, objects))
    except (OSError, subprocess.CalledProcessError):
        pass

def source_for(path, backup=False):
    origin = (path / 'repository').read_text().strip() if backup else git(path, 'remote', 'get-url', 'origin')
    return next((r for r in repos if origin in (r[1], str(r[0]))), None)

def redundant(path):
    src = source_for(path)
    if not src or (git(path, 'rev-parse', '--is-bare-repository') != 'true' and git(path, 'status', '--porcelain', '--untracked-files=all', '--ignored')):
        return False
    refs = set(git(path, 'for-each-ref', '--format=%(objectname)').splitlines())
    refs.add(git(path, 'rev-parse', 'HEAD'))
    return refs <= src[2]

def integrated_backup(path):
    src = source_for(path, True)
    if not src:
        return False
    repo = src[0]
    patch = path / 'changes.patch'
    with tempfile.TemporaryDirectory(prefix='fm-cleanup-') as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=str(P(tmp) / 'index'))
        run(['git', '-C', repo, 'read-tree', 'main'], env)
        if patch.stat().st_size:
            run(['git', '-C', repo, 'apply', '--cached', '--reverse', '--check', patch], env)
    with tarfile.open(path / 'untracked.tar') as archive:
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile() or run(['git', '-C', repo, 'show', 'main:' + member.name]) != archive.extractfile(member).read():
                return False
    return True

totals, clones = [0], []
for root in roots:
    task = root.name
    if not closed(task):
        continue
    for current, dirs, files in os.walk(root, followlinks=False):
        path = P(current)
        dirs[:] = [d for d in dirs if not (path / d).is_symlink() and d != '.git']
        if path == root:
            continue
        reason = None
        try:
            if path.name.startswith('worktree-backup.'):
                reason = 'backup-in-main' if integrated_backup(path) else None
                dirs[:] = []
            elif (path / '.git').exists() or ((path / 'HEAD').is_file() and (path / 'objects').is_dir()):
                reason = 'clone-refs-in-source' if not (path / '.git').is_file() and redundant(path) else None
                if not reason and not (path / '.git').is_file():
                    clones.append((path, task))
            elif path.name in ('node_modules', '.cache', '__pycache__', '.pytest_cache', '_cacache', 'codex-cache', 'codex-packages'):
                reason = 'regenerable-cache'
            elif (path / 'pyvenv.cfg').is_file():
                reason = 'python-runtime'
            elif (path / 'Local State').is_file() and (path / 'Default' / 'Preferences').is_file():
                reason = 'chrome-profile'
        except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError):
            reason = None
        if reason:
            remove(path, task, reason); dirs[:] = []

# Removing caches can make a formerly dirty clone redundant in this same pass.
for path, task in reversed(clones):
    try:
        if path.is_dir() and redundant(path):
            remove(path, task, 'clone-refs-in-source')
    except (OSError, subprocess.CalledProcessError):
        pass

for path in temps:
    task = path.name[3:]
    if closed(task):
        remove(path, task, 'closed-tasktmp')
# Returned pool slots are shared infrastructure, never removed behind Treehouse.
for repo, _, _ in repos:
    for block in git(repo, 'worktree', 'list', '--porcelain').split('\n\n'):
        fields = dict(line.split(' ', 1) for line in block.splitlines() if ' ' in line)
        path, branch = P(fields.get('worktree', '/')), fields.get('branch', '')
        task = branch[len('refs/heads/fm/'):]
        if not branch.startswith('refs/heads/fm/') or not closed(task):
            continue
        try:
            if (P.home() / '.treehouse') in path.resolve().parents or path.resolve() == repo.resolve():
                print('retain managed-worktree', str(path)); continue
            if not git(path, 'status', '--porcelain', '--untracked-files=all', '--ignored'):
                run(['git', '-C', repo, 'merge-base', '--is-ancestor', git(path, 'rev-parse', 'HEAD'), 'main'])
                remove(path, task, 'closed-merged-worktree', repo)
        except (OSError, subprocess.CalledProcessError):
            print('retain unmerged-or-dirty-worktree', str(path))
print('reclaimable_kib' if not apply else 'removed_kib', totals[0])
print('Outside Firstmate: report remaining disk use to the user; no external paths are deleted.')
PY
