#!/usr/bin/env bash
# Worker text captures mask credential-bearing lines before persisting them.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT/bin/fm-redact-log.py" <<'PY'
import subprocess
import sys

credential_lines = [
    'Jenkins-Crumb: synthetic-private-value',
    'Authorization: Bearer synthetic-private-value',
    'Set-Cookie: sid=synthetic-private-value; Secure',
    '{"access_token": "synthetic-private-value", "ok": true}',
    '+ export API_KEY=synthetic-private-value',
    'csrf_token=synthetic-private-value',
    'password="synthetic-private-value with spaces"',
    'client_secret: synthetic-private-value',
]
text = 'build status: ready\n' + '\n'.join(credential_lines) + '\nfinished\n'
result = subprocess.run([sys.executable, sys.argv[1]], input=text,
                        text=True, capture_output=True, check=True)
assert result.stdout == ('build status: ready\n' +
                         '[REDACTED credential line]\n' * len(credential_lines) +
                         'finished\n'), result.stdout
assert not result.stderr
print('ok - captured logs mask crumb, authorization, cookies, tokens, keys and passwords')
PY
