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
printf '{"type":"session_meta","payload":{"id":"%s","cli_version":"0.166.0","source":"cli","cwd":"%s"}}\n' \
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
