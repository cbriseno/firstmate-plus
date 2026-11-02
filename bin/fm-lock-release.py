#!/usr/bin/env python3
"""Lock release mechanics; the shell entrypoint owns usage and the claim lock.

Uses the existing native transport's framing and primary identity proof over a
direct Unix socket. No proxy, signals, load, resume, subscription or input.
Only metadata from initialize, thread/loaded/list and thread/read is consumed.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import socket
import stat
import struct
import subprocess
import sys
import time
from types import SimpleNamespace


BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fm_native", BIN / "fm-codex-native-rpc.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


class Refusal(ValueError):
    """A local diagnostic that contains no native response content."""


class DirectClient(native.Client):
    """Reuse the framing owner without starting or signalling a proxy process."""

    def __init__(self, args):
        self.diagnostic = {}
        self.deadline = time.monotonic() + 4
        self.pending = b""
        self.sequence = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.settimeout(4)
            self.sock.connect(args.remote[7:])
            pid, uid, _ = struct.unpack("3i", self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            if pid != args.owner_pid or uid != os.getuid():
                raise Refusal("native endpoint owner changed")
            self.proc = SimpleNamespace(stdin=self.sock.makefile("wb"),
                                        stdout=self.sock.makefile("rb", buffering=0))
            self.selector = selectors.DefaultSelector()
            self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        except BaseException:
            self.sock.close()
            raise

    def close(self):
        self.selector.close()
        self.proc.stdin.close()
        self.proc.stdout.close()
        self.sock.close()


def regular(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise Refusal("expected an owned regular file")
    return info


def fingerprint(path):
    info = regular(path)
    data = path.read_bytes()
    if len(data) > 4096:
        raise Refusal("oversized lock")
    return {"device": info.st_dev, "inode": info.st_ino,
            "sha256": hashlib.sha256(data).hexdigest()}


def shell_proof(state):
    result = subprocess.run(["bash", "-c", r'''
. "$1/fm-session-lock-lib.sh"
. "$1/fm-wake-lib.sh"
fm_session_lock_owned_by_self "$2" || exit 1
pid=$(cat "$2/.lock") || exit 1
printf '%s\n' "$pid"
fm_pid_identity "$pid" || printf 'unavailable\n'
''', "fm-release-proof", str(BIN), str(state)],
        capture_output=True, text=True, timeout=4)
    if result.returncode:
        raise Refusal("lock does not belong to the outgoing harness")
    return result.stdout.strip().split("\n", 1)


def exclusive_home(client, args):
    """Bounded, complete loaded-session inventory, projected to home and status."""
    client.upgrade()
    client.request("initialize", {
        "clientInfo": {"name": "firstmate_lock_release", "version": "1"},
        "capabilities": {"experimentalApi": True, "requestAttestation": False},
    })
    client.send({"method": "initialized"})
    outgoing = client.request("thread/read", {"threadId": args.thread, "includeTurns": False})
    if Path(outgoing["cwd"]).resolve() != Path(args.home):
        raise Refusal("outgoing session belongs to another home")
    if outgoing["status"] not in ("active", "idle", "notLoaded"):
        raise Refusal("outgoing session status is unproved")
    cursor, seen, cursors = None, set(), set()
    for _ in range(32):
        params = {"limit": 100}
        if cursor is not None:
            params["cursor"] = cursor
        result = client.request("thread/loaded/list", params)
        rows = result["data"]
        if not isinstance(rows, list) or len(rows) > 100:
            raise Refusal("invalid loaded-session inventory")
        for thread in rows:
            native.identifier(thread)
            if thread in seen:
                raise Refusal("changing loaded-session inventory")
            seen.add(thread)
            if thread == args.thread:
                continue
            peer = client.request("thread/read", {"threadId": thread, "includeTurns": False})
            if Path(peer["cwd"]).resolve() == Path(args.home) and peer["status"] != "notLoaded":
                raise Refusal("another live session exists in this home")
        cursor = result.get("nextCursor")
        if cursor is None:
            if (outgoing["status"] == "notLoaded") == (args.thread in seen):
                raise Refusal("outgoing status and loaded inventory disagree")
            return outgoing["status"]
        native.identifier(cursor)
        if cursor in cursors:
            raise Refusal("incomplete loaded-session inventory")
        cursors.add(cursor)
    raise Refusal("loaded-session inventory exceeds bound")


def timestamp():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def release(args):
    home, state, directory = Path(args.home), Path(args.state), Path(args.receipt)
    if (not home.is_absolute() or home.resolve() != home or state.resolve() != state
            or not directory.is_absolute() or directory.resolve() != directory):
        raise Refusal("home, state and receipt must be canonical absolute paths")
    if not args.authority.strip() or len(args.authority) > 4096:
        raise Refusal("handoff authority is required")
    lock, sidecar = state / ".lock", state / ".lock-session"
    receipt, archived = directory / "outgoing-retired.json", directory / "predecessor.lock.retired"
    # A completed receipt authorizes only an idempotent no-op, never a second
    # retirement. In particular, it cannot retire a successor's new lock.
    prior = None
    if directory.exists():
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise Refusal("receipt directory is not private")
        prior = native.read_private(receipt)
        if (prior.get("schema") != "fm-outgoing-retired.v2" or prior.get("home") != args.home
                or prior.get("state") not in ("prepared", "released")
                or prior.get("authority") != args.authority
                or prior.get("sid") != os.environ.get("CODEX_THREAD_ID")):
            raise Refusal("receipt does not identify this outgoing session and authority")
        if archived.exists() and fingerprint(archived) == prior["lock"]:
            if prior["state"] == "released":
                return {"state": "already-released", "receipt": str(receipt)}
            if sidecar.exists() and fingerprint(sidecar) == prior.get("sidecar"):
                # Only finish an interrupted sidecar move while no successor
                # lock exists. A successor's files are never touched.
                if lock.exists() or lock.is_symlink():
                    raise Refusal("successor acquired before sidecar retirement completed")
                os.rename(sidecar, directory / "predecessor.lock-session.retired")
            prior["state"] = "released"
            sync_directory(state)
            native.write_private(receipt, prior)
            return {"state": "already-released", "receipt": str(receipt)}
        if prior.get("state") != "prepared" or archived.exists() or archived.is_symlink():
            raise Refusal("receipt archive is missing or changed")
        if fingerprint(lock) != prior["lock"]:
            raise Refusal("lock changed after release preparation")
    original = fingerprint(lock)
    destination = directory if directory.exists() else directory.parent
    if destination.stat().st_dev != original["device"]:
        raise Refusal("receipt must share the session-lock filesystem")
    owner, identity = shell_proof(state)
    if sys.platform != "linux":
        return {"state": "retained", "reason": "session anchor exits with its harness"}
    argv = (Path("/proc") / owner / "cmdline").read_bytes().split(b"\0")
    # Only the separately hosted native app-server may be retired while alive.
    # An embedded/direct harness keeps its own lock until its normal exit.
    if b"app-server" not in argv[1:]:
        return {"state": "retained", "reason": "session anchor exits with its harness"}
    binding_path = Path(args.binding)
    if state != home / "state":
        raise Refusal("shared-runtime release requires the registered home state directory")
    binding = native.read_private(binding_path)
    digest = hashlib.sha256(binding_path.read_bytes()).hexdigest()
    if (binding.get("schema") != "fm-codex-primary-ingress.v1"
            or binding.get("home") != args.home or str(binding.get("owner_pid")) != owner
            or binding.get("guard", [None])[0] != identity):
        raise Refusal("shared runtime lacks an exact outgoing primary registration")
    proof = SimpleNamespace(**{key: binding[key] for key in
                            ("home", "thread", "executable", "executable_sha256", "remote", "owner_pid")})
    if sidecar.exists() or sidecar.is_symlink():
        regular(sidecar)
        if sidecar.read_text().strip() != proof.thread:
            raise Refusal("lock sidecar names another session")
    guard = native.primary_guard(proof)
    if list(guard) != binding["guard"]:
        raise Refusal("registered primary identity changed")
    client = DirectClient(proof)
    try:
        status = exclusive_home(client, proof)
        if (native.primary_guard(proof) != guard or fingerprint(lock) != original
                or hashlib.sha256(binding_path.read_bytes()).hexdigest() != digest):
            raise Refusal("outgoing proof changed before release")
        if prior is None:
            directory.mkdir(mode=0o700)
            prior = {"schema": "fm-outgoing-retired.v2", "state": "prepared", "at": timestamp(),
                     "sid": proof.thread, "former_lock_pid": owner, "process_identity": identity,
                     "role": "read-only retired primary", "authority": args.authority,
                     "home": args.home, "lock": original, "session_status": status,
                     "released_by_uid": os.getuid(),
                     "sidecar": fingerprint(sidecar) if sidecar.exists() else None,
                     "daemon_stopped": False, "signals_sent": False}
            native.write_private(receipt, prior)
        # Same-filesystem rename preserves the original inode and its contents.
        if fingerprint(lock) != prior["lock"]:
            raise Refusal("lock changed before archive")
        if prior["sidecar"] is not None and fingerprint(sidecar) != prior["sidecar"]:
            raise Refusal("sidecar changed before archive")
        os.rename(lock, archived)
        if prior["sidecar"] is not None:
            os.rename(sidecar, directory / "predecessor.lock-session.retired")
        sync_directory(state)
        prior["state"] = "released"
        native.write_private(receipt, prior)
        return {"state": "released", "receipt": str(receipt)}
    finally:
        client.close()


def main():
    try:
        fields = sys.stdin.buffer.read(32769).decode().split("\0")
        if len(fields) != 6 or fields[-1] or sum(map(len, fields)) > 32768:
            raise Refusal("invalid release input")
        args = SimpleNamespace(**dict(zip(("home", "state", "authority", "receipt", "binding"), fields)))
        print(json.dumps(release(args)))
    except (OSError, ValueError, KeyError, TypeError, IndexError, AttributeError, RecursionError, EOFError,
            TimeoutError, subprocess.SubprocessError) as error:
        print("error: " + str(error) if isinstance(error, Refusal) else "error: native identity/protocol proof failed (" + type(error).__name__ + ")", file=sys.stderr)
        print("error: lock release was not confirmed; preserve lock and receipt evidence and inspect the same receipt", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
