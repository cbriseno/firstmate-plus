#!/usr/bin/env bash
# Credentialed Codex activity proof. Uses the REAL fm-spawn launch captured
# through the existing fake-pane fixture, then executes it with the installed
# native Codex in a private tmux server and a disposable CODEX_HOME. Only auth
# is copied; user settings, hooks, trust, servers and conversations are untouched.
# Real prompts cover a long tool, completion, Escape, replacement and API error.
# Refresh docs/verification/runtime-backends.md after upgrading Codex.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_CODEX_ACTIVITY_LIVE codex tmux python3

version=$(codex --version 2>/dev/null)
[ "$version" = 'codex-cli 0.166.0' ] || fail "Codex activity guard needs refreshed evidence for $version"
[ "$(uname -s)" = Linux ] || fail "$version: native rollout ownership needs Linux /proc"
TMP_ROOT=$(fm_test_tmproot fm-codex-activity-live)
activity_home="$TMP_ROOT/home"
project="$TMP_ROOT/project"
wt="$TMP_ROOT/wt"
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
fm_test_spawn_home "$activity_home" codex
fm_test_spawn_brief "$activity_home" activity-proof
fm_git_worktree "$project" "$wt" activity-proof
launchlog="$TMP_ROOT/launch"
FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$activity_home" "$wt" "$fakebin" \
  activity-proof "$project" --mode local-only --yolo off --model gpt-6.1-sol --effort low \
  > "$TMP_ROOT/spawn-output" 2>&1 || fail "Codex $version: failed to capture real fm-spawn launch"

auth="${CODEX_HOME:-$HOME/.codex}/auth.json"
[ -f "$auth" ] || fail "Codex $version: this private guard needs a readable auth.json; no credential-store changes made"
mkdir -p "$TMP_ROOT/codex"
install -m 600 "$auth" "$TMP_ROOT/codex/auth.json"
FM_ACTIVITY_ROOT="$ROOT" FM_ACTIVITY_LAB="$TMP_ROOT" \
  python3 "$ROOT/tests/fixtures/codex-activity-live.py"
