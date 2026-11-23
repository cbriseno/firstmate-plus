#!/usr/bin/env bash
# Diagnose a Treehouse exhaustion after its get reports all slots in use or dirty.
# Usage: fm-treehouse-diagnose.sh <project-directory>
# Report a clean available branch that is absent upstream, distinguishing local integration.
set -u
project=${1:?usage: fm-treehouse-diagnose.sh <project-directory>}
ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || exit 0
base=${ref#origin/}
git -C "$project" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || exit 0
git -C "$project" rev-parse --verify --quiet "refs/heads/$base^{commit}" >/dev/null || exit 0
if status=$(cd "$project" && treehouse status --json 2>/dev/null); then
  slots=$(printf '%s\n' "$status" | jq -r '.[] | select(.status == "available" and (.branch // "") != "") | .path' 2>/dev/null) || exit 0
else
  # Older Treehouse releases expose only the human-readable status table.
  status=$(cd "$project" && treehouse status 2>/dev/null) || exit 0
  slots=$(printf '%s\n' "$status" | awk '$2 == "available" { sub(/^[^[:space:]]+[[:space:]]+available[[:space:]]+/, ""); print }')
fi
while IFS= read -r slot; do
  [ -n "$slot" ] || continue
  git -C "$slot" symbolic-ref --quiet HEAD >/dev/null 2>&1 || continue
  changes=$(git -C "$slot" status --porcelain 2>/dev/null) || continue
  [ -z "$changes" ] || continue
  git -C "$slot" merge-base --is-ancestor HEAD "$ref" 2>/dev/null && continue
  if git -C "$slot" merge-base --is-ancestor HEAD "refs/heads/$base" 2>/dev/null; then
    printf 'error: Treehouse cannot reuse a clean available worktree with a branch integrated into local %s but absent from %s; inspect its parked task before recycling it\n' "$base" "$ref"
  else
    printf 'error: Treehouse cannot reuse a clean available worktree with a branch absent from both local %s and %s; inspect its parked task before recycling it\n' "$base" "$ref"
  fi
  exit 0
done <<< "$slots"
