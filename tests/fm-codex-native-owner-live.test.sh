#!/usr/bin/env bash
# Read-only live guard for the opt-in native owner's structural binding.
# Run in the owning primary while its actual Stop callback is watching or
# observing an accepted queue. The latter reads bounded metadata through the
# attested executable's existing proxy and projects its own clientId/turn join.
# This guard submits no input, changes no hook/trust/config and does not prove
# delayed idle reentry. The coordinated acceptance in runtime-backends.md is
# separately required before treating that frontend as continuous.
# It reads the owning home's live records and queries the real Codex daemon, so
# it is opt-in: run it deliberately with FM_CODEX_NATIVE_OWNER_LIVE=1.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_NATIVE_OWNER_LIVE codex jq perl python3
unset FM_TEST_SEAM FM_TEST_HARNESS FM_PROC_ROOT_OVERRIDE
version=$(codex --version 2>&1) || fail 'Codex live guard cannot read installed version'
home=${FM_HOME:-$ROOT}
state=${FM_STATE_OVERRIDE:-$home/state}
config=${FM_CONFIG_OVERRIDE:-$home/config}
[ -f "$config/codex-native-supervision.json" ] \
  || fail "$version: native owner live check requested without an explicit binding"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-codex-native-lib.sh
. "$ROOT/bin/fm-codex-native-lib.sh"
fm_codex_native_binding "${FM_ROOT_OVERRIDE:-$ROOT}" "$home" "$state" "$config" \
  || fail "$version: no verified native binding in this owning primary; run after coordinated hook acceptance"
version=$("$FM_CN_BIN" --version 2>&1) || fail "$version: cannot read bound executable version"
[ "$version" = 'codex-cli 0.164.0' ] || fail "$version: native owner supports only the pinned 0.164.0 capability"
record="$state/.codex-native.json"
jq -e --arg binding "$FM_CN_BINDING" --arg thread "$FM_CN_THREAD" --arg session "$FM_CN_SESSION" \
  --arg anchor "$FM_CN_ANCHOR" --arg identity "$FM_CN_ANCHOR_ID" '
    (.phase == "watching" or .phase == "queued") and .binding == $binding and .thread == $thread and .session == $session
    and .anchor == $anchor and .anchor_identity == $identity and (.turn | type) == "string"
    and (.generation | type) == "string"
  ' "$record" >/dev/null 2>&1 || fail "$version: no current native Stop owner receipt"
pid=$(jq -r '.pid' "$record")
[ "$pid" = "$(cat "$state/.codex-native.lock/pid" 2>/dev/null)" ] \
  || fail "$version: native singleton does not own this receipt"
identity=$(fm_pid_identity "$pid") || fail "$version: native callback is dead"
jq -e --arg identity "$identity" --argjson now "$(date +%s)" '.identity == $identity and .deadline > $now' "$record" >/dev/null \
  || fail "$version: callback process identity changed"
if [ "$(jq -r '.phase' "$record")" = queued ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  client=$(jq -er '.client_id | select(type == "string" and length > 0)' "$record") \
    || fail "$version: queued receipt lacks explicit client ID"
  expected_binding=$FM_CN_BINDING
  generation=$(jq -r '.generation' "$record")
  metadata=$(CODEX_HOME="$FM_CN_HOME" fm_run_timed 6 python3 "$ROOT/bin/fm-codex-native-rpc.py" outcome \
    --executable "$FM_CN_BIN" --remote "$FM_CN_REMOTE" --thread "$FM_CN_THREAD" --client-id "$client") \
    || fail "$version: native outcome protocol unproved"
  fm_codex_native_binding "${FM_ROOT_OVERRIDE:-$ROOT}" "$home" "$state" "$config" \
    || fail "$version: binding changed during metadata read"
  [ "$FM_CN_BINDING" = "$expected_binding" ] && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ] \
    || fail "$version: callback/binding changed during metadata read"
  jq -e --arg generation "$generation" --arg client "$client" \
    '.phase == "queued" and .generation == $generation and .client_id == $client' "$record" >/dev/null \
    || fail "$version: delivery changed during metadata read"
  jq -e '(.turn_id | type) == "string" and (.status == "inProgress" or .status == "completed" or .status == "failed" or .status == "interrupted")' \
    <<< "$metadata" >/dev/null || fail "$version: own queued client ID has no explicit turn/outcome join"
  pass "$version: real queued client ID joined to its turn and metadata outcome (automatic recovery not tested)"
  exit 0
fi
fm_watcher_healthy "$state" "$ROOT/bin/fm-watch.sh" 300 "$home" \
  || fail "$version: native callback has no healthy bound watcher"
pass "$version: real owning-primary binding, Stop callback and watcher agree (idle reentry not tested)"
