#!/usr/bin/env python3
"""Codex activity for a locally launched, native Linux TUI.

launch STATE ID GEN WORKSPACE CODEX [ARGS...] normally records this process's
kernel identity, then execs the verified CLI with --no-daemon. A distinct
WORKSPACE/.claude/skills root uses an owned app-server: register that root with
skills/extraRoots/set before the interactive client receives its task. The
server owns the rollout and activity binding. CLI approval flags are retained;
unavailable registration prints Unsupported and falls back to the normal CLI.
The API call itself determines registration support. No hook, profile, repository
file or shared daemon is changed. Repositories with CLAUDE.md and no native
AGENTS file use the CLI project_doc_fallback_filenames setting on this launch.

classify STATE ID prints the shared busy classifier's two-field result. The
generation-specific ID.codex-owner.GEN.json binding is immutable after launch;
busy-gen selects it, so an old launcher cannot overwrite a replacement. The
first validated session is pinned in ID.codex-session.GEN.json; an in-process
conversation switch is unsupported until a new launch generation. Only
the bound process's open primary rollout and matching writer-lock are read;
extra open rollouts are accepted only for its explicit native guardian children.
The private server uses source vscode. Its notify callback forwards the original
program and payload only for a verified idle primary, never a guardian turn.
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
import runpy
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

from fm_task_sessions import bind, metadata


VERSION = "0.166.0"
LIMIT = 32 * 1024 * 1024
BIND_SECONDS = 120
BIND_POLL_SECONDS = .5
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


def record_owner(state, task, gen, workspace, command, pid, source="cli"):
    binary = shutil.which(command[0])
    if sys.platform != "linux" or not binary or generation(state, task) != gen:
        raise ValueError("unsupported launch")
    binary = str(Path(binary).resolve(strict=True))
    with open(binary, "rb") as handle:
        if handle.read(4) != b"\x7fELF":
            raise ValueError("non-native executable")
    result = subprocess.run([binary, "--version"], capture_output=True, timeout=5, check=True)
    if result.stdout.decode().strip() != "codex-cli " + VERSION:
        raise ValueError("unverified version")
    binding = {
        "schema": 1, "gen": gen, "pid": pid,
        "identity": identity(pid), "executable": binary,
        "workspace": str(Path(workspace).resolve(strict=True)),
        "codex_home": str(Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve()),
        "version": VERSION,
        "source": source,
    }
    with owner_path(state, task, gen).open("x") as handle:
        json.dump(binding, handle)
    return binary


def launch_with_skill_root(state, task, gen, workspace, command, root):
    # The native extraRoots API is process scoped. A private server retains it
    # across the bootstrap connection and the unchanged interactive client.
    with tempfile.TemporaryDirectory(prefix="fm-codex-roots-") as folder:
        remote = "unix://" + str(Path(folder) / "server.sock")
        server = None
        diagnostic = {"phase": "start"}
        try:
            with (Path(folder) / "server.log").open("w") as log:
                try:
                    options = []
                    arguments = iter(command[1:])
                    for arg in arguments:
                        if arg in ("-c", "--config"):
                            value = next(arguments)
                        elif arg.startswith("--config="):
                            value = arg.removeprefix("--config=")
                        else:
                            continue
                        if value.partition("=")[0].strip() == "notify":
                            original = decode(value.partition("=")[2])
                            callback = [sys.executable, str(Path(__file__).resolve()), "notify", str(state), task,
                                        gen, str(Path(workspace).resolve()), json.dumps(original)]
                            options.extend(["-c", "notify=" + json.dumps(callback)])
                        else:
                            options.extend(["-c", value])
                    diagnostic["phase"] = "start"
                    server = subprocess.Popen([command[0], "app-server", *options, "--listen", remote],
                                              cwd=workspace, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                    deadline = time.monotonic() + 20
                    while not (Path(folder) / "server.sock").exists() and server.poll() is None:
                        if time.monotonic() >= deadline:
                            raise TimeoutError()
                        time.sleep(.1)
                    client_type = runpy.run_path(str(Path(__file__).with_name("fm-codex-native-rpc.py")))["Client"]
                    client = client_type(SimpleNamespace(remote=remote, executable=command[0], wait_for_idle=20), diagnostic)
                    try:
                        client.upgrade()
                        client.request("initialize", {"clientInfo": {"name": "firstmate-worker-skills", "version": "1"},
                                                      "capabilities": {"experimentalApi": True}})
                        client.send({"method": "initialized"})
                        client.request("skills/extraRoots/set", {"extraRoots": [str(root.resolve())]})
                    finally:
                        client.close()
                except (OSError, ValueError, EOFError, TimeoutError, KeyError, subprocess.SubprocessError):
                    print("Unsupported: Codex native skill-root registration unavailable ("
                          + diagnostic["phase"] + "); continuing with configured approval.", file=sys.stderr)
                    return None
                try:
                    record_owner(state, task, gen, workspace, command, server.pid, "vscode")
                except (OSError, ValueError, subprocess.SubprocessError):
                    pass  # The existing activity capability limit does not restrict editing.
                if shutil.which("lsof"):
                    threading.Thread(target=bind_open_session,
                                     args=(state, task, gen, workspace, server.pid, lambda: server.poll() is None, "vscode"),
                                     daemon=True).start()
                return subprocess.call([command[0], "--remote", remote, *command[1:]])
        finally:
            if server is not None and server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def native_notify(state, task, gen, workspace, program, payload):
    """Keep guardian completions from invoking the worker's original notify."""
    try:
        data = decode(payload)
        if sys.platform == "linux":
            binding = decode(owner_path(state, task, gen).read_text())
            if binding["pid"] != os.getppid() or generation(state, task) != gen:
                return
            entry, session, _ = sample(binding)
        else:
            home = os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))
            entry = Path(open_rollout(os.getppid(), home, workspace, "vscode"))
            session = ROLLOUT.fullmatch(entry.name)[1]
            binding = {"workspace": workspace, "source": "vscode"}
        if data.get("thread-id") != session:
            return
        with entry.open("rb") as handle:
            if fold(handle, binding, session) != "idle":
                return
        subprocess.run([*decode(program), payload], check=False)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("warning: native Codex completion could not be attributed to its worker", file=sys.stderr)


def launch(state, task, gen, workspace, command):
    repo = Path(workspace)
    if (repo / "CLAUDE.md").is_file() and not any((repo / name).is_file()
                                                              for name in ("AGENTS.md", "AGENTS.override.md")):
        command = [command[0], "-c", 'project_doc_fallback_filenames=["CLAUDE.md"]', *command[1:]]
    root = Path(workspace) / ".claude/skills"
    if root.is_dir() and root.resolve() != (Path(workspace) / ".agents/skills").resolve():
        status = launch_with_skill_root(state, task, gen, workspace, command, root)
        if status is not None:
            raise SystemExit(status)
    if shutil.which("lsof"):
        try:
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "bind-session",
                              str(state), task, gen, str(Path(workspace).resolve()),
                              str(os.getpid())], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             close_fds=True)
        except OSError:
            pass
    try:
        binary = record_owner(state, task, gen, workspace, command, os.getpid())
        command = [binary, "--no-daemon", *command[1:]]
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    os.execvp(command[0], command)


def open_rollout(pid, codex_home, workspace, source="cli"):
    lsof = shutil.which("lsof")
    if not lsof:
        return None
    try:
        result = subprocess.run([lsof, "-a", "-p", str(pid), "-Fn"],
                                capture_output=True, text=True, timeout=3)
        if result.returncode:
            return None
        root = (Path(codex_home) / "sessions").resolve()
        candidates = []
        for line in result.stdout.splitlines():
            if not line.startswith("n"):
                continue
            path = Path(line[1:])
            match = ROLLOUT.fullmatch(path.name)
            if not match or path.is_symlink():
                continue
            resolved = path.resolve(strict=True)
            if root not in resolved.parents or not resolved.is_file():
                continue
            with resolved.open(encoding="utf-8", errors="replace") as stream:
                first = json.loads(stream.readline())
            if not isinstance(first, dict):
                continue
            payload = first.get("payload") or {}
            if not isinstance(payload, dict):
                continue
            if (first.get("type") != "session_meta" or payload.get("id") != match[1]
                    or payload.get("cli_version") != VERSION or payload.get("source") != source
                    or str(Path(payload.get("cwd", "")).resolve()) != workspace):
                continue
            candidates.append(str(resolved))
        candidates = list(dict.fromkeys(candidates))
        return candidates[0] if len(candidates) == 1 else None
    except (OSError, ValueError, subprocess.SubprocessError, TypeError):
        return None


def bind_open_session(state, task, gen, workspace, pid, alive=None, source="cli"):
    # The exec helper follows its parent; the server launch supplies its owned
    # Popen's poll instead, so both paths stop when their exact engine exits.
    alive = alive or (lambda: os.getppid() == pid)
    if not alive():
        return False
    try:
        meta = metadata(state, task)
    except OSError:
        return False
    if meta.get("busy_gen") != gen or meta.get("harness") != "codex":
        return False
    codex_home = str(Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).resolve())
    deadline = time.monotonic() + BIND_SECONDS
    while time.monotonic() < deadline and alive():
        session = open_rollout(pid, codex_home, workspace, source)
        if not alive():
            return False
        if session:
            bind(state, task, gen, session)
            return True
        time.sleep(BIND_POLL_SECONDS)
    return False


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
    primary, reviews = {}, {}
    for name, (entry, session) in logs.items():
        with entry.open("rb") as stream:
            header = decode(stream.readline(LIMIT + 1))
        if not isinstance(header, dict) or not isinstance(header.get("payload"), dict):
            raise ValueError("invalid session metadata")
        payload = header.get("payload", {})
        if (header.get("type") != "session_meta" or payload.get("id") != session
                or payload.get("cli_version") != VERSION or payload.get("cwd") != binding["workspace"]):
            raise ValueError("session identity mismatch")
        if payload.get("source") == binding.get("source", "cli"):
            primary[name] = (entry, session)
        elif (payload.get("source") == {"subagent": {"other": "guardian"}}
              and payload.get("thread_source") == "guardian_review"):
            reviews[session] = payload.get("parent_thread_id")
        else:
            raise ValueError("unrecognized concurrent session")
    if len(primary) != 1:
        raise ValueError("ambiguous or absent rollout")
    name, (entry, session) = next(iter(primary.items()))
    if locks != {session, *reviews} or any(parent != session for parent in reviews.values()):
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
                    or payload.get("cli_version") != VERSION or payload.get("source") != binding.get("source", "cli")
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
                or binding["version"] != VERSION or binding["gen"] != gen
                or binding.get("source", "cli") not in ("cli", "vscode")):
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
        try:
            if (state / (task + ".meta")).exists():
                bind(state, task, gen, before[0])
        except (OSError, ValueError, KeyError) as error:
            print("warning: session record failed: " + str(error), file=sys.stderr)
        return verdict + " " + source
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        return "unknown " + source


def main():
    if sys.argv[1:] in (["--help"], ["-h"]):
        print(__doc__)
        return
    if sys.argv[1:2] == ["notify"] and len(sys.argv) == 8:
        native_notify(Path(sys.argv[2]), *sys.argv[3:])
        return
    if len(sys.argv) < 4:
        raise SystemExit("usage: fm-codex-activity.py --help")
    action, state, task, *args = sys.argv[1:]
    if not TOKEN.fullmatch(task):
        raise ValueError("invalid task")
    state = Path(state)
    if action == "launch" and len(args) >= 3 and TOKEN.fullmatch(args[0]):
        launch(state, task, args[0], args[1], args[2:])
    elif action == "bind-session" and len(args) == 3:
        bind_open_session(state, task, args[0], str(Path(args[1]).resolve()), int(args[2]))
    elif action == "classify" and not args:
        print(classify(state, task))
    else:
        raise ValueError("usage: fm-codex-activity.py launch STATE ID GEN WORKSPACE CODEX [ARGS...] | classify STATE ID")


if __name__ == "__main__":
    main()
