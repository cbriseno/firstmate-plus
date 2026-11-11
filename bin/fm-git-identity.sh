#!/usr/bin/env bash
# Pin the configured public Git identity before launching a worker.
# Usage: fm-git-identity.sh <worktree> <project> <home>
# Read the project's effective user.name/user.email, falling back to the home's
# complete pair. Never infer identity from commit history or harness defaults.
# Write repository-local config, plus worktree config when enabled so a pooled
# copy's old identity cannot override it. Works with linked worktrees and clones.
set -eu
wt=$1
project=$2
home=$3
name=$(git -C "$project" config user.name || true)
email=$(git -C "$project" config user.email || true)
if [ -z "$name" ] || [ -z "$email" ]; then
  name=$(git -C "$home" config user.name || true)
  email=$(git -C "$home" config user.email || true)
fi
if [ -z "$name" ] || [ -z "$email" ]; then
  echo "error: configure public git user.name and user.email in project '$project' or home '$home' before launching a worker" >&2
  exit 1
fi
git -C "$wt" config --local user.name "$name"
git -C "$wt" config --local user.email "$email"
if [ "$(git -C "$wt" config --bool extensions.worktreeConfig || true)" = true ]; then
  git -C "$wt" config --worktree user.name "$name"
  git -C "$wt" config --worktree user.email "$email"
fi
