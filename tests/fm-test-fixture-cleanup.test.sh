#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

# The usual call runs in a command substitution, so a failed registration must
# stop the calling test itself, not only the subshell: a test that continued
# with an empty root once resolved it to its working directory and removed it.
test_fixture_registration_failure_stops_the_test() {
  local harness failure_tmp registry_dir output rc leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  output=$(TMPDIR="$failure_tmp" bash -c '
    . "$1"
    FM_TEST_CLEANUP_REGISTRY=$2
    d=$(fm_test_tmproot fm-test-cleanup-registration-failure)
    printf "continued with root [%s]\n" "$d"
  ' _ "$LIB" "$registry_dir" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a test continued with exit 0 after fm_test_tmproot failed: $output"
  assert_not_contains "$output" "continued with root" \
    "a test kept running after fm_test_tmproot could not register its root"
  assert_contains "$output" "fm_test_tmproot could not create a fixture root" \
    "a failed fixture root did not report why the test stopped"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "a failed fixture registration rolls back the root and stops the test"
}

# A disposable copy of the checkout, so the cases below run real suites whose
# ROOT and working directory are that copy and never this checkout.
make_checkout_copy() {  # <dir>
  mkdir -p "$1"
  cp -R "$ROOT/bin" "$ROOT/tests" "$1/" || fail "could not copy the checkout into $1"
}

# The reproduction of the lost-checkout incident: the real suite that removed a
# worker's checkout, run from a copy whose TMPDIR cannot be written, used to
# pass with exit 0 after its cleanup removed the whole copy.
test_failed_setup_stops_the_real_suite_and_keeps_its_checkout() {
  local harness copy ro output rc
  harness=$(fm_test_tmproot fm-test-cleanup-setup-harness)
  copy="$harness/checkout"
  ro="$harness/read-only-tmp"
  make_checkout_copy "$copy"
  mkdir -p "$ro"
  chmod 555 "$ro"
  if ( : > "$ro/probe" ) 2>/dev/null; then
    chmod 755 "$ro"
    pass "skip: this user can write a mode-555 directory, so setup cannot be made to fail"
    return 0
  fi
  output=$(cd "$copy" && TMPDIR="$ro" bash tests/fm-parent-channel-scan-exclusion.test.sh 2>&1)
  rc=$?
  chmod 755 "$ro"
  assert_present "$copy/tests/lib.sh" \
    "a suite whose setup failed removed the checkout it ran from"
  [ "$rc" -ne 0 ] || fail "a suite whose setup failed still exited 0: $output"
  assert_contains "$output" "tests/lib.sh setup failed" \
    "a failed setup did not report itself"
  pass "a suite whose setup fails stops red and keeps the checkout it ran from"
}

# The runner removed a live suite's TMPDIR after tests/lib.sh had loaded, so the
# suite's next fixture root failed. The suite must stop before its own
# `cd "$TMP_ROOT"` and cleanup trap can resolve the empty root to its checkout.
test_deleted_tmpdir_stops_the_suite_and_keeps_its_checkout() {
  local harness copy tmp output rc
  harness=$(fm_test_tmproot fm-test-cleanup-deleted-tmp-harness)
  copy="$harness/checkout"
  tmp="$harness/runner-worker/tmp"
  make_checkout_copy "$copy"
  mkdir -p "$tmp"
  output=$(cd "$copy" && TMPDIR="$tmp" bash -c '
    . tests/lib.sh
    rm -rf -- "$1"
    TMP_ROOT=$(fm_test_tmproot fm-parent-channel-scan-exclusion)
    mkdir -p "$TMP_ROOT"
    TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
    cleanup() { rm -rf -- "$TMP_ROOT"; }
    trap cleanup EXIT
    printf "continued with root [%s]\n" "$TMP_ROOT"
  ' _ "$harness/runner-worker" 2>&1)
  rc=$?
  assert_present "$copy/tests/lib.sh" \
    "a suite whose TMPDIR was removed mid-run removed the checkout it ran from"
  [ "$rc" -ne 0 ] || fail "a suite whose TMPDIR was removed still exited 0: $output"
  assert_not_contains "$output" "continued with root" \
    "a suite kept running after its TMPDIR was removed"
  pass "a suite whose TMPDIR disappears stops red and keeps its checkout"
}

# Whatever produced the value, fm_test_remove_tree never reaches the checkout
# under test or its working directory, and never runs on an empty path.
test_removal_guard_protects_checkout_and_working_directory() {
  local harness copy work output rc
  harness=$(fm_test_tmproot fm-test-cleanup-guard-harness)
  copy="$harness/checkout"
  make_checkout_copy "$copy"
  work=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-unmarked-cwd.XXXXXX") ||
    fail "could not create an unmarked working directory"
  FM_TEST_CLEANUP_DIRS+=("$work")

  output=$(cd "$copy" && bash -c '
    . tests/lib.sh
    TMP_ROOT=""
    TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
    fm_test_remove_tree "$TMP_ROOT"
    printf "continued\n"
  ' 2>&1)
  rc=$?
  assert_present "$copy/tests/lib.sh" "an empty root resolved to the working directory removed the checkout"
  [ "$rc" -ne 0 ] || fail "removing the checkout was not a hard failure: $output"
  assert_not_contains "$output" "continued" "a test kept running after trying to remove its checkout"
  assert_contains "$output" "contains the firstmate checkout under test" \
    "the refusal did not name the checkout"

  output=$(cd "$copy/tests" && bash -c '. ./lib.sh; fm_test_remove_tree ../..; printf "continued\n"' 2>&1)
  rc=$?
  assert_present "$copy/tests/lib.sh" "removing a directory above the checkout removed it"
  [ "$rc" -ne 0 ] || fail "removing a directory above the checkout was not a hard failure: $output"
  assert_not_contains "$output" "continued" "a test kept running after trying to remove a directory above its checkout"

  output=$(cd "$work" && bash -c '. "$1"; fm_test_remove_tree "$PWD"; printf "continued\n"' _ "$copy/tests/lib.sh" 2>&1)
  rc=$?
  assert_present "$work" "a test removed its unmarked working directory"
  [ "$rc" -ne 0 ] || fail "removing the working directory was not a hard failure: $output"
  assert_not_contains "$output" "continued" "a test kept running after trying to remove its working directory"
  assert_contains "$output" "contains the working directory" \
    "the refusal did not name the working directory"

  output=$(cd "$copy" && bash -c '
    . tests/lib.sh
    fm_test_remove_tree "" || printf "empty path status: %s\n" "$?"
    d=$(fm_test_tmproot fm-test-cleanup-guard-allowed)
    mkdir -p "$d/sub" && ln -s "$ROOT" "$d/link-to-checkout"
    fm_test_remove_tree "$d/link-to-checkout" && fm_test_remove_tree "$d/sub"
    [ -e "$d/link-to-checkout" ] || [ -e "$d/sub" ] || printf "removed ordinary paths\n"
    cd "$d" && fm_test_remove_tree "$d" && [ ! -e "$d" ] && printf "removed own fixture working directory\n"
  ' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "ordinary removals failed under the guard: $output"
  assert_contains "$output" "empty path status: 1" "removing an empty path did not fail"
  assert_contains "$output" "refused to remove an empty path" "an empty path was not refused"
  assert_contains "$output" "removed ordinary paths" "the guard blocked an ordinary fixture removal"
  assert_contains "$output" "removed own fixture working directory" \
    "the guard blocked a test removing the fixture root it had entered"
  assert_present "$copy/tests/lib.sh" "removing a symlink to the checkout removed the checkout"
  pass "fixture removal refuses empty paths, the checkout, and an unmarked working directory"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  fm_test_remove_tree "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# A fixture poller that reparented to init and names its root on its command
# line - the shape of the leaked stub arms, hook-home watchers, and fake harness
# loops - must be stopped by the owning suite's teardown before the root is
# removed, rather than left polling for a file that removal makes impossible.
test_cleanup_reaps_orphaned_poller_naming_its_root() {
  local harness out child_dir poller i survivors
  harness=$(fm_test_tmproot fm-test-cleanup-poller-harness)
  out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-poller)
    printf "%s\n" "while [ ! -e \"\$1\" ]; do sleep 0.1; done" > "$d/poller.sh"
    ( bash "$d/poller.sh" "$d/never" </dev/null >/dev/null 2>&1 &
      printf "%s\n" "$!" > "'"$harness"'/poller.pid" )
    printf "%s\n" "$d"
  ')
  child_dir=$(printf '%s\n' "$out" | sed -n '1p')
  poller=$(cat "$harness/poller.pid" 2>/dev/null || true)
  [ -n "$poller" ] || fail "the child suite never started its poller"
  i=0
  while [ "$i" -lt 30 ] && kill -0 "$poller" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$poller" 2>/dev/null; then
    kill -KILL "$poller" 2>/dev/null || true
    fail "the owning suite's teardown left its fixture poller pid $poller running"
  fi
  survivors=$(ps -ww -eo pid=,args= | FM_ROOT_MATCH="$child_dir/" awk 'index($0, ENVIRON["FM_ROOT_MATCH"])')
  [ -z "$survivors" ] || fail "processes naming the removed fixture root survived: $survivors"
  assert_absent "$child_dir" "the fixture root survived its owning process's normal exit"
  pass "fm_test_cleanup stops an orphaned poller that names its fixture root"
}

test_registries_avoid_git_worktree_root() {
  # A TMPDIR pointed at a repository root used to place live `.fm-test-*`
  # registries beside tracked files. A concurrent git add during a suite then
  # committed them (observed on the claim-walk CI fix round). The helper must
  # keep registries and fixture roots outside that root for the whole run.
  local harness repo nested dirfile child_dir pid tries entry
  harness=$(fm_test_tmproot fm-test-cleanup-gitroot-harness)
  repo="$harness/repo"
  nested="$repo/nested/tmp"
  dirfile="$harness/child-dir"
  mkdir -p "$nested"
  git -C "$repo" init -q
  bash -c '
    export TMPDIR="$1"
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-gitroot)
    printf "%s\n" "$d" > "$3"
    # Hold the suite open so a concurrent add would see any root-side leak.
    while :; do sleep 0.1; done
  ' _ "$nested" "$LIB" "$dirfile" &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the git-root TMPDIR child never published its fixture root"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the nested git-root TMPDIR child did not create a fixture root"
  case "$child_dir" in
    "$repo"|"$repo"/*)
      fail "fm_test_tmproot placed a fixture root inside the git worktree root: $child_dir"
      ;;
  esac
  for entry in "$repo"/.fm-test-cleanup.* "$repo"/.fm-test-procevent.* "$repo"/.fm-test-watcher.*; do
    [ ! -e "$entry" ] || fail "a live test registry landed in the git worktree root: $entry"
  done
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  assert_absent "$child_dir" \
    "the nested git-root TMPDIR child's fixture root survived SIGTERM"
  pass "test registries and fixture roots stay outside every git-root TMPDIR ancestor"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_stops_the_test
test_failed_setup_stops_the_real_suite_and_keeps_its_checkout
test_deleted_tmpdir_stops_the_suite_and_keeps_its_checkout
test_removal_guard_protects_checkout_and_working_directory
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registries_avoid_git_worktree_root
test_cleanup_reaps_orphaned_poller_naming_its_root
