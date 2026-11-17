#!/usr/bin/env bash
# Local integration branch used by sync and landed-work checks.
# Project Git config firstmate.localBranch overrides the conventional local branch.
fm_local_integration_branch() {
  local branch
  branch=$(git -C "$1" config --get firstmate.localBranch) || branch=local
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || return 1
  printf '%s\n' "$branch"
}

# A clean merge that introduces no change proves HEAD's content is integrated,
# including rewritten or squashed commits. Shared by auto-close and teardown;
# conflicts and inspection failures remain inconclusive.
fm_local_content_in_ref() {  # <worktree> <integration-ref>
  local wt=$1 ref=$2 default_tree merged_tree
  default_tree=$(git -C "$wt" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  merged_tree=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=${merged_tree%%$'\n'*}
  [ "$merged_tree" = "$default_tree" ]
}
