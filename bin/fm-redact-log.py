#!/usr/bin/env python3
"""Usage: command 2>&1 | python3 bin/fm-redact-log.py > captured.log

Mask credential-bearing lines before saving or sharing a worker's captured log.
This is a text-log filter, not a structured process-event payload transformer.
Unlabeled secrets cannot be recognized; select nonsecret fields when possible.
"""
import re
import sys

# Drop the whole line so quoted values, multiple fields, and shell trace output
# cannot leave a suffix of a credential behind. Preserve ordinary log lines.
CREDENTIAL = re.compile(
    r"(?i)(?:authorization|proxy-authorization|set-cookie|cookie)\s*['\"]?\s*[:=]"
    r"|\bbearer\s+\S+"
    r"|(?:[\w-]*(?:token|password|secret|crumb|csrf|xsrf)[\w-]*|api[_-]?key)"
    r"\s*['\"]?\s*[:=]"
)


def main():
    for line in sys.stdin:
        if CREDENTIAL.search(line):
            sys.stdout.write('[REDACTED credential line]\n')
        else:
            sys.stdout.write(line)


if __name__ == '__main__':
    main()
