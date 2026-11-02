#!/usr/bin/env bash
# tests/fm-install-followup.test.sh - bin/fm-install-followup.sh carries a
# captain's request from a project into the linked local installation its
# registry entry names (install=<project>). tests/fm-backlog-atomicity.test.sh
# pins the dispatch and teardown halves through the real spawn and teardown;
# this file pins what those callers do not reach:
#   1. brief scaffolds the follow-up through the real bin/fm-brief.sh with both
#      Task subsections filled - the original captain intent verbatim, where it
#      landed, and the integration spec - in the installation's registered mode,
#      and prints the spawn command with that installation's yolo.
#   2. brief refuses a registered no-mistakes-prod-only installation without
#      --mode, because that surface classification belongs to intake.
#   3. landed --discarded says the follow-up has nothing new to bring.
#   4. A hand-edited backlog is handed the add command instead of a filed row.
#   5. An unlinked project is a silent no-op for every subcommand.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :
FOLLOWUP="$ROOT/bin/fm-install-followup.sh"
TMP_ROOT=$(fm_test_tmproot fm-install-followup)
cd "$TMP_ROOT" || exit 1

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the follow-up is a tasks-axi row)\n'
  exit 0
}

make_home() {  # <name> -> home dir with a linked registry and a landed task t1
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config" "$home/state" "$home/projects/fork/.git"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  cat > "$home/data/projects.md" <<'EOF'
- fork [no-mistakes-prod-only +yolo install=private] - a public fork (added 2026-01-01)
- private [local-only +yolo] - the captain's private installation (added 2026-01-01)
- deck [direct-PR install=deck-private] - a fork whose installation is itself a policy (added 2026-01-01)
- deck-private [no-mistakes-prod-only] - an installation registered as a policy (added 2026-01-01)
- plain [direct-PR] - a project with no installation (added 2026-01-01)
EOF
  mkdir -p "$home/data/t1"
  cat > "$home/data/t1/brief.md" <<'EOF'
# Task
## Captain's intent
si yo lo pedi es porque lo necesito: make the widget work in my local setup

## Firstmate spec
Add the widget.

# Definition of done
Delivery contract: mode=direct-PR
EOF
  (cd "$home" && tasks-axi add t1 "the widget" --kind ship --repo fork --file data/backlog.md >/dev/null \
    && tasks-axi start t1 --file data/backlog.md >/dev/null \
    && tasks-axi 'done' t1 --pr https://github.com/o/fork/pull/7 --file data/backlog.md >/dev/null) \
    || fail "could not seed the landed task"
  printf '%s\n' "$home"
}

run_followup() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$FOLLOWUP" "$@"
}

test_brief_carries_the_intent_into_the_installation() {
  local home out brief intent spec
  home=$(make_home brief)
  out=$(run_followup "$home" brief t1 fork 2>&1) || fail "brief failed: $out"
  brief="$home/data/t1-install/brief.md"
  [ -f "$brief" ] || fail "brief wrote no follow-up brief"
  assert_grep "Delivery contract: mode=local-only" "$brief" "the follow-up does not ship in the installation's registered mode"
  if grep -qxF '{TASK}' "$brief" || grep -qxF '{FIRSTMATE_SPEC}' "$brief"; then
    fail "the follow-up brief kept a scaffold placeholder"
  fi
  intent=$(sed -n "/^## Captain's intent$/,/^## Firstmate spec$/p" "$brief")
  assert_contains "$intent" "si yo lo pedi es porque lo necesito: make the widget work in my local setup" \
    "the original captain intent was not carried verbatim"
  assert_contains "$intent" "landed first in fork as https://github.com/o/fork/pull/7" "the intent does not say where it landed"
  assert_contains "$intent" "works in this linked local installation, private" "the intent does not say it must work in the installation"
  spec=$(sed -n "/^## Firstmate spec$/,/^# /p" "$brief")
  assert_contains "$spec" "into private, the local installation fork is linked to" "the spec does not name the integration"
  assert_contains "$spec" "$home/projects/fork" "the spec does not point at the clone holding the landed work"
  assert_contains "$spec" "run this project's affected local checks" "the spec does not require local checks"
  assert_contains "$out" "next: bin/fm-spawn.sh t1-install <private project directory> --mode local-only --yolo on" \
    "brief did not print the spawn command with the installation's posture"
  pass "fm-install-followup: brief carries the captain intent, the landing, and the integration spec into the installation's mode"
}

test_brief_needs_a_mode_for_a_policy_installation() {
  local home out rc=0
  home=$(make_home policy)
  (cd "$home" && tasks-axi add t2 "deck" --kind ship --repo deck --file data/backlog.md >/dev/null)
  mkdir -p "$home/data/t2"
  cp "$home/data/t1/brief.md" "$home/data/t2/brief.md"
  out=$(run_followup "$home" brief t2 deck 2>&1) || rc=$?
  expect_code 2 "$rc" "a policy installation must need --mode"
  assert_contains "$out" "pass --mode" "the refusal does not say how to proceed"
  [ ! -e "$home/data/t2-install/brief.md" ] || fail "a refused brief still wrote a follow-up brief"
  out=$(run_followup "$home" brief t2 deck --mode direct-PR 2>&1) || fail "brief with --mode failed: $out"
  assert_grep "Delivery contract: mode=direct-PR" "$home/data/t2-install/brief.md" "--mode was not honored"
  pass "fm-install-followup: brief needs --mode for an installation registered as a policy, then honors it"
}

test_discarded_landing_has_nothing_to_bring() {
  local home out
  home=$(make_home discarded)
  run_followup "$home" ensure t1 fork >/dev/null || fail "ensure failed"
  out=$(run_followup "$home" landed t1 fork --discarded 2>&1) || fail "landed --discarded failed: $out"
  assert_contains "$out" "t1-install has nothing new to bring" "a discarded landing still reads as ready to install"
  assert_not_contains "$out" "is ready now" "a discarded landing asked for a dispatch"
  pass "fm-install-followup: a discarded landing says its follow-up has nothing new to bring"
}

test_hand_edited_backlog_gets_the_add_command() {
  local home out
  home=$(make_home manual)
  printf '%s\n' manual > "$home/config/backlog-backend"
  out=$(run_followup "$home" ensure t1 fork 2>&1) || fail "ensure failed on a hand-edited backlog: $out"
  assert_contains "$out" "queue t1-install ('Install t1 into private', repo private) blocked by t1 yourself" \
    "a hand-edited backlog was not told what to file"
  assert_not_contains "$(cat "$home/data/backlog.md")" "t1-install" "a hand-edited backlog was written"
  pass "fm-install-followup: a hand-edited backlog is handed the add command rather than written"
}

test_unlinked_project_is_a_no_op() {
  local home sub out
  home=$(make_home unlinked)
  for sub in ensure landed; do
    out=$(run_followup "$home" "$sub" t1 plain 2>&1) || fail "$sub failed for an unlinked project: $out"
    [ -z "$out" ] || fail "$sub spoke for an unlinked project: $out"
  done
  out=$(run_followup "$home" brief t1 plain 2>&1) || fail "brief failed for an unlinked project: $out"
  [ -z "$out" ] && [ ! -e "$home/data/t1-install" ] || fail "brief scaffolded a follow-up for an unlinked project"
  [ -z "$(cd "$home" && tasks-axi show t1-install --file data/backlog.md 2>/dev/null | sed -n 's/^  state: *//p')" ] \
    || fail "an unlinked project got a follow-up row"
  pass "fm-install-followup: an unlinked project is a silent no-op for every subcommand"
}

test_brief_carries_the_intent_into_the_installation
test_brief_needs_a_mode_for_a_policy_installation
test_discarded_landing_has_nothing_to_bring
test_hand_edited_backlog_gets_the_add_command
test_unlinked_project_is_a_no_op

echo "# fm-install-followup.test.sh: all assertions passed"
