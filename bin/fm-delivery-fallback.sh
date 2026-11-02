#!/usr/bin/env bash
# Switch a ship task that is already under way to a less rigorous delivery
# path because a captain rule made its selected path unavailable, and steer its
# worker onto the new contract.
# Usage: fm-delivery-fallback.sh <task-id> --mode <direct-PR|local-only> --reason <text> [--resolve-key <key>]
#
# A captain rule that allows a path only on an explicit request - no-mistakes,
# or GitHub Actions that a push or pull request would trigger - already states
# the captain's default, so it is a stated reason to drop rigor, never a
# question about the delivery mode (AGENTS.md section 7 owns that intake rule).
# A worker that meets such a rule reports it under the key bin/fm-dod-lib.sh's
# Definition of done names (`delivery-fallback`), and firstmate answers with
# this command rather than asking the captain. --reason is the rule, quoted
# briefly; it travels to the worker and into the printed outcome. Pass the
# worker's open key as --resolve-key so the steer closes that blocker at answer
# time (bin/fm-send.sh owns the close).
#
# Only a drop in rigor is a fallback: no-mistakes may fall back to direct-PR or
# local-only, and direct-PR to local-only. The new contract must be one the
# task's recorded forge and base branch accept (bin/fm-dod-lib.sh's
# fm_forge_valid_for_mode and fm_base_branch_valid), so a forge-bound task can
# never fall back to local-only, which publishes nothing; the refusal names why.
# Recorded upstream consent is kept for a publishing mode and dropped for
# local-only, which publishes nothing.
#
# What changes, in this order, and nothing else:
#   1. data/<id>/brief.md: its `# Definition of done` section (through the next
#      top-level heading) and rule 1 of its `# Rules` are re-rendered for the new
#      mode, so a later relaunch reads the same contract (bin/fm-spawn.sh
#      checks the brief's Delivery contract line against the recorded mode).
#   2. state/<id>.meta: mode= and fallback_from=<previous mode> under the
#      task's meta lock, and upstream_consent= removed on local-only. yolo= is
#      untouched, because delivery mode and merge authority are orthogonal.
#   3. One steer through bin/fm-send.sh carrying the new rule 1 and Definition
#      of done in full.
# Each step is idempotent, so a run interrupted after step 1 or 2 can simply be
# re-run with the same arguments: a record that already reads mode=<new> with
# fallback_from= set skips straight to resending the steer. It does not stop a no-mistakes run that
# already owns the branch: switch only a task whose pipeline has not started,
# which is exactly the task a forbidding rule leaves behind.
# Exit 0 switched, 1 a refused or failed step, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-delivery-fallback.sh <task-id> --mode <direct-PR|local-only> --reason <text> [--resolve-key <key>]" >&2
  exit 2
}

ID=${1:-}
[ -n "$ID" ] || usage
shift
NEW_MODE=
REASON=
RESOLVE_KEY=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || usage; NEW_MODE=$2; shift ;;
    --reason) [ "$#" -ge 2 ] || usage; REASON=$2; shift ;;
    --resolve-key) [ "$#" -ge 2 ] || usage; RESOLVE_KEY=$2; shift ;;
    *) usage ;;
  esac
  shift
done
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }
[ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] || { echo "error: --reason must quote the captain rule that made the path unavailable" >&2; exit 2; }

rigor() {
  case "$1" in
    no-mistakes) echo 3 ;;
    direct-PR) echo 2 ;;
    local-only) echo 1 ;;
    *) echo 0 ;;
  esac
}
case "$NEW_MODE" in
  direct-PR|local-only) ;;
  *) echo "error: --mode must be direct-PR or local-only, the paths a fallback can drop to" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
BRIEF="$DATA/$ID/brief.md"
[ -f "$META" ] || { echo "error: $ID has no task record at $META; only a ship task under way can fall back" >&2; exit 1; }
[ -f "$BRIEF" ] || { echo "error: $ID has no brief at $BRIEF" >&2; exit 1; }
[ "$(fm_dod_meta_value "$META" kind)" = ship ] || { echo "error: $ID is not a ship task; only a ship has a delivery path to fall back from" >&2; exit 1; }
OLD_MODE=$(fm_dod_meta_value "$META" mode)
RESEND=0
if [ "$OLD_MODE" = "$NEW_MODE" ] && [ -n "$(fm_dod_meta_value "$META" fallback_from)" ]; then
  OLD_MODE=$(fm_dod_meta_value "$META" fallback_from)
  RESEND=1
fi
if [ "$(rigor "$NEW_MODE")" -ge "$(rigor "$OLD_MODE")" ]; then
  echo "error: $ID ships ${OLD_MODE:-an unknown mode}; a fallback only drops to a path with less rigor, and $NEW_MODE is not one" >&2
  exit 1
fi

contract=$(sed -n 's/^Delivery contract: //p' "$BRIEF" | head -n 1)
[ -n "$contract" ] || { echo "error: $BRIEF has no Delivery contract line to re-render" >&2; exit 1; }
FORGE=none
CONSENT=
for token in $contract; do
  case "$token" in
    forge=*) FORGE=${token#forge=} ;;
    upstream-consent=*) CONSENT=${token#upstream-consent=} ;;
  esac
done
BRANCH=$(sed -n 's/^Ship branch: //p' "$BRIEF" | head -n 1)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
BASE=$(fm_dod_meta_value "$META" base_branch)
[ "$NEW_MODE" != local-only ] || CONSENT=
fm_forge_valid_for_mode "$FORGE" "$NEW_MODE" fm-delivery-fallback || exit 1
fm_base_branch_valid "$BASE" "$NEW_MODE" "$FORGE" fm-delivery-fallback || exit 1

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-delivery-fallback.XXXXXX") || exit 1
META_LOCK=
cleanup() {
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK"
  rm -rf "$TMP"
}
trap cleanup EXIT
fm_dod_block "$NEW_MODE" "$ID" "$BRANCH" "$FORGE" "$BASE" "$CONSENT" > "$TMP/dod" || exit 1
RULE_ONE=$(fm_ship_rule_one "$NEW_MODE" "$ID" "$BRANCH" "$FORGE" "$BASE") || exit 1

# 1. The brief.
rewrite_brief() {
  awk -v dod="$TMP/dod" -v rule="$RULE_ONE" '
    /^# / { in_dod = 0; in_rules = ($0 == "# Rules") }
    $0 == "# Definition of done" {
      while ((getline line < dod) > 0) print line
      in_dod = 1; next
    }
    in_dod { next }
    in_rules && !rule_done && /^1\. / { print rule; rule_done = 1; next }
    { print }
  ' "$BRIEF" > "$TMP/brief" || return 1
  if ! grep -q "^Delivery contract: mode=$NEW_MODE\( \|$\)" "$TMP/brief"; then
    echo "error: could not re-render $BRIEF's Definition of done" >&2
    return 1
  fi
  cat "$TMP/brief" > "$BRIEF"
}

# 2. The task record.
rewrite_meta() {
  local drop_consent='' meta_tmp
  [ "$NEW_MODE" != local-only ] || drop_consent=1
  META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$META_LOCK"
  awk -v mode="$NEW_MODE" -v from="$OLD_MODE" -v drop_consent="$drop_consent" '
    /^mode=/ { if (!seen) print "mode=" mode; seen = 1; next }
    /^fallback_from=/ { next }
    drop_consent && /^upstream_consent=/ { next }
    { print }
    END { if (!seen) print "mode=" mode; print "fallback_from=" from }
  ' "$META" > "$TMP/meta" || return 1
  meta_tmp=$(mktemp "$STATE/.fm-fallback-meta.XXXXXX") || return 1
  if ! { cat "$TMP/meta" > "$meta_tmp" && chmod 0600 "$meta_tmp" && mv -f -- "$meta_tmp" "$META"; }; then
    rm -f "$meta_tmp"
    echo "error: could not record mode=$NEW_MODE in $META" >&2
    return 1
  fi
  fm_lock_release "$META_LOCK"
  META_LOCK=
}

if [ "$RESEND" -eq 0 ]; then
  rewrite_brief || exit 1
  rewrite_meta || exit 1
fi

# 3. The worker.
{
  printf '%s\n' "Your delivery path changed: $OLD_MODE is unavailable for this task under this captain rule: $REASON"
  printf '%s\n' "That rule is the captain's standing answer, so this task now ships $NEW_MODE without anyone being asked; continue from where you are."
  printf '%s\n' "Rule 1 of your Rules now reads:"
  printf '%s\n\n' "$RULE_ONE"
  printf '%s\n' "This Definition of done replaces the earlier one in full:"
  cat "$TMP/dod"
} > "$TMP/steer"
send_args=("$ID")
[ -z "$RESOLVE_KEY" ] || send_args+=(--resolve-key "$RESOLVE_KEY")
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "${send_args[@]}" "$(cat "$TMP/steer")" || {
  echo "error: $ID's record and brief now say mode=$NEW_MODE, but the steer did not go out; re-run this command to resend it" >&2
  exit 1
}
echo "fallback: $ID now ships $NEW_MODE (was $OLD_MODE) under the captain rule: $REASON"
echo "Record that deviation and its reason in $ID's backlog note."
