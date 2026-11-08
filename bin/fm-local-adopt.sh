#!/usr/bin/env bash
# Usage: fm-local-adopt.sh <repo> <rebased-branch>
# Move a checkout's local integration branch (bin/fm-local-branch-lib.sh) to a
# branch a worker rebased onto main after fm-merge-local.sh or fm-local-sync.sh
# reported a conflict. Refuses unless the checkout is clean and on that branch,
# the target contains main and carries the same number of commits on top of main
# as the current branch; saves the old head as local-backup-<timestamp> first.
set -u
# shellcheck source=bin/fm-local-branch-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-local-branch-lib.sh"
fail() { printf '%s\n' "$1" >&2; exit 1; }
[ "$#" -eq 2 ] || fail 'Usage: fm-local-adopt.sh <repo> <rebased-branch>'
repo=$1 target=$2
branch=$(fm_local_integration_branch "$repo") || fail 'Invalid local integration branch'
[ "$(git -C "$repo" symbolic-ref --quiet --short HEAD)" = "$branch" ] || fail "Current branch is not $branch"
[ -z "$(git -C "$repo" status --porcelain)" ] || fail 'Working tree is dirty'
git -C "$repo" rev-parse --verify --quiet "refs/heads/$target" >/dev/null || fail "Branch $target does not exist"
git -C "$repo" merge-base --is-ancestor main "$target" || fail "$target does not contain main; rebase it onto main first"
mine=$(git -C "$repo" rev-list --count "main..$branch") theirs=$(git -C "$repo" rev-list --count "main..$target")
[ "$mine" = "$theirs" ] || fail "$target carries $theirs commits on main, $branch carries $mine; refusing"
backup="local-backup-$(date +%Y%m%d%H%M%S)"
before=$(git -C "$repo" rev-parse --short "$branch")
git -C "$repo" branch "$backup" "$branch" || fail 'Could not create the backup branch'
git -C "$repo" reset --quiet --keep "$target" || fail "Reset refused; $branch unchanged (backup $backup)"
printf '%s: %s -> %s (backup %s)\n' "$branch" "$before" "$(git -C "$repo" rev-parse --short "$branch")" "$backup"
