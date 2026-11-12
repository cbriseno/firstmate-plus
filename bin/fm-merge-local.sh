#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-local-branch-lib.sh
. "$SCRIPT_DIR/fm-local-branch-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be clean and on its default branch, or on
# its declared local integration branch (default + private overlay, see
# fm-local-sync.sh); there the default ref advances without a checkout and the
# integration branch is then rebased onto it.
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
INTEGRATION=
if [ "$cur" != "$DEFAULT" ]; then
  INTEGRATION=$(fm_local_integration_branch "$PROJ" 2>/dev/null || true)
  [ -n "$cur" ] && [ "$cur" = "$INTEGRATION" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT' or local integration branch '${INTEGRATION:-local}'; cannot merge safely" >&2; exit 1; }
fi
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

wip=$(git -C "$PROJ" log --format='%h %s' "$DEFAULT..$BRANCH" | awk 'index(substr($0, index($0, " ") + 1), "WIP") && !found { print $1; found=1 }')
if [ -n "$wip" ]; then
  echo "REFUSED: commit $wip has WIP in its subject; rewrite the unpublished branch and retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
if [ -z "$INTEGRATION" ]; then
  git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
else
  git -C "$PROJ" update-ref "refs/heads/$DEFAULT" "$(git -C "$PROJ" rev-parse "$BRANCH")" \
    "$(git -C "$PROJ" rev-parse "$DEFAULT")" || merge_status=$?
fi
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
[ "$before" = "$after" ] || fm_merge_notify_waiters "$FM_HOME" "$STATE" "$ID" "$PROJ"
# A separate integration task can land a previously preserved fm/<id> branch.
# Reconcile only matching queued rows whose exact branch is now contained in the
# local default; ordinary task branches and captain-held rows stay untouched.
reconcile_preserved_branches() {
  local branch preserved_id row state refs gate_status
  fm_backlog_transition_applies "$CONFIG" "$DATA" ship || gate_status=$?
  case "${gate_status:-0}" in
    0) ;;
    1) return 0 ;;
    *)
      echo "warning: $ID landed, but backlog reconciliation could not be configured ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 0
      ;;
  esac
  refs=$(git -C "$PROJ" for-each-ref --format='%(refname:short)' refs/heads/fm/) || {
    echo "warning: $ID landed, but preserved branches could not be listed for backlog reconciliation" >&2
    return 0
  }
  while IFS= read -r branch; do
    case "$branch" in fm/*) preserved_id=${branch#fm/} ;; *) continue ;; esac
    fm_pr_task_id_valid "$preserved_id" || continue
    git -C "$PROJ" merge-base --is-ancestor "$branch" "$DEFAULT" || continue
    if ! fm_backlog_row_probe "$DATA" "$preserved_id"; then
      [ "$FM_BACKLOG_ROW_RESULT" = not_found ] && continue
      echo "warning: $ID landed, but preserved task $preserved_id could not be read ($FM_BACKLOG_ROW_ERROR)" >&2
      continue
    fi
    state=${FM_BACKLOG_ROW_STATE%% *}
    [ "$state" = queued ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" != captain ] || continue
    row=$(fm_backlog_row_show "$DATA" "$preserved_id" --full) || {
      echo "warning: $ID landed, but preserved task $preserved_id's deliverable could not be read" >&2
      continue
    }
    printf '%s\n' "$row" | grep -Fq "preserved-branch:$branch" || continue
    if ! fm_backlog_done "$DATA" "$preserved_id" --note "local main via integration $ID"; then
      echo "warning: $ID landed, but preserved task $preserved_id could not be closed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    fi
  done <<EOF
$refs
EOF
}
reconcile_preserved_branches
# Retain the ready-head/integration facts through the same presentation owner.
# A failed publication does not undo a successful merge; reads can reconstruct
# ancestry and the warning requires reconciliation before cleanup.
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" presentation "$ID" --reconcile >/dev/null \
  || echo "warning: $ID landed; progress receipt needs owner reconciliation before cleanup" >&2
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
[ -n "$INTEGRATION" ] || exit 0
name=$(git -C "$PROJ" config user.name || git -C "$PROJ" show -s --format=%an "$INTEGRATION")
email=$(git -C "$PROJ" config user.email || git -C "$PROJ" show -s --format=%ae "$INTEGRATION")
if git -C "$PROJ" -c "user.name=$name" -c "user.email=$email" rebase --quiet "$DEFAULT" >/dev/null; then
  echo "rebased $INTEGRATION onto $DEFAULT in $PROJ"
else
  git -C "$PROJ" rebase --abort || true
  echo "warning: $BRANCH landed on $DEFAULT, but rebasing $INTEGRATION onto it conflicted and was aborted; $INTEGRATION is unchanged. Resolve with: git -C $PROJ rebase $DEFAULT" >&2
  exit 3
fi
