#!/usr/bin/env python3
"""Fold the registered reason for a blocked-by edge into the task's body.

Usage: fm_block_reason.py <blocker> <reason> < `tasks-axi show <id> --full`
Prints the new body.
Owner of the form: fm-tasks-axi.sh `block <id> --by <task> --because TEXT`.
"""
import json
import sys


def current_body(shown):
    for line in shown.splitlines():
        if line.startswith('  body: '):
            raw = line[len('  body: '):]
            if raw.startswith('"') and raw.endswith('"') and len(raw) > 1:
                try:
                    return json.loads(raw)
                except ValueError:
                    pass
            return '' if raw == '-' else raw
    return ''


def main():
    blocker, reason = sys.argv[1], sys.argv[2]
    entry = 'Blocked by %s because: %s' % (blocker, reason)
    body = current_body(sys.stdin.read())
    lines = body.split('\n') if body else []
    if entry not in lines:
        lines.append(entry)
    sys.stdout.write('\n'.join(lines))


if __name__ == '__main__':
    main()
