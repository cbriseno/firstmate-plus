#!/usr/bin/env python3
"""Worker turn-end adapter for relay-lite; Python 3.9/stdlib, Linux/macOS.

Usage: fm-worker-relay.py HOME STATE ID BUSY_GEN CHECKER
Claude Stop and Codex notify call this with the current launch generation.
CHECKER is relay-lite's relay-check executable (FM_RELAY_CHECK at spawn, then
PATH, then $XDG_DATA_HOME/firstmate-extensions/runtime/context-relay-lite/relay-check).
Thresholds and measurement belong exclusively to that checker. Missing inputs
emit the existing diagnostic event and leave the worker running.

At the first reached limit, request the manual handoff note through fm-send.
At its next completed turn, a nonempty launch-specific note permits fm-control
relaunch with the recorded profile. Never act on terminal/held/parked work or a
retired generation. The hook publishes state/ID.relay-ready; the owning watcher
uses --dispatch HOME STATE to start control outside the retiring worker scope.
It waits for the hook to exit, then publishes ID.relay-result for the watcher's
event classification. Success is informative; failure wakes supervision.
A safe-point note with unavailable activity emits one actionable failure per
verdict through the existing request marker; busy waits, idle recovers.
Replacement spawn retires only obsolete automatic relay inbox requests.
sessions.jsonl owns history. Internal --request/--control
PID modes continue after the native callback exits, without reevaluating usage.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent


def meta(state, task):
    return dict(line.split('=', 1) for line in (state / (task + '.meta')).read_text().splitlines() if '=' in line)


def eligible(state, task, gen):
    record = meta(state, task)
    if record.get('busy_gen') != gen or record.get('kind') not in ('ship', 'scout', 'host'):
        return None
    if (state / (task + '.parked')).exists():
        return None
    status = state / (task + '.status')
    lines = status.read_text().splitlines() if status.exists() else []
    if lines and re.match(r'^(done|failed|blocked|needs-decision|captain-held)\b', lines[-1]):
        return None
    return record


def event(env, task, result, reason):
    subprocess.run(['bash', str(ROOT / 'fm-diag.sh'), 'emit', 'context.relay',
                    'task=' + task, 'result=' + result, 'reason=' + reason],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def status(state, task, message):
    # Session mechanics do not change the worker's declared intent or wait.
    (state / (task + '.relay-result')).write_text('working: context relay ' + message)


def main():
    if sys.argv[1:2] == ['--retire']:
        state, task, current_gen = sys.argv[2:5]
        inbox = Path(state) / (task + '.inbox')
        for message in inbox.glob('*.msg'):
            body = message.read_text().partition('\n--\n')[2]
            match = re.match(r'FIRSTMATE_RELAY_GENERATION=([a-zA-Z0-9._-]+)\n', body)
            # Legacy automatic requests carried generation in the note name.
            if not match and body.startswith('Context relay threshold reached. Finish the current operation safely, then write '):
                match = re.search(r'/relay-note-([a-zA-Z0-9._-]+)\.md ', body)
            if match and match[1] != current_gen:
                (inbox / 'handled').mkdir(exist_ok=True)
                message.rename(inbox / 'handled' / message.name)
        return
    if sys.argv[1:2] == ['--dispatch']:
        home, state = sys.argv[2:4]
        # Recover a completed safe point even when the native callback was lost.
        for path in Path(state).glob('*.meta'):
            task = path.stem
            record = meta(Path(state), task)
            gen = record.get('busy_gen', '')
            data = Path(record.get('sessions_file', '/nonexistent')).parent
            note = data / ('relay-note-' + gen + '.md')
            if not gen or not (data / ('relay-request-' + gen)).exists() or not note.exists() or not note.read_text().strip():
                continue
            if not eligible(Path(state), task, gen):
                continue
            probe = subprocess.run(['bash', '-c',
                'source "$1/fm-backend.sh"; source "$1/fm-busy-lib.sh"; fm_busy_classify_meta "$2" "$3" "$4"',
                '_', str(ROOT), str(path), task, state], text=True, capture_output=True,
                env=dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=state), timeout=15)
            if probe.returncode == 0 and probe.stdout.startswith('idle '):
                ready = Path(state) / (task + '.relay-ready')
                if not ready.exists():
                    ready.write_text(json.dumps([gen, '', 0]))
            elif probe.returncode != 0 or not probe.stdout.startswith('busy '):
                message = ('failed: worker context relay ' + task + ' incomplete; activity=' +
                           (probe.stdout.strip() or 'probe-failed') + '; note=' + str(note))
                # Reuse the request lock and marker to report this verdict once.
                with (data / ('relay-request-' + gen)).open('r+') as request:
                    try:
                        fcntl.flock(request, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        continue
                    if (Path(state) / (task + '.relay-ready')).exists():
                        continue  # A completed native callback already supplied the safe point.
                    if request.read().strip() != message:
                        request.seek(0)
                        request.truncate()
                        request.write(message + '\n')
                        (Path(state) / (task + '.relay-result')).write_text(message)
                        event(dict(os.environ, FM_HOME=home), task, 'incomplete', 'activity-unavailable')
        for ready in Path(state).glob('*.relay-ready'):
            task = ready.name[:-len('.relay-ready')]
            gen, checker, pid = json.loads(ready.read_text())
            env = dict(os.environ)
            env.pop('FM_WORKER_PROCESS_SCOPE', None)
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), home, state, task,
                              gen, checker, '--control', str(pid)], env=env, start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ready.unlink()
        return
    home, state, task, gen, checker = sys.argv[1:6]
    home, state = Path(home), Path(state)
    if not re.fullmatch(r'[a-zA-Z0-9_-][a-zA-Z0-9._-]*', task):
        return
    env = dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(state), FM_TASK_ID=task,
               FM_RELAY_CHECK=checker)
    record = eligible(state, task, gen)
    if not record:
        return
    rows = [json.loads(line) for line in Path(record['sessions_file']).read_text().splitlines()]
    current = next((row for row in reversed(rows) if row.get('status') == 'active'), {})
    if not current.get('session'):
        event(env, task, 'unknown', 'session-unavailable')
        return
    data = Path(record['sessions_file']).parent
    env['FM_DATA_OVERRIDE'] = str(data.parent)
    note = data / ('relay-note-' + gen + '.md')
    mode = sys.argv[6:7]
    if not mode:
        if (data / ('relay-request-' + gen)).exists() and note.exists() and note.read_text().strip():
            (state / (task + '.relay-ready')).write_text(json.dumps([gen, checker, os.getpid()]))
            return
        if not (home / 'config/relay-lite.json').exists():
            return
        payload = {'cwd': record['worktree'], 'transcript_path': current['session']}
        snapshot = state / (task + '.' + gen + '.claude-context.json')
        if record.get('harness') == 'claude' and snapshot.exists():
            payload['statusline'] = json.loads(snapshot.read_text())
        payload = json.dumps(payload)
        check = subprocess.run(['python3', checker, '--json', str(home)], input=payload,
                               text=True, capture_output=True, env=env, timeout=10)
        result = json.loads(check.stdout) if check.returncode == 0 else {}
        if result.get('schema') != 'relay-lite.check.v1' or result.get('state') != 'reached':
            if result.get('state', 'unknown') == 'unknown':
                event(env, task, 'unknown', result.get('reason') or 'checker-unavailable')
            return
        if note.exists() and note.read_text().strip():
            (state / (task + '.relay-ready')).write_text(json.dumps([gen, checker, os.getpid()]))
            return
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), *sys.argv[1:6],
                          '--request', str(os.getpid())], env=env, start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    # Release the native hook before sending the inbox doorbell or exit command.
    for _ in range(100):
        if int(sys.argv[7]) == 0:
            break
        try:
            os.kill(int(sys.argv[7]), 0)
        except ProcessLookupError:
            break
        time.sleep(.1)
    else:
        event(env, task, 'incomplete', 'hook-still-running')
        return
    # Serialize replayed callbacks and retain a successfully sent request for
    # this launch so another callback cannot queue the same handoff again.
    request = (data / ('relay-request-' + gen)).open('a+')
    try:
        fcntl.flock(request, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    record = eligible(state, task, gen)
    if not record:
        return
    if mode == ['--request']:
        request.seek(0)
        if request.read():
            return
        message = (f'FIRSTMATE_RELAY_GENERATION={gen}\n'
                   f'This request applies only to generation {gen}. If task metadata busy_gen differs, '
                   'acknowledge this obsolete message and continue your assignment without waiting or writing its note. '
                   f'Context relay threshold reached. Finish the current operation safely, then write {note} '
                   'with objective, completed work, worktree/branch, evidence, remaining work, exact steering inbox '
                   'and external actions that must not be repeated. Temporary descendants will be terminated: wait for them '
                   'to finish or checkpoint them; only jobs started through fm-task-job.py survive. Acknowledge this message, end your turn and '
                   'start no new operation. The owning watcher will relaunch this task with that note. '
                   'Do not report done unless the actual assignment is complete.')
        sent = subprocess.run(['bash', str(ROOT / 'fm-send.sh'), task, message], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if sent.returncode == 0:
            request.write('requested\n')
            request.flush()
        status(state, task, 'handoff requested' if sent.returncode == 0 else 'incomplete: inbox delivery failed')
        return
    if mode != ['--control'] or not note.exists() or not note.read_text().strip():
        return
    status(state, task, 'relaunching from session ' + current['session'] + '; note=' + str(note))
    # Keep command output in memory; logs and transcript content stay out of notices.
    control = subprocess.run(['bash', str(ROOT / 'fm-control.sh'), task, 'relaunch',
                              '--harness', record['harness'], '--model', record['model'],
                              '--effort', record['effort'], '--note-file', str(note)],
                             env=env, text=True, capture_output=True)
    log = data / ('relay-control-' + gen + '.log')
    with log.open('w') as stream:
        subprocess.run([sys.executable, str(ROOT / 'fm-redact-log.py')],
                       input=control.stdout + control.stderr, text=True, stdout=stream, check=True)
    if control.returncode:
        status(state, task, 'incomplete; work and note preserved; diagnostic=' + str(log))
        (state / (task + '.relay-result')).write_text('failed: worker context relay ' + task + ' incomplete; diagnostic=' + str(log))
        event(env, task, 'incomplete', 'control-relaunch-failed')
        return
    status(state, task, 'replacement launched; session history=' + record['sessions_file'])
    (state / (task + '.relay-result')).write_text('working: worker context relay ' + task + ' replacement launched; session history=' + record['sessions_file'])
    event(env, task, 'launched', 'safe-point')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
        print('worker context relay unavailable: ' + type(error).__name__, file=sys.stderr)
        if len(sys.argv) >= 6 and not sys.argv[1].startswith('--'):
            status(Path(sys.argv[2]), sys.argv[3], 'incomplete: ' + type(error).__name__)
            (Path(sys.argv[2]) / (sys.argv[3] + '.relay-result')).write_text(
                'failed: worker context relay ' + sys.argv[3] + ' incomplete: ' + type(error).__name__)
