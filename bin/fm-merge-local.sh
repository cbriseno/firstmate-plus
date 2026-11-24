#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward. A branch that fell behind
# the default is first rebased in a throwaway clone; a conflict refuses with
# the exact cause and changes nothing.
# See SUPERVISOR.md prime directives, project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# Each successful movement records the integration task and request in the
# default branch reflog and the anonymized installation diagnostics.
# After the project's own checkout holds the landed work (the fast-forward, or
# the rebase of its local integration branch), a project that declares a
# service in config/restart/<project directory name> gets it restarted and
# verified, without asking: line `restart=<command>` runs first, then line
# `verify=<command>` (retried FM_RESTART_VERIFY_TRIES times, default 5, waiting
# FM_RESTART_VERIFY_WAIT seconds, default 1). Both run with bash in the project
# checkout. A failure only warns on stderr; it never changes the merge result.
# A project with no declaration is untouched. docs/configuration.md owns it.
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

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH. A branch that
# fell behind because another task landed first is rebased onto DEFAULT in a
# throwaway clone before updating either branch. A conflict or a branch already
# published to a remote refuses and leaves every ref as it was.
TIP=$BRANCH
REBASED=
REBASE_TMP=
rebase_cleanup() { [ -z "$REBASE_TMP" ] || rm -rf -- "$REBASE_TMP"; }
trap 'rebase_cleanup; merge_control_cleanup' EXIT
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  refuse_diverged() {
    echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged): $1" >&2
    echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry. $BRANCH and $DEFAULT are unchanged." >&2
    exit 1
  }
  if [ -n "$(git -C "$PROJ" branch -r --contains "$BRANCH" 2>/dev/null | head -1)" ]; then
    refuse_diverged "it is already published, so it is not rewritten"
  fi
  REBASE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-merge-rebase.XXXXXX")
  git clone -q --local --no-checkout "$PROJ" "$REBASE_TMP/c" || refuse_diverged "could not prepare a copy to rebase in"
  base_sha=$(git -C "$PROJ" rev-parse "$DEFAULT")
  name=$(git -C "$PROJ" config user.name || git -C "$PROJ" log -1 --format=%an "$BRANCH")
  email=$(git -C "$PROJ" config user.email || git -C "$PROJ" log -1 --format=%ae "$BRANCH")
  git -C "$REBASE_TMP/c" checkout -q --detach "$(git -C "$PROJ" rev-parse "$BRANCH")" || refuse_diverged "could not prepare a copy to rebase in"
  if ! git -C "$REBASE_TMP/c" -c "user.name=$name" -c "user.email=$email" rebase --quiet "$base_sha" >"$REBASE_TMP/rebase.out" 2>&1; then
    conflicts=$(git -C "$REBASE_TMP/c" diff --name-only --diff-filter=U | tr '\n' ' ')
    patch=$(git -C "$REBASE_TMP/c" rebase --show-current-patch 2>/dev/null | head -1 | cut -c1-80)
    refuse_diverged "rebasing onto $DEFAULT conflicts in: ${conflicts:-unknown files}(commit ${patch:-unknown}); resolve it in the branch"
  fi
  REBASED=$(git -C "$REBASE_TMP/c" rev-parse HEAD)
  git -C "$PROJ" fetch -q "$REBASE_TMP/c" "$REBASED" || refuse_diverged "could not bring the rebased commits into the project"
  TIP=$REBASED
  echo "rebased $BRANCH onto $DEFAULT in a separate copy"
fi

# Bring every copy that has <branch> checked out from <old> to <new> after the
# ref moved, keeping local edits (two-way read-tree). A copy it cannot carry
# is reported, never forced; the landing itself is unaffected.
follow_checked_out_copies() {
  local branch=$1 old=$2 new=$3 line wt='' found=''
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt=${line#worktree } ;;
      "branch refs/heads/$branch") found=$wt ;;
      "") [ -z "$found" ] || follow_one_copy "$found" "$old" "$new"; found=; wt= ;;
    esac
  done <<EOF
$(git -C "$PROJ" worktree list --porcelain)
EOF
  # The substitution drops the final blank line, so close the last record here.
  [ -z "$found" ] || follow_one_copy "$found" "$old" "$new"
}
follow_one_copy() {
  [ -d "$1" ] || return 0
  git -C "$1" read-tree -m -u "$2" "$3" >/dev/null 2>&1 \
    || echo "warning: $BRANCH landed, but its copy at $1 could not follow it; reset that copy to $BRANCH before closing it" >&2
}
# Captain rule 37: no commit whose whole message (subject or body) carries the
# word WIP, in any case, and no worker-close preservation commit, enters main.
wip=
for commit in $(git -C "$PROJ" rev-list "$DEFAULT..$TIP"); do
  message=$(git -C "$PROJ" log -1 --format=%B "$commit")
  if printf '%s\n' "$message" | grep -Eiqw 'wip' || [ "${message%%$'\n'*}" = "Save pending work before worker close" ]; then
    wip=$(git -C "$PROJ" rev-parse --short "$commit")
    break
  fi
done
if [ -n "$wip" ]; then
  echo "REFUSED: commit $wip is marked unfinished (WIP); rewrite the unpublished branch and retry." >&2
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
if [ -n "$REBASED" ]; then
  OLD_TIP=$(git -C "$PROJ" rev-parse "$BRANCH")
  git -C "$PROJ" update-ref "refs/heads/$BRANCH" "$REBASED" "$OLD_TIP" || {
    echo "error: $BRANCH moved while rebasing; nothing landed" >&2
    exit 1
  }
  # Moving a ref does not move the index or files of a copy that has it
  # checked out: the worker's copy would show the new commits as reverted
  # changes and refuse to close. Carry that copy to the new tip with a
  # two-way merge, which keeps the worker's own uncommitted edits.
  follow_checked_out_copies "$BRANCH" "$OLD_TIP" "$REBASED"
fi
# Attach the owner and request to the actual ref change. A failed merge or one
# already up to date contributes no movement. Preserve landing if attribution
# is unavailable while reconciling an older installation.
integration_note=$(FM_HOME="$FM_HOME" python3 "$SCRIPT_DIR/fm_integration.py" "$ID" "$DATA") \
  || integration_note="firstmate integrate [\"$ID\", null]"
if [ -z "$INTEGRATION" ]; then
  GIT_REFLOG_ACTION="$integration_note" git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
else
  git -C "$PROJ" update-ref -m "$integration_note" "refs/heads/$DEFAULT" "$(git -C "$PROJ" rev-parse "$BRANCH")" \
    "$(git -C "$PROJ" rev-parse "$DEFAULT")" || merge_status=$?
fi
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
if [ "$before" != "$after" ]; then
  # shellcheck source=bin/fm-diag.sh
  . "$SCRIPT_DIR/fm-diag.sh"
  integration_request=$(printf '%s' "${integration_note#firstmate integrate }" | jq -r '.[1] // empty') || integration_request=
  fm_diag_emit integration.ok "task=$ID" "project=$PROJ" "request=$integration_request"
  fm_merge_notify_waiters "$FM_HOME" "$STATE" "$ID" "$PROJ"
fi
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
restart_after_landing() {
  local decl restart verify tries wait n=0
  decl="$CONFIG/restart/$(basename "$PROJ")"
  [ -f "$decl" ] || return 0
  restart=$(sed -n 's/^restart=//p' "$decl" | head -n 1)
  verify=$(sed -n 's/^verify=//p' "$decl" | head -n 1)
  [ -n "$restart" ] || return 0
  if ! (cd "$PROJ" && bash -c "$restart") >&2; then
    echo "warning: $ID landed, but its restart command failed: $restart" >&2
    return 0
  fi
  echo "restarted $(basename "$PROJ")"
  [ -n "$verify" ] || return 0
  tries=${FM_RESTART_VERIFY_TRIES:-5}
  wait=${FM_RESTART_VERIFY_WAIT:-1}
  while [ "$n" -lt "$tries" ]; do
    if (cd "$PROJ" && bash -c "$verify") >/dev/null 2>&1; then
      echo "verified $(basename "$PROJ") responds"
      return 0
    fi
    n=$((n + 1))
    [ "$n" -ge "$tries" ] || sleep "$wait"
  done
  echo "warning: $ID landed and $(basename "$PROJ") restarted, but it did not answer its verify command: $verify" >&2
}
# Retain the ready-head/integration facts through the same presentation owner.
# A failed publication does not undo a successful merge; reads can reconstruct
# ancestry and the warning requires reconciliation before cleanup.
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" presentation "$ID" --reconcile >/dev/null \
  || echo "warning: $ID landed; progress receipt needs owner reconciliation before cleanup" >&2
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
[ -n "$INTEGRATION" ] || { restart_after_landing; exit 0; }
name=$(git -C "$PROJ" config user.name || git -C "$PROJ" show -s --format=%an "$INTEGRATION")
email=$(git -C "$PROJ" config user.email || git -C "$PROJ" show -s --format=%ae "$INTEGRATION")
if git -C "$PROJ" -c "user.name=$name" -c "user.email=$email" rebase --quiet "$DEFAULT" >/dev/null; then
  echo "rebased $INTEGRATION onto $DEFAULT in $PROJ"
  restart_after_landing
else
  git -C "$PROJ" rebase --abort || true
  echo "warning: $BRANCH landed on $DEFAULT, but rebasing $INTEGRATION onto it conflicted and was aborted; $INTEGRATION is unchanged. Resolve with: git -C $PROJ rebase $DEFAULT" >&2
  exit 3
fi
