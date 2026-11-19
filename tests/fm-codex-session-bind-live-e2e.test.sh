#!/usr/bin/env bash
# Opt-in: a real Codex worker records its process-owned transcript even when
# its CLI version has not qualified for semantic activity classification.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_SESSION_BIND_LIVE herdr codex lsof python3 jq
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name codex-session-bind)
TMP_ROOT=$(fm_test_tmproot fm-codex-session-bind-live)
cleanup() {
  local rc=$?
  trap - EXIT
  "$HELPER" teardown "$SESSION" || rc=1
  fm_test_remove_tree "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$TMP_ROOT/codex" "$TMP_ROOT/workspace" "$TMP_ROOT/state" "$TMP_ROOT/data/proof"
install -m 600 "${CODEX_HOME:-$HOME/.codex}/auth.json" "$TMP_ROOT/codex/auth.json"
GEN=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$TMP_ROOT/state" proof --state unknown)
"$HELPER" provision "$SESSION"
FM_BIND_LAB="$TMP_ROOT" FM_BIND_ROOT="$ROOT" FM_BIND_HELPER="$HELPER" \
  FM_BIND_SESSION="$SESSION" FM_BIND_GEN="$GEN" python3 - <<'PY'
import json, os, shlex, subprocess, sys, time
from pathlib import Path
lab, root = Path(os.environ["FM_BIND_LAB"]), Path(os.environ["FM_BIND_ROOT"])
workspace, state = lab / "workspace", lab / "state"
version = subprocess.check_output(["codex", "--version"], text=True).strip()
helper, session, gen = (os.environ[k] for k in ("FM_BIND_HELPER", "FM_BIND_SESSION", "FM_BIND_GEN"))
def herdr(*args):
    return subprocess.check_output([helper, "run", session, *args], text=True)
def wait(test, label):
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if test(): return
        time.sleep(.25)
    raise AssertionError(version + ": " + label)
record = lab / "data/proof/sessions.jsonl"
(state / "proof.meta").write_text("harness=codex\nmodel=gpt-6.1-sol\neffort=low\nspawned_at=2026-11-14T00:00:00Z\n"
                                  + "busy_gen=" + gen + "\nspawn_gen=" + gen + "\nproject=" + str(workspace) + "\nsessions_file=" + str(record) + "\n")
subprocess.run([sys.executable, str(root / "bin/fm_task_sessions.py"), "start", str(state), "proof"], check=True)
assert json.loads(record.read_text())["session"] is None
(lab / "codex/config.toml").write_text('[projects.' + json.dumps(str(workspace)) + ']\ntrust_level="trusted"\n')
command = ["env", "-u", "CODEX_THREAD_ID", "-u", "FM_TASK_ID", "-u", "FM_TASK_INBOX",
           "CODEX_HOME=" + str(lab / "codex"), sys.executable, str(root / "bin/fm-codex-activity.py"),
           "launch", str(state), "proof", gen, str(workspace), "codex", "--model", "gpt-6.1-sol",
           "-c", 'model_reasoning_effort="low"', "--dangerously-bypass-approvals-and-sandbox",
           "Run sleep 5 as one foreground shell command, wait for it, then reply BIND_READY. Do nothing else."]
ws = json.loads(herdr("workspace", "create", "--cwd", str(workspace), "--label", "bind-proof", "--no-focus"))
pane = ws["result"]["root_pane"]["pane_id"]
try:
    herdr("pane", "run", pane, shlex.join(command))
    wait(lambda: any(json.loads(r).get("session") for r in record.read_text().splitlines()), "session stayed null")
    rows = [json.loads(r) for r in record.read_text().splitlines()]
    assert len(rows) == 1, "binding duplicated the launch record"
    assert rows[0]["project"] == str(workspace) and rows[0]["status"] == "active"
    assert rows[0]["reason"] is None and rows[0]["launch"] == gen
    rollout = Path(rows[0]["session"])
    meta = json.loads(rollout.read_text().splitlines()[0])["payload"]
    assert meta["source"] == "cli" and meta["cwd"] == str(workspace)
    assert version == "codex-cli " + meta["cli_version"]
    wait(lambda: any(json.loads(r).get("payload", {}).get("type") == "task_complete"
                     for r in rollout.read_text().splitlines()), "real turn never completed")
    if meta["cli_version"] != "0.166.0":
        verdict = subprocess.check_output([sys.executable, str(root / "bin/fm-codex-activity.py"),
                                           "classify", str(state), "proof"], text=True).strip()
        assert verdict == "unknown codex-unverified", "session binding changed activity qualification"
    print("ok - " + version + ": real worker transcript bound; activity qualification unchanged")
finally:
    print(herdr("pane", "read", pane, "--source", "recent", "--lines", "25"))
PY
