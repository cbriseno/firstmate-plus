#!/usr/bin/env python3
"""Token-free private native server qualification; no live operator resources."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace


root, scratch, executable = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("release", root / "bin/fm-lock-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
private = scratch / "codex-home"
private.mkdir()
home = scratch / "primary"
home.mkdir()
endpoint = scratch / "control.sock"
env = dict(os.environ, CODEX_HOME=str(private), XDG_CONFIG_HOME=str(scratch / "config"),
           XDG_DATA_HOME=str(scratch / "data"), XDG_STATE_HOME=str(scratch / "state"),
           XDG_CACHE_HOME=str(scratch / "cache"), XDG_RUNTIME_DIR=str(scratch / "run"))
for key in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_REMOTE", "CODEX_THREAD_ID"):
    env.pop(key, None)
version = subprocess.check_output([str(executable), "--version"], env=env, text=True).strip()
with (scratch / "server.log").open("w") as log:
    server = subprocess.Popen([str(executable), "app-server", "--listen", "unix://" + str(endpoint)],
                              env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    controller = None
    try:
        for _ in range(100):
            if endpoint.exists():
                break
            if server.poll() is not None:
                raise AssertionError(version + ": private app-server exited")
            time.sleep(0.05)
        assert endpoint.exists(), version + ": private app-server did not listen"
        argv = (Path("/proc") / str(server.pid) / "cmdline").read_bytes().split(b"\0")
        assert b"app-server" in argv[1:], version + ": shared-runtime argv profile changed"
        args = SimpleNamespace(remote="unix://" + str(endpoint), owner_pid=server.pid, home=str(home))
        controller = release.DirectClient(args)
        controller.upgrade()
        controller.request("initialize", {"clientInfo": {"name": "firstmate_release_guard", "version": "1"},
                                          "capabilities": {"experimentalApi": True, "requestAttestation": False}})
        controller.send({"method": "initialized"})
        start = {"cwd": str(home), "experimentalRawEvents": False}
        outgoing = controller.request("thread/start", start)["thread"]["id"]
        peer = controller.request("thread/start", start)["thread"]["id"]
        args.thread = outgoing

        def probe():
            client = release.DirectClient(args)
            try:
                return release.exclusive_home(client, args)
            finally:
                client.close()

        try:
            probe()
        except release.Refusal as error:
            assert str(error) == "another live session exists in this home", (version, str(error))
        else:
            raise AssertionError(version + ": native idle peer was accepted")
        # Detachment is not session closure on the installed server. Archive
        # only this guard's private session to exercise actual notLoaded state.
        controller.request("thread/archive", {"threadId": peer})
        for _ in range(30):
            try:
                status = probe()
                break
            except release.Refusal:
                time.sleep(0.05)
        else:
            raise AssertionError(version + ": peer did not unload")
        assert status == "idle", (version, status)
        print("ok - " + version + ": real shared-runtime argv, Unix peer, loaded inventory and idle peer refusal")
        controller.request("thread/archive", {"threadId": outgoing})
        for _ in range(30):
            status = probe()
            if status == "notLoaded":
                break
            time.sleep(0.05)
        assert status == "notLoaded", (version, status)
        assert server.poll() is None
        print("ok - " + version + ": closed native session is notLoaded while its private daemon stays alive; no model turn")
    except BaseException:
        print("not ok - " + version + ": installed private lock-release protocol no longer proves the required lifecycle", file=sys.stderr)
        raise
    finally:
        if controller is not None:
            controller.close()
        # Only the server this guard just created, never a shared daemon.
        server.terminate()
        try:
            server.wait(timeout=4)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=2)
