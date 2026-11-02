"""Hermetic public-protocol peer; never a vendor capability proof.

Only IDs, request method/views, and operational kind are retained. Summary's
private canaries and arbitrary errors exist solely in response memory.
"""
import json
import base64
import hashlib
import os
import pathlib
import subprocess
import struct
import sys
import time

home = pathlib.Path(os.environ["FM_HOME"])
thread = "11111111-1111-4111-8111-111111111111"


def write(name, obj):
    temp = home / (name + ".tmp")
    temp.write_text(json.dumps(obj))
    temp.replace(home / name)


def exact(count):
    data = sys.stdin.buffer.read(count)
    if len(data) != count:
        raise EOFError()
    return data


def frame(data, opcode=1, final=True):
    payload = data if isinstance(data, bytes) else json.dumps(data).encode()
    size = len(payload)
    prefix = bytes([(0x80 if final else 0) | opcode])
    prefix += bytes([size]) if size < 126 else b"\x7e" + struct.pack("!H", size) if size < 65536 else b"\x7f" + struct.pack("!Q", size)
    sys.stdout.buffer.write(prefix + payload)
    sys.stdout.buffer.flush()


# Independent server wire fixture: the native control endpoint requires an
# HTTP upgrade before JSON RPC; the official proxy relays these bytes intact.
opening = sys.stdin.buffer.readline(16385)
if opening != b"GET / HTTP/1.1\r\n":
    # Counterfactual056 sent raw JSON; a real WebSocket acceptor rejects it.
    sys.stdout.buffer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
    sys.stdout.buffer.flush()
    raise SystemExit(0)
headers = {}
while True:
    line = sys.stdin.buffer.readline(16385)
    if line == b"\r\n":
        break
    name, value = line.decode("ascii").strip().split(":", 1)
    headers[name.lower()] = value.strip()
assert headers["sec-websocket-version"] == "13"
key = headers["sec-websocket-key"]
assert len(base64.b64decode(key)) == 16
accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
if (home / "bad-upgrade").exists():
    accept = "incorrect-accept"
sys.stdout.buffer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                         "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
sys.stdout.buffer.flush()
while True:
    try:
        first, second = exact(2)
    except EOFError:
        break
    assert first in (0x81, 0x8a) and second & 0x80, "client must mask text/control frames"
    size = second & 127
    if size == 126:
        size = struct.unpack("!H", exact(2))[0]
    elif size == 127:
        size = struct.unpack("!Q", exact(8))[0]
    assert size <= 1048576
    mask = exact(4)
    data = exact(size)
    decoded = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
    if first == 0x8a:
        assert decoded == b"probe"
        continue
    request = json.loads(decoded)
    method = request["method"]
    if method == "initialized":
        continue
    params = request.get("params", {})
    result = {}
    if method == "initialize":
        if (home / "initialize-error").exists():
            frame({"id": request["id"], "error": {"code": -32600,
                  "message": "PRIVATE_ERROR_CANARY"}})
            continue
        result = {"userAgent": "fixture"}
    elif method == "thread/read":
        assert params == {"threadId": thread, "includeTurns": False}
        if (home / "change-primary-lock").exists():
            (home / "state/.lock").write_text("0\n")
        state = (home / "inspect-state").read_text().strip()
        if state == "active" and (home / "idle-after-read").exists():
            (home / "inspect-state").write_text("idle")
        result = {"thread": {"id": "foreign" if state == "foreign" else thread,
                             "cwd": "/wrong-home" if state == "wrong-cwd" else str(home),
                             "status": {"type": "active" if state == "wrong-cwd" else state},
                             "preview": "PRIVATE_PREVIEW_CANARY",
                             "turns": [{"text": "PRIVATE_CONTENT_CANARY"}]}}
    elif method == "thread/queue/list":
        assert params["threadId"] == thread and params["limit"] == 1
        index = int(params.get("cursor", "0"))
        entries = json.loads((home / "queue-entries").read_text())
        result = {"data": [{"id": entries[index], "clientUserMessageId": "client-" + entries[index],
                            "input": [{"text": "PRIVATE_DRAFT_CANARY"}]}] if index < len(entries) else [],
                  "nextCursor": str(index + 1) if index + 1 < len(entries) else None}
    elif method == "turn/start":
        assert set(params) == {"threadId", "clientUserMessageId", "input"}
        assert params["threadId"] == thread
        assert set(params["input"][0]) == {"type", "text", "text_elements"}
        with (home / "mutations").open("a") as log:
            log.write(json.dumps({"method": method, "client_id": params["clientUserMessageId"]}) + "\n")
        if (home / "fail-direct").exists():
            frame({"id": request["id"], "error": {"code": -1, "message": "PRIVATE_ERROR_CANARY"}})
            continue
        result = {"turn": {"id": "direct-turn", "status": "inProgress",
                           "items": [{"text": "PRIVATE_DIRECT_CANARY"}]}}
    elif method == "thread/queue/delete":
        assert set(params) == {"threadId", "queuedSubmissionId"} and params["threadId"] == thread
        entries = json.loads((home / "queue-entries").read_text())
        queued = params["queuedSubmissionId"]
        result = {"deleted": queued in entries}
        write("queue-entries", [entry for entry in entries if entry != queued])
        with (home / "mutations").open("a") as log:
            log.write(json.dumps({"method": method, "submission_id": queued}) + "\n")
    elif method == "thread/queue/add":
        assert params["threadId"] == thread
        calls = (home / "calls").read_text().splitlines()
        count = len(calls) + 1
        # Decode the generated operational envelope in memory, never log text.
        message = params["input"][0]["text"]
        kind = subprocess.run(["bash", str(home / "bin/fm-operational-input.sh"), "kind"],
                              input=message, text=True, capture_output=True, check=True).stdout.strip()
        with (home / "calls").open("a") as log:
            log.write(json.dumps({"client_id": params["clientUserMessageId"], "kind": kind,
                                 "fresh_recovery": "Do not repeat already ACKed actions" in message}) + "\n")
        if (home / "block-queue").exists() or (count > 1 and (home / "block-retry").exists()):
            (home / "queue-pid").write_text(str(os.getpid()))
            (home / "queue-started").touch()
            time.sleep(30)
        if (home / "fail-queue").exists():
            frame({"id": request["id"], "error": {"code": -1, "message": "PRIVATE_ERROR_CANARY"}})
            continue
        turn_id = "turn-two" if count == 1 else "turn-three" if count == 2 else "turn-four"
        previous = json.loads((home / "turns").read_text()) if (home / "turns").exists() else []
        write("turns", [{"id": turn_id, "client_id": params["clientUserMessageId"]}] + previous)
        result = {"queuedSubmission": {"id": "submission-" + str(count),
                  "clientUserMessageId": params["clientUserMessageId"], "input": params["input"]}}
    elif method == "thread/turns/list":
        assert params["threadId"] == thread
        assert params["itemsView"] in ("summary", "notLoaded")
        assert params["limit"] == 1 and params["sortDirection"] == "desc"
        with (home / "views").open("a") as log:
            log.write(params["itemsView"] + "\n")
        turns = json.loads((home / "turns").read_text())
        index = int(params.get("cursor", "0"))
        row = turns[index] if index < len(turns) else None
        status = (home / "outcome").read_text().strip() if (home / "outcome").exists() else "inProgress"
        if status == "capacity-once":
            status = "capacity" if row and row["id"] == "turn-two" else "inProgress"
        error = None
        if status == "capacity":
            status = "failed"
            error = {"message": "Selected model is at capacity. Please try a different model."}
        elif status == "failed":
            error = {"message": "PRIVATE_ERROR_CANARY"}
        data = []
        if row:
            client_id = row["client_id"]
            if (home / "foreign").exists():
                client_id = "foreign-client"
                # A notification from another thread is never a join/outcome.
                frame({"method": "item/completed", "params": {"threadId": "foreign",
                      "turnId": "foreign-turn", "item": {"type": "userMessage", "clientId": row["client_id"],
                      "content": "PRIVATE_NOTIFICATION_CANARY"}}})
            items = [{"type": "userMessage", "id": "item-id-distinct-from-client",
                      "clientId": client_id, "content": "PRIVATE_CONTENT_CANARY"},
                     {"type": "agentMessage", "text": "PRIVATE_AGENT_CANARY"}] if params["itemsView"] == "summary" else []
            data = [{"id": row["id"], "status": status, "error": error, "items": items}]
        result = {"data": data, "nextCursor": str(index + 1) if index + 1 < len(turns) else None}
    else:
        raise AssertionError("unapproved operation")
    response = {"id": request["id"], "result": result}
    if (home / "fragment").exists():
        encoded = json.dumps(response).encode()
        middle = len(encoded) // 2
        frame(encoded[:middle], final=False)
        frame(b"probe", opcode=9)
        frame(encoded[middle:], opcode=0)
    else:
        frame(response)
