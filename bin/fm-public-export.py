#!/usr/bin/env python3
"""Create a reviewable public tree and patch, never a repository or a push.

Usage: python3 bin/fm-public-export.py --source <full-commit-sha>
  --public-base <full-commit-sha> --output <new-directory> [--deny-file <file>]

The caller verifies public-base independently on the public upstream before use.
Only committed blobs selected by docs/public-export-manifest.json are read.
Working files, index, refs, commit messages and authors are never copied.
The source must descend from public-base. Both identities are pinned full SHAs.
Unknown roots, unsafe links, new binary blobs, and introduced sensitive patterns
refuse the whole export before output creation. --deny-file adds private literal
strings, one per line, without printing their values. It is never exported.
Known managed AGENTS integration blocks are removed in the export only.

Output: tree/ (public candidate), changes.patch (git binary patch against base),
receipt.json (PRIVATE audit/provenance with source identity, hashes and counts).
Keep the receipt private. It is evidence, not an approval or a secret-scan proof.
A separate fresh public clone applies the patch and commits with a public-safe
message and identity. Never push the operator repository or use --all/--mirror.
No git checkout, refs, index, config, hooks, network or source objects are changed.
"""

import argparse
from collections import Counter
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import sys
import tempfile

CODE_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = 'docs/public-export-manifest.json'
SENSITIVE = {
    'user-path': rb'(?<![\w/])/(?:home|Users)/[A-Za-z0-9_.-]+(?:/[^\s\"\'`<>]*)?',
    'tailnet-address': rb'\b(?:100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d+\.\d+|[\w.-]+\.ts\.net)\b',
    'credential': rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----)',
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
               GIT_TERMINAL_PROMPT='0', GIT_NO_REPLACE_OBJECTS='1')
    return env


def git(*args, data=None, extra=None):
    env = git_env()
    env.update(extra or {})
    result = subprocess.run(['git', '-C', str(CODE_ROOT), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if result.returncode:
        # Git errors can include input content or private configured paths.
        raise ValueError('git operation failed: ' + args[0])
    return result.stdout


def commit(value):
    if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', value):
        raise ValueError('source and public-base must be full commit IDs')
    if git('rev-parse', '--verify', value + '^{commit}').decode().strip() != value:
        raise ValueError('identity does not resolve to the requested commit')
    return value


def entries(revision):
    result = {}
    for row in git('ls-tree', '-r', '-z', revision).split(b'\0'):
        if not row:
            continue
        meta, name = row.split(b'\t', 1)
        mode, kind, oid = meta.decode().split()
        path = name.decode('utf-8')
        if kind != 'blob' or mode not in ('100644', '100755', '120000'):
            raise ValueError('unsupported tree entry: ' + path)
        if any(ord(c) < 32 for c in path) or '\\' in path:
            raise ValueError('nonportable tree path')
        if path.startswith('/') or any(p in ('.', '..', '.git') for p in path.split('/')):
            raise ValueError('unsafe tree path')
        result[path] = (mode, oid)
    return result


def blob(oid):
    return git('cat-file', 'blob', oid)


def strip_overlay(data, names):
    count = 0
    for name in names:
        start = ('<!-- ' + name + ':managed:start -->').encode()
        end = ('<!-- ' + name + ':managed:end -->').encode()
        if start not in data and end not in data:
            continue
        if data.count(start) != 1 or data.count(end) != 1:
            raise ValueError('malformed managed AGENTS overlay')
        a, b = data.index(start), data.index(end) + len(end)
        if b <= a:
            raise ValueError('malformed managed AGENTS overlay order')
        data = data[:a] + data[b:]
        count += 1
    if b':managed:' in data:
        raise ValueError('unknown managed AGENTS overlay')
    return data, count


def export(args):
    source, base = commit(args.source), commit(args.public_base)
    git('merge-base', '--is-ancestor', base, source)
    selected, baseline = entries(source), entries(base)
    if MANIFEST not in selected:
        raise ValueError('source lacks the committed export manifest')
    manifest_bytes = blob(selected[MANIFEST][1])
    manifest = json.loads(manifest_bytes)
    if manifest.get('schema') != 1:
        raise ValueError('unknown export manifest schema')
    forbidden = [line for line in Path(args.deny_file).read_bytes().splitlines() if line] if args.deny_file else []
    output = Path(args.output).absolute()
    # Existing directories are never replaced, even empty ones or symlinks.
    if output.exists() or output.is_symlink():
        raise ValueError('output must not exist')
    if CODE_ROOT == output.resolve() or CODE_ROOT in output.resolve().parents:
        raise ValueError('output must be outside the source checkout')
    kept, excluded, findings, sanitized = {}, [], [], []
    for path, (mode, oid) in selected.items():
        if any(fnmatch.fnmatchcase(path, p) for p in manifest['exclude']):
            excluded.append(path)
            continue
        if not any(path == p or (p.endswith('/') and path.startswith(p)) for p in manifest['include']):
            findings.append({'path': path, 'category': 'unlisted-path', 'count': 1})
            continue
        content = blob(oid)
        original = blob(baseline[path][1]) if path in baseline else b''
        if path == 'AGENTS.md':
            content, count = strip_overlay(content, manifest['strip_managed_agents_blocks'])
            if count:
                sanitized.append({'path': path, 'category': 'managed-overlay', 'count': count})
        for label, pattern in SENSITIVE.items():
            matches = Counter(re.findall(pattern, content))
            # Preserve exact generic examples already in the independently
            # verified public base; introduced values/counts require correction.
            old = Counter(re.findall(pattern, original)) if label != 'credential' else Counter()
            count = sum((matches - old).values())
            if count:
                findings.append({'path': path, 'category': label, 'count': count})
        count = sum(content.count(value) for value in forbidden)
        if count:
            findings.append({'path': path, 'category': 'private-deny-list', 'count': count})
        try:
            content.decode('utf-8')
            text = b'\0' not in content
        except UnicodeDecodeError:
            text = False
        if not text and content != original:
            findings.append({'path': path, 'category': 'new-binary', 'count': 1})
        if mode == '120000':
            target = content.decode('utf-8')
            normalized = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
            if target.startswith('/') or '\\' in target or normalized == '..' or normalized.startswith('../'):
                findings.append({'path': path, 'category': 'escaping-link', 'count': 1})
        kept[path] = (mode, content)
    for path, (mode, content) in kept.items():
        if mode == '120000':
            target = posixpath.normpath(posixpath.join(posixpath.dirname(path), content.decode()))
            if target not in kept and not any(p.startswith(target + '/') for p in kept):
                findings.append({'path': path, 'category': 'excluded-link-target', 'count': 1})
    for required in manifest['required']:
        if required not in kept:
            findings.append({'path': required, 'category': 'missing-required', 'count': 1})
    if findings:
        print(json.dumps({'status': 'refused', 'findings': findings}, sort_keys=True))
        return 1
    # Build a tree in an isolated temporary index/object directory. The source
    # object database is read-only via alternates, never copied into the output.
    with tempfile.TemporaryDirectory(prefix='fm-public-export-') as scratch:
        temp = Path(scratch)
        (temp / 'objects').mkdir()
        common = Path(git('rev-parse', '--git-common-dir').decode().strip())
        if not common.is_absolute():
            common = CODE_ROOT / common
        env = {'GIT_INDEX_FILE': str(temp / 'index'),
               'GIT_OBJECT_DIRECTORY': str(temp / 'objects'),
               'GIT_ALTERNATE_OBJECT_DIRECTORIES': str((common / 'objects').resolve())}
        git('read-tree', '--empty', extra=env)
        index = b''
        for path, (mode, content) in kept.items():
            oid = git('hash-object', '-w', '--stdin', data=content, extra=env).strip()
            index += mode.encode() + b' ' + oid + b'\t' + path.encode() + b'\0'
        git('update-index', '-z', '--index-info', data=index, extra=env)
        tree = git('write-tree', extra=env).decode().strip()
        patch = git('-c', 'diff.noprefix=false', 'diff', '--binary', '--full-index',
                    '--no-ext-diff', '--no-textconv', '--no-renames',
                    '--src-prefix=a/', '--dst-prefix=b/', base, tree, '--', extra=env)
    receipt = {
        'schema': 1, 'source_commit': source,
        'source_tree': git('rev-parse', source + '^{tree}').decode().strip(),
        'public_base_commit': base, 'public_tree': tree,
        'manifest_sha256': digest(manifest_bytes), 'patch_sha256': digest(patch),
        'excluded': excluded, 'sanitized': sanitized,
        'files': [{'path': p, 'mode': m, 'sha256': digest(b)} for p, (m, b) in kept.items()],
        'history_exported': False,
        'limits': 'Heuristic scan, not publication approval; independently review the diff and public base. Receipt is private.'}
    output.mkdir(parents=False, mode=0o700)
    (output / 'tree').mkdir()
    for path, (mode, content) in kept.items():
        destination = output / 'tree' / PurePosixPath(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if mode == '120000':
            destination.symlink_to(content.decode())
        else:
            destination.write_bytes(content)
            destination.chmod(0o755 if mode == '100755' else 0o644)
    (output / 'changes.patch').write_bytes(patch)
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'status': 'exported', 'files': len(kept), 'excluded': len(excluded),
                      'sanitized': len(sanitized), 'public_tree': tree, 'patch_sha256': digest(patch)}))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--source', required=True)
    parser.add_argument('--public-base', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--deny-file')
    args = parser.parse_args()
    try:
        return export(args)
    except (ValueError, OSError, UnicodeError, KeyError) as error:
        # Values from the tree are never printed in failures.
        print('fm-public-export: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
