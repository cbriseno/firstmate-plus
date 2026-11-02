#!/usr/bin/env bash
# Retire only the outgoing primary's proven shared-runtime lock, as the last
# handoff operation. Never kills a process or stops a daemon. Acquisition and
# its refusal of live owners remain owned by fm-lock.sh.
#
# Usage: fm-lock-release.sh --authority TEXT --receipt ABSOLUTE_DIRECTORY
#        [--binding ABSOLUTE_FILE]
# The authority names the approved handoff. The new private receipt directory
# retains the original lock, optional session sidecar and outgoing-retired.json.
# Its parent must already exist on the same filesystem as the state directory.
# Repeating the same receipt is safe even after a successor acquires the lock.
# A prepared receipt recovers an interrupted archive without deleting evidence.
#
# Direct session anchors are retained: their normal process exit releases their
# authority. Shared Codex app-server anchors on Linux require the outgoing
# CODEX_THREAD_ID and the existing private primary-ingress registration (default
# state/.codex-primary-ingress.json; --binding selects an equivalent registration).
# Its native endpoint must prove the exact outgoing thread/home and no other
# loaded session in that home, including idle sessions. Unreadable, changed or
# incomplete proof refuses. No new registration or trust is created here.
# Other shared-runtime protocols are not inferred from a harness name.
# The receipt records the proven session, kernel process identity, authority,
# time and preserved lock identity. After release the outgoing primary must do
# no more fleet work and exit; this command does not close its session for it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
usage() { sed -n '2,/^set -u/p' "$SCRIPT_DIR/fm-lock-release.sh" | sed '$d;s/^# *//'; }
authority='' receipt='' binding=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --authority|--receipt|--binding)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$1" in
        --authority) authority=$2 ;;
        --receipt) receipt=$2 ;;
        --binding) binding=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -n "$authority" ] && [ -n "$receipt" ] || { usage >&2; exit 2; }
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo 'error: invalid session-lock state directory' >&2; exit 1; }
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
claim="$STATE/.lock.acquire"
fm_lock_acquire_wait_max "$claim" 5 || { echo 'error: session-lock claim is busy; retry the same receipt' >&2; exit 1; }
trap 'fm_lock_release "$claim"' EXIT
[ -n "$binding" ] || binding="$STATE/.codex-primary-ingress.json"
# The helper rechecks the exact archived/current inode while this same claim
# lock excludes acquisition, re-anchoring and another supported release.
# Keep caller-supplied paths and authority out of the interpreter's argv: the
# shared harness classifier legitimately recognizes Python-hosted harnesses.
printf '%s\0' "$FM_HOME" "$STATE" "$authority" "$receipt" "$binding" \
  | python3 "$SCRIPT_DIR/fm-lock-release.py"
