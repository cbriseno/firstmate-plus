#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-local.sh landing a branch that fell behind the
# default: it rebases and lands without running the publication batch, or
# refuses with the exact cause and changes no ref.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-autorebase)

# Project on main with a stub bin/fm-test-run.sh that records any invocation.
# The ship branch adds <ship file> and main then advances by one commit
# touching <main file> (conflicting when equal).
make_case() {  # <name> <main-file> <ship-file>
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  PROJ="$dir/projects/svc"
  ID="$1-t1"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$PROJ/bin"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" config user.name Test
  git -C "$PROJ" config user.email test@example.invalid
  printf 'base\n' > "$PROJ/shared"
  printf '#!/usr/bin/env bash\necho "$*" > "%s/ran"\n' "$dir" > "$PROJ/bin/fm-test-run.sh"
  chmod +x "$PROJ/bin/fm-test-run.sh"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -qm base
  git -C "$PROJ" checkout -qb "fm/$ID"
  printf 'ship\n' > "$PROJ/$3"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -qm ship
  git -C "$PROJ" checkout -q main
  printf 'other\n' > "$PROJ/$2"
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -qm other
  printf 'project=%s\nmode=local-only\nbranch=fm/%s\n' "$PROJ" "$ID" > "$HOME_DIR/state/$ID.meta"
}

land() {
  STATUS=0
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$MERGE_LOCAL" "$ID" 2>&1) || STATUS=$?
}

test_clean_rebase_lands_without_publication_batch() {
  make_case clean other ship
  local main_before; main_before=$(git -C "$PROJ" rev-parse main)
  land
  [ "$STATUS" -eq 0 ] || fail "a behind but non-conflicting branch did not land: $OUT"
  [ -f "$PROJ/ship" ] && [ -f "$PROJ/other" ] || fail "main lacks the rebased work"
  git -C "$PROJ" merge-base --is-ancestor "$main_before" main || fail "published main history was rewritten"
  [ "$(git -C "$PROJ" rev-parse main)" = "$(git -C "$PROJ" rev-parse "fm/$ID")" ] || fail "ship branch is not the landed head"
  [ ! -e "$TMP_ROOT/clean/ran" ] || fail "local integration ran the publication battery: $(cat "$TMP_ROOT/clean/ran")"
  pass "fm-merge-local: a behind branch rebases and lands without running the publication batch"
}

test_conflict_refuses_with_exact_cause_and_changes_nothing() {
  make_case conflict shared shared
  local m b; m=$(git -C "$PROJ" rev-parse main); b=$(git -C "$PROJ" rev-parse "fm/$ID")
  land
  [ "$STATUS" -eq 1 ] || fail "conflict did not refuse: $STATUS $OUT"
  assert_contains "$OUT" "conflicts in: shared" "the conflicting file was not named"
  [ "$(git -C "$PROJ" rev-parse main)" = "$m" ] && [ "$(git -C "$PROJ" rev-parse "fm/$ID")" = "$b" ] || fail "a ref moved on conflict"
  [ -z "$(git -C "$PROJ" status --porcelain)" ] || fail "project tree was touched"
  pass "fm-merge-local: a conflicting rebase refuses naming the file and moves nothing"
}

test_published_branch_is_not_rewritten() {
  make_case published other ship
  git -C "$PROJ" update-ref refs/remotes/origin/fm/"$ID" "fm/$ID"
  local b; b=$(git -C "$PROJ" rev-parse "fm/$ID")
  land
  [ "$STATUS" -eq 1 ] || fail "published branch was rebased: $STATUS $OUT"
  [ "$(git -C "$PROJ" rev-parse "fm/$ID")" = "$b" ] || fail "published branch moved"
  pass "fm-merge-local: a branch already on a remote is never rewritten"
}

test_worker_copy_stays_clean_after_rebase_landing() {
  make_case copy other ship
  local wt="$TMP_ROOT/copy/worker"
  git -C "$PROJ" worktree add -q "$wt" "fm/$ID" || fail "could not create the worker copy"
  printf 'scratch\n' > "$wt/untracked-note"
  land
  [ "$STATUS" -eq 0 ] || fail "a behind branch did not land: $OUT"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$PROJ" rev-parse main)" ] || fail "worker copy is not at the landed head"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || fail "worker copy shows the landed commits as changes: $(git -C "$wt" status --porcelain)"
  [ -f "$wt/other" ] || fail "worker copy lacks main's new files"
  [ -f "$wt/untracked-note" ] || fail "worker copy lost its own untracked file"
  pass "fm-merge-local: the worker copy follows the rebased branch and stays clean"
}

test_worker_copy_keeps_its_own_edits_after_rebase_landing() {
  make_case copyedit other ship
  local wt="$TMP_ROOT/copyedit/worker"
  git -C "$PROJ" worktree add -q "$wt" "fm/$ID" || fail "could not create the worker copy"
  printf 'edited\n' > "$wt/ship"
  land
  [ "$STATUS" -eq 0 ] || fail "a behind branch did not land: $OUT"
  [ "$(cat "$wt/ship")" = edited ] || fail "worker copy lost its uncommitted edit"
  [ "$(git -C "$wt" status --porcelain --untracked-files=no)" = " M ship" ] || fail "worker copy shows more than its own edit: $(git -C "$wt" status --porcelain)"
  pass "fm-merge-local: a worker copy with its own uncommitted edit keeps only that edit"
}

test_clean_rebase_lands_without_publication_batch
test_worker_copy_stays_clean_after_rebase_landing
test_worker_copy_keeps_its_own_edits_after_rebase_landing
test_conflict_refuses_with_exact_cause_and_changes_nothing
test_published_branch_is_not_rewritten
