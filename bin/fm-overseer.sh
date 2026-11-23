#!/usr/bin/env bash
# fm-overseer.sh - prepare and manage the captain's overseer session.
#
# The overseer (in Spanish, "supervisor") is one long-running Claude or Codex
# session that watches a Firstmate home's primary on the captain's behalf. Its
# role contract is overseer/AGENTS.md in this repository; this script owns the
# mechanics around it.
#
# Usage:
#   fm-overseer.sh setup <dir>   prepare <dir> so an agent started there loads
#                                the overseer contract natively
#   fm-overseer.sh -h|--help     print this text
#
# setup creates <dir> when missing and writes three untracked entries in it:
#   CLAUDE.md       symlink to <code-root>/overseer/AGENTS.md (Claude loads it)
#   AGENTS.md       symlink to the same file (Codex loads it)
#   firstmate-home  one line: the physical path of the home being overseen,
#                   FM_HOME when set, otherwise this script's code root
# Both loaders are symlinks to the contract itself, so a repository update
# reaches the next overseer session without rerunning setup. They are not an
# @-import: Claude treats an import that resolves outside its directory as an
# external include and skips it until approved, while a symlinked CLAUDE.md
# loads directly.
# setup refuses, changing nothing, when <dir> or any ancestor holds
# SUPERVISOR.md (an agent there would also load a home's or a task copy's
# instructions), or when an entry exists with other content. An entry that
# already matches is left alone, so setup is idempotent; it prints one line per
# entry written and a final OVERSEER_READY line.
#
# Interface for later pieces:
#   - The overseer finds the home through <dir>/firstmate-home; tools that act
#     for an overseer directory read the same file.
#   - The overseer's runtime records live in <home>/state/overseer/. The relay
#     writes the successor's handoff to state/overseer/handoff.md (the contract
#     reads it at session start and keeps it under 4 KB).
#   - Each new subcommand (watch, start, status, stop, doctor) is added to the
#     usage above; the contract points at this --help and names no command
#     itself, so only this header changes.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
code_root=${script_dir%/bin}

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'
}

refuse() {
  printf 'fm-overseer: %s\n' "$1" >&2
  exit 1
}

# Print the first ancestor of physical directory $1, or $1 itself, that holds
# SUPERVISOR.md; print nothing when none does.
supervisor_ancestor() {
  local d=$1
  while :; do
    if [ -e "$d/SUPERVISOR.md" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    [ "$d" = / ] && return 0
    d=$(dirname -- "$d")
  done
}

# Check entry $1 against symlink target $2; print "write" when it is absent,
# refuse when it holds anything else.
check_link() {
  local entry=$1 target=$2
  if [ -L "$entry" ]; then
    [ "$(readlink -- "$entry")" = "$target" ] && return 0
    refuse "$entry already links to $(readlink -- "$entry"), not $target; move it away first"
  fi
  [ -e "$entry" ] && refuse "$entry already exists and is not the overseer contract link; move it away first"
  printf 'write\n'
}

setup() {
  local dir=${1:?usage: fm-overseer.sh setup <dir>} home contract existing ancestor claude agents homefile
  contract="$code_root/overseer/AGENTS.md"
  [ -f "$contract" ] || refuse "contract missing: $contract"
  home=${FM_HOME:-$code_root}
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) && [ -f "$home/SUPERVISOR.md" ] ||
    refuse "not a Firstmate home: ${FM_HOME:-$code_root}"
  case $dir in /*) ;; *) dir=$PWD/$dir ;; esac
  existing=$dir
  while [ ! -d "$existing" ]; do existing=$(dirname -- "$existing"); done
  existing=$(CDPATH='' cd -- "$existing" && pwd -P)
  ancestor=$(supervisor_ancestor "$existing")
  [ -z "$ancestor" ] ||
    refuse "$dir is inside $ancestor, which holds SUPERVISOR.md; an overseer there would load that contract too; choose a directory outside any Firstmate home or copy"
  mkdir -p -- "$dir"
  dir=$(CDPATH='' cd -- "$dir" && pwd -P)

  claude=$(check_link "$dir/CLAUDE.md" "$contract")
  agents=$(check_link "$dir/AGENTS.md" "$contract")
  homefile=
  if [ -L "$dir/firstmate-home" ] || { [ -e "$dir/firstmate-home" ] && [ ! -f "$dir/firstmate-home" ]; }; then
    refuse "$dir/firstmate-home exists and is not a regular file; move it away first"
  elif [ -f "$dir/firstmate-home" ]; then
    [ "$(cat -- "$dir/firstmate-home")" = "$home" ] ||
      refuse "$dir/firstmate-home names $(cat -- "$dir/firstmate-home"), not $home; this directory oversees another home"
  else
    homefile=1
  fi

  if [ -n "$claude" ]; then
    ln -s -- "$contract" "$dir/CLAUDE.md"
    echo "OVERSEER_SETUP: linked $dir/CLAUDE.md to $contract"
  fi
  if [ -n "$agents" ]; then
    ln -s -- "$contract" "$dir/AGENTS.md"
    echo "OVERSEER_SETUP: linked $dir/AGENTS.md to $contract"
  fi
  if [ -n "$homefile" ]; then
    printf '%s\n' "$home" >"$dir/firstmate-home"
    echo "OVERSEER_SETUP: wrote $dir/firstmate-home naming $home"
  fi
  echo "OVERSEER_READY: $dir oversees $home; a Claude or Codex session started there loads the overseer contract"
}

case "${1:-}" in
  setup) shift; setup "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
