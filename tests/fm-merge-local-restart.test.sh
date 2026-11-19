#!/usr/bin/env bash
# Behavior tests for the restart that bin/fm-merge-local.sh runs after landing
# local-only work in a project that declares a service in config/restart/<project>.
# The declared commands are stand-ins that write marker files; no real service
# is ever restarted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-restart)

# Sets HOME_DIR PROJ ID MARK for one case: a project "svc" on main (or, with
# <integration> = yes, on a private "local" branch above main) and a ship
# branch one commit ahead of main, plus the task's meta record.
make_case() {  # <name> <integration: yes|no> [conflict]
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  PROJ="$dir/projects/svc"
  ID="$1-t1"
  MARK="$dir/marks"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$PROJ" "$MARK"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" config user.name Test
  git -C "$PROJ" config user.email test@example.invalid
  printf 'base\n' > "$PROJ/file"
  git -C "$PROJ" add file
  git -C "$PROJ" commit -qm base
  git -C "$PROJ" checkout -qb "fm/$ID"
  if [ "${3:-}" = conflict ]; then printf 'ship\n' > "$PROJ/file"; else printf 'ship\n' > "$PROJ/ship"; fi
  git -C "$PROJ" add -A
  git -C "$PROJ" commit -qm ship
  git -C "$PROJ" checkout -q main
  if [ "$2" = yes ]; then
    git -C "$PROJ" checkout -qb local
    if [ "${3:-}" = conflict ]; then printf 'private\n' > "$PROJ/file"; else printf 'private\n' > "$PROJ/private"; fi
    git -C "$PROJ" add -A
    git -C "$PROJ" commit -qm private
  fi
  printf 'project=%s\nmode=local-only\nbranch=fm/%s\n' "$PROJ" "$ID" > "$HOME_DIR/state/$ID.meta"
}

declare_restart() {  # <restart command> [<verify command>]
  mkdir -p "$HOME_DIR/config/restart"
  {
    printf 'restart=%s\n' "$1"
    [ -z "${2:-}" ] || printf 'verify=%s\n' "$2"
  } > "$HOME_DIR/config/restart/svc"
}

land() {  # sets OUT and STATUS
  STATUS=0
  OUT=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_RESTART_VERIFY_WAIT=0 "$MERGE_LOCAL" "$ID" 2>&1) || STATUS=$?
}

test_integration_branch_restarts_after_rebase_then_verifies() {
  make_case integration yes
  declare_restart "cat '$PROJ/ship' > '$MARK/restart'" "cat '$MARK/restart' >/dev/null && cat '$PROJ/private' > '$MARK/verify'"
  land
  [ "$STATUS" -eq 0 ] || fail "landing failed: $OUT"
  # The restart saw the rebased checkout (ship and private both present) and ran before verify.
  [ -f "$MARK/restart" ] || fail "the declared restart did not run: $OUT"
  [ -f "$MARK/verify" ] || fail "the declared verify did not run after the restart: $OUT"
  assert_contains "$OUT" "restarted svc" "output did not report the restart"
  assert_contains "$OUT" "verified svc responds" "output did not report the verification"
  pass "fm-merge-local: a declared restart and verify run after the integration branch is rebased"
}

test_default_branch_checkout_restarts() {
  make_case plain no
  declare_restart "touch '$MARK/restart'" "test -f '$MARK/restart'"
  land
  [ "$STATUS" -eq 0 ] || fail "landing failed: $OUT"
  [ -f "$MARK/restart" ] || fail "no restart after a plain fast-forward: $OUT"
  assert_contains "$OUT" "verified svc responds" "output did not report the verification"
  pass "fm-merge-local: a project without an integration branch restarts after the fast-forward"
}

test_no_declaration_changes_nothing() {
  make_case none yes
  land
  [ "$STATUS" -eq 0 ] || fail "landing failed: $OUT"
  assert_not_contains "$OUT" "restarted svc" "a project with no declaration was restarted"
  pass "fm-merge-local: a project that declares no restart is left alone"
}

test_failures_warn_without_failing_the_merge() {
  make_case badrestart yes
  declare_restart "exit 7" "touch '$MARK/verify'"
  land
  [ "$STATUS" -eq 0 ] || fail "a failed restart changed the merge result: $OUT"
  assert_contains "$OUT" "restart command failed" "a failed restart was not reported"
  [ ! -f "$MARK/verify" ] || fail "verify ran after a failed restart"
  make_case badverify yes
  declare_restart "touch '$MARK/restart'" "exit 1"
  land
  [ "$STATUS" -eq 0 ] || fail "a failed verify changed the merge result: $OUT"
  assert_contains "$OUT" "did not answer its verify command" "a failed verify was not reported"
  pass "fm-merge-local: a failing restart or verify warns and leaves the merge successful"
}

test_conflicted_rebase_does_not_restart() {
  make_case conflict yes conflict
  declare_restart "touch '$MARK/restart'"
  land
  [ "$STATUS" -eq 3 ] || fail "conflict case did not exit 3: $STATUS $OUT"
  [ ! -f "$MARK/restart" ] || fail "restarted although the integration rebase was aborted"
  pass "fm-merge-local: no restart when the integration rebase conflicts"
}

test_integration_branch_restarts_after_rebase_then_verifies
test_default_branch_checkout_restarts
test_no_declaration_changes_nothing
test_failures_warn_without_failing_the_merge
test_conflicted_rebase_does_not_restart
