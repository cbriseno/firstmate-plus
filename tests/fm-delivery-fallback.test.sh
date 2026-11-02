#!/usr/bin/env bash
# tests/fm-delivery-fallback.test.sh - bin/fm-delivery-fallback.sh switches a
# ship already under way to a less rigorous delivery path when a captain rule
# made its selected path unavailable, without a captain question.
# Driven through the real executable, the real bin/fm-brief.sh scaffold, and
# the real bin/fm-send.sh inbox plane over a stubbed tmux, it pins:
#   1. no-mistakes -> direct-PR re-renders the brief's Definition of done and
#      rule 1, records mode= and fallback_from= while keeping yolo= and upstream
#      consent, and durably steers the worker with the full new contract.
#   2. --resolve-key closes the worker's open delivery-fallback blocker.
#   3. A re-run resends the steer without changing the brief or the record.
#   4. direct-PR -> local-only drops upstream consent, which local-only never
#      uses, from both the contract and the record.
#   5. A switch that adds rigor, a forge-bound task falling back to local-only,
#      and a non-ship task are refused with nothing changed and nothing sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FALLBACK="$ROOT/bin/fm-delivery-fallback.sh"
BRIEF_SH="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-delivery-fallback)

make_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-t1\nwin\n'; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
}

# A home holding ship task t1 with a scaffolded brief in <mode>.
setup_case() {  # <name> <mode> [extra fm-brief args...]
  local dir="$TMP_ROOT/$1" mode=$2
  shift 2
  mkdir -p "$dir/home/state" "$dir/home/data"
  make_fakebin "$dir"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" "$BRIEF_SH" t1 proj --mode "$mode" "$@" >/dev/null \
    || fail "could not scaffold a $mode brief"
  sed -i.bak -e 's/^{TASK}$/ship the widget/' -e 's/^{FIRSTMATE_SPEC}$/Add the widget./' "$dir/home/data/t1/brief.md"
  rm -f "$dir/home/data/t1/brief.md.bak"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude" \
    "mode=$mode" "yolo=on" "worktree=$dir/wt" "project=$dir/proj"
  printf '%s\n' "$dir"
}

run_fallback() {  # <case-dir> <args...>
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" FM_SEND_SETTLE=0 \
    "$FALLBACK" t1 "$@" >"$dir/out" 2>"$dir/err"
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_no_mistakes_falls_back_to_direct_pr() {
  local dir brief meta body rc
  dir=$(setup_case nm-to-pr no-mistakes)
  printf 'upstream_consent=github.com/o/r\n' >>"$dir/home/state/t1.meta"
  sed -i.bak 's/^Delivery contract: mode=no-mistakes$/Delivery contract: mode=no-mistakes upstream-consent=github.com\/o\/r/' "$dir/home/data/t1/brief.md"
  rm -f "$dir/home/data/t1/brief.md.bak"
  run_fallback "$dir" --mode direct-PR --reason "run no-mistakes only when the user explicitly invokes it"
  rc=$?
  expect_code 0 "$rc" "a no-mistakes ship should fall back to direct-PR: $(cat "$dir/err")"
  brief="$dir/home/data/t1/brief.md"
  meta=$(cat "$dir/home/state/t1.meta")
  assert_grep "Delivery contract: mode=direct-PR upstream-consent=github.com/o/r" "$brief" "the brief's contract was not re-rendered for direct-PR with its consent"
  [ "$(grep -c '^# Definition of done$' "$brief")" = 1 ] || fail "the brief does not hold exactly one Definition of done"
  assert_grep "1. Never push to the default branch (push only your \`fm/t1\` branch). Never merge a PR." "$brief" "rule 1 was not re-rendered for direct-PR"
  if grep -qF 'Firstmate will then instruct you to run /no-mistakes' "$brief"; then
    fail "the no-mistakes contract survived the fallback"
  fi
  assert_contains "$meta" "mode=direct-PR" "the task record still names the old mode"
  assert_contains "$meta" "fallback_from=no-mistakes" "the task record does not say what it fell back from"
  assert_contains "$meta" "yolo=on" "the fallback touched merge authority"
  assert_contains "$meta" "upstream_consent=github.com/o/r" "a publishing fallback dropped the recorded consent"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the worker was not steered"
  body=$(record_body "$dir/home/state/t1.inbox/001.msg")
  assert_contains "$body" "run no-mistakes only when the user explicitly invokes it" "the steer does not quote the captain rule"
  assert_contains "$body" "Delivery contract: mode=direct-PR" "the steer does not carry the new Definition of done"
  assert_contains "$body" "push only your \`fm/t1\` branch" "the steer does not carry the new rule 1"
  assert_contains "$(cat "$dir/out")" "now ships direct-PR (was no-mistakes)" "the outcome line is missing"
  pass "fm-delivery-fallback: no-mistakes falls back to direct-PR in the brief, the record, and one durable steer"
}

test_resolve_key_closes_the_worker_blocker() {
  local dir rc
  dir=$(setup_case resolve no-mistakes)
  printf '%s\n' 'blocked [key=delivery-fallback] [at=1]: no-mistakes forbidden by a captain rule; its stated default: direct-PR' \
    >"$dir/home/state/t1.status"
  run_fallback "$dir" --mode direct-PR --reason "no-mistakes only on explicit request" --resolve-key delivery-fallback
  rc=$?
  expect_code 0 "$rc" "a fallback answering the worker's blocker failed: $(cat "$dir/err")"
  assert_grep "resolved [key=delivery-fallback]" "$dir/home/state/t1.status" "the worker's delivery-fallback blocker stayed open"
  pass "fm-delivery-fallback: --resolve-key closes the worker's delivery-fallback blocker at answer time"
}

test_rerun_resends_without_rewriting() {
  local dir before_brief before_meta rc
  dir=$(setup_case rerun no-mistakes)
  run_fallback "$dir" --mode direct-PR --reason "no-mistakes only on explicit request" || fail "first fallback failed: $(cat "$dir/err")"
  before_brief=$(cat "$dir/home/data/t1/brief.md")
  before_meta=$(cat "$dir/home/state/t1.meta")
  run_fallback "$dir" --mode direct-PR --reason "no-mistakes only on explicit request"
  rc=$?
  expect_code 0 "$rc" "a re-run after a completed switch should resend: $(cat "$dir/err")"
  [ "$(cat "$dir/home/data/t1/brief.md")" = "$before_brief" ] || fail "a re-run rewrote the brief"
  [ "$(cat "$dir/home/state/t1.meta")" = "$before_meta" ] || fail "a re-run rewrote the task record"
  [ -f "$dir/home/state/t1.inbox/002.msg" ] || fail "a re-run did not resend the steer"
  assert_contains "$(record_body "$dir/home/state/t1.inbox/002.msg")" "no-mistakes is unavailable" "the resend lost the path it fell back from"
  pass "fm-delivery-fallback: a re-run resends the steer and leaves the brief and record unchanged"
}

test_direct_pr_falls_back_to_local_only() {
  local dir meta rc
  dir=$(setup_case pr-to-local direct-PR)
  printf 'upstream_consent=github.com/o/r\n' >>"$dir/home/state/t1.meta"
  run_fallback "$dir" --mode local-only --reason "GitHub Actions only on explicit request"
  rc=$?
  expect_code 0 "$rc" "a direct-PR ship should fall back to local-only: $(cat "$dir/err")"
  assert_grep "Delivery contract: mode=local-only" "$dir/home/data/t1/brief.md" "the contract was not re-rendered for local-only"
  assert_grep "1. Never push to any remote and never open a PR." "$dir/home/data/t1/brief.md" "rule 1 was not re-rendered for local-only"
  meta=$(cat "$dir/home/state/t1.meta")
  assert_contains "$meta" "mode=local-only" "the record still names direct-PR"
  assert_not_contains "$meta" "upstream_consent=" "local-only kept a publication consent it never uses"
  pass "fm-delivery-fallback: direct-PR falls back to local-only and drops the unused upstream consent"
}

assert_refused_unchanged() {  # <case-dir> <label> <args...>
  local dir=$1 label=$2 before_brief before_meta rc
  shift 2
  before_brief=$(cat "$dir/home/data/t1/brief.md")
  before_meta=$(cat "$dir/home/state/t1.meta")
  run_fallback "$dir" "$@"
  rc=$?
  expect_code 1 "$rc" "$label"
  [ "$(cat "$dir/home/data/t1/brief.md")" = "$before_brief" ] || fail "$label: the brief changed"
  [ "$(cat "$dir/home/state/t1.meta")" = "$before_meta" ] || fail "$label: the task record changed"
  [ ! -e "$dir/home/state/t1.inbox" ] || fail "$label: the worker was steered"
}

test_refusals_change_nothing() {
  local dir
  dir=$(setup_case upgrade direct-PR)
  assert_refused_unchanged "$dir" "a switch to an equal path must refuse" --mode direct-PR --reason "x"
  assert_contains "$(cat "$dir/err")" "less rigor" "the equal-path refusal does not say why"
  dir=$(setup_case gerrit no-mistakes --forge gerrit)
  assert_refused_unchanged "$dir" "a forge-bound task must not fall back to local-only" --mode local-only --reason "x"
  assert_contains "$(cat "$dir/err")" "forge=gerrit cannot ship mode=local-only" "the forge refusal does not name the forge"
  dir=$(setup_case scout no-mistakes)
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=scout" "harness=claude"
  assert_refused_unchanged "$dir" "a scout has no delivery path to fall back from" --mode direct-PR --reason "x"
  pass "fm-delivery-fallback: an equal path, a forge-bound local-only fallback, and a non-ship task are refused with nothing changed"
}

test_no_mistakes_falls_back_to_direct_pr
test_resolve_key_closes_the_worker_blocker
test_rerun_resends_without_rewriting
test_direct_pr_falls_back_to_local_only
test_refusals_change_nothing

echo "# fm-delivery-fallback.test.sh: all assertions passed"
