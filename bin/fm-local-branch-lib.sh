#!/usr/bin/env bash
# Local integration branch used by sync and landed-work checks.
# Project Git config firstmate.localBranch overrides the conventional local branch.
fm_local_integration_branch() {
  local branch
  branch=$(git -C "$1" config --get firstmate.localBranch) || branch=local
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || return 1
  printf '%s\n' "$branch"
}
