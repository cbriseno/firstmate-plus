#!/usr/bin/env bash
# Tests for fm-primary-effort.sh: config/primary-effort reaches both harnesses' project-local settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-effort)
SCRIPT="$ROOT/bin/fm-primary-effort.sh"

new_home() { # <name> <config-content|->
  local h=$TMP_ROOT/$1
  mkdir -p "$h/config"
  [ "$2" = - ] || printf '%s\n' "$2" >"$h/config/primary-effort"
  printf '%s' "$h"
}

test_writes_both_harnesses_keeping_other_keys() {
  local h out
  h=$(new_home keep low)
  mkdir -p "$h/.claude" "$h/.codex"
  printf '{"permissions":{"allow":["Bash(x)"]},"effortLevel":"high"}\n' >"$h/.claude/settings.local.json"
  printf 'model = "m"\nmodel_reasoning_effort = "high"\n\n[projects]\nx = 1\n' >"$h/.codex/config.toml"
  out=$(bash "$SCRIPT" "$h")
  assert_contains "$out" "set primary effort low" "no report of the write"
  assert_equals low "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["effortLevel"])' "$h/.claude/settings.local.json")" "claude effortLevel not applied"
  assert_contains "$(cat "$h/.claude/settings.local.json")" 'Bash(x)' "claude settings lost other keys"
  assert_equals 'model = "m"
model_reasoning_effort = "low"

[projects]
x = 1' "$(cat "$h/.codex/config.toml")" "codex toml wrong"
  pass "applies the level to Claude and Codex and keeps other settings"
}

test_creates_files_and_is_idempotent() {
  local h out
  h=$(new_home fresh medium)
  bash "$SCRIPT" "$h" >/dev/null
  assert_equals 'model_reasoning_effort = "medium"' "$(cat "$h/.codex/config.toml")" "codex file not created"
  assert_contains "$(cat "$h/.claude/settings.local.json")" '"effortLevel": "medium"' "claude file not created"
  out=$(bash "$SCRIPT" "$h")
  assert_equals "" "$out" "second run is not silent"
  pass "creates missing files and is silent when already applied"
}

test_toml_key_after_table_is_inserted_on_top() {
  local h
  h=$(new_home table high)
  mkdir -p "$h/.codex"
  printf '[projects]\nmodel_reasoning_effort = "low"\n' >"$h/.codex/config.toml"
  bash "$SCRIPT" "$h" >/dev/null
  assert_equals 'model_reasoning_effort = "high"
[projects]
model_reasoning_effort = "low"' "$(cat "$h/.codex/config.toml")" "table key was touched or top key missing"
  pass "only the top-level key is managed"
}

test_other_values_change_nothing() {
  local h v
  for v in configured default max bogus -; do
    h=$(new_home "skip-$v" "$v")
    bash "$SCRIPT" "$h" >/dev/null
    [ ! -e "$h/.claude" ] && [ ! -e "$h/.codex" ] || fail "value '$v' wrote files"
  done
  h=$(new_home nofile -)
  bash "$SCRIPT" "$h" >/dev/null
  [ ! -e "$h/.claude" ] || fail "absent config wrote files"
  pass "absent, configured, default and invalid values change nothing"
}

test_writes_both_harnesses_keeping_other_keys
test_creates_files_and_is_idempotent
test_toml_key_after_table_is_inserted_on_top
test_other_values_change_nothing
