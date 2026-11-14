#!/usr/bin/env bash
# Opt-in real Codex title/worker completion proof in an isolated Herdr session.
# Uses only copied auth and private config; all lifecycle calls use the lab helper.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_TITLE_NOTIFY_LIVE herdr codex python3 jq
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name codex-title-notify)
TMP_ROOT=$(fm_test_tmproot fm-codex-title-notify)
cleanup() {
  local rc=$?
  trap - EXIT
  "$HELPER" teardown "$SESSION" || rc=1
  rm -rf -- "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/codex" "$TMP_ROOT/workspace" "$TMP_ROOT/state"
install -m 600 "${CODEX_HOME:-$HOME/.codex}/auth.json" "$TMP_ROOT/codex/auth.json"
GEN=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$TMP_ROOT/state" proof)
"$HELPER" provision "$SESSION"
FM_TITLE_LAB="$TMP_ROOT" FM_TITLE_ROOT="$ROOT" FM_TITLE_HELPER="$HELPER" \
  FM_TITLE_SESSION="$SESSION" FM_TITLE_GEN="$GEN" python3 - <<'PY'
import json, os, shlex, subprocess, sys, time
from pathlib import Path
lab, root = Path(os.environ["FM_TITLE_LAB"]), Path(os.environ["FM_TITLE_ROOT"])
workspace, state = lab / "workspace", lab / "state"
version = subprocess.check_output(["codex", "--version"], text=True).strip()
helper, session, gen = (os.environ[k] for k in ("FM_TITLE_HELPER", "FM_TITLE_SESSION", "FM_TITLE_GEN"))
def herdr(*args):
    return subprocess.check_output([helper, "run", session, *args], text=True)
def wait(test, label):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if test(): return
        time.sleep(.25)
    raise AssertionError(version + ": " + label)
marker = state / "proof.turn-ended"
program = ["bash", "-c", shlex.join(["bash", str(root / "bin/fm-busy-event.sh"), "apply", str(state), "proof", "idle",
           "--gen", gen, "--source", "codex-notify", "--event", "turn-complete", "--turn-ended"])]
forward = [sys.executable, str(root / "bin/fm-codex-activity.py"), "notify-cli", str(state), "proof",
           gen, str(workspace), json.dumps(program)]
# Record the raw native callback BEFORE invoking the production filter.
callback = lab / "callback.py"
callback.write_text("import json,sys,subprocess\nfrom pathlib import Path\n"
                    "with open(" + repr(str(lab / "callbacks.jsonl")) + ", 'a') as f: f.write(sys.argv[-1]+'\\n')\n"
                    "with open(" + repr(str(lab / "callback-errors.log")) + ", 'a') as err:\n"
                    " subprocess.run(" + repr(forward) + "+[sys.argv[-1]],check=True,stderr=err)\n")
(lab / "codex/config.toml").write_text('[projects.' + json.dumps(str(workspace)) + ']\ntrust_level="trusted"\n')
prompt = "Run this foreground shell command and wait for it, then reply DONE: " + shlex.quote(
    "touch " + str(lab / "started") + "; sleep 30; touch " + str(lab / "finished"))
command = ["env", "-u", "CODEX_THREAD_ID", "-u", "FM_TASK_ID", "-u", "FM_TASK_INBOX",
           "CODEX_HOME=" + str(lab / "codex"), "codex", "--model", "gpt-6.1-sol",
           "-c", 'model_reasoning_effort="low"', "--dangerously-bypass-approvals-and-sandbox",
           "-c", "notify=" + json.dumps([sys.executable, str(callback)]), prompt]
ws = json.loads(herdr("workspace", "create", "--cwd", str(workspace), "--label", "title-proof", "--no-focus"))
pane = ws["result"]["root_pane"]["pane_id"]
try:
    herdr("pane", "run", pane, shlex.join(command))
    raw = lab / "callbacks.jsonl"
    wait(lambda: raw.exists() and raw.stat().st_size, "no initial native callback")
    first = json.loads(raw.read_text().splitlines()[0])
    rollouts = list((lab / "codex/sessions").glob("*/*/*/rollout-*-" + first["thread-id"] + ".jsonl"))
    assert not rollouts, version + ": first callback no longer belongs to an ephemeral title thread"
    wait(lambda: (lab / "started").exists(), "foreground tool never started")
    assert not (lab / "finished").exists(), "busy observation became vacuous"
    assert not marker.exists(), "title callback woke the watcher during real work"
    assert "seq=1 state=busy" in (state / "proof.busy-state").read_text(), "title callback changed the ledger"
    wait(marker.exists, "real completion did not wake the watcher")
    assert (lab / "finished").exists(), "completion preceded the actual tool finish"
    assert "seq=2 state=idle" in (state / "proof.busy-state").read_text(), "real completion missing from ledger"
    print("ok - " + version + ": title ignored while worker busy; real completion wakes once")
finally:
    print("# callback errors: " + (lab / "callback-errors.log").read_text() if (lab / "callback-errors.log").exists() else "# no callbacks")
    print("# generation " + repr(gen) + "; state " + (state / "proof.busy-state").read_text())
    print(herdr("pane", "read", pane, "--source", "recent", "--lines", "30"))
PY
