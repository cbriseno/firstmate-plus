#!/usr/bin/env python3
"""List or close autolaunched D-Bus session buses that nothing uses any more.

Usage: python3 fm-dbus-orphans.py              list them, one bus per line
       python3 fm-dbus-orphans.py --close PID...  close the listed buses named

A process that reads the keyring without DBUS_SESSION_BUS_ADDRESS (gh keeps
its token there) autolaunches a private `dbus-daemon --syslog --fork
--print-pid N --print-address M --session`, which activates a
gnome-keyring-daemon; both outlive the caller forever. bin/fm-worker-processes.py
prevents this for workers; this finds the pairs already left behind.
A bus is listed only when it has that autolaunch argv, its address is not
published in ~/.dbus/session-bus (the desktop's own autolaunch record), and
it holds no connection beyond one per service it activated (DBUS_STARTER_ADDRESS
names its socket): the autolauncher has exited and no other process knows the
address. Each line names the origin inherited from the bus's environment
(FM_TASK_ID, HERDR_PANE_ID, CLAUDE_CODE_SESSION_ID) so an operator closes only
what they can attribute. --close re-checks each named bus, then sends TERM to
its activated services and the bus. Linux only; elsewhere it lists nothing.
"""

import os
from pathlib import Path
import signal
import sys


def env(pid):
    try:
        raw = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    except OSError:
        return {}
    return dict(item.decode(errors="replace").split("=", 1) for item in raw if b"=" in item)


def argv(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").split("\0")[:-1]
    except OSError:
        return []


def autolaunched(args):
    return (len(args) == 8 and os.path.basename(args[0]) == "dbus-daemon" and
            args[1:3] == ["--syslog", "--fork"] and args[3] == "--print-pid" and
            args[5] == "--print-address" and args[7] == "--session")


def orphans():
    if sys.platform != "linux":
        return {}
    uid = os.getuid()
    mine = []
    for p in os.listdir("/proc"):
        try:
            if p.isdigit() and os.stat(f"/proc/{p}").st_uid == uid:
                mine.append(int(p))
        except OSError:
            pass
    starters = {}
    for p in mine:
        starters.setdefault(env(p).get("DBUS_STARTER_ADDRESS", "").split(",")[0], []).append(p)
    # socket inode -> (state, path) for every named unix socket.
    sockets = {}
    for line in Path("/proc/net/unix").read_text().splitlines()[1:]:
        cols = line.split()
        if len(cols) >= 8:
            sockets[cols[6]] = (cols[5], cols[7])
    published = set()
    for record in (Path.home() / ".dbus/session-bus").glob("*"):
        try:
            published.add(record.read_text())
        except OSError:
            pass
    found = {}
    for pid in mine:
        if not autolaunched(argv(pid)):
            continue
        try:
            inodes = [os.readlink(f"/proc/{pid}/fd/{fd}")[8:-1] for fd in os.listdir(f"/proc/{pid}/fd")]
        except OSError:
            continue
        named = [sockets[i] for i in inodes if i in sockets]
        paths = {path for state, path in named if state == "01"}
        if len(paths) != 1:
            continue
        path = paths.pop()
        if any(f"unix:path={path}," in text for text in published):
            continue
        connections = sum(1 for state, p in named if state == "03" and p == path)
        services = starters.get(f"unix:path={path}", [])
        if connections <= len(services):
            found[pid] = (path, services, env(pid))
    return found


def main():
    args = sys.argv[1:]
    found = orphans()
    if not args:
        for pid, (path, services, e) in sorted(found.items()):
            origin = " ".join(f"{k}={e[k]}" for k in ("FM_TASK_ID", "HERDR_PANE_ID", "CLAUDE_CODE_SESSION_ID") if e.get(k))
            print(f"bus={pid} services={','.join(map(str, services)) or '-'} socket={path} origin={origin or 'unknown'}")
        return 0
    if args[0] != "--close" or len(args) < 2 or not all(a.isdigit() for a in args[1:]):
        raise SystemExit(__doc__)
    status = 0
    for pid in map(int, args[1:]):
        if pid not in found:
            print(f"skipped bus={pid}: not an unused autolaunched bus", file=sys.stderr)
            status = 1
            continue
        for target in found[pid][1] + [pid]:
            try:
                os.kill(target, signal.SIGTERM)
            except ProcessLookupError:
                pass
        print(f"closed bus={pid} services={','.join(map(str, found[pid][1])) or '-'}")
    return status


if __name__ == "__main__":
    sys.exit(main())
