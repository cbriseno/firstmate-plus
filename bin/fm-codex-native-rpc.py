#!/usr/bin/env python3
"""Native Codex transport for the pinned Stop owner and primary qualification.

queue/outcome retain fm-codex-stop-autoarm.sh's unchanged Codex 0.164 contract.

inspect is a read-only qualification probe for an explicitly named thread on
the existing endpoint. It returns only its identity, runtime status and cwd;
it does not load, resume or subscribe to a thread, or select native ownership.
queue-status also reads at most four one-entry queue pages, projecting only
the explicitly requested submission's ID and client ID. Not-found does not
mean delivered; a truncated search remains unknown. Neither mode sends input.
Its use on another version requires coordinated live qualification separately
from the Stop owner's unchanged version pin.

submit is a one-shot qualification of turn/start, not an installed wake owner.
It requires --home, --owner-pid and --executable-sha256, the caller's exact own
CODEX_THREAD_ID, primary-home/lock/ancestor/binary proof and a Unix peer owned
by that PID. The same proof and the exact active/idle thread cwd are checked
before submission. Only threadId/clientUserMessageId/input are sent. No retry,
resume or policy override exists. queue-remove has the same guard and removes
only an exact queued submission/client-ID pair, then verifies its absence.
submit --wait-for-idle 1..180 observes this same loaded thread active then idle
before its single submission. The bounded qualification is not supervision;
expiry, notLoaded, systemError or changed ownership never starts/resumes work.

register is an explicit owning-primary operation after coordinated active/idle
qualification. It atomically records that exact receiver, not a trust setting
or supervision owner, in state/.codex-primary-ingress.json (0600). Schema
fm-codex-primary-ingress.v1 stores home/thread/executable/executable_sha256,
remote/owner_pid/guard/registered_at. Removing it disables new deliveries.
deliver --home H --note-id N delegates only a canonical watcher wake for an
existing pending inbox note through that protected receiver. It never forges
the sender's CODEX_THREAD_ID. A fsynced exclusive state/inbox/.native/N.json
claim precedes the request; accepted, dispatching or unproved replays never
submit again. Missing/invalid receivers remain explicit unavailable receipts
with the note/queue intact. The primary replies through the existing inbox;
native acceptance alone does not establish handling or policy application.

Uses the attested executable's ephemeral `app-server proxy --sock` client;
never starts a server. That command is a byte relay; the existing control
socket requires RFC6455 upgrade and masked JSON text frames, not JSON lines.
Only initialize, an exact thread/read, bounded queue/list, an exact queue/delete,
our queue/add, a guarded turn/start, and bounded turns/list
are allowed. stdout is a metadata projection, stderr never contains vendor
responses. Summary is used only to join our clientId to its turn ID; item
content is discarded in memory. Outcomes use notLoaded. No notification or
arbitrary error text is retained. Requires Python 3's standard library.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import selectors
import socket
import stat
import subprocess
import struct
import sys
import tempfile
import time
import uuid


CAPACITY = "Selected model is at capacity. Please try a different model."
MAX_LINE = 1024 * 1024
PAGES = 4
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def identifier(value):
    if not isinstance(value, str) or not 0 < len(value) < 200:
        raise ValueError()
    if any(ord(c) < 32 for c in value):
        raise ValueError()
    return value


def target_guard(args):
    """Exact current Linux receiver, without borrowing the sender's identity."""
    if not sys.platform.startswith("linux"):
        raise ValueError()
    home = Path(args.home)
    marker = home / ".fm-secondmate-home"
    if not home.is_absolute() or str(home.resolve()) != str(home) or marker.exists() or marker.is_symlink():
        raise ValueError()
    state = home / "state"
    lock = state / ".lock"
    if state.is_symlink() or lock.is_symlink() or lock.read_text().strip() != str(args.owner_pid):
        raise ValueError()
    owner = Path("/proc") / str(args.owner_pid)
    if owner.stat().st_uid != os.getuid() or not os.path.samefile(owner / "exe", args.executable):
        raise ValueError()
    digest = hashlib.sha256()
    with open(args.executable, "rb") as executable:
        for block in iter(lambda: executable.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != args.executable_sha256:
        raise ValueError()
    if not args.remote.startswith("unix:///"):
        raise ValueError()
    endpoint = Path(args.remote[7:])
    endpoint_stat = endpoint.lstat()
    parent = endpoint.parent.stat()
    if (str(endpoint.resolve()) != str(endpoint) or not stat.S_ISSOCK(endpoint_stat.st_mode)
            or endpoint_stat.st_uid != os.getuid() or parent.st_uid != os.getuid() or parent.st_mode & 0o022):
        raise ValueError()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(1)
        peer.connect(str(endpoint))
        peer_pid, peer_uid, _ = struct.unpack("3i", peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if peer_pid != args.owner_pid or peer_uid != os.getuid():
            raise ValueError()
    env = dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(state))
    env.pop("FM_PROC_ROOT_OVERRIDE", None)
    for key in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE"):
        env.pop(key, None)
    proof = subprocess.run(["bash", "-c", r'''
. "$1/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$2" "$2/state" || exit 1
. "$1/fm-wake-lib.sh"
fm_pid_identity "$3"
''', "fm-native-qualification", str(Path(__file__).resolve().parent), str(home), str(args.owner_pid)],
        env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3)
    if proof.returncode or not proof.stdout.strip():
        raise ValueError()
    return (proof.stdout.strip(), endpoint_stat.st_dev, endpoint_stat.st_ino, lock.stat().st_ino)


def primary_guard(args):
    """Only the owning primary may qualify or register an ingress receiver."""
    if os.environ.get("CODEX_THREAD_ID") != args.thread:
        raise ValueError()
    # Kernel ancestry, not a process title or a shared daemon's mere existence.
    pid = os.getpid()
    for _ in range(64):
        if pid == args.owner_pid:
            break
        fields = (Path("/proc") / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
        pid = int(fields[1])
        if not pid:
            raise ValueError()
    else:
        raise ValueError()
    return target_guard(args)


def read_private(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError()
    data = path.read_bytes()
    if len(data) > 16384:
        raise ValueError()
    return json.loads(data)


def write_private(path, value):
    if path.exists() or path.is_symlink():
        read_private(path)
    fd, name = tempfile.mkstemp(prefix=".native-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
        folder = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(folder)
        finally:
            os.close(folder)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def prepare_delivery(args):
    """A registered primary delegates only a wake for an existing inbox note."""
    home = Path(args.home)
    if not home.is_absolute() or str(home.resolve()) != str(home) or (home / "state").is_symlink():
        raise ValueError()
    note = identifier(args.note_id)
    if ".." in note or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in note):
        raise ValueError()
    inbox = home / "state/inbox"
    if inbox.is_symlink():
        raise ValueError()
    pending = inbox / (note + ".note")
    if not pending.exists():
        if (inbox / "handled" / (note + ".note")).is_file():
            return {"state": "already-handled", "note_id": note}
        raise ValueError()
    if pending.is_symlink():
        raise ValueError()
    route_path = home / "state/.codex-primary-ingress.json"
    if not route_path.exists() and not route_path.is_symlink():
        return {"state": "unavailable", "reason": "not-configured", "note_id": note}
    route = read_private(route_path)
    if route.get("schema") != "fm-codex-primary-ingress.v1" or route.get("home") != str(home):
        raise ValueError()
    for field in ("thread", "executable", "executable_sha256", "remote", "owner_pid"):
        setattr(args, field, route[field])
    identifier(args.thread)
    args.guard = tuple(route["guard"])
    if target_guard(args) != args.guard:
        raise ValueError()
    claims = inbox / ".native"
    claims.mkdir(mode=0o700, exist_ok=True)
    info = claims.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError()
    claim = claims / (note + ".json")
    args.client_id = str(uuid.uuid4())
    receipt = {"state": "dispatching", "note_id": note, "client_id": args.client_id, "thread_id": args.thread}
    try:
        fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        return read_private(claim)  # Never replay a possibly accepted input.
    with os.fdopen(fd, "w") as output:
        json.dump(receipt, output, separators=(",", ":"))
        output.flush()
        os.fsync(output.fileno())
    folder = os.open(claims, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(folder)
    finally:
        os.close(folder)
    args.native_claim, args.native_receipt = claim, receipt
    body = ("Firstmate inbox event " + note + ": drain the durable wake queue and inbox, reconcile recorded captain answers "
            "before asking again, and reply to this note after actual handling. An answered question can still await "
            "application; retain that separately and preserve primary-owned policy review. No work deletion is authorized.")
    encoded = subprocess.run(["bash", str(Path(__file__).resolve().parent / "fm-operational-input.sh"), "encode", "watcher"],
        input=body, text=True, capture_output=True, timeout=3, check=True)
    args.native_message = encoded.stdout
    return None


def queue_presence(client, thread, submission):
    cursor = None
    for _ in range(PAGES):
        params = {"threadId": thread, "limit": 1}
        if cursor is not None:
            params["cursor"] = cursor
        page = client.request("thread/queue/list", params)
        for row in page["data"]:
            if row["id"] == submission:
                return {"queue_state": "queued", "client_id": row["client_id"]}
        cursor = page["nextCursor"]
        if cursor is None:
            return {"queue_state": "not-found"}
        identifier(cursor)
    return {"queue_state": "unknown", "reason": "page-bound"}


class Client:
    def __init__(self, args, diagnostic):
        self.diagnostic = diagnostic
        if args.remote != "unix://" and not args.remote.startswith("unix:///"):
            raise ValueError()
        self.deadline = time.monotonic() + (args.wait_for_idle + 6 if args.wait_for_idle else 4)
        self.pending = b""
        self.sequence = 0
        command = [args.executable, "app-server", "proxy"]
        if args.remote != "unix://":
            command += ["--sock", args.remote[7:]]
        self.proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)

    def close(self):
        self.selector.close()
        self.proc.stdin.close()
        if self.proc.poll() is None:
            self.proc.terminate()
        try:
            self.proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()

    def send(self, obj):
        self.diagnostic["phase"] = "write"
        self.send_frame(1, json.dumps(obj, separators=(",", ":")).encode())

    def send_frame(self, opcode, data):
        # The public control socket is WebSocket over Unix, even when reached
        # through the official byte-relay proxy. RFC6455 requires client masks.
        if len(data) > MAX_LINE:
            raise ValueError()
        mask = os.urandom(4)
        size = len(data)
        header = bytes([0x80 | opcode])
        if size < 126:
            header += bytes([0x80 | size])
        elif size < 65536:
            header += b"\xfe" + struct.pack("!H", size)
        else:
            header += b"\xff" + struct.pack("!Q", size)
        self.proc.stdin.write(header + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(data)))
        self.proc.stdin.flush()

    def receive(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0 or not self.selector.select(remaining):
            raise TimeoutError()
        block = os.read(self.proc.stdout.fileno(), 65536)
        if not block:
            raise EOFError()
        self.pending += block
        if len(self.pending) > MAX_LINE + 16384:
            raise ValueError()

    def take(self, size):
        while len(self.pending) < size:
            self.receive()
        data, self.pending = self.pending[:size], self.pending[size:]
        return data

    def upgrade(self):
        self.diagnostic["phase"] = "upgrade"
        key = base64.b64encode(os.urandom(16)).decode()
        request = ("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                   "Sec-WebSocket-Key: " + key + "\r\n\r\n")
        self.proc.stdin.write(request.encode())
        self.proc.stdin.flush()
        while b"\r\n\r\n" not in self.pending:
            if len(self.pending) >= 16384:
                raise ValueError()
            self.receive()
        raw, self.pending = self.pending.split(b"\r\n\r\n", 1)
        if len(raw) > 16384:
            raise ValueError()
        lines = raw.decode("ascii").split("\r\n")
        status = lines[0].split(" ", 2)
        code = int(status[1])
        self.diagnostic["httpCode"] = code
        if status[0] != "HTTP/1.1" or code != 101:
            raise ValueError()
        headers = {}
        for line in lines[1:]:
            name, value = line.split(":", 1)
            name = name.strip().lower()
            if name in headers:
                raise ValueError()
            headers[name] = value.strip()
        expected = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()
        if (headers.get("sec-websocket-accept") != expected
                or headers.get("upgrade", "").lower() != "websocket"
                or "upgrade" not in {v.strip() for v in headers.get("connection", "").lower().split(",")}
                or "sec-websocket-extensions" in headers
                or "sec-websocket-protocol" in headers):
            raise ValueError()

    def line(self):
        # Only the pinned uncompressed JSON text profile, not a general
        # WebSocket stack. Control/continuation frames remain bounded too.
        self.diagnostic["phase"] = "frame"
        parts = bytearray()
        started = False
        for _ in range(128):
            first, second = self.take(2)
            final, opcode = bool(first & 0x80), first & 15
            if first & 0x70 or second & 0x80:
                raise ValueError()
            size = second & 127
            if size == 126:
                size = struct.unpack("!H", self.take(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.take(8))[0]
            if size > MAX_LINE or (opcode >= 8 and (not final or size > 125)):
                raise ValueError()
            data = self.take(size)
            if opcode == 8:
                raise EOFError()
            if opcode == 9:
                self.send_frame(10, data)
                continue
            if opcode == 10:
                continue
            if (opcode == 1 and started) or (opcode == 0 and not started) or opcode not in (0, 1):
                raise ValueError()
            started = True
            parts.extend(data)
            if len(parts) > MAX_LINE:
                raise ValueError()
            if final:
                break
        else:
            raise ValueError()
        self.diagnostic["phase"] = "decode"
        return json.loads(parts)

    def request(self, method, params):
        self.diagnostic["operation"] = method
        self.sequence += 1
        self.send({"id": self.sequence, "method": method, "params": params})
        for _ in range(64):
            obj = self.line()
            if obj.get("id") == self.sequence and "method" not in obj:
                if "error" in obj:
                    self.diagnostic["phase"] = "rpc"
                    code = obj["error"].get("code")
                    if type(code) is int:
                        self.diagnostic["rpcCode"] = code
                    raise ValueError()
                self.diagnostic["phase"] = "project"
                result = obj["result"]
                if method == "thread/read":
                    thread = result["thread"]
                    if thread["id"] != params["threadId"]:
                        raise ValueError()
                    status = thread["status"]["type"]
                    cwd = thread["cwd"]
                    if status not in ("notLoaded", "idle", "active", "systemError"):
                        raise ValueError()
                    if not isinstance(cwd, str) or not cwd.startswith("/") or any(ord(c) < 32 for c in cwd):
                        raise ValueError()
                    # Never return preview, items, history or arbitrary errors.
                    return {"thread_id": thread["id"], "status": status, "cwd": cwd}
                if method == "thread/turns/list":
                    # Drop inseparable content at the decoding boundary,
                    # before returning anything to correlation/outcome logic.
                    data = result["data"]
                    if not isinstance(data, list) or len(data) > 1:
                        raise ValueError()
                    projected = []
                    for turn in data:
                        row = {"id": identifier(turn["id"])}
                        if params["itemsView"] == "summary":
                            row["clients"] = [item.get("clientId") for item in turn.get("items", [])
                                              if item.get("type") == "userMessage"]
                        else:
                            row["status"] = turn.get("status")
                            error = turn.get("error") or {}
                            row["error_class"] = "capacity" if row["status"] == "failed" and error.get("message") == CAPACITY else "other"
                        projected.append(row)
                    return {"data": projected, "nextCursor": result.get("nextCursor")}
                if method == "thread/queue/list":
                    data = result["data"]
                    if not isinstance(data, list) or len(data) > 1:
                        raise ValueError()
                    # Input stays outside the projection, including user drafts.
                    return {"data": [{"id": identifier(row["id"]),
                                      "client_id": identifier(row["clientUserMessageId"])} for row in data],
                            "nextCursor": result.get("nextCursor")}
                if method == "turn/start":
                    turn = result["turn"]
                    status = turn["status"]
                    if status not in ("inProgress", "completed", "failed", "interrupted"):
                        raise ValueError()
                    return {"turn_id": identifier(turn["id"]), "status": status}
                if method == "thread/queue/delete":
                    if type(result["deleted"]) is not bool:
                        raise ValueError()
                    return {"deleted": result["deleted"]}
                return result
            # Ignore unsolicited traffic, including other threads, without
            # inspecting, projecting, logging or responding to its payload.
        raise ValueError()

    def turns(self, thread, view):
        cursor = None
        for _ in range(PAGES):
            params = {"threadId": thread, "limit": 1,
                      "sortDirection": "desc", "itemsView": view}
            if cursor is not None:
                params["cursor"] = cursor
            result = self.request("thread/turns/list", params)
            data = result["data"]
            if not isinstance(data, list) or len(data) > 1:
                raise ValueError()
            yield from data
            cursor = result.get("nextCursor")
            if cursor is None:
                return
            identifier(cursor)


def project(args, client):
    thread = identifier(args.thread)
    client.upgrade()
    client.request("initialize", {
        "clientInfo": {"name": "firstmate_native_owner", "version": "1"},
        "capabilities": {"experimentalApi": True, "requestAttestation": False},
    })
    client.send({"method": "initialized"})
    if args.mode == "inspect":
        return client.request("thread/read", {"threadId": thread, "includeTurns": False})
    if args.mode == "register":
        metadata = client.request("thread/read", {"threadId": thread, "includeTurns": False})
        if (metadata["cwd"] != args.home or metadata["status"] not in ("active", "idle")
                or primary_guard(args) != args.guard):
            raise ValueError()
        route = {field: getattr(args, field) for field in
                 ("home", "thread", "executable", "executable_sha256", "remote", "owner_pid", "guard")}
        route.update(schema="fm-codex-primary-ingress.v1", registered_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        write_private(Path(args.home) / "state/.codex-primary-ingress.json", route)
        return {"state": "registered", "thread_id": thread}
    if args.mode in ("queue-status", "queue-remove"):
        submission = identifier(args.submission_id)
        metadata = client.request("thread/read", {"threadId": thread, "includeTurns": False})
        base = {"thread_id": thread, "thread_status": metadata["status"], "submission_id": submission}
        presence = queue_presence(client, thread, submission)
        if args.mode == "queue-remove" and presence["queue_state"] == "queued":
            client.diagnostic["phase"] = "primary-guard"
            if (metadata["cwd"] != args.home or metadata["status"] not in ("active", "idle")
                    or presence["client_id"] != identifier(args.client_id) or primary_guard(args) != args.guard):
                raise ValueError()
            if time.monotonic() >= client.deadline:
                raise TimeoutError()
            deletion = client.request("thread/queue/delete", {"threadId": thread, "queuedSubmissionId": submission})
            presence = queue_presence(client, thread, submission)
            if presence["queue_state"] != "not-found":
                raise ValueError()
            return dict(base, queue_state="removed" if deletion["deleted"] else "not-found", client_id=args.client_id)
        return dict(base, **presence)
    if args.mode in ("submit", "deliver"):
        client_id = identifier(args.client_id)
        if str(uuid.UUID(client_id)) != client_id:
            raise ValueError()
        metadata = client.request("thread/read", {"threadId": thread, "includeTurns": False})
        idle_observed_at = None
        if args.wait_for_idle:
            deadline = time.monotonic() + args.wait_for_idle
            if metadata["status"] != "active" or metadata["cwd"] != args.home:
                raise ValueError()
            while True:
                if time.monotonic() >= deadline:
                    raise TimeoutError()
                time.sleep(min(1, max(0, deadline - time.monotonic())))
                metadata = client.request("thread/read", {"threadId": thread, "includeTurns": False})
                if metadata["cwd"] != args.home or metadata["status"] not in ("active", "idle"):
                    raise ValueError()
                if metadata["status"] == "idle":
                    idle_observed_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    break
        client.diagnostic["phase"] = "primary-guard"
        guard = target_guard if args.mode == "deliver" else primary_guard
        if (metadata["cwd"] != args.home or metadata["status"] not in ("active", "idle")
                or guard(args) != args.guard):
            raise ValueError()
        if args.mode == "deliver" and not (Path(args.home) / "state/inbox" / (args.note_id + ".note")).is_file():
            return {"state": "already-handled"}
        message = args.native_message if args.mode == "deliver" else sys.stdin.buffer.read(16385).decode()
        if not message.strip() or len(message.encode()) > 16384:
            raise ValueError()
        if time.monotonic() >= client.deadline:
            raise TimeoutError()
        result = client.request("turn/start", {
            "threadId": thread, "clientUserMessageId": client_id,
            "input": [{"type": "text", "text": message, "text_elements": []}],
        })
        if idle_observed_at:
            result["idle_observed_at"] = idle_observed_at
        return dict(result, client_id=client_id)
    if args.mode == "queue":
        client_id = identifier(args.client_id)
        # Only the owner's freshly generated operational instruction arrives
        # here. Never read a transcript, old queue input or response input.
        message = os.read(0, 16385).decode()
        if not message or len(message.encode()) > 16384:
            raise ValueError()
        result = client.request("thread/queue/add", {
            "threadId": thread, "clientUserMessageId": client_id,
            "input": [{"type": "text", "text": message, "textElements": []}],
        })
        submission = result["queuedSubmission"]
        if submission["clientUserMessageId"] != client_id:
            raise ValueError()
        return {"client_id": client_id, "submission": identifier(submission["id"])}
    turn_id = args.turn_id
    if not turn_id:
        client_id = identifier(args.client_id)
        matches = set()
        for turn in client.turns(thread, "summary"):
            if client_id in turn["clients"]:
                matches.add(identifier(turn["id"]))
            # No item is returned or retained. Content/text/preview is never
            # accessed, compared, formatted, reconstructed or retransmitted.
        if len(matches) != 1:
            return {"status": "unknown", "error_class": "correlation-missing"}
        turn_id = matches.pop()
    identifier(turn_id)
    for turn in client.turns(thread, "notLoaded"):
        if turn.get("id") != turn_id:
            continue
        status = turn.get("status")
        if status not in ("inProgress", "completed", "interrupted", "failed"):
            raise ValueError()
        return {"turn_id": turn_id, "status": status, "error_class": turn["error_class"]}
    return {"turn_id": turn_id, "status": "unknown", "error_class": "outcome-missing"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("inspect", "queue-status", "submit", "queue-remove", "register", "deliver", "queue", "outcome"))
    parser.add_argument("--executable", default="")
    parser.add_argument("--remote", default="")
    parser.add_argument("--thread", default="")
    parser.add_argument("--client-id", default="")
    parser.add_argument("--turn-id", default="")
    parser.add_argument("--submission-id", default="")
    parser.add_argument("--home", default="")
    parser.add_argument("--owner-pid", type=int, default=0)
    parser.add_argument("--executable-sha256", default="")
    parser.add_argument("--wait-for-idle", type=int, default=0)
    parser.add_argument("--note-id", default="")
    args = parser.parse_args()
    if not 0 <= args.wait_for_idle <= 180 or (args.wait_for_idle and args.mode != "submit"):
        parser.error("--wait-for-idle requires submit and a bound of 1..180 seconds")
    client = None
    diagnostic = {"phase": "spawn", "operation": "initialize", "rpcCode": None,
                  "exitCode": None, "deadline": False}
    try:
        if args.mode in ("submit", "queue-remove", "register"):
            diagnostic["phase"] = "primary-guard"
            args.guard = primary_guard(args)
        if args.mode == "deliver":
            diagnostic["phase"] = "registered-target"
            existing = prepare_delivery(args)
            if existing is not None:
                print(json.dumps(existing, separators=(",", ":")))
                return 0
        client = Client(args, diagnostic)
        result = project(args, client)
        if args.mode in ("submit", "queue-remove", "register", "deliver"):
            diagnostic["phase"] = "primary-guard"
            guard = target_guard if args.mode == "deliver" else primary_guard
            if guard(args) != args.guard:
                raise ValueError()
        if args.mode == "deliver":
            receipt = dict(args.native_receipt, **result)
            receipt["state"] = result.get("state", "accepted")
            write_private(args.native_claim, receipt)
            result = receipt
        print(json.dumps(result, separators=(",", ":")))
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError, RecursionError,
            EOFError, TimeoutError, subprocess.SubprocessError) as error:
        # Includes rejected, interrupted and ambiguous dispatch. Never echo a
        # raw exception, vendor error or partially decoded private response.
        diagnostic["deadline"] = isinstance(error, TimeoutError)
        if client is not None:
            diagnostic["exitCode"] = client.proc.poll()
        result = {"status": "unknown", "error_class": "protocol-unproved", "diagnostic": diagnostic}
        if args.mode == "deliver":
            result.update(state="unproved" if hasattr(args, "native_claim") else "unavailable")
            if hasattr(args, "native_claim"):
                result = dict(args.native_receipt, **result)
                try:
                    write_private(args.native_claim, result)
                except (OSError, ValueError):
                    pass  # The pre-dispatch claim still prevents another send.
        print(json.dumps(result, separators=(",", ":")))
        return 1
    finally:
        if client is not None:
            client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
