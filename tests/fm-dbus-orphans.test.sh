#!/usr/bin/env bash
# fm-dbus-orphans.py lists and closes only autolaunched session buses nobody uses.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "$(uname -s)" != Linux ] || ! command -v dbus-daemon >/dev/null 2>&1; then
  printf 'skip: dbus orphans: Linux dbus-daemon absent\n'
  exit 0
fi

python3 - "$ROOT" <<'PY' || fail 'an unused autolaunched bus must be listed and closable, a used one never'
import os, pathlib, socket, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
tool = [sys.executable, str(root/'bin/fm-dbus-orphans.py')]
# The exact argv libdbus autolaunch uses, printing pid and address to stdout.
out = subprocess.run(['dbus-daemon', '--syslog', '--fork', '--print-pid', '1', '--print-address', '1', '--session'],
                     capture_output=True, text=True, timeout=10).stdout.split()
address, pid = out[0], int(out[1])
path = address.split('=', 1)[1].split(',')[0]
def listed():
    return any(line.startswith(f'bus={pid} ') for line in subprocess.run(tool, capture_output=True, text=True).stdout.splitlines())
try:
    assert listed(), 'an unused autolaunched bus was not listed'
    client = socket.socket(socket.AF_UNIX)
    client.connect(path)
    time.sleep(0.2)
    assert not listed(), 'a bus with a live client was listed'
    refused = subprocess.run(tool + ['--close', str(pid)], capture_output=True, text=True)
    assert refused.returncode == 1 and os.path.exists(f'/proc/{pid}'), 'a used bus was closed'
    client.close()
    time.sleep(0.2)
    closed = subprocess.run(tool + ['--close', str(pid)], capture_output=True, text=True)
    assert closed.returncode == 0, closed.stderr
    for _ in range(50):
        if not os.path.exists(f'/proc/{pid}'):
            break
        time.sleep(0.1)
    else:
        raise AssertionError('the unused bus survived --close')
finally:
    try:
        os.kill(pid, 15)
    except ProcessLookupError:
        pass
PY
pass "fm-dbus-orphans lists and closes an unused autolaunched bus and refuses one with a client"
