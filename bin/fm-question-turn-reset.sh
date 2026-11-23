#!/usr/bin/env bash
# UserPromptSubmit hook: clear turn state and supply current standing grants.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
if fm_primary_scope_matches "$FM_ROOT" "$STATE" && fm_session_lock_owned_by_self "$STATE"; then
  rm -f -- "$STATE/.captain-hold-turn" "$STATE/.captain-question-block"
  DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  python3 "$SCRIPT_DIR/fm-standing-grants.py" context "$DATA/standing-grants.json" || :
fi
