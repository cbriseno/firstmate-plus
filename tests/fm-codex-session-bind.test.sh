#!/usr/bin/env bash
set -euo pipefail

ROOT=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parent.parent)' "${BASH_SOURCE[0]}")
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-session-bind.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

home="$TMP_ROOT/home"
state="$home/state"
data="$home/data"
workspace="$TMP_ROOT/workspace"
codex_home="$TMP_ROOT/codex"
fakebin="$TMP_ROOT/bin"
task=bind-proof
gen=current-gen
session=11111111-2222-3333-4444-555555555555
rollout="$codex_home/sessions/2026/11/11/rollout-test-$session.jsonl"
mkdir -p "$state" "$data/$task" "$workspace" "$codex_home/sessions/2026/11/11" "$fakebin"

cat > "$state/$task.meta" <<EOF
harness=codex
model=test-model
effort=low
spawned_at=2026-11-11T11:00:00Z
busy_gen=$gen
sessions_file=$data/$task/sessions.jsonl
EOF
printf '{"type":"session_meta","payload":{"id":"%s","cli_version":"0.169.0","source":"cli","cwd":"%s"}}\n' \
  "$session" "$workspace" > "$rollout"
cat > "$fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nn%s\n' "\${3#-p}" '$rollout'
EOF
chmod +x "$fakebin/lsof"

PATH="$fakebin:$PATH" CODEX_HOME="$codex_home" python3 "$ROOT/bin/fm-codex-activity.py" \
  bind-session "$state" "$task" "$gen" "$workspace" "$$"
python3 - "$data/$task/sessions.jsonl" "$rollout" <<'PY'
import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
assert len(rows) == 1 and rows[0]['session'] == sys.argv[2], rows
PY

printf 'ok - Codex rollout binding records the current task session through the launch interface\n'

# Registration is capability-based on newer versions; an unavailable API must
# keep the original writable CLI invocation.
mkdir -p "$workspace/.claude/skills"
printf 'Follow the repository convention.\n' > "$workspace/CLAUDE.md"
cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'codex-cli 0.167.0\n'; exit 0; fi
if [ "${1:-}" = app-server ]; then
  printf '%s\n' "$@" > "$FM_TEST_CODEX_SERVER_ARGS"
  exit 64
fi
printf '%s\n' "$@" > "$FM_TEST_CODEX_ARGS"
printf 'editable\n' > "$FM_TEST_CODEX_RESULT"
SH
chmod +x "$fakebin/codex"
PATH="$fakebin:$PATH" CODEX_HOME="$codex_home" FM_TEST_CODEX_ARGS="$TMP_ROOT/args" \
  FM_TEST_CODEX_SERVER_ARGS="$TMP_ROOT/server-args" FM_TEST_CODEX_RESULT="$workspace/result" python3 "$ROOT/bin/fm-codex-activity.py" \
  launch "$state" "$task" "$gen" "$workspace" "$fakebin/codex" --approve-for-me 'original task' \
  > "$TMP_ROOT/fallback.log" 2>&1
printf '%s\n' -c 'project_doc_fallback_filenames=["CLAUDE.md"]' --approve-for-me 'original task' > "$TMP_ROOT/expected-args"
[ "$(head -n 1 "$TMP_ROOT/server-args")" = app-server ]
cmp "$TMP_ROOT/expected-args" "$TMP_ROOT/args"
[ "$(cat "$workspace/result")" = editable ]
rg -q 'Unsupported: Codex native skill-root registration unavailable' "$TMP_ROOT/fallback.log"
printf 'ok - newer Codex attempts native registration; unavailable API retains editable configured launch\n'

# A newer capable server has no qualified activity binding, but its primary
# completion must still reach the configured callback. Keep real parent/file
# ownership while the portable lsof fixture projects that open descriptor.
PATH="$fakebin:$PATH" CODEX_HOME="$codex_home" python3 - \
  "$ROOT/bin/fm-codex-activity.py" "$state" "$task" "$gen" "$workspace" "$rollout" "$TMP_ROOT" <<'PYNOTIFY'
import json
from pathlib import Path
import subprocess
import sys
activity, state, task, gen, workspace, rollout, scratch = sys.argv[1:]
state, rollout, scratch = Path(state), Path(rollout), Path(scratch)
workspace = str(Path(workspace).resolve())
session = json.loads(rollout.read_text().splitlines()[0])["payload"]["id"]
(state / (task + ".busy-gen")).write_text(gen + "\n")
rows = [{"type": "session_meta", "payload": {"id": session, "cli_version": "0.167.0", "source": "vscode", "cwd": workspace}},
        {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "primary-turn"}},
        {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "primary-turn"}}]
rollout.write_text("".join(json.dumps(row) + "\n" for row in rows))
delivered = scratch / "notification.json"
program = [sys.executable, "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])", str(delivered)]
def notify(thread):
    subprocess.run([sys.executable, activity, "notify", str(state), task, gen, workspace,
                    json.dumps(program), json.dumps({"thread-id": thread})], check=True)
with rollout.open("rb"):
    notify(session)
    assert delivered.is_file(), "primary completion was dropped"
    assert json.loads(delivered.read_text())["thread-id"] == session, "wrong thread completion was forwarded"
    verdict = subprocess.check_output([sys.executable, activity, "classify", str(state), task], text=True).strip()
    assert verdict == "unknown codex-unverified", verdict
    delivered.unlink()
    notify("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    assert not delivered.exists(), "guardian completion was forwarded"
    (state / (task + ".busy-gen")).write_text("replacement\n")
    notify(session)
    assert not delivered.exists(), "old generation completion was forwarded"
PYNOTIFY
printf 'ok - newer native primary notification forwards; guardian and stale callbacks do not; activity stays unqualified\n'

# Exercise the actual launcher and callback without relying on lsof or /proc. The captured
# title callback has a different, ephemeral thread; a persisted guardian is also
# auxiliary. Neither may touch the watcher marker or change its ledger record.
cat > "$fakebin/codex" <<'PYCLI'
#!/usr/bin/env python3
import json, os, subprocess, sys
if sys.argv[1:] == ["--version"]:
    print("codex-cli 0.169.0")
    raise SystemExit(0)
args = iter(sys.argv[1:])
for arg in args:
    if arg in ("-c", "--config"):
        value = next(args)
        if value.startswith("notify="):
            callback = json.loads(value.partition("=")[2])
for event in json.loads(os.environ["FM_TEST_CALLBACKS"]):
    subprocess.run([*callback, json.dumps(event)], check=True)
PYCLI
chmod +x "$fakebin/codex"
PATH="$fakebin:$PATH" CODEX_HOME="$codex_home" python3 - \
  "$ROOT/bin/fm-codex-activity.py" "$ROOT/bin/fm-busy-event.sh" "$state" "$workspace" "$rollout" "$fakebin/codex" <<'PYCLI'
import json, os
from pathlib import Path
import shlex, subprocess, sys
activity, writer, state, workspace, rollout, codex = sys.argv[1:]
state, rollout = Path(state), Path(rollout)
task = "notify-proof"
gen = subprocess.check_output(["bash", writer, "arm", str(state), task], text=True).strip()
marker = state / (task + ".turn-ended")
record = state / (task + ".busy-state")
program = ["bash", "-c", shlex.join(["bash", writer, "apply", str(state), task, "idle", "--gen", gen,
                                   "--source", "codex-notify", "--event", "turn-complete", "--turn-ended"])]
primary = json.loads(rollout.read_text().splitlines()[0])["payload"]["id"]
# This persisted fixture deliberately uses a newer version, as notify ownership
# is independent of the separate Linux activity classifier's version pin.
header = {"type": "session_meta", "payload": {"id": primary, "cli_version": "0.169.0",
          "source": "cli", "cwd": workspace}}
rollout.write_text(json.dumps(header) + "\n")
title = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
guardian = "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
guardian_path = rollout.with_name("rollout-test-" + guardian + ".jsonl")
guardian_path.write_text(json.dumps({"type": "session_meta", "payload": {
    "id": guardian, "source": {"subagent": {"other": "guardian"}}, "cwd": workspace}}) + "\n")
def emit(thread):
    env = dict(os.environ, FM_TEST_CALLBACKS=json.dumps([{"type": "agent-turn-complete", "thread-id": thread}]))
    subprocess.run([sys.executable, activity, "launch", str(state), task, gen, workspace, codex,
                    "--config=notify=" + json.dumps(program), "real work"], env=env, check=True)
for auxiliary in (title, guardian):
    emit(auxiliary)
    assert not marker.exists(), "auxiliary callback woke the watcher"
    assert "state=busy" in record.read_text(), "auxiliary callback settled the worker"
emit(primary)
assert marker.exists(), "real worker completion did not wake the watcher"
assert "state=idle" in record.read_text(), "real worker completion did not settle the ledger"
marker.unlink()
subprocess.run(["bash", writer, "arm", str(state), task], check=True, stdout=subprocess.DEVNULL)
emit(primary)
assert not marker.exists(), "old incarnation woke its replacement"
PYCLI
printf 'ok - CLI launch ignores ephemeral title and guardian callbacks; real completion wakes; stale generation stays silent\n'
