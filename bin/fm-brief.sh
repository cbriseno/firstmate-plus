#!/usr/bin/env bash
# --requirements <brief> prints the numbered original intent for insertion into
# ## Captain's requirements after filling the task. Regenerate on added asks.
# Acceptance format and semantics are owned by bin/fm-dod-lib.sh.
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# Ship, scout, and host briefs carry only task-specific facts; fm-spawn.sh hands
# every task worker the shared worker/AGENTS.md contract at launch. Ship, scout, and host `# Task` sections have two subsections Firstmate
# fills before dispatch: `{TASK}` under `## Captain's intent` (the captain's
# own ask plus the context needed to read it, including the substance of any
# report, decision, or PR the ask refers to, without added speaker labels or
# direct address) and `{FIRSTMATE_SPEC}`
# under `## Firstmate spec` (operational boundaries and established evidence, never the captain's
# intent). bin/fm-dod-lib.sh owns the no-mistakes `--intent` contract those
# subsections feed; bin/fm-spawn.sh refuses leftover placeholders and a
# `## Captain's intent` line opening with a Captain label or address. Secondmate
# charters still use a single `{TASK}` charter fill. Firstmate may adjust other
# sections when the task genuinely deviates (e.g. working an existing external
# PR instead of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--branch-prefix <prefix>] [--base-branch <branch>] [--forge <none|gerrit|forgejo|external> [--shape squash]] [--effect <line>] [--publish] [--herdr-lab]
#        fm-brief.sh <task-id> <repo-name> --scout [--base-branch <branch>] [--effect <line>] [--publish] [--herdr-lab]
#        fm-brief.sh <task-id> --scout --installation [--effect <line>]
#        fm-brief.sh <task-id> --host --path <absolute-or-HOME-relative-path> [--path <path>...] [--effect <line>] [--publish]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   It offers the Lavish review loop only when `fm-bootstrap.sh lavish-compatible`
#   confirms the legacy board-compatibility floor; otherwise it asks for a text report.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab explicitly requests the hard isolation contract backed by
#   bin/fm-herdr-lab.sh when the task will issue Herdr lifecycle commands.
#   Ship and scout scaffolds include the isolation contract by default, so a
#   later acceptance requirement cannot leave the worker without a safe lab.
#   The contract is used only when Herdr lifecycle operations are necessary.
# For ship tasks, --mode is REQUIRED and shapes the definition of done. Firstmate
# resolves it per task at intake (SUPERVISOR.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never reads it:
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> configured merge authority
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> configured merge authority
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                the configured merge authority approves, firstmate merges to local main
# no-mistakes-prod-only is a registry policy, not a task mode; resolve it to one of
# the three concrete modes at intake before calling this script.
# --branch-prefix <prefix> optionally overrides the ship branch's "fm/" prefix, so
# the resolved branch is "<prefix><task-id>" instead of the default "fm/<task-id>".
# Pass an empty prefix ("--branch-prefix ''") for a bare "<task-id>" branch, or a
# conventional prefix such as "fix/" - useful for a third-party project that does
# not use this tooling and should not see an "fm/"-branded branch or PR. Defaults
# to "fm/" when omitted, so every existing installation's branch names are
# unchanged. Like --mode, this script never reads data/projects.md for it: the
# registry's optional "branch=<prefix>" annotation (bin/fm-project-mode.sh's
# header owns that format and its --branch-prefix query) is the captain's
# standing per-project preference, and firstmate resolves it per task at intake
# and passes the explicit flag. Refused on --scout and --secondmate: a scout
# makes no branch and a charter is not a delivery contract.
# --category <name> records the dispatch rule category; --rationale <line>
#   records its reason. When configured rules declare categories, category is
#   required for ship, scout, and host scaffolds; reason_required rules also
#   require a rationale. Existing briefs without a category need the documented
#   fm-spawn override or a recorded category before launch.
# --diagnosis-scope <bounded|long|ambiguous> selects a configured category
#   from the scope assessed at intake: standard for bounded, hard otherwise.
#   Use it instead of --category for diagnostics using those categories.
# --dispatch-effort <level> records the selected effort for automatic dispatch
#   when the configured profile does not already fix it.
# --dispatch-harness <name> and --dispatch-model <name> record the other axes
#   when no configured profile supplies them.
# --base-branch <branch> starts the task from origin's <branch> instead of the
# repository default, for work that belongs on a named integration, feature, or
# release branch. It writes a "Base branch: <branch>" line under `# Setup`, which
# bin/fm-spawn.sh requires to agree with the same --base-branch it is passed to
# choose the copy's starting point, and a ship's
# Definition of done then targets that branch with its pull request.
# bin/fm-dod-lib.sh's fm_base_branch_valid owns which deliveries accept one.
# Refused on --secondmate.
# --forge names the project's forge, defaults to none, and is orthogonal to --mode
# exactly as the registry's `forge=` token is. It is the captain's confirmed
# registry binding, read from data/projects.md at intake and passed here; this
# script never infers a forge and never looks the binding up, and bin/fm-spawn.sh
# refuses a brief whose forge disagrees with the registry. bin/fm-project-mode.sh's
# header owns what the binding means, and bin/fm-dod-lib.sh owns what `gerrit`,
# `forgejo`, and `external` change in the Definition of done. On `forgejo` this
# script also names tea instead of gh-axi in the ship brief's forge-CLI rule, and
# on `external` that rule names no forge CLI, because the home's review tool is
# the only publishing tool. A forge on --mode local-only is refused, because that
# mode publishes nothing, and `external` also refuses no-mistakes.
# --shape names how a forge=gerrit task is published, and only `squash` - one
# change - is accepted: `stack` is refused until a stack can be watched by its
# membership pinned when its watch is armed, because the merge watch follows one
# change.
# It defaults to squash on gerrit and is refused without it.
# --upstream-consent <host>/<owner>/<repo> records the captain's one-off
# approval for this one task to publish to that repository when it is
# firstmate's own upstream. It renders as an `upstream-consent=` token on the
# Delivery contract line, bin/fm-spawn.sh checks it against this home's role
# authority and records it in the task record, and bin/fm-promote.sh honors it
# the same way. Ship-only: a scout publishes nothing and a charter is not a
# delivery contract.
# --effect <line> declares the one outward action (a push, a publication, a
# deploy) that the task's own ask performs, for ship, scout, and host briefs.
# Every generated contract forbids pushing and publishing, so without it a task
# whose objective is that action would carry a contract contradicting its own
# ask. It renders a `# Authorized outward effect` section with an
# `Outward effect:` line that lifts those prohibitions for exactly that action;
# bin/fm-spawn.sh applies the self-repository publication gate to such a brief
# even on local-only. Compare the ask's outward actions with the contract before
# scaffolding; a task whose deliverable is only that action is a host task.
# --publish is the standard `--effect` for a task whose ask is to publish: it
# renders the same section with the fixed outward effect "publish through the
# publication gate without asking", so the standard "Never push" lines never
# contradict the ask and the worker has no authority question to raise. Pass it
# instead of `--effect` for every publication task; combine it with `--effect`
# only to state a different outward action, which then wins.
# --project <dir> is the task's project directory, used to detect when a ship
# brief would publish to firstmate's own repository: for such a task this
# scaffold refuses a publishing mode that the home's role or recorded consent
# does not authorize, before the contract exists. Pass it on every ship
# scaffold so detection does not depend on the caller recognizing the repo;
# bin/fm-spawn.sh repeats the check at launch regardless.
# The generated ship brief records the chosen mode as a fixed machine-readable
# "Delivery contract: mode=<mode>" line, followed by " forge=gerrit shape=squash"
# on Gerrit, " forge=forgejo" on Forgejo, or " forge=external" on an external
# review tool. bin/fm-spawn.sh reads that line and
# refuses to launch a ship task whose explicit --mode or registered forge
# disagrees, so an adjusted brief and the recorded task metadata cannot drift
# apart.
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# worker/AGENTS.md owns the shared rule against administering the no-mistakes
# daemon or worktree pool. A secondmate charter does not get it because that home allocates and returns its own crewmates' slots.
# --mode, --forge, and --shape are refused on scout and secondmate scaffolds: a
# scout's deliverable is a report rather than a merge, and a charter is not a
# delivery contract.
# There is no --yolo flag here. The worker never owns merge decisions, so yolo is
# a spawn-time and firstmate-side input only (SUPERVISOR.md section 7).
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known wait expected to clear on its own, including
# the worker's own background work, pipeline or long command; blocked when
# firstmate must act. The first-sight alert remains; repeats use the long cadence.
# Emission-time syntax and legacy unknown-time handling are owned by
# bin/fm-classify-lib.sh; each scaffold renders the stamp as a literal <epoch>
# placeholder the worker replaces with a numeric Unix time as it appends, so a
# scaffold never emits a substitution a file-write tool would copy through.
# Ship, scout and host status commands carry --card-status, so one report
# writes the status line, the card and the progress checkpoint together
# (bin/fm-task-status.sh owns that call; bin/fm-tasks-axi.sh presentation owns
# the card fields and their bounds). Secondmate charters keep the plain append.
# Every scaffold also carries the steering-inbox receive-and-ack section:
# process state/<id>.inbox/*.msg in order and acknowledge each by moving it to
# handled/ (record, doorbell, and ladder owned by bin/fm-task-inbox-lib.sh).
# worker/AGENTS.md bounds ship crewmate edits to a
# project's AGENTS.md/CLAUDE.md: only corrections of factually wrong
# information, including wrong information the task itself introduced - never
# additions of missing knowledge. A correction edits only the wrong text and
# never runs fm-ensure-agents-md.sh, whose inserted sections and created
# pointer file are themselves additions.
# Scaffolds carry no role scope: fm-spawn.sh supplies fm_brief_worker_role from
# fm-dod-lib.sh to every ship/scout launch brief, so this file never becomes a
# second owner of a contract that must stay current across relaunches.
# A home may carry standing worker instructions without editing this tracked
# script: when config/brief-include.md exists under the active home, ship and
# scout scaffolds append its text verbatim as their last section, "# Home brief
# additions", which defers to every other section of the brief. It goes last
# because the machine-read `# Task` heading resolves to its first match, so
# appended text can never shadow it; a later scout promotion appends its ship
# contract below it, which that position-free deference already covers. An
# absent or blank file changes nothing; a present path that is not a readable
# regular file, or text carrying its own "Delivery contract: mode=" line (which
# a later scout promotion could not outrank), stops the scaffold before
# anything is written. Secondmate charters never take it.
# Refuses to overwrite an existing brief.
set -eu
if [ "${1:-}" = --requirements ]; then
  [ "$#" = 2 ] || { echo 'usage: fm-brief.sh --requirements <brief>' >&2; exit 2; }
  # shellcheck source=bin/fm-dod-lib.sh
  . "$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)/fm-dod-lib.sh"
  fm_brief_requirements "$2"
  exit
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$SCRIPT_DIR/fm-role-lib.sh"
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
IFS= read -r -d '' CREWMATE_PAUSE_INSTRUCTIONS <<EOF || true
   Use \`$PAUSED_VERB: {why}\` - distinct from \`blocked:\` - when deliberately waiting for work or an external condition expected to clear on its own, including your own validation round.
   Before ending your turn with your own background shell or monitor still running, or before waiting on your own pipeline run or a long foreground command, append \`$PAUSED_VERB [at=<epoch>]: {job and completion condition}\` to the status file.
   Name what you are waiting for and what will let you resume; do not repeat the declaration on every poll.
   A load wait below the current admission ceiling is rejected; choose another exit condition.
   Do not declare active implementation or reasoning as a wait.
   Firstmate may still raise one first-sight alert; the declared wait then uses the existing long recheck cadence instead of repeated possible-wedge alarms.
   When you know when the wait clears, include \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) for a recheck at that time; for your own background job or command with a timeout, that time is its start plus its timeout, rounded up to the minute.
   Follow the resolution rule below when the wait clears, then resume the task.
   Before declaring \`blocked\`, follow the obstacle classification referenced below.
EOF

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  STATE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
else
  STATE="$FM_HOME/state"
fi
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
case "$CONFIG" in /*) ;; *) CONFIG="$PWD/$CONFIG" ;; esac
KIND=ship
HOST_PATHS=()
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
# shellcheck source=bin/fm-host-task-lib.sh
. "$SCRIPT_DIR/fm-host-task-lib.sh"
HERDR_LAB=0
NO_PROJECTS=0
INSTALLATION=0
MODE=
MODE_SET=0
BRANCH_PREFIX=fm/
BRANCH_PREFIX_SET=0
BASE_BRANCH=
BASE_BRANCH_SET=0
FORGE=none
FORGE_SET=0
SHAPE=
SHAPE_SET=0
UPSTREAM_CONSENT=
UPSTREAM_CONSENT_SET=0
PROJECT_DIR=
PROJECT_DIR_SET=0
EFFECT=
EFFECT_SET=0
PUBLISH=0
CATEGORY=
DIAGNOSIS_SCOPE=
DIAGNOSIS_SCOPE_SET=0
RATIONALE=
DISPATCH_EFFORT=
DISPATCH_HARNESS=
DISPATCH_MODEL=
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      path) HOST_PATHS+=("$a") ;;
      mode) MODE=$a; MODE_SET=1 ;;
      branch-prefix) BRANCH_PREFIX=$a; BRANCH_PREFIX_SET=1 ;;
      base-branch) BASE_BRANCH=$a; BASE_BRANCH_SET=1 ;;
      forge) FORGE=$a; FORGE_SET=1 ;;
      shape) SHAPE=$a; SHAPE_SET=1 ;;
      upstream-consent) UPSTREAM_CONSENT=$a; UPSTREAM_CONSENT_SET=1 ;;
      project) PROJECT_DIR=$a; PROJECT_DIR_SET=1 ;;
      effect) EFFECT=$a; EFFECT_SET=1 ;;
      category) CATEGORY=$a ;;
      diagnosis-scope) DIAGNOSIS_SCOPE=$a; DIAGNOSIS_SCOPE_SET=1 ;;
      rationale) RATIONALE=$a ;;
      dispatch-effort) DISPATCH_EFFORT=$a ;;
      dispatch-harness) DISPATCH_HARNESS=$a ;;
      dispatch-model) DISPATCH_MODEL=$a ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --host) KIND=host ;;
    --path) want_value=path ;;
    --path=*) HOST_PATHS+=("${a#--path=}") ;;
    --scout) KIND=scout ;;
    --installation) INSTALLATION=1 ;;
    --secondmate) KIND=secondmate ;;
    --herdr-lab) HERDR_LAB=1 ;;
    --no-projects) NO_PROJECTS=1 ;;
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --branch-prefix) want_value="branch-prefix" ;;
    --branch-prefix=*) BRANCH_PREFIX=${a#--branch-prefix=}; BRANCH_PREFIX_SET=1 ;;
    --base-branch) want_value="base-branch" ;;
    --base-branch=*) BASE_BRANCH=${a#--base-branch=}; BASE_BRANCH_SET=1 ;;
    --forge) want_value=forge ;;
    --forge=*) FORGE=${a#--forge=}; FORGE_SET=1 ;;
    --shape) want_value=shape ;;
    --shape=*) SHAPE=${a#--shape=}; SHAPE_SET=1 ;;
    --upstream-consent) want_value="upstream-consent" ;;
    --upstream-consent=*) UPSTREAM_CONSENT=${a#--upstream-consent=}; UPSTREAM_CONSENT_SET=1 ;;
    --project) want_value="project" ;;
    --project=*) PROJECT_DIR=${a#--project=}; PROJECT_DIR_SET=1 ;;
    --category) want_value=category ;;
    --category=*) CATEGORY=${a#--category=} ;;
    --diagnosis-scope) want_value=diagnosis-scope ;;
    --diagnosis-scope=*) DIAGNOSIS_SCOPE=${a#--diagnosis-scope=}; DIAGNOSIS_SCOPE_SET=1 ;;
    --rationale) want_value=rationale ;;
    --rationale=*) RATIONALE=${a#--rationale=} ;;
    --dispatch-effort) want_value=dispatch-effort ;;
    --dispatch-effort=*) DISPATCH_EFFORT=${a#--dispatch-effort=} ;;
    --dispatch-harness) want_value=dispatch-harness ;;
    --dispatch-harness=*) DISPATCH_HARNESS=${a#--dispatch-harness=} ;;
    --dispatch-model) want_value=dispatch-model ;;
    --dispatch-model=*) DISPATCH_MODEL=${a#--dispatch-model=} ;;
    --publish) PUBLISH=1 ;;
    --effect) want_value=effect ;;
    --effect=*) EFFECT=${a#--effect=}; EFFECT_SET=1 ;;
    # yolo never reaches the worker: it is firstmate's merge authority, not a
    # brief input. Refuse it loudly so it is never silently dropped here and then
    # believed to have been recorded.
    --yolo|--yolo=*) echo "error: --yolo is not a brief input; pass it to bin/fm-spawn.sh, which records the task's merge posture" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

# Resolve a diagnosis from its declared scope, before validating the category.
if [ "$DIAGNOSIS_SCOPE_SET" = 1 ]; then
  [ "$KIND" != secondmate ] && [ -z "$CATEGORY" ] && [ -f "$CONFIG/crew-dispatch.json" ] || {
    echo 'error: --diagnosis-scope requires a worker dispatch matrix and replaces --category' >&2; exit 1
  }
  case "$DIAGNOSIS_SCOPE" in
    bounded) CATEGORY=standard ;;
    long|ambiguous) CATEGORY=hard ;;
    *) echo 'error: --diagnosis-scope requires bounded, long, or ambiguous' >&2; exit 1 ;;
  esac
fi

if [ "$KIND" = secondmate ]; then
  [ "$PUBLISH" -eq 0 ] || { echo 'error: --publish applies only to ship, scout, and host briefs' >&2; exit 1; }
  [ -z "$CATEGORY$RATIONALE$DISPATCH_EFFORT$DISPATCH_HARNESS$DISPATCH_MODEL" ] || { echo 'error: dispatch options apply only to worker briefs' >&2; exit 1; }
else
  case "$CATEGORY" in *[!a-z0-9-]*) echo 'error: --category requires lowercase letters, digits, or hyphens' >&2; exit 1 ;; esac
  case "$RATIONALE" in *$'\n'*|*$'\r'*) echo 'error: --rationale must be one line' >&2; exit 1 ;; esac
  case "$DISPATCH_EFFORT" in ''|low|medium|high|xhigh|max) ;; *) echo 'error: invalid --dispatch-effort' >&2; exit 1 ;; esac
  case "$DISPATCH_HARNESS" in *[!a-z0-9-]*) echo 'error: invalid --dispatch-harness' >&2; exit 1 ;; esac
  case "$DISPATCH_MODEL" in *$'\n'*|*$'\r'*) echo 'error: --dispatch-model must be one line' >&2; exit 1 ;; esac
  if [ -z "$CATEGORY" ] && [ -n "$DISPATCH_EFFORT$DISPATCH_HARNESS$DISPATCH_MODEL" ]; then
    [ -n "$DISPATCH_EFFORT" ] && [ -n "$DISPATCH_HARNESS" ] && [ -n "$DISPATCH_MODEL" ] || { echo 'error: without a category record all three dispatch axes' >&2; exit 1; }
  fi
  [ -z "$RATIONALE" ] || [ -n "$CATEGORY$DISPATCH_HARNESS" ] || { echo 'error: --rationale requires a category or dispatch profile' >&2; exit 1; }
  if [ -f "$CONFIG/crew-dispatch.json" ]; then
    categories=$(jq -r 'if ((.rules // []) | type) != "array" then error("invalid rules") else any((.rules // [])[]; has("category")) end' "$CONFIG/crew-dispatch.json" 2>/dev/null) || { echo 'error: invalid dispatch categories' >&2; exit 1; }
    if [ "$categories" = true ] || [ "$DIAGNOSIS_SCOPE_SET" = 1 ]; then
      if ! jq -e --arg category "$CATEGORY" --arg rationale "$RATIONALE" '
        (if $category == "default" and has("default") then [{use: .default}] else [.rules[] | select(.category == $category)] end) as $rules |
        ($category | test("^[a-z0-9-]+$")) and ($rules | length == 1) and
        (($rules[0].reason_required // false) != true or ($rationale | test("[^[:space:]]")))
      ' "$CONFIG/crew-dispatch.json" >/dev/null 2>&1; then
        echo 'error: choose a configured --category and supply --rationale when required' >&2; exit 1
      fi
    fi
  fi
fi

# Ship delivery mode is an explicit per-task decision (SUPERVISOR.md section 7). A
# missing or invalid value stops the scaffold rather than silently defaulting.
if [ "$KIND" = ship ]; then
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
elif [ "$MODE_SET" -eq 1 ]; then
  echo "error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi

# A ship branch's prefix is optional per-project cosmetics, not a delivery
# decision, but it still only makes sense where a branch is actually created.
if [ "$KIND" != ship ] && [ "$BRANCH_PREFIX_SET" -eq 1 ]; then
  echo "error: --branch-prefix applies only to ship briefs; a scout makes no branch and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
case "$BRANCH_PREFIX" in
  *' '*) echo "error: --branch-prefix must not contain a space (got '$BRANCH_PREFIX')" >&2; exit 1 ;;
  -*) echo "error: --branch-prefix must not start with '-' (got '$BRANCH_PREFIX')" >&2; exit 1 ;;
esac
# The forge is validated against the same closed set the renderers enforce, so a
# typo or an impossible mode/forge pair stops here rather than reaching a worker.
if [ "$KIND" = ship ]; then
  fm_forge_valid_for_mode "$FORGE" "$MODE" "fm-brief.sh --forge" || exit 1
  if [ "$FORGE" = gerrit ]; then
    [ "$SHAPE_SET" -eq 1 ] || SHAPE=squash
    case "$SHAPE" in
      squash) ;;
      stack)
        echo "error: --shape stack is refused: a stack is several changes, and it must be watched by its membership pinned when its watch is armed, which this fleet does not yet do - the merge watch follows exactly one change, so a stack's wake could report one change as the whole stack; publish --shape squash" >&2
        exit 1 ;;
      *) echo "error: --shape must be squash (got '$SHAPE')" >&2; exit 1 ;;
    esac
  elif [ "$SHAPE_SET" -eq 1 ]; then
    echo "error: --shape applies only with --forge gerrit, where the worker publishes the change itself" >&2
    exit 1
  fi
  # A Forgejo project's pull requests are handled with tea, so the ship brief's
  # forge-CLI rule names it instead of gh-axi; an external review tool has no
  # forge CLI at all; every other forge keeps gh-axi.
  if [ "$FORGE" = forgejo ]; then
    FORGE_RULE_LINE="Use tea for Forgejo operations and chrome-devtools-axi for browser operations."
  elif [ "$FORGE" = external ]; then
    FORGE_RULE_LINE="Publish only through the review tool your Definition of done names, and use chrome-devtools-axi for browser operations."
  else
    FORGE_RULE_LINE="Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations."
  fi
elif [ "$FORGE_SET" -eq 1 ] || [ "$SHAPE_SET" -eq 1 ]; then
  echo "error: --forge and --shape apply only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract" >&2
  exit 1
fi
if [ "$BASE_BRANCH_SET" -eq 1 ]; then
  if [ "$KIND" = host ] || [ "$KIND" = secondmate ] || [ -z "$BASE_BRANCH" ]; then
    echo "error: --base-branch takes a branch name and applies only to ship and scout briefs" >&2
    exit 1
  fi
  fm_base_branch_valid "$BASE_BRANCH" "$MODE" "$FORGE" "fm-brief.sh --base-branch" || exit 1
fi
if [ "$KIND" != ship ]; then
  [ "$UPSTREAM_CONSENT_SET" -eq 0 ] || {
    echo "error: --upstream-consent applies only to ship briefs; a scout publishes nothing and a charter is not a delivery contract" >&2
    exit 1
  }
  [ "$PROJECT_DIR_SET" -eq 0 ] || {
    echo "error: --project applies only to ship briefs" >&2
    exit 1
  }
fi
if [ "$UPSTREAM_CONSENT_SET" -eq 1 ]; then
  [ -n "$UPSTREAM_CONSENT" ] || {
    echo "error: --upstream-consent requires a non-empty <host>/<owner>/<repo> value" >&2
    exit 1
  }
  fm_role_scope_valid "$UPSTREAM_CONSENT" || {
    echo "error: --upstream-consent must be <host>/<owner>/<repo> (got '$UPSTREAM_CONSENT')" >&2
    exit 1
  }
  UPSTREAM_CONSENT=$(fm_role_scope_norm "$UPSTREAM_CONSENT")
fi
# Self-repository pre-gate for a publishing ship brief: detectable only when
# --project was passed, so the check runs here only then. bin/fm-spawn.sh
# repeats it at launch with the resolved project path.
if [ "$KIND" = ship ] && [ "$MODE" != local-only ] && [ "$PROJECT_DIR_SET" -eq 1 ]; then
  [ -n "$PROJECT_DIR" ] || {
    echo "error: --project requires a non-empty directory" >&2
    exit 1
  }
  gate_rc=0
  fm_role_gate_self_publish "$FM_HOME" "$CONFIG" "$PROJECT_DIR" "$FM_ROOT" "$UPSTREAM_CONSENT" || gate_rc=$?
  case $gate_rc in
    0 | 2) ;;
    *)
      echo "error: $FM_ROLE_PUB_DENIAL" >&2
      echo "error: to let this home publish to ${FM_ROLE_PUB_TARGET:-that repository}, write 'maintainer ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>}' into $CONFIG/firstmate-role (docs/configuration.md \"Firstmate role\"), or pass --upstream-consent ${FM_ROLE_PUB_TARGET:-<host>/<owner>/<repo>} for this one task with the captain's explicit approval" >&2
      exit 1
      ;;
  esac
fi
ID=${POS[0]:-}
fm_task_id_creation_valid "$ID" || { echo 'error: invalid task id' >&2; exit 2; }
if [ "$KIND" = host ]; then
  [ "${#POS[@]}" -eq 1 ] || { echo 'error: --host takes no project' >&2; exit 2; }
elif [ "${#HOST_PATHS[@]}" -gt 0 ]; then
  echo 'error: --path requires --host' >&2; exit 2
fi
if [ "$INSTALLATION" -eq 1 ]; then
  [ "$KIND" = scout ] && [ "${#POS[@]}" -eq 1 ] && [ "$BASE_BRANCH_SET" -eq 0 ] || {
    echo 'error: --installation requires --scout with no project or base branch' >&2; exit 2;
  }
fi
BRANCH="$BRANCH_PREFIX$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: --branch-prefix and task id must form a valid git branch (got '$BRANCH')" >&2
  exit 1
fi
printf -v BRANCH_Q '%q' "$BRANCH"

if [ "$KIND" = secondmate ] && [ "$HERDR_LAB" -eq 1 ]; then
  echo "error: --herdr-lab applies only to crewmate ship or scout briefs" >&2
  exit 1
fi

if [ "$NO_PROJECTS" -eq 1 ] && [ "$KIND" != secondmate ]; then
  echo "error: --no-projects applies only to --secondmate charters" >&2
  exit 1
fi

# The optional home-local include is read before anything is written, so an
# unusable file never leaves a partial scaffold behind.
BRIEF_INCLUDE_FILE="$CONFIG/brief-include.md"
BRIEF_INCLUDE_BODY=
if [ "$KIND" != secondmate ] && { [ -e "$BRIEF_INCLUDE_FILE" ] || [ -L "$BRIEF_INCLUDE_FILE" ]; }; then
  { [ -f "$BRIEF_INCLUDE_FILE" ] && BRIEF_INCLUDE_BODY=$(cat "$BRIEF_INCLUDE_FILE" 2>/dev/null); } || {
    echo "error: $BRIEF_INCLUDE_FILE must be a readable regular file" >&2
    exit 1
  }
  if printf '%s\n' "$BRIEF_INCLUDE_BODY" | grep -q '^Delivery contract: mode='; then
    echo "error: $BRIEF_INCLUDE_FILE must not carry a 'Delivery contract: mode=' line; the delivery mode is a per-task --mode decision" >&2
    exit 1
  fi
  [ -n "$(printf '%s' "$BRIEF_INCLUDE_BODY" | tr -d '[:space:]')" ] || BRIEF_INCLUDE_BODY=
fi

# Append the include as the last section of a ship or scout scaffold.
append_brief_include() {
  [ -n "$BRIEF_INCLUDE_BODY" ] || return 0
  printf '\n%s\n%s\n%s\n' \
    '# Home brief additions' \
    "These are this home's standing additions; every other section of this brief takes precedence over anything here that conflicts." \
    "$BRIEF_INCLUDE_BODY" >> "$BRIEF"
}

BRIEF="$DATA/$ID/brief.md"
[ -e "$BRIEF" ] && { echo "error: $BRIEF already exists" >&2; exit 1; }
mkdir -p "$DATA/$ID"

ASK_USER_BLOCK=
if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  ASK_USER_BLOCK=$(fm_ask_user_escalation_block "$DATA" "$ID")
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

STATUS_FILE=$(shell_quote "$STATE/$ID.status")
# Status publication owns its immediate wake; a watcher is only the backstop.
STATUS_APPEND="FM_HOME=$(shell_quote "$FM_HOME") FM_STATE_OVERRIDE=$(shell_quote "$STATE") FM_CONFIG_OVERRIDE=$(shell_quote "$CONFIG") bash $(shell_quote "$FM_ROOT/bin/fm-task-status.sh") $(shell_quote "$ID") '{state}' '{one short line}'"
# The worker's report command: the status append plus its card, so the
# presentation reaches the same data directory the brief names.
REPORT_ENV=
[ "$DATA" = "$FM_HOME/data" ] || REPORT_ENV="FM_DATA_OVERRIDE=$(shell_quote "$DATA") "
STATUS_REPORT="$REPORT_ENV$STATUS_APPEND --card-status '{what is happening now}'"
# The host brief's card rule; ship and scout workers read it in worker/AGENTS.md rule 4.
IFS= read -r -d '' CARD_RULE <<EOF || true
   The status command's \`--card-status\` also refreshes the card the captain's board shows for this task and renews your progress checkpoint in the same call; there is no separate card write.
   Write \`{what is happening now}\` as one plain line of at most 120 characters that states a fact about the work rather than a message, in the language of the captain's own words under \`## Captain's intent\`, without repeating the card title and without ids, paths, hashes, or tool names.
   When you report done, add \`--summary '{what this delivers, in one or two plain sentences}'\` to the same command, in the same language.
   Exit 3 means the status line was recorded but the card was not: never repeat the status line.
EOF
CARD_RULE=${CARD_RULE%$'\n'}
INBOX_DIR=$(shell_quote "$STATE/$ID.inbox")
PROGRESS_CONTRACT=
if [ "$KIND" != secondmate ]; then
  PROGRESS_CONTRACT=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" progress-contract "$ID")
fi

# The receive-and-ack half of the steering-inbox contract, included in every
# scaffold kind. The record format, doorbell line, and re-ring ladder are
# owned by bin/fm-task-inbox-lib.sh. The doorbell names the inbox as
# "$FM_TASK_INBOX", which bin/fm-spawn.sh exports into every launch; the full
# path here remains the fallback for a worker launched without that export.
# The doorbell itself is self-describing, so this section is reinforcement
# for the natural-checkpoint habit, not the only carrier of the instruction.
# config/wait-no-turns keeps decision waits turn-free; active monitoring
# checks the inbox between bounded waits.
IFS= read -r -d '' INBOX_SECTION <<EOF || true
# Declared progress and safe pauses
$PROGRESS_CONTRACT
When firstmate requests a safe point, preserve work and record paused with its exact safe-point request key and a numeric at stamp only after reaching that point.
Do not resume from that pause until firstmate explicitly steers resumption.

# Firstmate instruction inbox
Firstmate steers you through durable message files in $INBOX_DIR.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list them with \`find $INBOX_DIR -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V\`, read and act on each message in numeric order, then acknowledge each handled message by moving it: \`mv $INBOX_DIR/NNN.msg $INBOX_DIR/handled/\`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.
EOF
if [ "$KIND" = secondmate ]; then
  INBOX_SECTION=${INBOX_SECTION#*"# Firstmate instruction inbox"}
  INBOX_SECTION="# Firstmate instruction inbox$INBOX_SECTION"
fi
if [ -e "$CONFIG/wait-no-turns" ]; then
  if [ "$KIND" = secondmate ]; then
    INBOX_SECTION+="Do not poll or list the inbox while waiting; a waiting instruction rings."$'\n'
  else
    INBOX_SECTION+="During active monitoring, check the inbox between bounded waits as the worker contract requires."$'\n'
  fi
fi
INBOX_SECTION=${INBOX_SECTION%$'\n'}
SHORT_INBOX="# Firstmate instruction inbox${INBOX_SECTION#*"# Firstmate instruction inbox"}"

# How a crewmate or scout waits. A decision wait ends the turn; active
# monitoring checks the inbox between bounded waits while other external
# waits use a blocking shell command sized to the harness.
# Emitted only when config/wait-no-turns is present.
IFS= read -r -d '' WAIT_SECTION <<'EOF' || true
# Waiting
Every turn you take resends your whole context, so a decision wait must cost no turns.
When rule 5 or 6 requires stopping, end your turn at once: do not check the inbox, the status file, or anything else, because the answer arrives as a terminal message that starts your next turn.
For active monitoring of a running build or other task, bound each blocking wait to 30 seconds and check the inbox before the next wait or task step.
Keep the running work alive while checking; use the harness's bounded process wait or a task job when the work must survive a conversation relaunch.
Wait on other external conditions with ONE blocking shell command that returns when the state changes: `no-mistakes axi run` or `respond` with `--wait`, `gh pr checks <pr> --watch`, or `until <condition>; do sleep 30; done` for anything else.
In Claude Code that `until` loop in a single Bash call is the sanctioned foreground wait: when the harness refuses a sleep-then-check command and points you at backgrounding instead, reissue the wait as the loop rather than accepting the background.
Bound that command by what your harness lets one command run: in Pi pass the bash tool a `timeout` of at most 2700 seconds, because Pi sets none by default; in Claude Code pass the Bash tool its maximum `timeout` of 600000 ms, because its default is 2 minutes; in Codex keep waiting on a still-running command with empty `write_stdin` polls of up to 300000 ms; elsewhere pass your shell tool its largest timeout and assume at most 10 minutes.
Give any `--wait` a duration a little under that bound.
When the bound passes with nothing changed, run the same blocking command again; active monitoring follows the inbox check above.
The one exception is `respond`: it sent its answer before it began waiting, so reattach with `no-mistakes axi run --wait` instead, and never send the same `respond` again, because it would answer whichever gate parks next without you reading it.
A wait your shell can watch this way needs no `paused:` line, except your own pipeline run, a long foreground command, or your own validation round, which you declare once just before its blocking hold: append `paused:` once just before its first blocking command, then continue the wait, and never append it again as you reissue that command.
EOF
WAIT_SECTION=${WAIT_SECTION%$'\n'}
WAIT_BLOCK=
if [ -e "$CONFIG/wait-no-turns" ]; then
  WAIT_BLOCK="$WAIT_SECTION"$'\n\n'
fi

if [ "$KIND" = secondmate ]; then
SECONDMATE_PROJECTS=""
idx=1
while [ "$idx" -lt "${#POS[@]}" ]; do
  SECONDMATE_PROJECTS="${SECONDMATE_PROJECTS}${SECONDMATE_PROJECTS:+ }${POS[$idx]}"
  idx=$((idx + 1))
done
if [ "$NO_PROJECTS" -eq 1 ]; then
  [ -z "$SECONDMATE_PROJECTS" ] || { echo "error: --no-projects cannot be combined with a project list" >&2; exit 1; }
else
  [ -n "$SECONDMATE_PROJECTS" ] || { echo "error: --secondmate requires at least one project, or --no-projects for a project-less home" >&2; exit 1; }
fi
SECONDMATE_CHARTER=${FM_SECONDMATE_CHARTER:-"{TASK}"}
SECONDMATE_SCOPE=${FM_SECONDMATE_SCOPE:-${FM_SECONDMATE_CHARTER:-"{TASK}"}}
if [ "$NO_PROJECTS" -eq 1 ]; then
  PROJECT_CLONES_BODY="None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under \`projects/\`; its crews take pooled worktrees of that firstmate repo."
  PROJECT_CLONES_NOTE="This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo."
else
  PROJECT_CLONES_BODY=$(printf '%s\n' "$SECONDMATE_PROJECTS" | tr ' ' '\n' | sed 's/^/- /')
  PROJECT_CLONES_NOTE="The projects above are local clones for work you supervise; they are not an exclusive ownership claim."
fi
cat > "$BRIEF" <<EOF
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
$SECONDMATE_CHARTER

# Routing scope
$SECONDMATE_SCOPE

# Project clones
$PROJECT_CLONES_BODY

# Operating model
You are in an isolated firstmate home. The local \`SUPERVISOR.md\` is your job description, and your local \`data/\`, \`state/\`, \`config/\`, and \`projects/\` dirs are yours to operate.
$PROJECT_CLONES_NOTE
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# The captain and the parent channel
Nobody reads this chat: the captain and the main firstmate see only what is appended to $STATUS_FILE, and a captain-facing sentence that is not appended there has not been sent.
That file is your parent channel, and in this home it IS the captain: every sentence you would say to the captain, and every outcome the local SUPERVISOR.md tells a firstmate to bring to the captain, is one appended line there, never chat.
Your own machinery publishes the durable facts about your crew's work for you (\`bin/fm-parent-channel-lib.sh\`): a child's terminal done or failed line with its note and PR on every supervision poll, a PR-ready line when you register a PR, a task you hold for the captain and its answer, a merge, and a child's final line at cleanup all reach the parent channel from the scripts that record them, whether or not you append anything.
What only you can append is judgement: the answer to a marked request below, a recommendation or caveat on a delivered outcome, a blocker or failure of your own, and anything else you would otherwise say to the captain.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading \`$FM_FROMFIRST_LABEL\` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe \`corr=<id>\` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: \`bin/fm-secondmate-report.sh <verb> <corr_id> <note>\` appends that correlated line to the parent channel itself - do not pass a status path, and do not write a hand path under this home.
A plain \`echo\` that includes the same \`corr=<id>\` on this parent channel is equally valid; do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's \`data/\` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load \`captain-hold-lifecycle\` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.
A request arriving through the instruction inbox below follows the same marker and reply rules.

$INBOX_SECTION

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   \`$STATUS_APPEND\`
States: working, needs-decision, blocked, $PAUSED_VERB, done, failed.
Substitute \`<epoch>\` with the current Unix time in seconds - run \`date +%s\` and write the number it printed; a stamp that is not plain digits records no time at all.
Use \`$PAUSED_VERB: {why}\` (distinct from \`blocked:\`) only when your domain is deliberately idling on a known external wait you expect to clear on its own, naming when it clears with \`until <YYYY-MM-DDTHH:MMZ>\` (UTC) when you know; use \`blocked:\` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, work ready for review, or work you landed.
Work you landed includes a merge you performed yourself under standing merge authority and one the captain merged on the forge: under that authority nothing is ever \"ready for review\", so a landed merge that goes unreported reaches the captain as silence.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is \`working [key=<work-slug>]: {material phase}\`, use the same key on its later \`$PAUSED_VERB\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append \`resolved [key=<work-slug>] [at=<epoch>]: {why it is no longer active}\`.
\`resolved\` separately closes an escalated decision or blocker, and only a \`resolved\` line carrying that decision's exact key closes it: a later \`done\` or \`working\` event never does, even when the answer is what started that work.
The main firstmate's answer normally writes that closing line at answer time; when a blocker or wait clears WITHOUT an answer from the main firstmate, append \`resolved [at=<epoch>]: {how it cleared}\` yourself (keyed with \`[key=<slug>]\` if you opened it with one) as your domain resumes.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through \`bin/fm-session-start.sh\` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append \`blocked [at=<epoch>]: {why}\` or \`failed [at=<epoch>]: {why}\` to the main status file and stop.
EOF
if [ "$SECONDMATE_CHARTER" = "{TASK}" ]; then
  echo "scaffolded: $BRIEF (secondmate charter; replace {TASK})"
else
  echo "scaffolded: $BRIEF (secondmate charter)"
fi
exit 0
fi

REPO=${POS[1]:-host}

if [ "$KIND" = ship ] || [ "$KIND" = scout ] || [ "$HERDR_LAB" -eq 1 ]; then
# shellcheck source=bin/fm-herdr-contract-lib.sh
. "$SCRIPT_DIR/fm-herdr-contract-lib.sh"
HERDR_SECTION=$(fm_herdr_contract "$FM_ROOT" "$ID")
else
IFS= read -r -d '' HERDR_SECTION <<'EOF' || true
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
EOF
HERDR_SECTION=${HERDR_SECTION%$'\n'}
fi

IFS= read -r -d '' TASK_SECTION <<'EOF' || true
# Task
## Captain's intent
{TASK}

## Captain's requirements
{CAPTAIN_REQUIREMENTS}

## Firstmate spec
{FIRSTMATE_SPEC}

Report language: use the language of the request above; if it is unspecified, use the installation language. Carry it into the report, actions, and checks.
EOF
TASK_SECTION=${TASK_SECTION%$'\n'}
if [ -n "$CATEGORY" ]; then
  TASK_SECTION="$TASK_SECTION
Dispatch category: $CATEGORY"
fi
if [ -n "$RATIONALE" ]; then TASK_SECTION="$TASK_SECTION
Dispatch rationale: $RATIONALE"; fi
if [ -n "$DISPATCH_HARNESS" ]; then TASK_SECTION="$TASK_SECTION
Dispatch harness: $DISPATCH_HARNESS"; fi
if [ -n "$DISPATCH_MODEL" ]; then TASK_SECTION="$TASK_SECTION
Dispatch model: $DISPATCH_MODEL"; fi
if [ -n "$DISPATCH_EFFORT" ]; then TASK_SECTION="$TASK_SECTION
Dispatch effort: $DISPATCH_EFFORT"; fi
if [ "$PUBLISH" -eq 1 ] && [ "$EFFECT_SET" -eq 0 ]; then
  EFFECT='publica lo integrado por push al remoto del proyecto a través de su compuerta de publicación, sin pedir autorización adicional'
  EFFECT_SET=1
fi
if [ "$PUBLISH" -eq 1 ]; then TASK_SECTION="$TASK_SECTION
Publication task: yes"; fi
if [ "$EFFECT_SET" -eq 1 ]; then
  case "$KIND" in secondmate) echo "error: --effect applies only to ship, scout, and host briefs" >&2; exit 1 ;; esac
  case "$EFFECT" in ''|*$'\n'*|*$'\r'*) echo "error: --effect needs one line naming the exact outward action the task's own ask performs" >&2; exit 1 ;; esac
  TASK_SECTION="$TASK_SECTION

# Authorized outward effect
Outward effect: $EFFECT
This task's own ask requires exactly this outward action: perform it as stated, through every gate the task names.
The push, PR, publication, and remote-write prohibitions elsewhere in this brief do not apply to this one action; everything else they forbid stays forbidden."
fi

DECK_LINE='Deck address is not configured; use the manual report review path.'
if [ -f "$CONFIG/deck-url" ] && [ ! -L "$CONFIG/deck-url" ]; then
  DECK_URL=$(cat "$CONFIG/deck-url")
  if [[ "$DECK_URL" =~ ^https?://[^[:space:]/?#]+(/[^[:space:]?#]*)?$ ]]; then
    DECK_LINE="Deck address for report links: ${DECK_URL%/}"
  fi
fi

if [ -n "$BASE_BRANCH" ]; then
  SETUP_BASE="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean copy of its base branch.
Base branch: $BASE_BRANCH"
else
  SETUP_BASE="You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch."
fi

if [ "$KIND" = host ]; then
  HOST_TARGETS=$(fm_host_paths "${HOST_PATHS[@]+"${HOST_PATHS[@]}"}") || exit 1
  printf '%s\n' "$HOST_TARGETS" > "$DATA/$ID/host-paths"
  cat > "$BRIEF" <<EOF
$TASK_SECTION

# Setup
$HERDR_SECTION

Host task: $ID
Working directory: $DATA/$ID/work
Verify pwd -P is exactly this scratch directory before doing anything.
This directory is not a Git repository; do not create a branch, commit, push, or merge.

# Authorized outside paths
Only the exact paths below and their descendants may be changed outside your scratch directory and task records.
$HOST_TARGETS

# Rules
Use working, needs-decision, blocked, paused, done, or failed; report only meaningful phase changes.
A decision above your scope requires needs-decision and stopping for firstmate.
Close any keyed decision or blocker only with a resolved line carrying that exact key.
Report status with numeric Unix timestamps using:
\`$STATUS_REPORT\`
$CARD_RULE
$CREWMATE_PAUSE_INSTRUCTIONS
$INBOX_SECTION

# Definition of done
Complete the requested host operation, verify its result, and write $DATA/$ID/report.md.
Append done with a numeric at stamp only when the requested operation is complete.
Teardown removes scratch only; it never removes the authorized outside paths.
EOF
  append_brief_include
  echo "scaffolded: $BRIEF (host; replace {TASK} and {FIRSTMATE_SPEC}, then generate {CAPTAIN_REQUIREMENTS} with fm-brief.sh --requirements)"
  exit 0
fi

if [ "$INSTALLATION" -eq 1 ]; then
  SETUP_BASE="Installation audit: read the Firstmate installation at $FM_HOME without borrowing a project.
Working directory: $DATA/$ID/work
This directory is not a Git repository. Read the installation; do not modify it."
fi
if [ "$KIND" = scout ]; then
if "$SCRIPT_DIR/fm-bootstrap.sh" lavish-compatible >/dev/null 2>&1; then
  LAVISH_LINE='If your deliverable is a visual artifact the captain will review and iterate on, use the lavish-axi rule: create or resume one board with lavish-axi --no-open <artifact.html>, give its URL once, reuse that session through feedback rounds, never launch its URL in a browser, and end it with lavish-axi end <artifact.html> when finished. Then arm your board with bin/fm-procevent-lavish.sh arm <artifact.html> --for <task-id> --park; never run lavish-axi poll yourself. Re-arm with --park after each nonterminal round, with a reply that answers the captain directly in one or two sentences before any status line or escalation, to acknowledge it, route the board feedback through your steering inbox, write needs-decision [key=board-review] with the live board URL while you wait for the reviewer, and end your turn: --park closes your idle session and the next round resumes it. Stop at session_ended or an empty End without re-arming - acknowledge that final round with bin/fm-procevent.sh handled <source-id> <sequence> to conclude and retire your board.'
else
  LAVISH_LINE='Lavish is unavailable (lavish-axi is missing or below its supported version floor); still deliver the required standalone HTML report, and ask firstmate to arrange any requested review.'
fi
if [ "$INSTALLATION" -eq 1 ]; then
  # shellcheck disable=SC2016 # The worker must receive the variable literally.
  SCOUT_SCRATCH_RULE='Keep the installation read-only. Put scratch output in the task tmpdir (the parent of `$GOTMPDIR`), which teardown deletes.'
else
  # shellcheck disable=SC2016 # The worker must receive the variable literally.
  SCOUT_SCRATCH_RULE='Keep project edits inside this worktree; put labs, installations, copies, and other scratch output in the task tmpdir (the parent of `$GOTMPDIR`), which teardown deletes.'
fi
cat > "$BRIEF" <<EOF
$TASK_SECTION
$DECK_LINE

$HERDR_SECTION

# Setup
$SETUP_BASE
$(if [ "$INSTALLATION" -eq 1 ]; then printf "Installation audit: read-only\n"; fi)
This is a SCOUT task: deliver a written report, not a PR.
The task copy is disposable; teardown preserves local changes in a recoverable backup, but the report must stand alone.

# Task-specific rules and paths
Never push or open a PR.
$SCOUT_SCRATCH_RULE
Keep only reports, logs, and captures under \`$DATA/$ID/\`; outside the worktree, also write the status, card, and steering-inbox records authorized below.
Status command: \`$STATUS_REPORT\`
$SHORT_INBOX
Declared external-wait status: $PAUSED_VERB
$WAIT_BLOCK
# Definition of done
Write findings to \`$DATA/$ID/report.md\` with what you did, findings, evidence, recommendations and unresolved work. Also deliver \`$DATA/$ID/report.html\` under the worker contract; retain the Markdown record for existing task integrations.
Before writing the HTML, reread the Reports section of the worker contract, and before delivering it check the report yourself against that section's delivery list; no other reviewer is needed.
For a diagnosis, follow diagnostic-reasoning and cite the always-on diagnostic logs; with local changes include the applied diff (including new files), commands to reproduce, and the result.
A plan or protocol reports its expected quota and cost as information and never proposes waiting for a captain approval because the work spends them.
$LAVISH_LINE
Before reporting done, load \`captain-hold-lifecycle\` and pass its shared completion gate for the report and any visual review.
When the report is complete, append \`done [at=<epoch>]: {one-line conclusion}\` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
EOF
append_brief_include
echo "scaffolded: $BRIEF (scout; replace {TASK} and {FIRSTMATE_SPEC}, then generate {CAPTAIN_REQUIREMENTS} with fm-brief.sh --requirements)"
exit 0
fi

# Ship task: shape Setup / Rule 1 by this task's explicit delivery mode, validated
# above, and render the Definition of done from its single owner, bin/fm-dod-lib.sh,
# which bin/fm-promote.sh renders too so a promoted scout receives the same contract.
# The block opens with the fixed "Delivery contract: mode=<mode>" line that
# bin/fm-spawn.sh checks against its own explicit --mode and the project's
# registered forge before launching.
case "$MODE" in
  direct-PR)
    SETUP2=""
    ;;
  local-only)
    SETUP2=""
    ;;
  *)  # no-mistakes
    SETUP2="
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`."
    ;;
esac
RULE1=$(fm_ship_rule_one "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH") || exit 1
DOD=$(fm_dod_block "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH" "$UPSTREAM_CONSENT") || exit 1

cat > "$BRIEF" <<EOF
$TASK_SECTION
$DECK_LINE

$HERDR_SECTION

# Setup
$SETUP_BASE
Run \`pwd -P\` and \`git rev-parse --show-toplevel\` in a separate tool call, then inspect their output and verify both name your disposable task worktree, not firstmate's primary checkout; if not, report blocked and stop before branching.
1. First action: create your branch: \`git checkout -b $BRANCH_Q --\`$SETUP2

# Task-specific rules and paths
$RULE1
2. Keep project edits inside this worktree; put labs, installations, copies, and other scratch output in the task tmpdir (the parent of \`\$GOTMPDIR\`), which teardown deletes.
   Keep only reports, logs, and captures under \`$DATA/$ID/\`; outside the worktree, also write the status, card, and steering-inbox records authorized below.
   Leave the worktree clean before reporting done.
3. $FORGE_RULE_LINE
4. Before handing off a code change, run its regression test that fails without the change, the project's check, and a short run of the critical flow.
   For Firstmate itself, run \`bin/fm-test-run.sh --changed --base origin/main\` once per batch before publication, from a clean checkout of main.
Status command: \`$STATUS_REPORT\`
$SHORT_INBOX
Declared external-wait status: $PAUSED_VERB
$ASK_USER_BLOCK
$WAIT_BLOCK
$DOD
EOF
append_brief_include
if [ "$FORGE" = none ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE; replace {TASK} and {FIRSTMATE_SPEC}, then generate {CAPTAIN_REQUIREMENTS} with fm-brief.sh --requirements)"
elif [ "$FORGE" = gerrit ]; then
  echo "scaffolded: $BRIEF (ship, mode=$MODE forge=$FORGE shape=$SHAPE; replace {TASK} and {FIRSTMATE_SPEC}, then generate {CAPTAIN_REQUIREMENTS} with fm-brief.sh --requirements)"
else
  echo "scaffolded: $BRIEF (ship, mode=$MODE forge=$FORGE; replace {TASK} and {FIRSTMATE_SPEC}, then generate {CAPTAIN_REQUIREMENTS} with fm-brief.sh --requirements)"
fi
