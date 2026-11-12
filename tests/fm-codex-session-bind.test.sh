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
