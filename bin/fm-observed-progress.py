#!/usr/bin/env python3
"""Observe only the deliverable files named in the existing progress declaration.

Usage: fm-observed-progress.py PRESENTATION WORKTREE DATA_DIRECTORY
Print ``unknown`` when there is no usable declaration or an observation fails.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

def observe(presentation, worktree, data):
    fields = json.loads(Path(presentation).read_text(encoding='utf-8'))['presentation']
    progress = fields.get('progress') or {}
    deliverables = progress.get('deliverables')
    if not isinstance(deliverables, list) or not deliverables or len(deliverables) > 30:
        return 'unknown'
    digest = hashlib.sha256(json.dumps([fields.get('phase'), progress], sort_keys=True,
                                      separators=(',', ':')).encode())
    roots = {'data': Path(data), 'worktree': Path(worktree) if worktree else None}
    for item in deliverables:
        if not isinstance(item, dict) or set(item) != {'root', 'path'}:
            return 'unknown'
        root = roots.get(item['root'])
        relative = item['path']
        if (root is None or not isinstance(relative, str) or not relative
                or any(part in ('', '.', '..') for part in relative.split('/'))):
            return 'unknown'
        if not root.is_dir():
            return 'unknown'
        base = root.resolve()
        path = (base / relative).resolve()
        if os.path.commonpath((str(base), str(path))) != str(base):
            return 'unknown'
        digest.update(relative.encode('utf-8', 'surrogateescape') + b'\0')
        try:
            info = path.stat()
        except FileNotFoundError:
            digest.update(b'missing\0')
            continue
        if not stat.S_ISREG(info.st_mode):
            return 'unknown'
        with path.open('rb') as stream:
            for block in iter(lambda: stream.read(65536), b''):
                digest.update(block)
    return digest.hexdigest()


if __name__ == '__main__':
    try:
        print(observe(*sys.argv[1:4]))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError):
        print('unknown')
