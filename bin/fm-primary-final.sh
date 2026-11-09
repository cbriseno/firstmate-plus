#!/usr/bin/env bash
# Capture a verified primary's complete final text in the opt-in fleet ledger.
# Usage: fm-primary-final.sh claude|codex [<Codex notify JSON>]
# Hook JSON comes from stdin; Codex notify supplies its JSON as the last argument.
# Requires the existing primary scope and session-lock ownership. Workers and
# foreign hook hosts are inert. This records text, never infers or answers a call.
# Exit 1 means capture failed; the canonical chat remains available for replay.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -e "$CONFIG/fleet-ledger" ] || exit 0
case "${1:-}" in claude|codex) ;; *) exit 2 ;; esac
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" && fm_session_lock_owned_by_self "$STATE" || exit 0
if [ "$#" -eq 2 ]; then payload=$2; else payload=$(cat); fi
fm_hook_payload_is_foreign_host "$payload" && exit 0
value=$(printf '%s' "$payload" | jq -ce --arg harness "$1" '
  select(.hook_event_name == "Stop" or .type == "agent-turn-complete")
  | {harness:$harness, session:(.session_id // .["thread-id"]),
     turn:(.prompt_id // .["turn-id"] // null),
     text:(.last_assistant_message // .["last-assistant-message"])}
  | select((.session | type) == "string" and (.text | type) == "string")') || {
    echo 'fm-primary-final: missing final text or session; capture unavailable' >&2
    exit 1
  }
printf '%s\n' "$value" | FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
  bash "$SCRIPT_DIR/fm-fleet-ledger.sh" entity primary.final primary
