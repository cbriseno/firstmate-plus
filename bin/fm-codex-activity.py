#!/usr/bin/env python3
"""Codex activity for a locally launched, native Linux TUI.

launch STATE ID GEN WORKSPACE CODEX [ARGS...] records this process's kernel
identity, then execs the verified CLI with --no-daemon. Unsupported installations
still launch normally and have no activity binding. It never installs hooks,
changes Codex configuration, starts a relay, or searches other conversations.

classify STATE ID prints the shared busy classifier's two-field result. The
generation-specific ID.codex-owner.GEN.json binding is immutable after launch;
busy-gen selects it, so an old launcher cannot overwrite a replacement. The
first validated session is pinned in ID.codex-session.GEN.json; an in-process
conversation switch is unsupported until a new launch generation. Only
the bound process's open rollout and matching writer-lock descriptor are read.
The native executable, boot/start identity, workspace, CLI version, session ID,
and generation must all agree before and after the read. No descriptor, partial
JSON, conflicting lifecycle, unsupported version, or unreadable evidence means
unknown. Logs over 32 MiB are unsupported rather than folded incompletely.

The semantic source is the rollout's task_started / task_complete / turn_aborted
events, never the process's existence or its output. An error without a verified
terminal event stays unknown. API consumers retain the busy|idle|unknown SOURCE
interface. Endpoint death remains the caller's responsibility.
"""

import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


VERSION = "0.166.0"
LIMIT = 32 * 1024 * 1024
TOKEN = re.compile(r"[A-Za-z0-9._-]+\Z")
UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
ROLLOUT = re.compile(r"rollout-.+-(" + UUID + r")\.jsonl\Z")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def decode(data):
    return json.loads(data, object_pairs_hook=unique_object)


def generation(state, task):
    value = (state / (task + ".busy-gen")).read_text().strip()
    if not TOKEN.fullmatch(value):
        raise ValueError("invalid generation")
    return value


def owner_path(state, task, gen):
    return state / (task + ".codex-owner." + gen + ".json")


def identity(pid):
    proc = Path("/proc") / str(pid)
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    if fields[0] in ("Z", "X"):
        raise ValueError("process exited")
    return [Path("/proc/sys/kernel/random/boot_id").read_text().strip(), fields[19],
            os.readlink(proc / "ns/pid")]


def launch(state, task, gen, workspace, command):
    binary = shutil.which(command[0])
    try:
        if sys.platform != "linux" or not binary or generation(state, task) != gen:
            raise ValueError("unsupported launch")
        binary = str(Path(binary).resolve(strict=True))
        # Script shims have a different kernel executable and remain unsupported.
        with open(binary, "rb") as handle:
            if handle.read(4) != b"\x7fELF":
                raise ValueError("non-native executable")
        result = subprocess.run([binary, "--version"], capture_output=True, timeout=5, check=True)
        if result.stdout.decode().strip() != "codex-cli " + VERSION:
            raise ValueError("unverified version")
        binding = {
            "schema": 1, "gen": gen, "pid": os.getpid(),
            "identity": identity(os.getpid()), "executable": binary,
            "workspace": str(Path(workspace).resolve(strict=True)),
            "codex_home": str(Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve()),
            "version": VERSION,
        }
        # Exclusive, generation-specific publication: no shared mutable cache.
        with owner_path(state, task, gen).open("x") as handle:
            json.dump(binding, handle)
        command = [binary, "--no-daemon", *command[1:]]
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    os.execvp(command[0], command)


def sample(binding):
    pid = binding["pid"]
    if type(pid) is not int or pid <= 1 or identity(pid) != binding["identity"]:
        raise ValueError("stale process")
    proc = Path("/proc") / str(pid)
    if not os.path.samefile(proc / "exe", binding["executable"]):
        raise ValueError("executable changed")
    home = Path(binding["codex_home"])
    logs, locks = {}, set()
    for entry in (proc / "fd").iterdir():
        try:
            target = Path(os.readlink(entry))
        except FileNotFoundError:
            continue  # unrelated descriptors may close while sampling
        if target.parent == home / "thread-writer-locks" and target.suffix == ".lock":
            locks.add(target.stem)
        match = ROLLOUT.fullmatch(target.name)
        if match and target.parent.parent.parent.parent == home / "sessions":
            if target.is_symlink() or not stat.S_ISREG(entry.stat().st_mode):
                raise ValueError("invalid rollout")
            if not os.path.samefile(entry, target):
                raise ValueError("replaced rollout")
            logs[str(target)] = (entry, match[1])
    if len(logs) != 1:
        raise ValueError("ambiguous or absent rollout")
    name, (entry, session) = next(iter(logs.items()))
    if session not in locks or len(locks) != 1:
        raise ValueError("writer identity mismatch")
    info = entry.stat()
    return entry, session, (name, info.st_dev, info.st_ino)


def fold(handle, binding, session):
    data = handle.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError("oversize rollout")
    active, seen, settled, uncertain = None, set(), False, False
    for number, line in enumerate(data.splitlines(keepends=True)):
        if not line.endswith(b"\n"):
            raise ValueError("partial rollout")
        row = decode(line)
        if not isinstance(row, dict):
            raise ValueError("invalid row")
        payload = row.get("payload")
        if not isinstance(payload, dict):
            raise ValueError("invalid payload")
        if number == 0:
            if (row.get("type") != "session_meta" or payload.get("id") != session
                    or payload.get("cli_version") != VERSION or payload.get("source") != "cli"
                    or payload.get("cwd") != binding["workspace"]):
                raise ValueError("session identity mismatch")
            continue
        if row.get("type") == "session_meta":
            raise ValueError("multiple sessions")
        if row.get("type") != "event_msg":
            continue
        if "thread_id" in payload and payload["thread_id"] != session:
            raise ValueError("conflicting thread")
        event = payload.get("type")
        attribution = payload.get("turn_attribution")
        if isinstance(attribution, dict) and attribution.get("turn_id") != payload.get("turn_id"):
            raise ValueError("conflicting turn attribution")
        if event == "task_started":
            turn = payload.get("turn_id")
            if not isinstance(turn, str) or not TOKEN.fullmatch(turn) or turn in seen or active:
                raise ValueError("conflicting turn start")
            active = turn
            seen.add(turn)
            settled, uncertain = False, False
        elif event in ("task_complete", "turn_aborted"):
            if not active or payload.get("turn_id") != active:
                raise ValueError("unmatched turn close")
            active, settled, uncertain = None, True, False
        elif event == "error":
            if "turn_id" in payload and payload["turn_id"] != active:
                raise ValueError("conflicting error turn")
            uncertain = True
    if uncertain:
        return "unknown"
    return "busy" if active else "idle" if settled else "unknown"


def classify(state, task):
    source = "codex-unverified"
    try:
        gen = generation(state, task)
        path = owner_path(state, task, gen)
        if not path.is_file():
            return "unknown " + source
        source = "codex-rollout"
        binding = decode(path.read_text())
        if (sys.platform != "linux" or binding["schema"] != 1
                or binding["version"] != VERSION or binding["gen"] != gen):
            raise ValueError("unsupported binding")
        entry, session, before = sample(binding)
        with entry.open("rb") as handle:
            info = os.fstat(handle.fileno())
            if (info.st_dev, info.st_ino) != before[1:]:
                raise ValueError("descriptor replaced")
            verdict = fold(handle, binding, session)
            if os.fstat(handle.fileno()).st_size != info.st_size:
                raise ValueError("rollout changed during read")
        _, after_session, after = sample(binding)
        if (session != after_session or before != after or generation(state, task) != gen
                or decode(path.read_text()) != binding):
            raise ValueError("binding changed during read")
        pinned = state / (task + ".codex-session." + gen + ".json")
        session_binding = {"session": session, "rollout": list(before)}
        try:
            with pinned.open("x") as handle:
                json.dump(session_binding, handle)
        except FileExistsError:
            if decode(pinned.read_text()) != session_binding:
                raise ValueError("session changed within launch generation")
        if generation(state, task) != gen:
            raise ValueError("generation changed during session binding")
        return verdict + " " + source
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return "unknown " + source


def main():
    if sys.argv[1:] in (["--help"], ["-h"]):
        print(__doc__)
        return
    if len(sys.argv) < 4:
        raise SystemExit("usage: fm-codex-activity.py --help")
    action, state, task, *args = sys.argv[1:]
    if not TOKEN.fullmatch(task):
        raise ValueError("invalid task")
    state = Path(state)
    if action == "launch" and len(args) >= 3 and TOKEN.fullmatch(args[0]):
        launch(state, task, args[0], args[1], args[2:])
    elif action == "classify" and not args:
        print(classify(state, task))
    else:
        raise ValueError("usage: fm-codex-activity.py launch STATE ID GEN WORKSPACE CODEX [ARGS...] | classify STATE ID")


if __name__ == "__main__":
    main()
