#!/usr/bin/env bash
# Expose a task copy's .agents/skills to Claude's native --add-dir loader.
# Usage: fm-claude-native-skills.sh <task-copy> <task-data-dir>
# Prints an additional directory, or nothing when no bridge is needed.
# The task-owned symlink is discovery wiring, never a copy of skill bodies or
# a write to project configuration. Native .claude/skills retains precedence.
# Claude loads project instructions, agents, commands, hooks and MCP from cwd;
# this bridge supplies only the otherwise undiscovered shared skill directory.
set -eu
project=$(cd "$1" && pwd -P)
data=$(cd "$2" && pwd -P)
[ -d "$project/.agents/skills" ] || exit 0
shared=$(cd "$project/.agents/skills" && pwd -P)
if [ -d "$project/.claude/skills" ]; then
  native=$(cd "$project/.claude/skills" && pwd -P)
  [ "$shared" != "$native" ] || exit 0
fi
bridge="$data/claude-native"
mkdir -p "$bridge/.claude"
ln -sfn "$shared" "$bridge/.claude/skills"
printf '%s\n' "$bridge"
