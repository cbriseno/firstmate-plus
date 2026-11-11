#!/usr/bin/env bash
# Interactive Claude trust guard. Run deliberately from an isolated linked
# task worktree: FM_CLAUDE_TRUST_LIVE_E2E=1 bash tests/fm-claude-trust-live-e2e.test.sh
# Uses a private config copy and tmux server, edits one temporary file in this
# worktree, and preserves the real user's external-import decision and config.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_TRUST_LIVE_E2E claude tmux node git

VERSION=$(claude --version)
LAB=$(fm_test_tmproot fm-claude-trust-live)
LAB=$(cd -P "$LAB" && pwd -P)
SOCKET="fm-claude-trust-live-$$"
PROOF=
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$PROOF" ] || rm -f -- "$PROOF"
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The public helper verifies this is a linked worktree of the canonical project;
# it refuses a primary checkout. Never lease or change the caller's pool slot.
COMMON=$(git -C "$ROOT" rev-parse --git-common-dir)
PROJECT=$(cd "$ROOT" && cd "$(dirname "$COMMON")" && pwd -P)
CONFIG="$LAB/config"
mkdir -m 700 "$CONFIG"
SOURCE_CONFIG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SOURCE_STORE=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
[ ! -f "$SOURCE_STORE" ] || cp "$SOURCE_STORE" "$CONFIG/.claude.json"
[ ! -f "$SOURCE_CONFIG/.credentials.json" ] || cp "$SOURCE_CONFIG/.credentials.json" "$CONFIG/.credentials.json"
node - "$CONFIG/.claude.json" "$PROJECT" "$ROOT" <<'NODE'
const fs = require('node:fs');
const [store, project, worktree] = process.argv.slice(2);
const root = fs.existsSync(store) ? JSON.parse(fs.readFileSync(store, 'utf8')) : {};
root.projects ??= {};
root.projects[project] = {
  ...root.projects[project], hasTrustDialogAccepted: false,
  hasClaudeMdExternalIncludesApproved: false, hasClaudeMdExternalIncludesWarningShown: true,
};
delete root.projects[worktree];
fs.writeFileSync(store, JSON.stringify(root), {mode: 0o600});
NODE
printf 'External imports fixture.\n' > "$LAB/external.md"
printf '@%s/external.md\n' "$LAB" > "$CONFIG/CLAUDE.md"
CLAUDE_CONFIG_DIR="$CONFIG" bash "$ROOT/bin/fm-claude-trust.sh" "$ROOT" "$PROJECT" \
  || fail "$VERSION: could not register trust; run in an isolated linked task worktree"

PROOF=$(mktemp "$ROOT/.fm-claude-trust-live.XXXXXX")
printf 'pending\n' > "$PROOF"
PROMPT="Edit $(basename "$PROOF"): replace pending with claude-trust-live-ok using the Edit tool. Then reply VALIDATION_DONE and stop."
# An actual interactive TTY is essential: print mode skips startup trust gates.
printf '%q ' env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  "CLAUDE_CONFIG_DIR=$CONFIG" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  claude --model "${FM_CLAUDE_TRUST_LIVE_MODEL:-haiku}" --effort low \
  --permission-mode auto --allowedTools Edit,Read --setting-sources project,local \
  --settings '{"disableAllHooks":true,"feedbackDrafts":"off"}' \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --append-system-prompt "You are a validation worker. Do not supervise, delegate, or run session-start. Edit only $(basename "$PROOF") in the current worktree, then stop." \
  "$PROMPT" > "$LAB/run.sh"
tmux -L "$SOCKET" new-session -d -s validation -x 140 -y 40 -c "$ROOT" "bash '$LAB/run.sh'"
for ((i=0; i<120; i++)); do
  if [ "$(cat "$PROOF")" = claude-trust-live-ok ]; then
    if ! node - "$CONFIG/.claude.json" "$PROJECT" <<'NODE'
const fs = require('node:fs');
const [store, project] = process.argv.slice(2);
const entry = JSON.parse(fs.readFileSync(store, 'utf8')).projects[project];
process.exit(entry.hasTrustDialogAccepted === true &&
  entry.hasClaudeMdExternalIncludesApproved === false &&
  entry.hasClaudeMdExternalIncludesWarningShown === true ? 0 : 1);
NODE
    then
      fail "$VERSION: external-import decision changed"
    fi
    pass "$VERSION: interactive worktree edit completed with external imports declined"
    exit 0
  fi
  sleep 1
done
tmux -L "$SOCKET" capture-pane -p -t validation -S -60 >&2 || true
fail "$VERSION: interactive worker did not edit its proof file within 120 seconds"
