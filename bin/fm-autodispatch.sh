#!/usr/bin/env bash
# fm-autodispatch.sh - launch one ready, briefed ship task by the same rules a
# manual dispatch follows, so lanes that are free never wait for the primary.
#
# Usage: fm-autodispatch.sh <task-id>
#
# The watcher calls this in `fm-tasks-axi.sh work continuations` order for a
# queued task with a brief and no spawn-deferred marker once capacity admits.
# The backlog's current `ready` view must still contain the task. It derives only what a
# person would read off the brief and the registry, in the same order:
#   1. repo      the backlog row's repo; its directory is projects/<repo>, else
#                the one existing absolute path in its data/projects.md line;
#   2. mode      the brief's "Delivery contract: mode=" line (ship briefs only);
#   3. yolo      the project's registered posture (fm-project-mode.sh), off on
#                a gerrit or external forge, where fm-spawn.sh refuses it;
#   4. profile   when config/crew-dispatch.json declares categories, the rule
#                named by the brief's "Dispatch category:" line, only if it
#                has exactly one profile and no captain approval; without a
#                dispatch file the brief carries the primary's selected axes;
#   5. branch    --branch-prefix and --base-branch read back from the brief.
# Then it runs fm-spawn.sh, which still owns every admission, category and
# delivery check; a spawn that refuses reports its own error here.
#
# Exit: 0 launched (fm-spawn's line on stdout), 75 spawn deferred for capacity
#   (its marker is written; the watcher's deferral tick relaunches it),
#   76 allocation lock held (marker records the lock; the watcher retries),
#   3 not auto-launchable (reason on stderr; the primary decides as before),
#   any other nonzero: the spawn itself failed (its last line on stderr).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
export FM_HOME
ID=${1:?usage: fm-autodispatch.sh <task-id>}
BRIEF="$DATA/$ID/brief.md"

skip() { echo "not auto-launchable: $*" >&2; exit 3; }
tasks() { FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" bash "$SCRIPT_DIR/fm-tasks-axi.sh" "$@"; }

[ -f "$BRIEF" ] || skip "no brief"
[ ! -f "$STATE/$ID.meta" ] || skip "already launched"

MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
[ -n "$MODE" ] || skip "brief has no ship delivery contract"

REPO=$(tasks ready 2>/dev/null | python3 -c '
import csv, sys
rows = False
for line in sys.stdin:
    if line.startswith("ready["): rows = True
    elif rows:
        if not line.startswith("  "): break
        f = next(csv.reader([line.strip()]))
        if f[0] == sys.argv[1] and len(f) > 3: print(f[3]); break
' "$ID")
[ -n "$REPO" ] || skip "task has no repo"

PROJ=
if [ -d "$PROJECTS/$REPO" ]; then
  PROJ="$PROJECTS/$REPO"
else
  line=$(grep -F -- "- $REPO [" "$DATA/projects.md" 2>/dev/null | head -n 1)
  [ -n "$line" ] || line=$(grep -F -- "- $REPO - " "$DATA/projects.md" 2>/dev/null | head -n 1)
  for p in $(printf '%s\n' "$line" | grep -o '/[A-Za-z0-9._/-]*' | sed 's/[.,;]*$//'); do
    if [ -d "$p/.git" ] || [ -f "$p/.git" ]; then PROJ=$p; break; fi
  done
fi
[ -n "$PROJ" ] || skip "no project directory for repo $REPO"

FORGE=$("$SCRIPT_DIR/fm-project-mode.sh" --forge "$REPO" 2>/dev/null) || skip "registry entry for $REPO does not resolve"
YOLO=$("$SCRIPT_DIR/fm-project-mode.sh" "$REPO" 2>/dev/null | cut -d' ' -f2)
case "$YOLO" in on|off) ;; *) skip "no registered yolo posture for $REPO" ;; esac
case "$FORGE" in gerrit|external) YOLO=off ;; esac

args=("$ID" "$PROJ" --mode "$MODE" --yolo "$YOLO")

BRANCH=$(sed -n 's/^Ship branch: //p' "$BRIEF" | head -n 1)
case "$BRANCH" in
  *"$ID") prefix=${BRANCH%"$ID"}; [ "$prefix" = fm/ ] || args+=(--branch-prefix "$prefix") ;;
esac
BASE=$(sed -n 's/^Base branch: //p' "$BRIEF" | head -n 1)
[ -z "$BASE" ] || args+=(--base-branch "$BASE")

if [ -f "$CONFIG/crew-dispatch.json" ]; then
  category=$(sed -n 's/^Dispatch category: //p' "$BRIEF" | head -n 1)
  profile=$(jq -r --arg c "$category" '
    (if $c == "default" and has("default") then [{use: .default}] else [.rules[]? | select(.category == $c)] end) as $r
    | if ($c | test("^[a-z0-9-]+$")) and ($r | length) == 1 and ($r[0].use | type) == "object"
        and ($r[0].approval // null) == null and ($r[0].use.harness // "") != ""
      then [$r[0].use.harness, ($r[0].use.model // ""), ($r[0].use.effort // "")] | join("|")
      else empty end' "$CONFIG/crew-dispatch.json" 2>/dev/null)
  [ -n "$profile" ] || skip "dispatch category '$category' has no single approved profile"
  IFS="|" read -r h m e <<< "$profile"
  [ -n "$m" ] || m=$(sed -n 's/^Dispatch model: //p' "$BRIEF" | head -n 1)
  [ -n "$e" ] || e=$(sed -n 's/^Dispatch effort: //p' "$BRIEF" | head -n 1)
  case "$e" in low|medium|high|xhigh|max) ;; *) skip "dispatch category '$category' needs a recorded effort" ;; esac
  [ -n "$m" ] && [ "$m" != default ] || skip "dispatch category '$category' needs a concrete model"
  args+=(--harness "$h")
  [ -z "$m" ] || args+=(--model "$m")
  [ -z "$e" ] || args+=(--effort "$e")
else
  h=$(sed -n 's/^Dispatch harness: //p' "$BRIEF" | head -n 1)
  m=$(sed -n 's/^Dispatch model: //p' "$BRIEF" | head -n 1)
  e=$(sed -n 's/^Dispatch effort: //p' "$BRIEF" | head -n 1)
  [ -n "$h" ] && [ -n "$m" ] && [ "$m" != default ] || skip "brief needs a selected dispatch harness and model"
  case "$e" in low|medium|high|xhigh|max) ;; *) skip "brief needs a selected dispatch effort" ;; esac
  args+=(--harness "$h" --model "$m" --effort "$e")
fi

FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" FM_SPAWN_NO_GUARD=1 FM_AUTODISPATCH=1 \
  exec "$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" </dev/null
