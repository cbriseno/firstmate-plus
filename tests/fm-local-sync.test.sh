#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export FM_LIVE=0
scratch=$(mktemp -d) || exit 1
trap 'fm_test_remove_tree "$scratch"' EXIT
script="$ROOT/bin/fm-local-sync.sh"
git init -q --bare "$scratch/origin.git"
git init -q -b main "$scratch/work"
git -C "$scratch/work" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m base
git --git-dir="$scratch/origin.git" fetch -q "$scratch/work" main:main
git -C "$scratch/work" remote add origin "$scratch/origin.git"
git -C "$scratch/work" checkout -qb local
printf 'private\n' > "$scratch/work/private"
git -C "$scratch/work" add private
git -C "$scratch/work" -c user.name=Test -c user.email=test@example.com commit -qm private
git clone -q -b main "$scratch/origin.git" "$scratch/upstream"
printf 'public\n' > "$scratch/upstream/public"
git -C "$scratch/upstream" add public
git -C "$scratch/upstream" -c user.name=Test -c user.email=test@example.com commit -qm update
git --git-dir="$scratch/origin.git" fetch -q "$scratch/upstream" main:main
bash "$script" "$scratch/work" --restart true > "$scratch/output" 2>&1
git -C "$scratch/work" merge-base --is-ancestor main local
[ "$(git -C "$scratch/work" rev-parse main)" = "$(git -C "$scratch/upstream" rev-parse main)" ]
grep -q 'Restart exit code: 0' "$scratch/output"
printf 'dirty\n' > "$scratch/work/dirty"
if bash "$script" "$scratch/work" > "$scratch/output" 2>&1; then exit 1; fi
grep -q 'dirty' "$scratch/output"
rm "$scratch/work/dirty"
git -C "$scratch/work" checkout -q main
if bash "$script" "$scratch/work" > "$scratch/output" 2>&1; then exit 1; fi
grep -q 'not local' "$scratch/output"
git -C "$scratch/work" checkout -q local
before=$(git -C "$scratch/work" rev-parse main)
git --git-dir="$scratch/origin.git" update-ref refs/heads/main "$(git -C "$scratch/work" rev-parse main^)"
if bash "$script" "$scratch/work" > "$scratch/output" 2>&1; then exit 1; fi
[ "$(git -C "$scratch/work" rev-parse main)" = "$before" ]
git --git-dir="$scratch/origin.git" update-ref refs/heads/main "$before"
printf 'conflict\n' > "$scratch/upstream/private"
git -C "$scratch/upstream" add private
git -C "$scratch/upstream" -c user.name=Test -c user.email=test@example.com commit -qm conflict
git --git-dir="$scratch/origin.git" fetch -q "$scratch/upstream" main:main
before=$(git -C "$scratch/work" rev-parse local)
if bash "$script" "$scratch/work" > "$scratch/output" 2>&1; then exit 1; fi
grep -q 'Rebase aborted' "$scratch/output"
[ "$(git -C "$scratch/work" rev-parse local)" = "$before" ]
[ -z "$(git -C "$scratch/work" status --porcelain)" ]
printf 'fm-local-sync: all cases passed\n'

# Auto-close and teardown share this content check; a squash must count as
# integrated even though the worker's commits are not ancestors of main.
# shellcheck source=bin/fm-local-branch-lib.sh
. "$ROOT/bin/fm-local-branch-lib.sh"
git init -q -b main "$scratch/content"
git -C "$scratch/content" config user.name Test
git -C "$scratch/content" config user.email test@example.invalid
printf 'base\n' > "$scratch/content/file"
git -C "$scratch/content" add file
git -C "$scratch/content" commit -qm base
git -C "$scratch/content" checkout -qb worker
printf 'work\n' > "$scratch/content/file"
git -C "$scratch/content" commit -qam work
if fm_local_content_in_ref "$scratch/content" main; then fail 'unintegrated content was accepted'; fi
git -C "$scratch/content" checkout -q main
git -C "$scratch/content" merge --squash worker >/dev/null
git -C "$scratch/content" commit -qm squash
printf 'unrelated\n' > "$scratch/content/other"
git -C "$scratch/content" add other
git -C "$scratch/content" commit -qm unrelated
git -C "$scratch/content" checkout -q worker
if git -C "$scratch/content" merge-base --is-ancestor HEAD main; then fail 'squash fixture is vacuous'; fi
fm_local_content_in_ref "$scratch/content" main || fail 'squashed content was not recognized'
printf 'more work\n' >> "$scratch/content/file"
git -C "$scratch/content" commit -qam more
if fm_local_content_in_ref "$scratch/content" main; then fail 'extra unintegrated content was accepted'; fi
printf 'integration content: unlanded refused, squash recognized, extra work refused\n'
