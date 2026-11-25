#!/usr/bin/env bash
# Diagnose a Treehouse exhaustion after its get reports all slots in use or dirty.
# Usage: fm-treehouse-diagnose.sh <project-directory>
# Report a clean available branch that is absent upstream, distinguishing local integration.
set -u
project=${1:?usage: fm-treehouse-diagnose.sh <project-directory>}
if inventory=$(cd "$project" && treehouse status --json 2>/dev/null) &&
  printf '%s\n' "$inventory" | jq -e 'type == "array"' >/dev/null 2>&1; then
  printf '%s\n' 'Treehouse pool inventory (snapshot):'
  printf '%s\n' "$inventory" | python3 -c '
import json, subprocess, sys
for slot in json.load(sys.stdin):
    path = slot.get("path", "")
    reasons = []
    if slot.get("status") != "available":
        reasons.append("status=" + str(slot.get("status", "unknown")))
    if slot.get("lease_id"):
        reasons.append("leased to " + str(slot.get("lease_holder") or "unknown holder"))
    if slot.get("processes"):
        reasons.append("processes present")
    def git(*args):
        return subprocess.run(["git", "-C", path, *args], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True)
    if path:
        changes = git("status", "--porcelain", "--untracked-files=all")
        if changes.returncode:
            reasons.append("worktree status unreadable")
        elif changes.stdout:
            reasons.append("uncommitted changes")
        head = git("rev-parse", "--verify", "HEAD")
        if head.returncode:
            reasons.append("HEAD unreadable")
        elif not git("for-each-ref", "--contains", head.stdout.strip(), "--format=%(refname)", "refs/heads", "refs/tags", "refs/remotes").stdout:
            reasons.append("HEAD has no preserving ref")
    print("  {}: {}".format(path or "unknown path", "; ".join(reasons) or "available; Treehouse did not reuse it"))
'
else
  printf '%s\n' 'Treehouse pool inventory unavailable.'
fi
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
