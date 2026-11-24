#!/usr/bin/env python3
"""Own a worker's temporary processes, independently of its terminal backend.

Usage: python3 fm-worker-processes.py run SCOPE SHELL-COMMAND [HOME CONFIG]
       python3 fm-worker-processes.py cleanup-meta STATE/TASK.meta
       python3 fm-worker-processes.py sample STATE
       python3 fm-worker-processes.py footprint STATE
       python3 fm-worker-processes.py park-safe STATE/TASK.meta
       python3 fm-worker-processes.py park-gone STATE/TASK.meta
       python3 fm-worker-processes.py owns STATE/TASK.meta PID

Spawn records process_scope=STATE/TASK:spawn_gen and runs this wrapper with
FM_WORKER_PROCESS_SCOPE set to that value, after environment filtering.
Linux uses a child subreaper: even double-forked children that clear their
environment stay below the wrapper. Other platforms use inherited identity
plus live descendants; detached children that also strip identity can escape.
TERM, a two-second grace, then KILL precede verification. Zombies are reaped
by the wrapper as soon as they exit, not only at the end: as subreaper it
inherits every orphan of a long-lived worker, and unreaped ones accumulated by
the hundreds (472 under one test-running worker on 9 Nov 2026). No process-name, cwd, session-wide, or cross-home matching.
On Linux a worker launched without DBUS_SESSION_BUS_ADDRESS gets one private
session bus owned by its scope: otherwise every Secret Service lookup (gh
keeps its token in the keyring) autolaunched a new dbus-daemon and
gnome-keyring-daemon that never exited (63 pairs, ~517 MB, on 9 Nov 2026).
macOS needs no bus; its keychain has no per-call daemon.
Python 3 is required on the common worker launch and cleanup path.
The wrapper publishes agent.liveness on child start and after scope cleanup,
bound to the current process_scope in task metadata; an idle turn is not exit.
Spawn passes HOME and CONFIG explicitly, including when STATE is elsewhere;
standalone callers may omit them for the standard HOME/state layout.
sample appends one worker.procs diagnostic event (bin/fm-diag.sh) per live
scope under STATE: its processes, the zombies they have not reaped, and RSS.
footprint prints one "<task> <rss-kb>" line per live scope under STATE whose
task metadata still records that exact process_scope: the resident memory of
the lane's whole process tree, read through the same per-platform ownership
adapter. bin/fm-capacity.sh owns how admission uses it.
park-safe returns 0 for a verified idle process tree, 1 for extra work, and
2 when the scope or platform cannot establish that fact.
owns returns 0 when PID is inside the task's own process scope, 1 when it is
alive elsewhere (another copy's run), 2 when ownership cannot be established.
"""

import ctypes
import datetime as dt
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import time

KEY = b"FM_WORKER_PROCESS_SCOPE="


def environment(pid):
    try:
        if sys.platform == "linux":
            return Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        if sys.platform == "darwin":
            # KERN_PROCARGS2 supplies argv/env boundaries; ps eww flattens them.
            mib = (ctypes.c_int * 3)(1, 49, pid)
            data = ctypes.create_string_buffer(1024 * 1024)
            size = ctypes.c_size_t(len(data))
            if ctypes.CDLL(None).sysctl(mib, 3, data, ctypes.byref(size), None, 0):
                return []
            raw = data.raw[:size.value]
            argc = struct.unpack_from("i", raw)[0]
            offset = raw.index(b"\0", 4) + 1
            while raw[offset] == 0:
                offset += 1
            for _ in range(argc):
                offset = raw.index(b"\0", offset) + 1
            return raw[offset:].split(b"\0")
    except (OSError, ValueError, IndexError):
        return []
    raise RuntimeError(f"unsupported process ownership platform: {sys.platform}")


def snapshot():
    probe = subprocess.Popen(["ps", "-axo", "pid=,ppid=,uid=,stat=,lstart="],
                             stdout=subprocess.PIPE, text=True)
    rows = probe.communicate()[0]
    if probe.returncode:
        raise RuntimeError("cannot snapshot worker processes")
    return {int(p): (int(parent), stamp) for p, parent, uid, state, stamp in
            (line.split(None, 4) for line in rows.splitlines())
            if int(uid) == os.getuid() and int(p) != probe.pid and not state.startswith("Z")}


def descendants(rows, roots):
    selected = set(roots)
    while True:
        expanded = selected | {pid for pid, (parent, _) in rows.items() if parent in selected}
        if expanded == selected:
            return selected
        selected = expanded


def owned(scope, root=None):
    rows = snapshot()
    # A process-event runner (bin/fm-procevent.sh isolate_process) leads its own
    # group and is owned by its registration, which outlives the worker that
    # armed it: a board listener must survive its owner's exit, park or relaunch.
    exempt = descendants(rows, {pid for pid in rows
                                if f"FM_PROCEVENT_RUNNER_GROUP={pid}".encode() in environment(pid)})
    selected = {pid for pid in rows if KEY + os.fsencode(scope) in environment(pid)}
    if root is not None:
        selected.add(root)
    rows = {pid: row for pid, row in rows.items() if pid not in exempt}
    selected = descendants(rows, selected - exempt)
    return {pid: rows[pid][1] for pid in selected if pid in rows and pid != os.getpid()}


def cleanup(scope, root=None):
    # Keep descendants captured before TERM even if a parent exits first.
    tracked = owned(scope, root)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        current = snapshot()
        for pid, stamp in tracked.items():
            if pid in current and current[pid][1] == stamp:
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + (2 if sig == signal.SIGTERM else 1)
        while time.monotonic() < deadline:
            current = snapshot()
            tracked = {p: s for p, s in tracked.items() if p in current and current[p][1] == s}
            tracked.update(owned(scope, root))
            if not tracked:
                return
            time.sleep(0.1)
    raise RuntimeError(f"worker processes still alive: {sorted(tracked)}")


def publish_liveness(scope, state, home=None, config=None):
    path, gen = scope.rsplit(":", 1)
    task_path = Path(path)
    home = Path(home) if home else task_path.parent.parent
    config = Path(config) if config else home / "config"
    if not (config / "fleet-ledger").exists():
        return
    try:
        meta = dict(line.split("=", 1) for line in Path(path + ".meta").read_text().splitlines() if "=" in line)
        if meta.get("process_scope") != scope:
            return
        value = dict(state=state, source="worker.process", verdict="process_started" if state == "alive" else "process_exited",
                     gen=gen, observed_at=dt.datetime.now(dt.timezone.utc).isoformat())
        result = subprocess.run(["bash", str(Path(__file__).resolve().parent / "fm-fleet-ledger.sh"),
                                 "entity", "agent.liveness", task_path.name], input=json.dumps(value), text=True,
                                env=dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(task_path.parent),
                                         FM_CONFIG_OVERRIDE=str(config)), timeout=10)
        if result.returncode:
            print("worker liveness publication failed", file=sys.stderr)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"worker liveness publication failed: {error}", file=sys.stderr)


def run(scope, command, home=None, config=None):
    if sys.platform == "linux":
        if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0):
            raise OSError(ctypes.get_errno(), "cannot enable worker child subreaper")
        if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            try:
                bus = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1"],
                                     capture_output=True, text=True, timeout=10)
                if bus.returncode == 0 and bus.stdout.strip():
                    os.environ["DBUS_SESSION_BUS_ADDRESS"] = bus.stdout.strip()
            except (OSError, subprocess.TimeoutExpired):
                pass
    elif sys.platform != "darwin":
        raise RuntimeError(f"unsupported worker platform: {sys.platform}")
    # Terminal SIGINT belongs to the interactive harness; HUP/TERM close scope.
    signal.signal(signal.SIGINT, lambda *_: None)
    def stop(sig, _frame):
        raise SystemExit(128 + sig)
    signal.signal(signal.SIGHUP, stop)
    signal.signal(signal.SIGTERM, stop)
    # Workers yield the CPU to the captain's interactive use of the machine
    # (9 Nov 2026: tests and backfills made the desktop sluggish for days).
    # FM_WORKER_NICE=0 keeps normal priority; children inherit it.
    try:
        os.nice(int(os.environ.get("FM_WORKER_NICE", "10")))
    except (OSError, ValueError):
        pass
    try:
        child = subprocess.Popen(["/bin/sh", "-c", command])
        publish_liveness(scope, "alive", home, config)
        # Reap every child that exits, including orphans reparented to this
        # subreaper, until the worker's own shell returns.
        while True:
            pid, status = os.waitpid(-1, 0)
            if pid == child.pid:
                child.returncode = os.waitstatus_to_exitcode(status)
                return child.returncode
    finally:
        # Do not interrupt cleanup a second time while terminal teardown runs.
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        cleanup(scope, os.getpid())
        publish_liveness(scope, "dead", home, config)
        if sys.platform == "linux":
            try:
                while os.waitpid(-1, os.WNOHANG)[0]:
                    pass
            except ChildProcessError:
                pass


def usage(state):
    """Yield (task, meta, procs, zombies, rss_kb) for each live scope under STATE."""
    probe = subprocess.run(["ps", "-axo", "pid=,ppid=,uid=,stat=,rss="], capture_output=True, text=True, check=True)
    rows = {}
    for line in probe.stdout.splitlines():
        pid, parent, uid, stat, rss = line.split()[:5]
        if int(uid) == os.getuid():
            rows[int(pid)] = (int(parent), stat, int(rss))
    prefix = os.fsencode(str(Path(state).resolve())) + b"/"
    scopes = {}
    for pid, (_, stat, _) in rows.items():
        if stat.startswith("Z"):
            continue
        for item in environment(pid):
            if item.startswith(KEY + prefix):
                scopes.setdefault(item[len(KEY):].decode(errors="replace"), set()).add(pid)
    for scope, members in sorted(scopes.items()):
        while True:  # children that cleared their environment still belong
            grown = members | {pid for pid, (parent, stat, _) in rows.items() if parent in members and not stat.startswith("Z")}
            if grown == members:
                break
            members = grown
        task = scope.rsplit(":", 1)[0].rsplit("/", 1)[-1]
        path = Path(state) / f"{task}.meta"
        meta = {}
        if path.is_file():
            meta = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        zombies = sum(1 for parent, stat, _ in rows.values() if stat.startswith("Z") and parent in members)
        yield scope, task, meta, len(members), zombies, sum(rows[pid][2] for pid in members)


def sample(state):
    for _, task, meta, procs, zombies, rss_kb in usage(state):
        subprocess.run(["bash", str(Path(__file__).resolve().parent / "fm-diag.sh"), "emit", "worker.procs", f"task={task}",
                        f"harness={meta.get('harness', '')}", f"procs={procs}", f"zombies={zombies}", f"rss_mb={rss_kb // 1024}"],
                       stdin=subprocess.DEVNULL, timeout=10)
    return 0


def footprint(state):
    for scope, task, meta, _, _, rss_kb in usage(state):
        if meta.get("process_scope") == scope:
            print(task, rss_kb)
    return 0


def park_safe(path, gone=False):
    """Return success only for a verified idle worker process tree on Linux."""
    if sys.platform != 'linux':
        return 2
    try:
        path = Path(path)
        meta = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
        scope = meta['process_scope']
        if scope != f"{path.parent.resolve()}/{path.stem}:{meta['spawn_gen']}":
            return 2
        members = owned(scope)
        if gone:
            return 1 if members else 0
        rows = snapshot()
        names = {pid: Path(f'/proc/{pid}/comm').read_text().strip() for pid in members}
        wrappers = []
        for pid in members:
            args = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
            if any(arg.endswith(b'/fm-worker-processes.py') for arg in args) and b'run' in args and os.fsencode(scope) in args:
                wrappers.append(pid)
        if len(wrappers) != 1:
            return 2
        wrapper = wrappers[0]
        children = lambda pid: [p for p in members if rows[p][0] == pid]
        shells = children(wrapper)
        if len(shells) != 1 or names[shells[0]] not in ('sh', 'bash'):
            return 1
        agents = children(shells[0])
        family = subprocess.run(
            ['bash', '-c', '. "$1"; fm_control_harness_family "$2"', '_',
             str(Path(__file__).resolve().parent / 'fm-control-lib.sh'), meta.get('harness', '')],
            capture_output=True, text=True, timeout=10)
        if family.returncode:
            return 2
        harness = family.stdout
        if len(agents) != 1 or names[agents[0]] != harness or harness not in ('codex', 'claude'):
            return 1
        agent = agents[0]
        allowed = {wrapper, shells[0], agent}
        # Codex's persistent code-mode server is idle only when it has no child.
        for pid in children(agent):
            if harness != 'codex' or names[pid] != 'codex-code-mode' or children(pid):
                return 1
            allowed.add(pid)
        return 0 if set(members) == allowed else 1
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        return 2


def owns(path, pid):
    """Tell whether PID belongs to the task's own process scope."""
    try:
        path = Path(path)
        meta = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
        scope = meta['process_scope']
        if scope != f"{path.parent.resolve()}/{path.stem}:{meta['spawn_gen']}":
            return 2
        return 0 if int(pid) in owned(scope) else 1
    except (OSError, KeyError, ValueError, RuntimeError):
        return 2


def main():
    if len(sys.argv) == 4 and sys.argv[1] == 'owns':
        return owns(sys.argv[2], sys.argv[3])
    if len(sys.argv) == 3 and sys.argv[1] == 'park-safe':
        return park_safe(sys.argv[2])
    if len(sys.argv) == 3 and sys.argv[1] == 'park-gone':
        return park_safe(sys.argv[2], gone=True)
    if len(sys.argv) == 3 and sys.argv[1] == "sample":
        return sample(sys.argv[2])
    if len(sys.argv) == 3 and sys.argv[1] == "footprint":
        return footprint(sys.argv[2])
    if len(sys.argv) in (4, 6) and sys.argv[1] == "run":
        scope = sys.argv[2]
        if os.environ.get(KEY[:-1].decode()) != scope:
            raise RuntimeError("worker scope missing from launch environment")
        return run(scope, *sys.argv[3:])
    if len(sys.argv) == 3 and sys.argv[1] == "cleanup-meta":
        path = Path(sys.argv[2])
        meta = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        scope = meta.get("process_scope")
        if scope:
            if scope != f"{path.parent.resolve()}/{path.stem}:{meta.get('spawn_gen', '')}":
                raise RuntimeError("worker scope does not match task metadata")
            cleanup(scope)
        return 0
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
