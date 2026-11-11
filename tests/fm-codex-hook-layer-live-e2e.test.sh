#!/usr/bin/env bash
# Live guard for the codex crewmate launch's native hook posture.
#
# Executes the captured fm-spawn command with installed Codex, then verifies
# an actual file edit and turn completion. Native hooks remain enabled; the
# disposable project and CODEX_HOME contain no hooks to trust. Only auth is
# copied from the operator's profile. This submits a real prompt, so is opt-in.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_CODEX_HOOK_LAYER_LIVE codex tmux python3

CODEX_VERSION=$(codex --version 2>/dev/null) || fail 'cannot read installed Codex version'
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  printf 'approve-for-me\n' > "$home/config/codex-approval-mode"
  fm_test_spawn_brief "$home" "$id" \
    "Write Rover's admission attestation in README.md according to this repository's admission format. Do not change other project files or commit. Then reply DONE."
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" config user.name 'Test Worker'
  git -C "$proj" config user.email 'test@example.com'
  mkdir -p "$proj/.claude/skills/amber-ledger"
  python3 -c 'import secrets; print("ROVER_ADMISSION_" + secrets.token_hex(8))' > "$case_dir/expected"
  printf '%s\n' 'Every admission output must contain REPO_NATIVE_GUARD. Follow the repository admission skill to determine the required attestation format.' > "$proj/CLAUDE.md"
  printf '%s\n' '---' 'name: amber-ledger' 'description: Use when emitting an admission attestation for Rover.' '---' \
    "The Rover admission format requires version code $(cat "$case_dir/expected"). Include this version code in every emitted admission attestation." \
    > "$proj/.claude/skills/amber-ledger/SKILL.md"
  git -C "$proj" add CLAUDE.md .claude/skills/amber-ledger/SKILL.md
  git -C "$proj" commit -qm 'Seed native admission format'
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >"$case_dir/spawn.log" 2>&1 || {
    cat "$case_dir/spawn.log" >&2
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
  }
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

test_installed_codex_edits_with_preserved_hook_posture() {
  local launch flags auth
  launch=$(capture_codex_launch ship --mode local-only --yolo off --model gpt-6.1-sol --effort low)
  flags=$(codex_global_flags "$launch")
  case " $flags " in
    *' --approve-for-me '*) ;;
    *) fail "codex $CODEX_VERSION captured launch omitted --approve-for-me" ;;
  esac
  case " $flags " in
    *' --dangerously-bypass-approvals-and-sandbox '*)
      fail "codex $CODEX_VERSION captured launch retained the complete-bypass posture"
      ;;
  esac
  case " $flags " in
    *' --disable hooks '*) fail "codex $CODEX_VERSION launch disabled native hooks" ;;
  esac
  case " $flags " in
    *' --dangerously-bypass-hook-trust '*) fail "codex $CODEX_VERSION launch bypassed hook trust review" ;;
  esac
  case " $flags " in
    *' --sandbox read-only '*) fail "codex $CODEX_VERSION launch prevents assigned edits" ;;
  esac

  auth="${CODEX_HOME:-$HOME/.codex}/auth.json"
  [ -r "$auth" ] || fail "codex $CODEX_VERSION: live editing needs a readable auth.json"
  mkdir -p "$TMP_ROOT/codex"
  install -m 600 "$auth" "$TMP_ROOT/codex/auth.json"
  FM_CODEX_EDIT_LAB="$TMP_ROOT" FM_CODEX_EDIT_VERSION="$CODEX_VERSION" FM_CODEX_EDIT_ROOT="$ROOT" \
    python3 - <<'PY' || fail "codex $CODEX_VERSION: real worker editing failed"
import json
import os
from pathlib import Path
import subprocess
import sys
import time

lab = Path(os.environ["FM_CODEX_EDIT_LAB"])
version = os.environ["FM_CODEX_EDIT_VERSION"]
workspace = lab / "ship/wt"
state = lab / "ship/home/state"
target = workspace / "README.md"
expected = (lab / "ship/expected").read_text().strip()
assert expected not in target.read_text(), "edit assertion would be vacuous"
brief = lab / "ship/home/data/codex-hook-layer-ship/launch-brief.md"
assert "Unsupported registration is reported without restricting edits" in brief.read_text()
assert expected not in brief.read_text() and "amber-ledger" not in brief.read_text()
assert not (workspace / ".agents/skills").exists(), "fixture masks the foreign-root case"
assert not (workspace / "AGENTS.md").exists(), "fixture masks the instruction fallback"
env = os.environ.copy()
env["CODEX_HOME"] = str(lab / "codex")
env["FM_HOME"] = str(lab / "ship/home")
for key in ("FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "CODEX_THREAD_ID"):
    env.pop(key, None)
# Only the private directory is trusted; no hook trust is manufactured.
(lab / "codex/config.toml").write_text(
    "[projects." + json.dumps(str(workspace)) + ']\ntrust_level="trusted"\n'
    + "[projects." + json.dumps(str(lab / "ship/project")) + ']\ntrust_level="trusted"\n'
)
socket = "fm-codex-worker-edit-" + str(os.getpid())
generation = (state / "codex-hook-layer-ship.busy-gen").read_text().strip()
activity = Path(os.environ["FM_CODEX_EDIT_ROOT"]) / "bin/fm-codex-activity.py"
checks_activity = sys.platform == "linux" and version == "codex-cli 0.166.0"
seen_busy = False

def activity_state():
    return subprocess.check_output([sys.executable, str(activity), "classify", str(state),
                                    "codex-hook-layer-ship"], env=env, text=True, timeout=10).strip()

def tmux(*args):
    return subprocess.check_output(["tmux", "-L", socket, *args], text=True, env=env, timeout=10)

try:
    launch = (lab / "ship/launch.log").read_text().strip()
    tmux("new-session", "-d", "-s", "proof", "-x", "160", "-y", "50", "-c", str(workspace),
         "bash", "-c", launch)
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        status = activity_state() if checks_activity else ""
        seen_busy = seen_busy or status == "busy codex-rollout"
        if (expected in target.read_text() and "REPO_NATIVE_GUARD" in target.read_text()
                and (state / "codex-hook-layer-ship.turn-ended").exists()
                and (not checks_activity or status == "idle codex-rollout")):
            if checks_activity:
                assert seen_busy, "native server never exposed its bound busy state"
            print("ok - " + version + ": native skill, repository instructions, edit and completion verified", flush=True)
            break
        time.sleep(.25)
    else:
        raise AssertionError(version + ": worker did not edit README.md and complete within 180s")
    matching = []
    for rollout in (lab / "codex/sessions").rglob("*.jsonl"):
        rows = [json.loads(line) for line in rollout.read_text().splitlines()]
        if not any(r.get("type") == "session_meta" and r.get("payload", {}).get("cwd") == str(workspace)
                   and r.get("payload", {}).get("source") == "vscode" for r in rows):
            continue
        native_instructions = False
        for row in rows:
            value = row.get("payload", {})
            if row.get("type") != "response_item" or value.get("type") != "message":
                continue
            text = "\n".join(c.get("text", "") for c in value.get("content", []))
            if "FIRSTMATE_OP: v1 launch-brief" in text:
                break
            native_instructions = native_instructions or "REPO_NATIVE_GUARD" in text
            if "Available skills" in text and "amber-ledger" in text:
                matching.append(rollout)
        if rollout in matching:
            assert native_instructions, "CLAUDE.md instructions were absent before the task"
    assert matching, "actual worker's initial native catalog omitted the repository skill"
    print("ok - native catalog and CLAUDE.md loaded before the unnamed task", flush=True)
finally:
    try:
        print("# real worker pane:\n" + tmux("capture-pane", "-p", "-S", "-200", "-t", "proof:0"), flush=True)
    finally:
        subprocess.run(["tmux", "-L", socket, "kill-server"], env=env, capture_output=True, timeout=10)
        subprocess.run([sys.executable, str(activity.with_name("fm-worker-processes.py")),
                        "cleanup-meta", str(state / "codex-hook-layer-ship.meta")],
                       env=env, check=True, timeout=30)
PY
}

test_installed_codex_edits_with_preserved_hook_posture

echo "# all fm-codex-hook-layer-live-e2e tests passed"
