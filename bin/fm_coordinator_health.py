"""Controlled application's lifetime owner for the existing supervision host.

One thread owns park/restart; no hook owns a second cycle in this application.
FM_COORDINATOR_GRACE (300s) bounds pending wakes/inboxes and stale heartbeats;
FM_COORDINATOR_POLL (5s) bounds inspection frequency. The host alone repairs
sources/deliveries. This module observes them and emits transition alarms through
the existing optional fm-notify.py contract; delivery belongs to the installation.
The current verdict is always in state/.coordinator-health.json and every reply;
a terminal also keeps it in its title. SIGKILL/machine death needs an external
process manager and is outside this opt-in pilot's availability guarantee.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import tempfile
import time

BIN = Path(__file__).resolve().parent


class Health:
    def __init__(self, home, env):
        self.home, self.env = home, env
        self.state = home / 'state'
        self.status = 'starting'
        self.reason = ''
        self.pending = []
        self.alarm_active = False
        self.park = None
        self.started = time.monotonic()
        self.stop = threading.Event()
        self.grace = max(1, int(env.get('FM_COORDINATOR_GRACE', '300')))
        self.poll = max(1, int(env.get('FM_COORDINATOR_POLL', '5')))
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def verdict(self, state, reason=''):
        previous = self.status
        changed = (state, reason) != (previous, self.reason)
        self.status, self.reason = state, reason
        record = dict(state=state, reason=reason, pending=self.pending, at=time.time(), owner_pid=os.getpid())
        path = self.state / '.coordinator-health.json'
        with tempfile.NamedTemporaryFile(mode='w', dir=self.state, prefix='.coordinator-health-', delete=False) as stream:
            json.dump(record, stream)
        Path(stream.name).replace(path)
        if not changed:
            return
        print('Firstmate supervision: ' + state + (': ' + reason if reason else ''), file=sys.stderr, flush=True)
        if sys.stderr.isatty():
            print('\033]0;Firstmate supervision: ' + state + '\007', end='', file=sys.stderr, flush=True)
        # Only actual transitions alarm; initial healthy/idle is silent externally.
        if state == 'degraded' and not self.alarm_active or state in ('healthy', 'idle') and self.alarm_active:
            self.alarm_active = state == 'degraded'
            event = 'supervision-' + ('degraded' if state == 'degraded' else 'recovered')
            r = subprocess.run([sys.executable, str(BIN / 'fm-notify.py'), '--home', str(self.home),
                                *(['--command-file', self.env['FM_NOTIFICATION_COMMAND_FILE']]
                                  if self.env.get('FM_NOTIFICATION_COMMAND_FILE') else []),
                                '--event', event, '--text', ('Supervisión degradada: ' + reason)[:240]
                                if state == 'degraded' else 'Supervisión recuperada.'],
                               env=self.env, capture_output=True, timeout=10)
            if r.returncode:
                print('Firstmate notification command failed; device delivery is unknown.', file=sys.stderr, flush=True)

    def age(self, path):
        try:
            return time.time() - path.stat().st_mtime
        except FileNotFoundError:
            return float('inf')

    def inspect(self, active=True):
        outcomes = subprocess.run(['bash', str(BIN / 'fm-branch-outcome.sh'), 'present'], env=self.env,
                                  text=True, capture_output=True, timeout=10)
        if outcomes.returncode:
            return 'supervision outcomes could not be inspected'
        self.pending = [json.loads(line) for line in outcomes.stdout.splitlines() if line.strip()]
        self.pending = [row for row in self.pending if row.get('verdict') == 'captain']
        for row in self.pending:
            if time.time() - row['epoch'] > self.grace:
                return 'supervision outcome awaiting action: ' + row['summary'][:180]
        if not active:
            return ''
        watcher = subprocess.run(['bash', '-c', '. "$1"; fm_watcher_healthy "$STATE" "$2" "$3" "$FM_HOME"',
                                  '_', str(BIN / 'fm-wake-lib.sh'), str(BIN / 'fm-watch.sh'), str(self.grace)],
                                 env=self.env, capture_output=True, timeout=10)
        if watcher.returncode:
            if time.monotonic() - self.started < 25:
                return 'watcher cycle starting'
            return 'watcher identity or heartbeat absent or expired'
        # A fresh heartbeat cannot hide an old unconsumed obligation.
        queue = self.state / '.wake-queue'
        if queue.exists():
            for row in queue.read_text().splitlines():
                fields = row.split('\t')
                if len(fields) != 5 or not fields[0].isdigit():
                    return 'wake queue unreadable'
                if time.time() - int(fields[0]) > self.grace:
                    return 'supervision obligation awaiting attention'
        for message in self.state.glob('*.inbox/*.msg'):
            if self.age(message) > self.grace:
                return 'worker instruction awaiting acknowledgement'
        result = subprocess.run(['bash', str(BIN / 'fm-procevent.sh'), 'list'], env=self.env,
                                text=True, capture_output=True, timeout=10)
        if result.returncode:
            return 'listener coverage could not be inspected'
        for row in result.stdout.splitlines()[1:]:
            fields = row.split()
            if len(fields) >= 4 and fields[2] in ('none', 'orphaned', 'uncertain') or len(fields) >= 4 and fields[2].endswith('/dead'):
                return 'registered event listener is not listening'
        return ''

    def run(self):
        log = None
        try:
            log = (self.state / '.coordinator-host.log').open('a')
            while not self.stop.is_set():
                if not list(self.state.glob('*.meta')) and not list((self.state / 'procevent').glob('*.source')):
                    reason = self.inspect(active=False)
                    self.verdict('degraded' if reason else 'idle', reason)
                else:
                    if self.park is None:
                        self.started = time.monotonic()
                        self.park = subprocess.Popen(['bash', str(BIN / 'fm-supervision-host.sh'), 'park'],
                            stdout=log, stderr=log, env=self.env, start_new_session=True)
                    elif self.park.poll() is not None:
                        rc = self.park.returncode
                        self.park = None
                        if rc:
                            self.verdict('degraded', 'supervision host exited (' + str(rc) + '); restarting')
                    try:
                        reason = self.inspect()
                    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
                        reason = 'supervision inspection failed: ' + type(e).__name__
                    if self.park is not None and self.park.poll() is None:
                        state = 'starting' if reason == 'watcher cycle starting' else 'degraded' if reason else 'healthy'
                        self.verdict(state, reason)
                self.stop.wait(self.poll)
        except Exception as e:
            self.verdict('degraded', 'supervision owner failed: ' + type(e).__name__)
        finally:
            if self.park is not None and self.park.poll() is None:
                os.killpg(self.park.pid, signal.SIGTERM)
                try:
                    self.park.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(self.park.pid, signal.SIGKILL)
                    self.park.wait()
            if log:
                log.close()

    def close(self):
        self.stop.set()
        self.thread.join(timeout=35)
        if not self.thread.is_alive():
            subprocess.run(['bash', str(BIN / 'fm-supervision-host.sh'), 'stop'], env=self.env,
                           capture_output=True, timeout=90)
        if list(self.state.glob('*.meta')):
            self.verdict('degraded', 'controlled application stopped; supervision has no owner')
