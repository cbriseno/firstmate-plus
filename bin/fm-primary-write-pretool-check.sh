#!/usr/bin/env bash
# PreToolUse guard against the firstmate primary doing work itself.
#
# AGENTS.md section 1: firstmate delegates every actionable request to a worker,
# including changes to the captain's personal environment, and its own direct
# writes stay inside its private operational state, the guarded fleet scripts,
# and hard rule 1's captain-approved project operations. Before this guard
# nothing enforced that outside project clones, so a primary could edit the
# captain's shell aliases or a plugin's user configuration itself instead of
# dispatching a worker the captain can watch. This guard refuses such a write
# before it runs and names the dispatch path instead.
# bin/fm-primary-write-policy.mjs is the sole owner of the per-target decision;
# this wrapper scopes the guard to a genuine primary home, owns the escape
# hatch and the allowed-path set, acquires the harness payload, and renders the
# established harness responses. It never executes, sources, evaluates, or
# expands the command. See docs/primary-write-guard.md for the complete
# contract, carve-outs, residual limits, and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-primary-write-pretool-check.sh [--claude]
#   bin/fm-primary-write-pretool-check.sh --tool <name> [--command <cmd>] [--path <file>] [--cwd <dir>] [--claude]
#
# Stdin mode reads .tool_name, .cwd, and .tool_input (Claude and Codex), or
# .toolName and .toolInput. Guarded tools: Bash (.command), Edit, MultiEdit,
# and Write (.file_path), NotebookEdit (.notebook_path), and Codex apply_patch
# (.command holding the patch). Every other tool allows without classification.
# CLI mode is for tests and future adapters that already hold the fields.
#
# Allowed write paths, in a genuine primary home (docs/primary-write-guard.md
# owns the rationale for each):
#   - the effective state, data, and config directories, plus state/, data/,
#     config/, and .lavish/ under both FM_HOME and the code root;
#   - the home's gitignored .env file and root-level scratchpad* paths;
#   - temp directories: /tmp, /var/tmp, and $TMPDIR, or the colon-separated
#     FM_PRIMARY_WRITE_TEMP_DIRS when set (for tests and specialized setup);
#   - the private state, data, and config directories of every local secondmate
#     home registered in data/secondmates.md;
#   - in a secondmate home, its parent channel (bin/fm-parent-channel-lib.sh);
#   - live grants from bin/fm-primary-write-grant.sh, the only way into a
#     project clone and never into a grant record itself;
#   - git checkout and switch on the home's own checkout (worktree-tangle
#     restore), while every other mutating git command there is refused.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   ESCAPE - FM_ALLOW_PRIMARY_WRITE=1 in the session environment allows.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
set -u

TOOL=""
CMD=""
FILE_PATH=""
CWD=""
TOOL_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-primary-write-pretool-check.sh [--tool <name> [--command <cmd>] [--path <file>] [--cwd <dir>]] [--claude]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name, cwd, and tool_input).
Denies a write by the firstmate primary outside its private operational paths:
state/, data/, config/, .lavish/, a temp dir, or a live captain-approval grant
from bin/fm-primary-write-grant.sh. Names the worker dispatch path instead.
Fires only in a genuine firstmate primary home; it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo.
Exits 0 to allow and 2 to deny. Set FM_ALLOW_PRIMARY_WRITE=1 in the session
environment to allow deliberately. Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool) [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }; TOOL=$2; TOOL_SET=1; shift 2 ;;
    --command) [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }; CMD=$2; shift 2 ;;
    --path) [ "$#" -gt 1 ] || { echo "error: --path requires a value" >&2; exit 2; }; FILE_PATH=$2; shift 2 ;;
    --cwd) [ "$#" -gt 1 ] || { echo "error: --cwd requires a value" >&2; exit 2; }; CWD=$2; shift 2 ;;
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  # Cursor also loads the tracked Claude settings; this guard is not wired for
  # Cursor (docs/primary-write-guard.md), so that duplicate delivery stands down.
  fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
  # Four NUL-terminated fields, so commands and paths keep their newlines.
  {
    IFS= read -r -d '' TOOL
    IFS= read -r -d '' CWD
    IFS= read -r -d '' CMD
    IFS= read -r -d '' FILE_PATH
  } < <(printf '%s' "$PAYLOAD" | jq -j '
    (.tool_input // .toolInput // {}) as $in
    | [(.tool_name // .toolName // ""), (.cwd // ""),
       ($in.command // ""), ($in.file_path // $in.notebook_path // $in.path // "")]
    | map((if type == "string" then . else "" end) + "\u0000") | add' 2>/dev/null)
fi

case "$TOOL" in
  Edit|MultiEdit|Write|NotebookEdit) [ -n "$FILE_PATH" ] || exit 0 ;;
  Bash|apply_patch) [ -n "$CMD" ] || exit 0 ;;
  *) exit 0 ;;
esac

# Strict-superset prefilter for shell commands (transport only; owns zero
# classification semantics): a command with no redirection and no write-shaped
# command word cannot produce a target, so it skips the scope checks and Node.
# Quotes, backslashes, and line breaks are stripped first so quoted or escaped
# command-word fragments still reach the policy, and an ANSI-C or locale quote
# delegates outright because the classifier decodes those. The stem list is
# COUPLED to the command classes in bin/fm-primary-write-policy.mjs: adding a
# command there REQUIRES adding its name here in the same change.
if [ "$TOOL" = "Bash" ]; then
  case "$CMD" in
    *"\$'"*|*'$"'*|*'>'*) ;;
    *)
      PREFILTER=$CMD
      PREFILTER=${PREFILTER//\\/}
      PREFILTER=${PREFILTER//\"/}
      PREFILTER=${PREFILTER//\'/}
      PREFILTER=${PREFILTER//$'\n'/ }
      PREFILTER=${PREFILTER//$'\r'/ }
      STEMS='tee|cp|mv|install|ln|rsync|rm|rmdir|unlink|shred|touch|mkdir|truncate|chmod|chown|chgrp|sed|dd|curl|wget|git|apply_patch|eval|xargs|find|bash|sh|zsh|dash|ksh|python[0-9.]*|node|nodejs|bun|deno|perl|ruby'
      [[ " $PREFILTER " =~ (^|[^A-Za-z0-9_.-])($STEMS)([^A-Za-z0-9_-]|$) ]] || exit 0
      ;;
  esac
fi

# The single deliberate escape hatch, unforgeable in-session for the same
# reason as FM_ALLOW_SUBAGENT: it must be present when the harness launches.
[ "${FM_ALLOW_PRIMARY_WRITE:-}" != "1" ] || exit 0

FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
PROJECTS=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}

# Scope to a genuine primary home exactly as the delegation guard does: a plain
# checkout or a marked secondmate home is in scope, a linked task worktree - the
# shape bin/fm-spawn.sh hands every crewmate - is not, so workers are never
# affected. Any failure to confirm the home is inert, never a block.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

POLICY="$SCRIPT_DIR/fm-primary-write-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

[ -n "$CWD" ] || CWD=$PWD
ARGS=(--tool "$TOOL" --cwd "$CWD" --projects "$PROJECTS"
  --home-checkout "$FM_ROOT" --home-checkout "$FM_HOME"
  --protect "$STATE/primary-write-grants"
  --allow "$STATE" --allow "$DATA" --allow "$CONFIG"
  --allow-file "$FM_HOME/.env" --allow-file "$FM_ROOT/.env")
for home in "$FM_HOME" "$FM_ROOT"; do
  for dir in state data config .lavish; do
    ARGS+=(--allow "$home/$dir")
  done
  ARGS+=(--allow-prefix "$home/scratchpad")
done

TEMP_DIRS=${FM_PRIMARY_WRITE_TEMP_DIRS-/tmp:/var/tmp:${TMPDIR:-}}
IFS=: read -r -a TEMP_LIST <<< "$TEMP_DIRS"
for dir in "${TEMP_LIST[@]}"; do
  [ -n "$dir" ] && ARGS+=(--allow "$dir")
done

# Local secondmate homes registered here: the main home curates their memory
# files and charters directly (secondmate-provisioning, stow).
if [ -f "$DATA/secondmates.md" ]; then
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  while IFS= read -r line; do
    secondmate_registry_parse_line "$line" 2>/dev/null || continue
    [ "${SECONDMATE_REGISTRY_REMOTE:-0}" = 0 ] || continue
    case "${SECONDMATE_REGISTRY_HOME:-}" in /*) ;; *) continue ;; esac
    for dir in state data config; do
      ARGS+=(--allow "$SECONDMATE_REGISTRY_HOME/$dir")
    done
  done < "$DATA/secondmates.md"
fi

# A secondmate home reports judgement on its parent channel.
if fm_root_is_secondmate_home "$FM_HOME" || fm_root_is_secondmate_home "$FM_ROOT"; then
  # shellcheck source=bin/fm-parent-channel-lib.sh
  . "$SCRIPT_DIR/fm-parent-channel-lib.sh"
  CHANNEL=$(fm_parent_channel_destination "$FM_HOME" "$STATE" 2>/dev/null) && [ -n "$CHANNEL" ] \
    && ARGS+=(--allow-file "$CHANNEL")
fi

if compgen -G "$STATE/primary-write-grants/*.grant" >/dev/null 2>&1; then
  while IFS= read -r granted; do
    [ -n "$granted" ] && ARGS+=(--grant "$granted")
  done < <(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-primary-write-grant.sh" active 2>/dev/null)
fi

if [ "$TOOL" = "Bash" ] || [ "$TOOL" = "apply_patch" ]; then
  ARGS+=(--command "$CMD")
else
  ARGS+=(--path "$FILE_PATH")
fi

POLICY_OUTPUT=$(node "$POLICY" "${ARGS[@]}" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  '
}

ESCAPED=$(json_escape "[$CODE] $REASON Launch the session with FM_ALLOW_PRIMARY_WRITE=1 for a deliberate exception.")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
