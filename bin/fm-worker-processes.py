#!/usr/bin/env python3
"""Own a worker's temporary processes, independently of its terminal backend.

Usage: python3 fm-worker-processes.py run SCOPE SHELL-COMMAND
       python3 fm-worker-processes.py cleanup-meta STATE/TASK.meta
       python3 fm-worker-processes.py sample STATE

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
sample appends one worker.procs diagnostic event (bin/fm-diag.sh) per live
scope under STATE: its processes, the zombies they have not reaped, and RSS.
"""

import ctypes
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


def owned(scope, root=None):
    rows = snapshot()
    selected = {pid for pid in rows if KEY + os.fsencode(scope) in environment(pid)}
    if root is not None:
        selected.add(root)
    while True:
        expanded = selected | {pid for pid, (parent, _) in rows.items() if parent in selected}
        if expanded == selected:
            break
        selected = expanded
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


def run(scope, command):
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
        if sys.platform == "linux":
            try:
                while os.waitpid(-1, os.WNOHANG)[0]:
                    pass
            except ChildProcessError:
                pass


def sample(state):
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
        meta = Path(state) / f"{task}.meta"
        harness = ""
        if meta.is_file():
            harness = next((line[8:] for line in meta.read_text().splitlines() if line.startswith("harness=")), "")
        zombies = sum(1 for parent, stat, _ in rows.values() if stat.startswith("Z") and parent in members)
        rss_mb = sum(rows[pid][2] for pid in members) // 1024
        subprocess.run(["bash", str(Path(__file__).resolve().parent / "fm-diag.sh"), "emit", "worker.procs", f"task={task}",
                        f"harness={harness}", f"procs={len(members)}", f"zombies={zombies}", f"rss_mb={rss_mb}"],
                       stdin=subprocess.DEVNULL, timeout=10)
    return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "sample":
        return sample(sys.argv[2])
    if len(sys.argv) == 4 and sys.argv[1] == "run":
        scope = sys.argv[2]
        if os.environ.get(KEY[:-1].decode()) != scope:
            raise RuntimeError("worker scope missing from launch environment")
        return run(scope, sys.argv[3])
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
