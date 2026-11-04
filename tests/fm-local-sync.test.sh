#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export FM_LIVE=0
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
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
