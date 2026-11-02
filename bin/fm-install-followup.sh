#!/usr/bin/env bash
# Carry a captain's request from a project into its linked local installation.
# A project opts in with the registry token install=<project>
# (bin/fm-project-mode.sh owns the token, its --install query, and its
# refusals): work that lands there is finished for the captain only once it
# also reaches <project>, for example a public fork whose changes must reach the
# captain's private Firstmate home or plugin runtime. This script is the single
# owner of what that link does; the existing spawn, merge, and teardown paths
# call it rather than carrying a second copy.
#
# Usage:
#   fm-install-followup.sh ensure <task-id> <project-name>
#   fm-install-followup.sh landed <task-id> <project-name> [--discarded]
#   fm-install-followup.sh brief <task-id> <project-name> [--mode <no-mistakes|direct-PR|local-only>]
#
# The follow-up is an ordinary backlog work item, `<task-id>-install`, of kind
# ship and repo <project>, Queued and blocked by <task-id> itself. The
# dependency is the whole mechanism: it is filed when the original is
# dispatched, so it is visible from the start and cannot be lost between the
# landing and a later turn, and the original's own close in bin/fm-teardown.sh
# is what clears it, so landing makes it dispatchable with no new state, hold,
# or watcher.
#
# ensure files that item when <project-name> registers a link and is a no-op
# otherwise; tasks-axi `add` is idempotent, so a repeat keeps the existing row.
# bin/fm-spawn.sh calls it on every fresh ship dispatch, before any endpoint
# or local copy exists, and refuses the dispatch when it fails, because a
# dispatched task whose follow-up was never filed is exactly the dropped
# installation this exists to prevent. A home whose backlog is edited by hand
# (bin/fm-backlog-transition-lib.sh's gate does not apply) gets the exact add
# command to run instead. Exit 0 filed or not linked, 1 the backlog refused,
# 2 usage, 3 the registry refused the link.
#
# landed is bin/fm-teardown.sh's call after a ship's backlog close lands. It
# re-runs ensure, so work dispatched before this script existed is covered
# too, and then prints the one next action: the follow-up is ready, and the
# request is not finished until it lands in the installation. That dispatch is
# firstmate's to perform in the same turn, never a question for the captain.
# With --discarded (a --force teardown, which lands nothing) it instead says
# the follow-up has nothing new to bring. It never fails a teardown that
# already completed: a failure prints the manual command to stderr and exits 1.
#
# brief scaffolds data/<task-id>-install/brief.md through bin/fm-brief.sh and
# fills both Task subsections, so the dispatch costs firstmate no drafting:
# `## Captain's intent` is the original brief's subsection verbatim plus one
# sentence naming where it landed and that it must now work in the
# installation, and `## Firstmate spec` is the fixed integration instruction
# below. The mode is the installation's registered flat mode, or --mode; a
# registered no-mistakes-prod-only policy needs --mode, because that surface
# classification is firstmate's at intake (project-management). It prints the
# bin/fm-spawn.sh command to run next with the installation's registered yolo,
# leaving the dispatch profile to the ordinary intake rule.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() {
  echo "usage: fm-install-followup.sh ensure <task-id> <project-name>" >&2
  echo "       fm-install-followup.sh landed <task-id> <project-name> [--discarded]" >&2
  echo "       fm-install-followup.sh brief <task-id> <project-name> [--mode <no-mistakes|direct-PR|local-only>]" >&2
  exit 2
}

CMD=${1:-}
ID=${2:-}
PROJECT=${3:-}
[ -n "$CMD" ] && [ -n "$ID" ] && [ -n "$PROJECT" ] || usage
shift 3
DISCARDED=0
MODE_ARG=
while [ "$#" -gt 0 ]; do
  case "$CMD:$1" in
    landed:--discarded) DISCARDED=1 ;;
    brief:--mode) [ "$#" -ge 2 ] || usage; MODE_ARG=$2; shift ;;
    *) usage ;;
  esac
  shift
done
case "$CMD" in ensure|landed|brief) ;; *) usage ;; esac

# The registry answers first, so an unlinked project - every ship dispatch and
# teardown that never opted in - costs one registry read and nothing else.
TARGET=$("$SCRIPT_DIR/fm-project-mode.sh" --install "$PROJECT" 2>/dev/null)
status=$?
if [ "$status" -ne 0 ]; then
  "$SCRIPT_DIR/fm-project-mode.sh" --install "$PROJECT" >/dev/null || true
  exit 3
fi
[ -n "$TARGET" ] || exit 0

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

fm_task_id_creation_valid "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }

FID="$ID-install"
if ! fm_task_id_creation_valid "$FID"; then
  echo "error: $PROJECT links install=$TARGET, but its follow-up id $FID is not a valid task id (64 characters at most); dispatch $ID under a shorter id" >&2
  exit 1
fi
TITLE="Install $ID into $TARGET"
BODY="Brings the work that lands for $ID in $PROJECT into $TARGET, the local installation $PROJECT is linked to (install=$TARGET). The captain's request is finished only once it works there. Blocked by $ID until it lands; then dispatch it at once with bin/fm-install-followup.sh brief $ID $PROJECT - never a captain decision."

ensure_followup() {
  local gate_status
  if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
    if ! fm_backlog_mutate "$DATA" add "$FID" "$TITLE" --kind ship --repo "$TARGET" \
        --blocked-by "$ID" --body "$BODY" --queue; then
      echo "error: could not file $ID's install follow-up $FID in this home's backlog ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 1
    fi
    echo "install follow-up: $FID is queued for $TARGET, blocked until $ID lands"
    return 0
  fi
  gate_status=$?
  if [ "$gate_status" -eq 2 ]; then
    echo "error: could not file $ID's install follow-up $FID: this home's backlog cannot be read ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    return 1
  fi
  echo "install follow-up: this home's backlog is edited by hand ($FM_BACKLOG_TRANSITION_SKIP); queue $FID ('$TITLE', repo $TARGET) blocked by $ID yourself so the installation is not dropped"
  return 0
}

# The row's recorded state, or empty when it cannot be read.
followup_state() {
  fm_backlog_transition_applies "$CONFIG" "$DATA" ship || return 0
  fm_backlog_row_probe "$DATA" "$FID" >/dev/null 2>&1 || return 0
  printf '%s\n' "$FM_BACKLOG_ROW_STATE"
}

case "$CMD" in
  ensure)
    ensure_followup
    exit $?
    ;;
  landed)
    if [ "$DISCARDED" -eq 1 ]; then
      case "$(followup_state)" in
        queued\ *)
          echo "Install follow-up: $FID has nothing new to bring, because this teardown discarded $ID's work rather than landing it; remove it with bin/fm-tasks-axi.sh rm $FID unless other landed work still has to reach $TARGET." ;;
      esac
      exit 0
    fi
    if ! out=$(ensure_followup); then
      echo "error: $ID landed in $PROJECT, but its install follow-up $FID for $TARGET could not be filed; queue it yourself and dispatch it now" >&2
      exit 1
    fi
    # A hand-edited backlog was handed the add command rather than a filed row.
    fm_backlog_transition_applies "$CONFIG" "$DATA" ship || printf '%s\n' "$out"
    echo "Install follow-up: $FID brings $ID's landed work into $TARGET, the captain's linked local installation, and is ready now. The captain's request is not finished until it lands there: dispatch it in this turn without asking, starting with bin/fm-install-followup.sh brief $ID $PROJECT."
    exit 0
    ;;
esac

# brief
SOURCE_BRIEF="$DATA/$ID/brief.md"
[ -f "$SOURCE_BRIEF" ] || { echo "error: $ID's brief is not at $SOURCE_BRIEF, so its captain intent cannot be carried; scaffold $FID with bin/fm-brief.sh and fill it by hand" >&2; exit 1; }
INTENT=$(fm_brief_task_heading_body "$SOURCE_BRIEF" "## Captain's intent")
if [ -z "$(printf '%s' "$INTENT" | tr -d '[:space:]')" ]; then
  echo "error: $SOURCE_BRIEF has no \`## Captain's intent\` subsection to carry; scaffold $FID with bin/fm-brief.sh and fill it by hand" >&2
  exit 1
fi

RAW_MODE=$("$SCRIPT_DIR/fm-project-mode.sh" --raw "$TARGET" 2>/dev/null | cut -d' ' -f1)
POSTURE=$("$SCRIPT_DIR/fm-project-mode.sh" "$TARGET" 2>/dev/null) || {
  "$SCRIPT_DIR/fm-project-mode.sh" "$TARGET" >/dev/null || true
  exit 3
}
YOLO=${POSTURE#* }
FORGE=$("$SCRIPT_DIR/fm-project-mode.sh" --forge "$TARGET" 2>/dev/null) || exit 3
PREFIX=$("$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$TARGET" 2>/dev/null) || PREFIX=fm/
MODE=${MODE_ARG:-$RAW_MODE}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: $TARGET registers no-mistakes-prod-only, a policy rather than a task mode; classify this integration's surface at intake and pass --mode" >&2
    exit 2 ;;
  *) echo "error: unknown delivery mode '$MODE'" >&2; exit 2 ;;
esac

DELIVERED="the change recorded on backlog item $ID"
if fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
  links=$(fm_backlog_row_show "$DATA" "$ID" 2>/dev/null | sed -n 's/^  links: *//p' | head -1 | tr -d '"')
  case "$links" in
    *pr:http*) DELIVERED=${links#*pr:}; DELIVERED=${DELIVERED%%[ ,]*} ;;
  esac
fi
SOURCE_CLONE=
[ -e "$PROJECTS/$PROJECT/.git" ] && SOURCE_CLONE="$PROJECTS/$PROJECT"
TARGET_DIR=
[ -d "$PROJECTS/$TARGET" ] && TARGET_DIR="$PROJECTS/$TARGET"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-install-followup.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
printf '%s\n\n%s\n' "$INTENT" "It landed first in $PROJECT as $DELIVERED; it is finished only once it also works in this linked local installation, $TARGET." > "$TMP/intent"
{
  echo "Bring the work that landed for task $ID in $PROJECT ($DELIVERED) into $TARGET, the local installation $PROJECT is linked to by its install=$TARGET registry token."
  if [ -n "$SOURCE_CLONE" ]; then
    echo "The firstmate clone at $SOURCE_CLONE holds $PROJECT with that work on its default branch; fetch from it or from its remote."
  fi
  echo "Integrate it the way this project already receives $PROJECT's changes - read its history and remotes first, for example an earlier merge of $PROJECT's default branch - and keep every local change of this project that $PROJECT does not carry."
  echo "Resolve ordinary conflicts yourself; report blocked only for a conflict whose resolution would change behavior the captain relies on."
  echo "Then make sure the behavior the captain's intent describes is present and working here: run this project's affected local checks and exercise the change the way the intent uses it."
  echo "Bring only what $PROJECT has landed: publish nothing to $PROJECT's remote and start no work beyond this integration."
} > "$TMP/spec"

brief_args=("$FID" "$TARGET" --mode "$MODE")
[ "$FORGE" = none ] || brief_args+=(--forge "$FORGE")
[ "$PREFIX" = fm/ ] || brief_args+=(--branch-prefix "$PREFIX")
[ -z "$TARGET_DIR" ] || brief_args+=(--project "$TARGET_DIR")
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-brief.sh" "${brief_args[@]}" >/dev/null || exit 1
BRIEF="$DATA/$FID/brief.md"
awk -v intent="$TMP/intent" -v spec="$TMP/spec" '
  $0 == "{TASK}" { while ((getline line < intent) > 0) print line; next }
  $0 == "{FIRSTMATE_SPEC}" { while ((getline line < spec) > 0) print line; next }
  { print }
' "$BRIEF" > "$TMP/brief" || exit 1
cat "$TMP/brief" > "$BRIEF" || exit 1

spawn_cmd="bin/fm-spawn.sh $FID ${TARGET_DIR:-<$TARGET project directory>} --mode $MODE --yolo $YOLO"
[ "$PREFIX" = fm/ ] || spawn_cmd="$spawn_cmd --branch-prefix '$PREFIX'"
echo "scaffolded: $BRIEF (ship, mode=$MODE; both Task subsections filled from $ID)"
echo "next: $spawn_cmd, adding the dispatch profile the ordinary intake resolves for it"
