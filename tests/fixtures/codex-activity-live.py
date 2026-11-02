"""Exercise the captured worker launch against real Codex, only in private resources."""

import json
import http.server
import os
from pathlib import Path
import shlex
import subprocess
import threading
import time


root = Path(os.environ["FM_ACTIVITY_ROOT"])
lab = Path(os.environ["FM_ACTIVITY_LAB"])
state, workspace, home = lab / "home/state", lab / "wt", lab / "codex"
task = "activity-proof"
socket = "fm-codex-activity-" + str(os.getpid())
launch = (lab / "launch").read_text().strip()
brief = lab / "home/data" / task / "launch-brief.md"
gen = (state / (task + ".busy-gen")).read_text().strip()
busy_lib = root / "bin/fm-busy-lib.sh"
error_server = None
request_rejected = threading.Event()
authorization_seen = threading.Event()
env = os.environ.copy()
env["CODEX_HOME"] = str(home)
# Private directory trust only; this never reaches the user's trust store.
(home / "config.toml").write_text(
    "[projects." + json.dumps(str(workspace)) + ']\ntrust_level="trusted"\n'
)


def tmux(*args):
    return subprocess.check_output(["tmux", "-L", socket, *args], text=True, env=env, timeout=10)


def verdict():
    return subprocess.check_output([
        "bash", "-c", '. "$1"; fm_busy_classify tmux private codex "$2" "$3"',
        "bash", str(busy_lib), task, str(state),
    ], text=True, timeout=5).strip()


def wait_for(test, label, seconds=100):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(.25)
    raise AssertionError("codex-cli 0.166.0: " + label + "; last verdict=" + verdict())


def wait_state(expected):
    wait_for(lambda: verdict() == expected + " codex-rollout", expected)


def send(pane, prompt):
    tmux("send-keys", "-t", pane, "-l", prompt)
    time.sleep(1)
    tmux("send-keys", "-t", pane, "Enter")


def prompt(marker, seconds):
    return ("Run exactly this shell command as one foreground tool and wait for it to finish: "
            + shlex.quote("touch " + str(marker) + "; sleep " + str(seconds)
                          + "; touch " + str(marker) + ".finished")
            + ". Then reply with DONE. Do nothing else.")


def rows(generation):
    owner = json.loads((state / (task + ".codex-owner." + generation + ".json")).read_text())
    for fd in (Path("/proc") / str(owner["pid"]) / "fd").iterdir():
        try:
            name = os.readlink(fd)
        except FileNotFoundError:
            continue
        if "/sessions/" in name and "/rollout-" in name:
            try:
                return [json.loads(line) for line in Path(name).read_text().splitlines()]
            except (FileNotFoundError, ValueError):
                return []  # poll again while the native writer publishes
    return []


def events(generation):
    return [r["payload"] for r in rows(generation) if r.get("type") == "event_msg"]


def start(pane, command):
    tmux("new-window", "-d", "-t", "proof:", "-n", pane, "-c", str(workspace),
         "bash", "-c", command)


def arm():
    return subprocess.check_output(["bash", str(root / "bin/fm-busy-event.sh"), "arm", str(state),
                                    task, "--state", "unknown"], text=True).strip()


try:
    # The very same baseline with no owner binding stays unknown despite a live pane.
    assert verdict() == "unknown codex-unverified"
    marker = lab / "long-tool"
    brief.write_text(prompt(marker, 20))
    tmux("new-session", "-d", "-s", "proof", "-x", "160", "-y", "45", "-c", str(workspace))
    start("first", launch)
    wait_state("busy")
    wait_for(marker.exists, "real foreground tool never started")
    for _ in range(4):
        assert not Path(str(marker) + ".finished").exists(), "long-tool assertion became vacuous"
        assert verdict() == "busy codex-rollout"
        time.sleep(1)
    wait_state("idle")
    assert any(e["type"] == "task_complete" for e in events(gen))
    print("ok - codex-cli 0.166.0: captured launch, task start, quiet long tool and ordinary completion", flush=True)

    marker = lab / "interrupt-tool"
    send("proof:first", prompt(marker, 60))
    wait_for(marker.exists, "interrupt tool never started")
    wait_state("busy")
    tmux("send-keys", "-t", "proof:first", "Escape")
    wait_state("idle")
    assert any(e["type"] == "turn_aborted" for e in events(gen))
    print("ok - codex-cli 0.166.0: real Escape emits a bound turn_aborted and settles idle", flush=True)

    # Leave the old process alive. Its later close must not settle its replacement.
    old_marker = lab / "old-tool"
    send("proof:first", prompt(old_marker, 8))
    wait_for(old_marker.exists, "old replacement tool never started")
    newer = arm()
    assert newer != gen and verdict() == "unknown codex-unverified"
    marker = lab / "replacement-tool"
    brief.write_text(prompt(marker, 25))
    start("replacement", launch.replace(gen, newer))
    wait_for(marker.exists, "replacement tool never started")
    wait_state("busy")
    wait_for(lambda: any(e["type"] == "task_complete" and e.get("turn_id") ==
                        [x for x in events(gen) if x["type"] == "task_started"][-1]["turn_id"]
                        for e in events(gen)), "old turn did not complete")
    assert verdict() == "busy codex-rollout", "old close overwrote replacement"
    wait_state("idle")
    print("ok - codex-cli 0.166.0: old completion cannot overwrite the live replacement generation", flush=True)

    # The real Codex engine owns this failure; no fake harness or fake success.
    # Connection refusal instead leaves Codex reconnecting with an OPEN turn.
    # A private HTTP 400 is terminal and exercises its actual failure closure.
    class Reject(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            if self.headers.get("Authorization") is not None:
                authorization_seen.set()
            body = b'{"error":{"message":"Private activity failure probe","type":"invalid_request_error"}}'
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            request_rejected.set()

        do_GET = do_POST

        def log_message(self, *args):
            pass

    error_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Reject)
    threading.Thread(target=error_server.serve_forever, daemon=True).start()
    endpoint = "http://127.0.0.1:" + str(error_server.server_port)
    failed = arm()
    brief.write_text("Reply briefly.")
    error_flags = (" -c 'model_provider=\"fm-activity-error\"'"
                   " -c 'model_providers.fm-activity-error={name=\"Private error probe\","
                   "base_url=\"" + endpoint + "\",wire_api=\"responses\","
                   "request_max_retries=1,stream_max_retries=1,requires_openai_auth=false}' ")
    failing = launch.replace(gen, failed).replace(" --disable hooks ", error_flags + " --disable hooks ")
    start("failure", failing)
    wait_for(lambda: (state / (task + ".codex-owner." + failed + ".json")).exists(), "failure owner missing")
    wait_for(request_rejected.is_set, "real Codex never exercised the private HTTP failure")
    wait_state("idle")
    assert not authorization_seen.is_set(), "private custom provider received authorization"
    result = verdict()
    assert any(e["type"] == "task_complete" for e in events(failed))
    print("ok - codex-cli 0.166.0: native HTTP 400 error => " + result + "; events="
          + ",".join(e["type"] for e in events(failed)
                     if e["type"] in ("task_started", "task_complete", "turn_aborted", "error")), flush=True)
    print("ok - codex-cli 0.166.0: verified one installed native harness; no other harness invoked", flush=True)
except BaseException:
    # Preserve the actual private failure surface rather than guessing why a
    # process disappeared before it could produce a lifecycle record.
    for pane in ("first", "replacement", "failure"):
        try:
            print("# private " + pane + " failure surface:\n"
                  + tmux("capture-pane", "-p", "-t", "proof:" + pane), flush=True)
        except subprocess.SubprocessError:
            pass
    raise
finally:
    if error_server is not None:
        error_server.shutdown()
        error_server.server_close()
    subprocess.run(["tmux", "-L", socket, "kill-server"], env=env, capture_output=True, timeout=10)
