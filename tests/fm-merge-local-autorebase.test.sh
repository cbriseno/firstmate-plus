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

test_remote_ready_line_lands_and_syncs() {
  local dir="$TMP_ROOT/remote" primary="$TMP_ROOT/remote/primary" remote="$TMP_ROOT/remote/home"
  local host_root="$TMP_ROOT/remote/host's checkout" fake="$TMP_ROOT/remote/ssh" remote_tip primary_tip
  mkdir -p "$primary/bin" "$primary/data" "$primary/state" "$primary/config"
  git -C "$primary" init -q -b main || fail "could not create primary"
  git -C "$primary" config user.name Test
  git -C "$primary" config user.email test@example.invalid
  printf 'data/\nstate/\nconfig/\n.fm-secondmate-*\n' > "$primary/.gitignore"
  printf '# Firstmate\n' > "$primary/AGENTS.md"
  cp "$ROOT/bin/fm-remote-file.sh" "$ROOT/bin/fm-captain-hold.sh" "$ROOT/bin/fm-remote-secondmate-control.sh" "$primary/bin/"
  cp "$ROOT/bin/fm-ff-lib.sh" "$ROOT/bin/fm-secondmate-registry-lib.sh" "$primary/bin/"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$primary/bin/fm-guard.sh"
  chmod +x "$primary/bin/fm-guard.sh"
  git -C "$primary" add -A
  git -C "$primary" commit -qm base
  git clone -q --no-hardlinks "$primary" "$remote" || fail "could not create remote home"
  git clone -q --no-hardlinks "$primary" "$host_root" || fail "could not create remote code root"
  git -C "$remote" config user.name Test
  git -C "$remote" config user.email test@example.invalid
  git -C "$remote" checkout -qb fm/return-task
  printf 'from the remote\n' > "$remote/delivered"
  git -C "$remote" add delivered
  git -C "$remote" commit -qm 'Remote delivery'
  remote_tip=$(git -C "$remote" rev-parse HEAD)
  git -C "$remote" checkout -q main
  git -C "$primary" commit -qm 'Primary advanced while worker ran' --allow-empty
  primary_tip=$(git -C "$primary" rev-parse HEAD)
  mkdir -p "$remote/state" "$remote/data"
  printf 'mobile\n' > "$remote/.fm-secondmate-home"
  printf 'kind=ship\nmode=local-only\nproject=%s\nbranch=fm/return-task\n' "$remote" > "$remote/state/return-task.meta"
  printf 'done [at=1]: ready in branch fm/return-task\n' > "$remote/state/return-task.status"
  printf '%s\n' "- mobile - remote route (host: remote-mac; root: $host_root; home: $remote; scope: delivery; projects: none; added 2026-11-24)" > "$primary/data/secondmates.md"
  printf 'kind=secondmate\nbackend=remote\nwindow=remote:mobile\nendpoint_task_id=mobile\nhome=%s\nremote_host=remote-mac\nremote_root=%s\n' \
    "$remote" "$host_root" > "$primary/state/mobile.meta"
  printf '\n- firstmate [local-only] - project\n' > "$primary/data/projects.md"
  printf 'done [key=child-outcome-return-task-done-aabbccdd] [at=2]: child return-task done: ready in branch fm/return-task mode=local-only yolo=off head=%s\n' \
    "$remote_tip" > "$primary/state/mobile.status"
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "${1:-}" = -o ]; do shift 2; done
[ "${1:-}" != -- ] || shift
[ "$1" = remote-mac ] || exit 91
shift
case "$1" in
  'git-upload-pack '*|'git-receive-pack '*|'bash -s -- '*) exec bash -c "$1" ;;
  fm-remote-entrypoint.sh) ;;
  *) exit 92 ;;
esac
decode_argv() {
  printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D
}
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(decode_argv "$5")
case "${args[0]}:${args[1]}" in
  fm-remote-secondmate-control.sh:send)
    printf '%s\n' "${args[3]}" >> "$LAND_SEND"
    exit 0 ;;
  fm-remote-secondmate-control.sh:sync)
    [ ! -f "$LAND_REJECT_SYNC" ] || exit 255 ;;
esac
FM_HOME="$LAND_REMOTE" FM_ROOT_OVERRIDE="$LAND_HOST_ROOT" exec "$LAND_TOOLS/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$fake"
  (
    export FM_HOME="$primary" FM_ROOT_OVERRIDE="$primary" FM_SSH_BIN="$fake" FM_SEND_REMOTE_BUDGET=120
    export LAND_TOOLS="$ROOT" LAND_REMOTE="$remote" LAND_HOST_ROOT="$host_root"
    export LAND_SEND="$dir/delivered-message" LAND_REJECT_SYNC="$dir/reject-sync"
    # An existing installation has acknowledged this revision in its home,
    # although its transport still executes from an older root checkout.
    git -C "$host_root" fetch -q "$primary" "$primary_tip:refs/fm/primary-main"
    git -C "$remote" fetch -q "$host_root" "$primary_tip"
    git -C "$remote" merge -q --ff-only "$primary_tip"
    printf '%s\n' "$primary_tip" > "$primary/state/.remote-main-mobile"
    printf '# Uncommitted work\n' >> "$host_root/AGENTS.md"
    if "$ROOT/bin/fm-remote-land.sh" --sync; then
      fail "a dirty code root was reported as synchronized"
    fi
    assert_grep '# Uncommitted work' "$host_root/AGENTS.md" "the root's edit was overwritten"
    [ "$(< "$primary/state/.remote-main-mobile")" = "$primary_tip" ] || fail "the incomplete sync was acknowledged"
    git -C "$host_root" checkout -q -- AGENTS.md
    "$ROOT/bin/fm-remote-land.sh" --tick 2>&1 || true
    [ "$(git -C "$primary" rev-parse main)" = "$primary_tip" ] || fail "yolo off allowed automatic integration"
    [ "$(git -C "$host_root" rev-parse HEAD)" = "$primary_tip" ] || fail "the code root stayed behind an already synced home"
    printf '\n- firstmate [local-only +yolo] - project\n' > "$primary/data/projects.md"
    touch "$LAND_REJECT_SYNC"
    "$ROOT/bin/fm-remote-land.sh" --tick 2>&1 || true
    [ -f "$primary/delivered" ] || fail "the remote ready branch did not land on primary main"
    [ -f "$LAND_SEND" ] && fail "the official was notified before sync"
    [ "$(git -C "$primary" rev-parse "refs/remotes/mobile/fm/return-task")" = "$remote_tip" ] || fail "the fetched source was rewritten"
    git -C "$primary" merge-base --is-ancestor "$primary_tip" main || fail "primary history was rewritten"
    rm -f -- "$LAND_REJECT_SYNC"
    "$ROOT/bin/fm-remote-land.sh" --tick 2>&1 || true
    [ "$(git -C "$remote" rev-parse main)" = "$(git -C "$primary" rev-parse main)" ] || fail "the remote home did not synchronize on retry"
    assert_grep 'primary integrated return-task' "$LAND_SEND" "the official did not receive the landing confirmation"
    "$ROOT/bin/fm-remote-land.sh" --tick 2>&1 || true
    [ "$(wc -l < "$LAND_SEND")" -eq 1 ] || fail "the ready line replayed its acknowledgement"

    git -C "$primary" checkout -qb fm/local-followup
    printf 'ordinary local follow-up\n' > "$primary/followup"
    git -C "$primary" add followup
    git -C "$primary" commit -qm 'Ordinary local integration'
    git -C "$primary" checkout -q main
    printf 'project=%s\nmode=local-only\nbranch=fm/local-followup\n' "$primary" > "$primary/state/local-followup.meta"
    # Registered machines still receive integrations when no agent is running.
    mv "$primary/state/mobile.meta" "$dir/stopped-mate.meta"
    "$MERGE_LOCAL" local-followup || fail "ordinary local merge did not land"
    local deadline=$((SECONDS + 180)) landed
    landed=$(git -C "$primary" rev-parse main)
    while { [ "$(git -C "$remote" rev-parse main)" != "$landed" ] ||
            [ "$(git -C "$host_root" rev-parse HEAD)" != "$landed" ]; } && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.1
    done
    [ "$(git -C "$remote" rev-parse main)" = "$landed" ] || fail "ordinary local merge did not propagate automatically"
    [ "$(git -C "$host_root" rev-parse HEAD)" = "$landed" ] || fail "remote commands still run from the previous checkout"
    [ "$(git -C "$host_root" rev-parse origin/main)" != "$landed" ] || fail "the private sync moved origin/main"
    [ -f "$remote/state/return-task.status" ] || fail "remote home state was lost"
  ) || exit 1
  pass "a mirrored remote ready line returns and rebases its branch, retries sync and confirms once"
}

test_remote_ready_line_lands_and_syncs
