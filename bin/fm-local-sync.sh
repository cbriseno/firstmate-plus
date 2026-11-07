#!/usr/bin/env bash
# Usage: fm-local-sync.sh <repo> [--restart <command...>]
set -u
# shellcheck source=bin/fm-local-branch-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-local-branch-lib.sh"

fail() { printf '%s\n' "$1" >&2; exit 1; }
[ "$#" -ge 1 ] || fail 'Usage: fm-local-sync.sh <repo> [--restart <command...>]'
repo=$1
shift
if [ "$#" -gt 0 ]; then
  [ "$1" = --restart ] && [ "$#" -ge 2 ] || fail 'Expected --restart followed by a command'
  shift
fi
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || fail 'Not a Git repository'
[ -z "$(git -C "$repo" status --porcelain)" ] || fail 'Working tree is dirty'
branch=$(fm_local_integration_branch "$repo") || fail 'Invalid local integration branch'
[ "$(git -C "$repo" symbolic-ref --quiet --short HEAD)" = "$branch" ] || fail "Current branch is not $branch"
git -C "$repo" remote get-url origin >/dev/null 2>&1 || fail 'Remote origin does not exist'
git -C "$repo" show-ref --verify --quiet refs/heads/main || fail 'Branch main does not exist'
main_before=$(git -C "$repo" rev-parse main)
local_before=$(git -C "$repo" rev-parse "$branch")
git -C "$repo" fetch origin main:main || fail 'Fetch failed; main and local remain unchanged'
name=$(git -C "$repo" config user.name || true)
email=$(git -C "$repo" config user.email || true)
[ -n "$name" ] || name=$(git -C "$repo" show -s --format=%an "$branch")
[ -n "$email" ] || email=$(git -C "$repo" show -s --format=%ae "$branch")
if ! git -C "$repo" -c "user.name=$name" -c "user.email=$email" rebase main; then
  git -C "$repo" rebase --abort || fail 'Rebase abort failed; inspect local and main'
  fail 'Rebase aborted; local is unchanged and main retains the fetched update'
fi
result=0
if [ "$#" -gt 0 ]; then
  "$@" || result=$?
  printf 'Restart exit code: %s\n' "$result"
fi
printf 'main: %s -> %s; local: %s -> %s\n' "$main_before" "$(git -C "$repo" rev-parse main)" "$local_before" "$(git -C "$repo" rev-parse "$branch")"
exit "$result"
