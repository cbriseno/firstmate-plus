#!/usr/bin/env bash
# Make a Firstmate home load its supervisor contract natively.
#
# Usage: fm-home-instructions.sh <home>
#
# SUPERVISOR.md is tracked, so it is also present in every task copy of this
# repository, where workers must not load it. Only untracked files separate a
# home from a task copy, so each home gets two untracked files:
#   CLAUDE.local.md     imports SUPERVISOR.md and the home's captain records
#                       (Claude loads it beside CLAUDE.md in that directory).
#   AGENTS.override.md  a link to SUPERVISOR.md (Codex reads it in place of
#                       AGENTS.md in that directory).
# An existing file is never touched. For each file written, one line is
# printed; the running session loads it from its next start, so the line tells
# it to read SUPERVISOR.md now. Silent when both files already exist.
set -eu

home=${1:?usage: fm-home-instructions.sh <home>}
[ -f "$home/SUPERVISOR.md" ] || exit 0

if [ ! -e "$home/CLAUDE.local.md" ] && [ ! -L "$home/CLAUDE.local.md" ]; then
  printf '%s\n' \
    '<!-- Untracked; written by bin/fm-home-instructions.sh. Loads this home'"'"'s supervisor contract and captain records. -->' \
    '@SUPERVISOR.md' \
    '@data/captain-shared.md' \
    '@data/captain.md' >"$home/CLAUDE.local.md"
  echo "BOOTSTRAP_INFO: wrote $home/CLAUDE.local.md; read SUPERVISOR.md now, it loads natively from the next session"
fi
if [ ! -e "$home/AGENTS.override.md" ] && [ ! -L "$home/AGENTS.override.md" ]; then
  ln -s SUPERVISOR.md "$home/AGENTS.override.md"
  echo "BOOTSTRAP_INFO: linked $home/AGENTS.override.md to SUPERVISOR.md; read SUPERVISOR.md now, it loads natively from the next session"
fi
