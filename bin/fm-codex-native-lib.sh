#!/usr/bin/env bash
# Explicit, home-local Codex native supervision binding. Sourced only.
# docs/configuration.md owns config/codex-native-supervision.json's schema.
# This is an operator attestation of an already verified target, not discovery,
# hook trust, or a claim that async hooks survive a turn on an untested client.
# No CLI is probed here. A selected root's failed proof blocks its final while
# foreground work continues; docs/configuration.md owns that opt-in boundary.

_FM_CODEX_NATIVE_DIR=${BASH_SOURCE[0]%/*}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_FM_CODEX_NATIVE_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$_FM_CODEX_NATIVE_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_CODEX_NATIVE_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$_FM_CODEX_NATIVE_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$_FM_CODEX_NATIVE_DIR/fm-supervision-engine-lib.sh"

fm_codex_native_binding() { # <root> <home> <state> <config> [Stop JSON]; sets FM_CN_* on success
  local root=$1 home=$2 state=$3 config=$4 file data device pid identity digest
  file="$config/codex-native-supervision.json"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(uname -s)" = Linux ] || return 1
  command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1 || return 1
  fm_primary_scope_matches "$root" "$state" || return 1
  # A configured host keeps its existing arm owner; this increment does not
  # adapt its lifecycle or away/quiet routing.
  fm_supervision_host_enabled "$config" codex && return 1
  device=$(fm_pr_file_device "$config") || return 1
  fm_pr_private_file_valid "$file" 600 "$device" || return 1
  digest=$(fm_custom_check_sha256 "$file") || return 1
  data=$(jq -er '
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def path: type == "string" and startswith("/") and (test("[\u0000-\u001f]") | not);
    select(.schema == 1 and .cli_version == "0.164.0") |
    select((.thread_id | uuid) and (.session_id | uuid) and .thread_id == .session_id) |
    select((.owner_pid | type) == "string" and (.owner_pid | test("^[1-9][0-9]*$"))) |
    select((.owner_identity | type) == "string" and (.owner_identity | length) > 0 and (.owner_identity | test("[\u0000-\u001f]") | not)) |
    select((.executable | path) and (.codex_home | path)) |
    select((.executable_sha256 | type) == "string" and (.executable_sha256 | test("^[0-9a-f]{64}$"))) |
    select((.remote | type) == "string" and (.remote | test("^unix://(/[^\u0000-\u001f]+)?$"))) |
    [.thread_id,.session_id,.owner_pid,.owner_identity,.executable,.executable_sha256,.remote,.codex_home] | @tsv
  ' "$file" 2>/dev/null) || return 1
  # shellcheck disable=SC2034 # Binding fields are consumed by the hook owner.
  IFS=$'\t' read -r FM_CN_THREAD FM_CN_SESSION FM_CN_ANCHOR FM_CN_ANCHOR_ID FM_CN_BIN FM_CN_BIN_HASH FM_CN_REMOTE FM_CN_HOME <<< "$data"
  # Native hooks inherit the app-server environment, not the tool's thread
  # injection. A root Stop payload identifies its thread; descendant turns use
  # SubagentStop. Tool-side probes still require their own thread context.
  if [ "$#" -eq 5 ]; then
    fm_codex_native_payload "$5" || return 1
  else
    [ "${CODEX_THREAD_ID:-}" = "$FM_CN_THREAD" ] || return 1
  fi
  [ -d "$FM_CN_HOME" ] && [ -x "$FM_CN_BIN" ] || return 1
  pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  [ "$pid" = "$FM_CN_ANCHOR" ] || return 1
  fm_session_lock_owned_by_self "$state" || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  [ "$identity" = "$FM_CN_ANCHOR_ID" ] || return 1
  [ "/proc/$pid/exe" -ef "$FM_CN_BIN" ] || return 1
  [ "$("$_FM_CODEX_NATIVE_DIR/fm-harness.sh" 2>/dev/null)" = codex ] || return 1
  [ "$(fm_custom_check_sha256 "$FM_CN_BIN")" = "$FM_CN_BIN_HASH" ] || return 1
  [ "$(fm_custom_check_sha256 "$file")" = "$digest" ] || return 1
  # shellcheck disable=SC2034 # Consumed by the hook owner.
  FM_CN_BINDING=$digest
  # home is explicit even when the code root is elsewhere.
  [ -d "$home" ]
}

fm_codex_native_payload() { # <payload>; binding must already be loaded
  # shellcheck disable=SC2034 # Consumed by the hook owner.
  FM_CN_TURN=$(printf '%s' "$1" | jq -er --arg session "$FM_CN_SESSION" '
    select(.hook_event_name == "Stop" and .session_id == $session) |
    .turn_id | select(type == "string" and length > 0 and length < 200 and (test("[\u0000-\u001f]") | not))
  ' 2>/dev/null) || return 1
}

fm_codex_native_required() { # <root> <state> <config> <payload>; intent, not owner proof
  local root=$1 state=$2 config=$3 payload=$4 file device
  file="$config/codex-native-supervision.json"
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(uname -s)" = Linux ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fm_primary_scope_matches "$root" "$state" || return 1
  [ ! -e "$state/.afk" ] || return 1
  fm_supervision_host_enabled "$config" codex && return 1
  device=$(fm_pr_file_device "$config") || return 1
  fm_pr_private_file_valid "$file" 600 "$device" || return 1
  # Select only this explicit root. Invalid owner/turn/lease evidence must not
  # make its native requirement disappear; full validation remains separate.
  jq -e --argjson payload "$payload" '
    select(.schema == 1 and (.thread_id | type) == "string") |
    select(.thread_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) |
    select(.session_id == .thread_id and $payload.hook_event_name == "Stop" and $payload.session_id == .thread_id)
  ' "$file" >/dev/null 2>&1 || return 1
  [ "$("$_FM_CODEX_NATIVE_DIR/fm-harness.sh" 2>/dev/null)" = codex ]
}
