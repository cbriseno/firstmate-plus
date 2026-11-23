#!/usr/bin/env bash
# Behavioral regressions for bin/fm-overseer.sh setup: native loaders for the
# overseer contract, idempotence, and the refusals that keep a Firstmate
# contract out of the overseer's directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OVERSEER="$ROOT/bin/fm-overseer.sh"
TMP_ROOT=$(fm_test_tmproot fm-overseer)
CONTRACT=$(cd -P -- "$ROOT/overseer" && pwd -P)/AGENTS.md

make_home() {  # <dir>
  mkdir -p "$1" && : >"$1/SUPERVISOR.md"
}

test_setup_writes_native_loaders() {
  local home dir out real_home
  home="$TMP_ROOT/home-a"
  dir="$TMP_ROOT/outside/overseer"
  make_home "$home"
  real_home=$(cd -P -- "$home" && pwd -P)
  out=$(FM_HOME="$home" bash "$OVERSEER" setup "$dir" 2>&1) || fail "setup failed in a fresh directory: $out"
  [ "$(readlink "$dir/CLAUDE.md")" = "$CONTRACT" ] || fail "CLAUDE.md does not link to the contract"
  [ "$(readlink "$dir/AGENTS.md")" = "$CONTRACT" ] || fail "AGENTS.md does not link to the contract"
  [ "$(cat "$dir/firstmate-home")" = "$real_home" ] || fail "firstmate-home does not name the home"
  cmp -s "$dir/CLAUDE.md" "$CONTRACT" || fail "Claude's loader does not resolve to the contract text"
  assert_contains "$out" "OVERSEER_READY:" "setup did not report readiness"
  pass "setup links both harness loaders to the contract and names the home"

  out=$(FM_HOME="$home" bash "$OVERSEER" setup "$dir" 2>&1) || fail "a second setup failed: $out"
  assert_not_contains "$out" "OVERSEER_SETUP:" "a second setup rewrote an entry that already matched"
  pass "setup is idempotent"
}

test_setup_refuses_inside_a_firstmate_tree() {
  local home out
  home="$TMP_ROOT/home-b"
  make_home "$home"
  if out=$(FM_HOME="$home" bash "$OVERSEER" setup "$home/nested/overseer" 2>&1); then
    fail "setup accepted a directory inside a Firstmate home"
  fi
  assert_contains "$out" "holds SUPERVISOR.md" "the refusal does not name the reason"
  [ ! -e "$home/nested" ] || fail "a refused setup still created the directory"
  pass "setup refuses a directory inside a Firstmate home or copy without creating it"
}

test_setup_refuses_foreign_entries() {
  local home dir other out
  home="$TMP_ROOT/home-c"
  other="$TMP_ROOT/home-d"
  dir="$TMP_ROOT/outside/foreign"
  make_home "$home"
  make_home "$other"
  mkdir -p "$dir"
  printf 'my own notes\n' >"$dir/CLAUDE.md"
  if out=$(FM_HOME="$home" bash "$OVERSEER" setup "$dir" 2>&1); then
    fail "setup accepted a foreign CLAUDE.md"
  fi
  [ "$(cat "$dir/CLAUDE.md")" = "my own notes" ] || fail "setup changed a foreign CLAUDE.md"
  [ ! -e "$dir/AGENTS.md" ] && [ ! -e "$dir/firstmate-home" ] ||
    fail "a refused setup still wrote other entries"
  rm -f "$dir/CLAUDE.md"
  FM_HOME="$home" bash "$OVERSEER" setup "$dir" >/dev/null 2>&1 || fail "setup failed after the foreign file moved"
  if out=$(FM_HOME="$other" bash "$OVERSEER" setup "$dir" 2>&1); then
    fail "setup rebound a directory that oversees another home"
  fi
  assert_contains "$out" "oversees another home" "the rebind refusal does not name the reason"
  pass "setup refuses foreign entries and a directory bound to another home"
}

test_setup_refuses_a_non_home() {
  local out
  mkdir -p "$TMP_ROOT/not-a-home"
  if out=$(FM_HOME="$TMP_ROOT/not-a-home" bash "$OVERSEER" setup "$TMP_ROOT/outside/x" 2>&1); then
    fail "setup accepted a home without SUPERVISOR.md"
  fi
  assert_contains "$out" "not a Firstmate home" "the refusal does not name the reason"
  pass "setup refuses a directory that is not a Firstmate home"
}

test_setup_writes_native_loaders
test_setup_refuses_inside_a_firstmate_tree
test_setup_refuses_foreign_entries
test_setup_refuses_a_non_home
