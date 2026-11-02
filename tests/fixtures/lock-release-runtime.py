#!/usr/bin/env python3
"""Real process ancestry and private Unix metadata server for lock release."""

import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading


ROOT, SCRATCH = map(Path, sys.argv[2:])
SERVER = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
ENDPOINT = SCRATCH / "native.sock"
SERVER.bind(str(ENDPOINT))
SERVER.listen()
META = {}
CALLS = []
ERRORS = []


def take(stream, size):
    data = b""
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


def serve():
    while True:
        conn, _ = SERVER.accept()
        try:
            stream = conn.makefile("rb", buffering=0)
            request = b""
            while b"\r\n\r\n" not in request:
                request += take(stream, 1)
            headers = dict(line.split(b": ", 1) for line in request.split(b"\r\n")[1:] if b": " in line)
            key = base64.b64encode(hashlib.sha1(headers[b"Sec-WebSocket-Key"] + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + key + b"\r\n\r\n")
            while True:
                first, second = take(stream, 2)
                assert first == 0x81 and second & 128
                size = second & 127
                if size == 126:
                    size = struct.unpack("!H", take(stream, 2))[0]
                elif size == 127:
                    size = struct.unpack("!Q", take(stream, 8))[0]
                mask, payload = take(stream, 4), take(stream, size)
                request = json.loads(bytes(c ^ mask[i % 4] for i, c in enumerate(payload)))
                method = request["method"]
                CALLS.append(method)
                assert method in ("initialize", "initialized", "thread/read", "thread/loaded/list")
                if "id" not in request:
                    continue
                if method == "initialize":
                    result = {}
                elif method == "thread/loaded/list":
                    result = {"data": list(META.get("loaded", [])), "nextCursor": META.get("cursor")}
                else:
                    sid = request["params"]["threadId"]
                    row = META["threads"][sid]
                    result = {"thread": {"id": sid, "cwd": row[0], "status": {"type": row[1]}}}
                payload = json.dumps({"id": request["id"], "result": result}).encode()
                header = bytes([0x81, len(payload)]) if len(payload) < 126 else b"\x81\x7e" + struct.pack("!H", len(payload))
                conn.sendall(header + payload)
        except (EOFError, BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            ERRORS.append(repr(error))
        finally:
            stream.close()
            conn.close()


threading.Thread(target=serve, daemon=True).start()


def run(command, env, expected=0):
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=12)
    assert result.returncode == expected, (command, result.returncode, result.stdout, result.stderr)
    return result.stdout


# Every case uses this one private runtime process and executable. Sample their
# invariant identity once; each public release still verifies it independently.
RUNTIME_ENV = dict(os.environ, FM_HOME=str(SCRATCH / "identity-home"), CODEX_THREAD_ID="outgoing", FM_LIVE="0")
for key in ("FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_PROC_ROOT_OVERRIDE", "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID",
            "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE"):
    RUNTIME_ENV.pop(key, None)
(SCRATCH / "identity-home/state").mkdir(parents=True)
RUNTIME_IDENTITY = run(["bash", "-c", '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"',
                        "fixture", str(ROOT), str(os.getpid())], RUNTIME_ENV).strip()
EXECUTABLE = str(Path(sys.executable).resolve())
EXECUTABLE_HASH = hashlib.sha256(Path(EXECUTABLE).read_bytes()).hexdigest()


def fixture(label):
    home = SCRATCH / label
    home.mkdir()
    (home / "state").mkdir()
    (home / "bin").mkdir()
    (home / "AGENTS.md").write_text("fixture\n")
    subprocess.run(["git", "init", "-q", str(home)], check=True)
    state = home / "state"
    (state / ".lock").write_text(str(os.getpid()) + "\n")
    env = dict(RUNTIME_ENV, FM_HOME=str(home))
    binding = {"schema": "fm-codex-primary-ingress.v1", "home": str(home), "thread": "outgoing",
               "owner_pid": os.getpid(), "executable": EXECUTABLE,
               "executable_sha256": EXECUTABLE_HASH,
               "remote": "unix://" + str(ENDPOINT),
               "guard": [RUNTIME_IDENTITY, ENDPOINT.stat().st_dev, ENDPOINT.stat().st_ino, (state / ".lock").stat().st_ino]}
    binding_file = state / ".codex-primary-ingress.json"
    binding_file.write_text(json.dumps(binding))
    binding_file.chmod(0o600)
    META.clear()
    META.update(threads={"outgoing": [str(home), "notLoaded"]}, loaded=[])
    command = ["bash", str(ROOT / "bin/fm-lock.sh"), "release", "--authority", "approved fixture handoff", "--receipt", str(home / "receipt")]
    return home, env, command, binding_file


home, env, command, binding = fixture("closed-session")
lock = home / "state/.lock"
original = lock.stat().st_ino
assert "held by live harness" in run(["bash", str(ROOT / "bin/fm-lock.sh"), "status"], env)
# The ordinary acquisition refusal remains intact while the shared daemon lives.
fake = SCRATCH / "direct/codex"
fake.parent.mkdir()
fake.symlink_to("/bin/bash")
acquire = [str(fake), "-c", 'bash "$1/bin/fm-lock.sh"; rc=$?; exit "$rc"', "successor", str(ROOT)]
run(acquire, env, 1)
(home / "state/.lock-session").write_text("outgoing\n")
assert json.loads(run(command, env))["state"] == "released"
receipt = json.loads((home / "receipt/outgoing-retired.json").read_text())
assert receipt["sid"] == "outgoing" and receipt["authority"] == "approved fixture handoff"
assert receipt["former_lock_pid"] == str(os.getpid()) and receipt["at"].endswith("Z")
assert receipt["signals_sent"] is False and receipt["daemon_stopped"] is False
assert receipt["state"] == "released" and receipt["session_status"] == "notLoaded"
assert (home / "receipt/predecessor.lock.retired").stat().st_ino == original
assert (home / "receipt/predecessor.lock-session.retired").read_text() == "outgoing\n"
assert not lock.exists()
assert json.loads(run(command, env))["state"] == "already-released"
run(acquire, env)
successor = lock.read_bytes()
assert json.loads(run(command, env))["state"] == "already-released" and lock.read_bytes() == successor
assert SERVER.fileno() >= 0 and not ERRORS
print("ok - live shared daemon, closed session, preserved receipt, successor acquisition and idempotent replay")

for label, mutate in (
    ("foreign-owner", lambda h, e, b: (h / "state/.lock").write_text("1\n")),
    ("foreign-session", lambda h, e, b: e.update(CODEX_THREAD_ID="other")),
    ("changed-process", lambda h, e, b: b.update(guard=["changed", *b["guard"][1:]])),
    ("foreign-sidecar", lambda h, e, b: (h / "state/.lock-session").write_text("other\n")),
    ("missing-registration", lambda h, e, b: b.update(schema="unregistered")),
    ("foreign-home", lambda h, e, b: META.update(threads={"outgoing": [str(SCRATCH), "idle"]})),
    ("changed-binary", lambda h, e, b: b.update(executable_sha256="0" * 64)),
    ("active-peer", lambda h, e, b: META.update(threads={"outgoing": [str(h), "active"], "peer": [str(h), "active"]}, loaded=["outgoing", "peer"])),
    ("idle-peer", lambda h, e, b: META.update(threads={"outgoing": [str(h), "idle"], "peer": [str(h), "idle"]}, loaded=["peer"])),
    ("incomplete-list", lambda h, e, b: META.update(cursor="repeated")),
    ("missing-live-outgoing", lambda h, e, b: META.update(threads={"outgoing": [str(h), "idle"]}, loaded=[])),
):
    home, env, command, path = fixture(label)
    binding = json.loads(path.read_text())
    mutate(home, env, binding)
    path.write_text(json.dumps(binding))
    before = (home / "state/.lock").read_bytes()
    run(command, env, 1)
    assert (home / "state/.lock").read_bytes() == before and not (home / "receipt").exists()
    print("ok - refuses " + label + " without retiring the lock")

home, env, command, path = fixture("other-home")
META.update(threads={"outgoing": [str(home), "active"], "peer": [str(SCRATCH), "active"]}, loaded=["outgoing", "peer"])
assert json.loads(run(command, env))["state"] == "released"
print("ok - unrelated loaded home does not block the outgoing home")

home, env, command, path = fixture("interrupted-receipt")
assert json.loads(run(command, env))["state"] == "released"
receipt_path = home / "receipt/outgoing-retired.json"
receipt = json.loads(receipt_path.read_text())
receipt["state"] = "prepared"
receipt_path.write_text(json.dumps(receipt))
assert json.loads(run(command, env))["state"] == "already-released"
assert json.loads(receipt_path.read_text())["state"] == "released"
assert not (home / "state/.lock").exists()
print("ok - interrupted final receipt converges without reacquiring or retiring another lock")

home, env, command, path = fixture("prepared-archive")
assert json.loads(run(command, env))["state"] == "released"
receipt_path = home / "receipt/outgoing-retired.json"
receipt = json.loads(receipt_path.read_text())
receipt["state"] = "prepared"
receipt_path.write_text(json.dumps(receipt))
(home / "receipt/predecessor.lock.retired").rename(home / "state/.lock")
assert json.loads(run(command, env))["state"] == "released"
print("ok - interrupted preparation revalidates the outgoing proof before completing")

for harness in ("claude", "codex", "opencode", "grok", "kimi", "pi", "pi-signed", "omp", "cursor-agent"):
    # Retaining a direct anchor requires no primary receiver or Git checkout.
    home = SCRATCH / ("direct-" + harness)
    (home / "state").mkdir(parents=True)
    env = dict(RUNTIME_ENV, FM_HOME=str(home))
    launcher = fake.parent / harness
    if not launcher.exists():
        launcher.symlink_to("/bin/bash")
    script = 'printf "%s\\n" "$$" > "$FM_HOME/state/.lock"; bash "$1/bin/fm-lock.sh" release --authority direct --receipt "$FM_HOME/receipt"; test "$(cat "$FM_HOME/state/.lock")" = "$$"'
    assert '"state": "retained"' in run([str(launcher), "-c", script, "direct", str(ROOT)], env)
    assert not (home / "receipt").exists()
    print("ok - direct " + harness + " anchor is left byte-identical")
assert not ERRORS, ERRORS
