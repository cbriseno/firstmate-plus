#!/usr/bin/env bash
# One PreToolUse review for the cd-guard, watcher-arm and primary-write seatbelts.
#
# Claude and Codex used to run bin/fm-arm-pretool-check.sh,
# bin/fm-cd-pretool-check.sh and bin/fm-primary-write-pretool-check.sh as three
# separate hooks, each starting a shell and most starting jq, git and Node, for
# every tool action (~0.9 s p50 per action on a loaded host). This entry reads
# the payload once with shell builtins only and runs a seatbelt only when the
# action can touch what it protects; the three scripts stay the sole owners of
# every decision and of the deny output. See docs/pretool-check.md.
#
# Usage: <PreToolUse JSON on stdin> | bin/fm-pretool-check.sh [--claude]
#
# Exit/output contract: exactly that of the seatbelt that denied (exit 2 with
# its stderr object, and its stdout object unless --claude). Everything else
# exits 0 with no output. A payload this entry cannot decode with builtins
# (unicode escapes, an unknown shape, an oversized command) is never skipped:
# it runs every seatbelt that applies to its tool, as the three hooks did.
set -u
# shellcheck source=bin/fm-diag.sh
. "${BASH_SOURCE[0]%/*}/fm-diag.sh" 2>/dev/null && fm_diag_hook_begin pretool && trap fm_diag_hook_end EXIT

ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude) ARGS+=(--claude); shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//' ; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

IFS= read -r -d '' PAYLOAD || true
[ -n "$PAYLOAD" ] || exit 0

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
# shellcheck source=bin/fm-pretool-prefilter-lib.sh
. "$SCRIPT_DIR/fm-pretool-prefilter-lib.sh"

# Decode the JSON string value that follows the key $1 into DECODED. Returns 1
# on anything other than plain text and the escapes below, so the caller
# delegates instead of guessing.
json_string_after() {  # <key>
  local rest=${PAYLOAD#*\""$1"\":\"} chunk esc
  [ "$rest" != "$PAYLOAD" ] || return 1
  DECODED=''
  while :; do
    chunk=${rest%%[\"\\]*}
    [ "$chunk" != "$rest" ] || return 1
    DECODED+=$chunk
    rest=${rest:${#chunk}}
    [ "${rest:0:1}" != '"' ] || return 0
    esc=${rest:1:1}
    rest=${rest:2}
    case "$esc" in
      n) DECODED+=$'\n' ;;
      r) DECODED+=$'\r' ;;
      t) DECODED+=$'\t' ;;
      b|f) DECODED+=' ' ;;
      '"'|\\|/) DECODED+=$esc ;;
      *) return 1 ;;
    esac
  done
}

# Run one seatbelt on the payload; its deny (exit 2) ends this hook unchanged.
run_seatbelt() {  # <script>
  local rc=0
  FM_DIAGNOSTICS=0 "$SCRIPT_DIR/$1" "${ARGS[@]+"${ARGS[@]}"}" <<<"$PAYLOAD" || rc=$?
  [ "$rc" -ne 2 ] || exit 2
}

TOOL=''
[ "${#PAYLOAD}" -le 65536 ] && json_string_after tool_name && TOOL=$DECODED
case "$TOOL" in
  Bash|apply_patch|Read|Edit|MultiEdit|Write|NotebookEdit) ;;
  '') # undecodable: run every seatbelt, as the three separate hooks did
    run_seatbelt fm-arm-pretool-check.sh
    run_seatbelt fm-cd-pretool-check.sh
    run_seatbelt fm-primary-write-pretool-check.sh
    exit 0 ;;
  *) exit 0 ;;
esac

# The cd and write seatbelts act only in a genuine primary home: a plain
# checkout, or a marked secondmate home. A linked task worktree - the shape every
# crewmate gets - is inert for both, so a plain `.git` file naming a worktree
# gitdir skips them without starting git. The arm seatbelt has no home scope.
ROOT=${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}
PRIMARY=1
if [ -f "$ROOT/.git" ] && [ ! -e "$ROOT/.fm-secondmate-home" ]; then
  gitdir=''
  IFS= read -r gitdir < "$ROOT/.git" 2>/dev/null || true
  case "$gitdir" in gitdir:*/worktrees/*) PRIMARY=0 ;; esac
fi

CMD=''
case "$TOOL" in
  Bash|apply_patch)
    json_string_after command || { DECODED=''; CMD='@undecodable'; }
    [ "$CMD" = '@undecodable' ] || CMD=$DECODED
    ;;
esac

case "$TOOL" in
  Bash)
    if [ "$CMD" = '@undecodable' ]; then
      run_seatbelt fm-arm-pretool-check.sh
      [ "$PRIMARY" -eq 0 ] || { run_seatbelt fm-cd-pretool-check.sh; run_seatbelt fm-primary-write-pretool-check.sh; }
    else
      [ -n "$CMD" ] || exit 0
      ! fm_prefilter_arm_may_match "$CMD" || run_seatbelt fm-arm-pretool-check.sh
      if [ "$PRIMARY" -eq 1 ]; then
        ! fm_prefilter_cd_may_match "$CMD" || run_seatbelt fm-cd-pretool-check.sh
        ! fm_prefilter_write_may_match "$CMD" || run_seatbelt fm-primary-write-pretool-check.sh
      fi
    fi
    ;;
  *)
    # apply_patch and the file tools reach only the write seatbelt.
    [ "$PRIMARY" -eq 1 ] && run_seatbelt fm-primary-write-pretool-check.sh
    ;;
esac
exit 0
