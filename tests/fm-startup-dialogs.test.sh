#!/usr/bin/env bash
# Behavior tests for bin/fm-startup-dialogs.sh with a REAL tmux server on a
# private TMUX_TMPDIR. A small fake agent draws the dialogs exactly as the real
# panes did (recorded 2026-11-18 on Codex 0.169.0 and Claude Code 2.1.328: same
# heading, same rows, cursor on the first row) and records the keys it receives
# and which row Enter landed on. The real harnesses are exercised by the live
# run in docs/verification/runtime-backends.md, not here.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-startup-dialogs)
export TMUX_TMPDIR="$TMP_ROOT/tmux"
mkdir -p "$TMUX_TMPDIR"
trap 'tmux kill-server >/dev/null 2>&1 || true' EXIT

DIALOGS="${DIALOGS_UNDER_TEST:-$ROOT/bin/fm-startup-dialogs.sh}"
DIALOGS_BASH="${FM_DIALOGS_BASH:-bash}"
export FM_STARTUP_DIALOGS_POLL=0.2
# Exercise multibyte cursor recognition even when awk uses byte-oriented matching.
export LC_ALL=C

# The fake agent: fake-agent <log> <cursor-glyph> <heading-line>... -- <row>...
# Down moves the cursor, Enter records the row it landed on and then shows the
# working line a started agent shows.
cat >"$TMP_ROOT/fake-agent.sh" <<'EOF'
#!/usr/bin/env bash
log=$1 glyph=$2
shift 2
heads=()
while [ "$1" != "--" ]; do heads+=("$1"); shift; done
shift
rows=("$@")
sel=0
draw() {
  clear
  printf '%s\n' "${heads[@]}"
  local i
  for i in "${!rows[@]}"; do
    if [ "$i" = "$sel" ]; then printf '%s %s\n' "$glyph" "${rows[$i]}"; else printf '  %s\n' "${rows[$i]}"; fi
  done
}
draw
while IFS= read -rsn1 k; do
  if [ "$k" = $'\e' ]; then
    read -rsn2 rest
    [ "$rest" = '[B' ] && { echo down >>"$log"; sel=$((sel + 1)); [ "$sel" -lt "${#rows[@]}" ] || sel=$((${#rows[@]} - 1)); draw; }
  elif [ -z "$k" ]; then
    echo "enter:${rows[$sel]}" >>"$log"
    clear
    echo "Working (0s • esc to interrupt)"
    sleep 30
    exit 0
  fi
done
EOF
chmod +x "$TMP_ROOT/fake-agent.sh"

# run_case <name> <launch-dir> <log> <glyph> <heading...> -- <rows...>
# Starts the fake agent in a pane, runs the script against it, prints its stderr.
run_case() {
  local name=$1 dir=$2 log=$3 glyph=$4
  shift 4
  tmux kill-server >/dev/null 2>&1 || true
  sleep 0.4
  : >"$log"
  tmux -f /dev/null new-session -d -s "$name" -x 160 -y 40 -c "$dir" \
    "$TMP_ROOT/fake-agent.sh $(printf '%q ' "$log" "$glyph" "$@")"
  sleep 0.5
  "$DIALOGS_BASH" "$DIALOGS" tmux "$name:0" "${CASE_HARNESS:-codex}" "$dir" 8 2>&1
}

LAUNCH="$TMP_ROOT/launch"
mkdir -p "$LAUNCH"
LAUNCH=$(cd -P "$LAUNCH" && pwd -P)

FOLDER_HEAD=("Folder access" "$LAUNCH" "Trust this folder? Codex can read, edit, and run files here, subject to your permission settings." "Your trust decision will be saved.")
FOLDER_ROWS=("1. Trust and continue" "2. Back to Agent Command Center")
HOOKS_HEAD=("Hooks need review" "10 hooks are new or changed." "Hooks can run outside the sandbox after you trust them.")
HOOKS_ROWS=("1. Review hooks" "2. Trust all and continue" "3. Continue without trusting (hooks won't run)")
IMPORT_ROWS=("No, disable external imports" "Yes, allow external imports")

test_codex_folder_in_launch_dir_is_trusted() {
  local log="$TMP_ROOT/log1" out
  out=$(run_case folder "$LAUNCH" "$log" '›' "${FOLDER_HEAD[@]}" -- "${FOLDER_ROWS[@]}")
  assert_contains "$(cat "$log")" "enter:1. Trust and continue" "the folder dialog for the launch directory was not accepted"
  assert_contains "$out" "codex-folder: answered" "the answer was not reported"
}

test_codex_folder_wrapped_across_lines_is_trusted() {
  local log="$TMP_ROOT/log-wrapped" out split first second
  split=$((${#LAUNCH} / 2))
  first=${LAUNCH:0:split}; second=${LAUNCH:split}
  out=$(run_case wrapped "$LAUNCH" "$log" '›' "Folder access" "  $first" "  $second" "" "Trust this folder? Codex can read." -- "${FOLDER_ROWS[@]}")
  assert_contains "$(cat "$log")" 'enter:1. Trust and continue' 'the wrapped launch path was not accepted'
  assert_contains "$out" 'codex-folder: answered' 'the wrapped folder answer was not reported'
  out=$(run_case wrapped-other "$LAUNCH" "$log" '›' "Folder access" "  $first" "  ${second}other" "" "Trust this folder? Codex can read." -- "${FOLDER_ROWS[@]}")
  assert_equals '' "$(cat "$log")" 'a different wrapped path received keys'
  pass 'wrapped folder paths are matched exactly'
}

if [ "${FM_TEST_WRAPPED_FOLDER_ONLY:-0}" = 1 ]; then
  test_codex_folder_wrapped_across_lines_is_trusted
  exit 0
fi

test_codex_folder_with_repository_note_is_trusted() {
  local log="$TMP_ROOT/log-note" out split first second
  split=$((${#LAUNCH} / 2))
  first=${LAUNCH:0:split}; second=${LAUNCH:split}
  out=$(run_case rootnote "$LAUNCH" "$log" '›' "Folder access" "  $first" "  $second" "" \
    "  Note: You’re in a subdirectory of a Git project. Trusting will apply to the" \
    "  repository root:" "  /some/repository" "" "Trust this folder? Codex can read." -- "${FOLDER_ROWS[@]}")
  assert_contains "$(cat "$log")" 'enter:1. Trust and continue' 'repository note prevented launch folder trust'
}

test_codex_folder_elsewhere_is_left() {
  local log="$TMP_ROOT/log2" out
  out=$(run_case other "$LAUNCH" "$log" '›' "Folder access" "/somewhere/else" "Trust this folder? Codex can read." -- "${FOLDER_ROWS[@]}")
  assert_equals "" "$(cat "$log")" "a folder that is not the launch directory received keys"
  assert_contains "$out" "left for the operator" "the refusal was not reported"
}

test_refusal_queues_one_actionable_notice() {
  local home="$TMP_ROOT/notice-home" log="$TMP_ROOT/log-notice" out count
  mkdir -p "$home/state" "$home/data" "$home/config"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STARTUP_DIALOGS_ALERT_ID=notice-test \
    run_case notice "$LAUNCH" "$log" '›' "Folder access" "/somewhere/else" "Trust this folder?" -- "${FOLDER_ROWS[@]}")
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STARTUP_DIALOGS_ALERT_ID=notice-test \
    run_case notice-again "$LAUNCH" "$log" '›' "Folder access" "/somewhere/else" "Trust this folder?" -- "${FOLDER_ROWS[@]}")
  count=$(find "$home/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  assert_equals 1 "$count" 'refusal should queue one notice for the launch'
  assert_contains "$(cat "$home/state/inbox/"*.note)" 'Inspect the pane before sending input' 'notice must give an action'
}

test_codex_hooks_are_trusted_with_down_then_enter() {
  local log="$TMP_ROOT/log3" out
  out=$(run_case hooks "$LAUNCH" "$log" '›' "${HOOKS_HEAD[@]}" -- "${HOOKS_ROWS[@]}")
  assert_equals "down
enter:2. Trust all and continue" "$(cat "$log")" "hooks were not trusted with Down then Enter on the accepting row"
}

test_codex_hooks_of_a_foreign_project_are_left() {
  local dir="$TMP_ROOT/foreign" log="$TMP_ROOT/log4" out
  mkdir -p "$dir/.codex"
  : >"$dir/.codex/hooks.json"
  out=$(run_case foreign "$dir" "$log" '›' "${HOOKS_HEAD[@]}" -- "${HOOKS_ROWS[@]}")
  assert_equals "" "$(cat "$log")" "a third-party project's own hooks were trusted"
  assert_contains "$out" "carries its own Codex hooks" "the refusal reason was not reported"
}

test_codex_hooks_of_a_firstmate_checkout_are_trusted() {
  local dir="$TMP_ROOT/fmcheckout" log="$TMP_ROOT/log5" out
  mkdir -p "$dir/.codex" "$dir/bin"
  : >"$dir/.codex/hooks.json"
  : >"$dir/bin/fm-turnend-guard.sh"
  out=$(run_case fmcheckout "$dir" "$log" '›' "${HOOKS_HEAD[@]}" -- "${HOOKS_ROWS[@]}")
  assert_contains "$(cat "$log")" "enter:2. Trust all and continue" "Firstmate's own hooks were not trusted"
}

test_claude_imports_of_the_operators_claude_dir_are_allowed() {
  local log="$TMP_ROOT/log6" out
  out=$(CASE_HARNESS=claude HOME="$TMP_ROOT/home" run_case imp "$LAUNCH" "$log" '❯' \
    "Allow external CLAUDE.md file imports?" "External imports:" "    $TMP_ROOT/home/.claude/RTK.md" "Important: Only use Claude Code with files you trust." \
    -- "${IMPORT_ROWS[@]}")
  assert_equals "down
enter:Yes, allow external imports" "$(cat "$log")" "the operator's own import was not allowed"
}

test_codex_hooks_of_prepared_overseer_are_trusted() {
  local home="$TMP_ROOT/overseer-home" dir="$TMP_ROOT/overseer-dir" log="$TMP_ROOT/overseer-log" out
  mkdir -p "$home"
  : > "$home/SUPERVISOR.md"
  FM_HOME="$home" bash "$ROOT/bin/fm-overseer.sh" setup "$dir" >/dev/null || fail 'overseer setup failed'
  out=$(FM_HOME="$home" run_case overseer "$dir" "$log" '›' "${HOOKS_HEAD[@]}" -- "${HOOKS_ROWS[@]}")
  assert_contains "$(cat "$log")" 'enter:2. Trust all and continue' 'prepared overseer hook was not trusted'
  mkdir -p "$dir/.codex"
  printf '{"hooks":{}}\n' > "$dir/.codex/hooks.json"
  out=$(FM_HOME="$home" run_case overseer-modified "$dir" "$log" '›' "${HOOKS_HEAD[@]}" -- "${HOOKS_ROWS[@]}")
  assert_equals '' "$(cat "$log")" 'new project hooks received trust'
  assert_contains "$out" 'left for the operator' 'new project hooks were not refused'
  pass 'prepared overseer without project hooks receives Codex trust'
}

test_claude_imports_outside_are_left() {
  local log="$TMP_ROOT/log7" out
  out=$(CASE_HARNESS=claude HOME="$TMP_ROOT/home" run_case impout "$LAUNCH" "$log" '❯' \
    "Allow external CLAUDE.md file imports?" "External imports:" "    $TMP_ROOT/home/.claude/RTK.md" "    /srv/third-party/notes.md" "Important: Only use Claude Code with files you trust." \
    -- "${IMPORT_ROWS[@]}")
  assert_equals "" "$(cat "$log")" "an import outside the operator's directories was allowed"
  assert_contains "$out" "left for the operator" "the refusal was not reported"
}

test_bypass_warning_is_not_answered() {
  local log="$TMP_ROOT/log8" out
  out=$(CASE_HARNESS=claude run_case bypass "$LAUNCH" "$log" '❯' "WARNING: Claude Code running in Bypass Permissions mode" -- "No, exit" "Yes, I accept")
  assert_equals "" "$(cat "$log")" "the bypass-permissions warning received keys"
}

test_a_quoted_dialog_in_a_normal_screen_is_not_answered() {
  local log="$TMP_ROOT/log9" out
  out=$(run_case quote "$LAUNCH" "$log" '>' "He wrote: Hooks need review and 2. Trust all and continue" -- "a normal row")
  assert_equals "" "$(cat "$log")" "quoted dialog text was answered"
}

test_an_unreadable_pane_returns_at_once() {
  local start end
  tmux kill-server >/dev/null 2>&1 || true
  sleep 0.4
  tmux -f /dev/null new-session -d -s alive -x 80 -y 24 "sleep 30"
  start=$(date +%s)
  "$DIALOGS_BASH" "$DIALOGS" tmux "nosuch:9" codex "$LAUNCH" 30 >/dev/null 2>&1
  end=$(date +%s)
  [ $((end - start)) -le 5 ] || fail "a pane that cannot be read was watched for $((end - start))s"
}

if [ "${FM_TEST_HOOKS_ONLY:-0}" = 1 ]; then
  test_codex_hooks_are_trusted_with_down_then_enter
  exit 0
fi

test_codex_folder_in_launch_dir_is_trusted
test_codex_folder_wrapped_across_lines_is_trusted
test_codex_folder_with_repository_note_is_trusted
test_codex_folder_elsewhere_is_left
test_refusal_queues_one_actionable_notice
test_codex_hooks_are_trusted_with_down_then_enter
test_codex_hooks_of_a_foreign_project_are_left
test_codex_hooks_of_a_firstmate_checkout_are_trusted
test_codex_hooks_of_prepared_overseer_are_trusted
test_claude_imports_of_the_operators_claude_dir_are_allowed
test_claude_imports_outside_are_left
test_bypass_warning_is_not_answered
test_a_quoted_dialog_in_a_normal_screen_is_not_answered
test_an_unreadable_pane_returns_at_once
pass "start-up dialogs: trusted inside the approved scope, left outside it"
