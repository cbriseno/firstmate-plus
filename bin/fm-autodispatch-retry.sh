#!/usr/bin/env bash
# Wait for a deferred allocation outside the watcher, then retry dispatch.
# Usage: fm-autodispatch-retry.sh <task-id> <home> <state> <config>
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id=${1:?task id required}; FM_HOME=${2:?home required}; STATE=${3:?state required}; CONFIG=${4:?config required}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
marker="$STATE/.autodispatch-lock-$id"
held=
trap '[ -z "$held" ] || fm_lock_release "$held"' EXIT
while [ -f "$marker" ]; do
  lock=
  IFS= read -r lock < "$marker" || true
  if [ -n "$lock" ] && [ -d "${lock%/*}" ]; then
    if ! fm_lock_acquire_wait "$lock"; then
      out='error: allocation lock unavailable'
      rc=1
      break
    fi
    held=$lock
    fm_lock_release "$held" || exit 1
    held=
  fi
  [ -f "$marker" ] || exit 0
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    bash "$SCRIPT_DIR/fm-autodispatch.sh" "$id" 2>&1 </dev/null) || rc=$?
  [ "$rc" = 76 ] || break
done
[ -f "$marker" ] || exit 0
case ${rc:-3} in
  0|75) printf '%s\n' "$out"; rm -f -- "$marker"; exit 0 ;;
  3) out='not auto-launchable after waiting for allocation' ;;
esac
printf '%s\n' "${out:-automatic dispatch failed}" | python3 "$SCRIPT_DIR/fm-redact-log.py" | tail -n 1 | cut -c1-300 > "$STATE/.autodispatch-failed-$id"
rm -f -- "$marker"
fm_wake_append check "autodispatch-failed-$id" "check: automatic launch of ready task $id failed: $(cat "$STATE/.autodispatch-failed-$id"); dispatch it manually" || true
exit 1
