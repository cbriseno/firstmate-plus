#!/usr/bin/env bash
# The primary update preserves committed, staged, unstaged and untracked work.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.com
scratch=$(fm_test_tmproot fm-update-local)
trap 'fm_test_remove_tree "$scratch"' EXIT
mkdir -p "$scratch/home/state" "$scratch/home/data"
git init -q -b main "$scratch/origin"
printf 'base\n' > "$scratch/origin/file"
git -C "$scratch/origin" add file
git -C "$scratch/origin" commit -qm base
git clone -q "$scratch/origin" "$scratch/install"
printf 'own commit\n' > "$scratch/install/own"
git -C "$scratch/install" add own
git -C "$scratch/install" commit -qm own
printf 'staged\n' > "$scratch/install/staged"
git -C "$scratch/install" add staged
printf 'unstaged\n' >> "$scratch/install/staged"
printf 'new\n' > "$scratch/install/new"
printf 'remote\n' > "$scratch/origin/remote"
git -C "$scratch/origin" add remote
git -C "$scratch/origin" commit -qm remote
before=$(git -C "$scratch/install" status --porcelain)
FM_ROOT_OVERRIDE="$scratch/install" FM_HOME="$scratch/home" bash "$ROOT/bin/fm-update.sh" > "$scratch/out" 2>&1
[ -f "$scratch/install/remote" ] || fail 'remote content did not arrive'
[ "$(cat "$scratch/install/own")" = 'own commit' ] || fail 'local commit lost'
[ "$(cat "$scratch/install/new")" = new ] || fail 'untracked content lost'
[ "$(git -C "$scratch/install" show :staged)" = staged ] || fail 'staged content lost'
[ "$(cat "$scratch/install/staged")" = "$(printf 'staged\nunstaged')" ] || fail 'unstaged content lost'
[ "$(git -C "$scratch/install" status --porcelain)" = "$before" ] || fail 'index or working state changed'
git -C "$scratch/install" merge-base --is-ancestor origin/main HEAD || fail 'remote commit is not integrated'
# A conflicting remote edit must leave both the original commit and local edits.
printf 'local conflict\n' > "$scratch/install/file"
git -C "$scratch/install" add file
git -C "$scratch/install" commit -qm conflict
printf 'pending\n' >> "$scratch/install/file"
printf 'remote conflict\n' > "$scratch/origin/file"
git -C "$scratch/origin" add file
git -C "$scratch/origin" commit -qm conflict
before=$(git -C "$scratch/install" rev-parse HEAD)
FM_ROOT_OVERRIDE="$scratch/install" FM_HOME="$scratch/home" bash "$ROOT/bin/fm-update.sh" > "$scratch/out" 2>&1
[ "$(git -C "$scratch/install" rev-parse HEAD)" = "$before" ] || fail 'conflict moved local head'
[ "$(cat "$scratch/install/file")" = "$(printf 'local conflict\npending')" ] || fail 'conflict lost pending edit'
[ "$(cat "$scratch/install/new")" = new ] || fail 'conflict lost untracked file'
assert_contains "$(cat "$scratch/out")" 'integration failed' 'conflict is reported'
pass 'primary update preserves local work and rolls back a conflict'
