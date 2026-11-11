#!/usr/bin/env bash
# Discovery wiring preserves native skills and points at the current task copy.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-claude-native-skills)
PROJECT="$LAB/project with spaces"
DATA="$LAB/task"
mkdir -p "$PROJECT" "$DATA"
HELPER="$ROOT/bin/fm-claude-native-skills.sh"
[ -z "$(bash "$HELPER" "$PROJECT" "$DATA")" ] || fail 'empty project created a bridge'
mkdir -p "$PROJECT/.agents/skills/shared" "$PROJECT/.claude/skills/native"
printf 'original\n' > "$PROJECT/.claude/skills/native/SKILL.md"
printf 'first\n' > "$PROJECT/.agents/skills/shared/SKILL.md"
BRIDGE=$(bash "$HELPER" "$PROJECT" "$DATA")
cmp "$BRIDGE/.claude/skills/shared/SKILL.md" "$PROJECT/.agents/skills/shared/SKILL.md"
[ "$(cat "$PROJECT/.claude/skills/native/SKILL.md")" = original ] || fail 'native skill changed'
printf 'updated\n' > "$PROJECT/.agents/skills/shared/SKILL.md"
[ "$(cat "$BRIDGE/.claude/skills/shared/SKILL.md")" = updated ] || fail 'bridge copied a stale skill body'
[ "$(bash "$HELPER" "$PROJECT" "$DATA")" = "$BRIDGE" ] || fail 'relaunch changed discovery path'
OTHER="$LAB/other"
mkdir -p "$OTHER/.agents/skills/new"
printf 'replacement\n' > "$OTHER/.agents/skills/new/SKILL.md"
bash "$HELPER" "$OTHER" "$DATA" >/dev/null
[ ! -e "$BRIDGE/.claude/skills/shared" ] || fail 'relaunch retained an old task copy'
[ "$(cat "$BRIDGE/.claude/skills/new/SKILL.md")" = replacement ] || fail 'relaunch did not retarget discovery'
LINKED="$LAB/already-native"
mkdir -p "$LINKED/.agents/skills" "$LINKED/.claude"
ln -s ../.agents/skills "$LINKED/.claude/skills"
[ -z "$(bash "$HELPER" "$LINKED" "$DATA")" ] || fail 'native symlink was exposed twice'
pass 'Claude shared-skill discovery follows the task copy without modifying project skills'
