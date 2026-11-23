#!/usr/bin/env bash
# Exercise the real owned process tree and an active child before parking.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-park-safe)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import os, pathlib, signal, subprocess, sys, time
root, tmp = map(pathlib.Path, sys.argv[1:])
tool = root / 'bin/fm-worker-processes.py'
state = tmp / 'state'; state.mkdir()
scope = f'{state}/worker:fixture'
meta = state / 'worker.meta'
meta.write_text(f'process_scope={scope}\nspawn_gen=fixture\nharness=codex\n')
if sys.platform != 'linux':
    assert subprocess.run([sys.executable, str(tool), 'park-safe', str(meta)]).returncode == 2
    assert subprocess.run([sys.executable, str(tool), 'park-gone', str(meta)]).returncode == 2
    sys.exit(0)
agent = tmp / 'agent.py'
mode = tmp / 'mode.py'
mode.write_text('''import ctypes, pathlib, subprocess, sys, time\nctypes.CDLL(None).prctl(15, b"codex-code-mode", 0, 0, 0)\np=pathlib.Path(sys.argv[1]); (p/"ready").touch()\nwhile not (p/"start").exists(): time.sleep(.05)\nc=subprocess.Popen(["sleep", "60"]); (p/"started").touch()\nwhile not (p/"stop").exists(): time.sleep(.05)\nc.terminate(); c.wait(); (p/"stopped").touch()\nwhile not (p/"exit").exists(): time.sleep(.05)\n''')
agent.write_text('''import ctypes, pathlib, subprocess, sys\nctypes.CDLL(None).prctl(15, b"codex", 0, 0, 0)\np=pathlib.Path(sys.argv[1]); c=subprocess.Popen([sys.executable, str(p/"mode.py"), str(p)]); c.wait()\n''')
import shlex
command = f'{shlex.quote(sys.executable)} {shlex.quote(str(agent))} {shlex.quote(str(tmp))}; :'
worker = subprocess.Popen([sys.executable, str(tool), 'run', scope, command],
                          env=dict(os.environ, FM_WORKER_PROCESS_SCOPE=scope))
def wait(name):
    for _ in range(600):
        if (tmp / name).exists(): return
        if worker.poll() is not None: raise AssertionError('worker exited before ' + name)
        time.sleep(.1)
    raise AssertionError('worker did not reach ' + name)
def probe(verb='park-safe'):
    return subprocess.run([sys.executable, str(tool), verb, str(meta)]).returncode
try:
    wait('ready')
    assert probe() == 0, 'idle worker was not recognized'
    meta.write_text(f'process_scope={scope}\nspawn_gen=fixture\nharness=codex-cli\n')
    assert probe() == 0, 'recorded harness aliases did not use the control adapter'
    assert probe('park-gone') == 1, 'live worker was incorrectly treated as gone'
    (tmp/'start').touch(); wait('started')
    assert probe() == 1, 'live child was incorrectly treated as safe'
    (tmp/'stop').touch(); wait('stopped')
    assert probe() == 0, 'worker did not become safe after its child exited'
    meta.write_text('spawn_gen=fixture\nharness=codex\n')
    assert probe() == 2, 'missing scope was not unknown'
finally:
    (tmp/'exit').touch()
    try: worker.wait(timeout=20)
    except subprocess.TimeoutExpired:
        worker.send_signal(signal.SIGTERM); worker.wait(timeout=20)
meta.write_text(f'process_scope={scope}\nspawn_gen=fixture\nharness=codex\n')
assert probe('park-gone') == 0, 'empty scope did not permit interrupted park recovery'
PY
pass 'parking waits for owned children and refuses an unknown scope'
