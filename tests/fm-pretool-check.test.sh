#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the single PreToolUse review (docs/pretool-check.md).
#
# bin/fm-pretool-check.sh replaces three hooks (arm, cd, primary-write) per
# action. The seatbelts keep owning every decision and their own suites prove
# them, so this suite copies the real entry beside STUB seatbelts that record
# each run, and proves which of them an action reaches: none for an action that
# cannot touch anything protected, only the arm seatbelt in a task worktree,
# all that apply in a primary, everything when the payload cannot be decoded,
# and the first deny passing through unchanged. It also runs the real
# seatbelts once to prove the deny shape end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-pretool-check)
RUNLOG="$TMP_ROOT/runs.log"
DIAGLOG="$TMP_ROOT/diag"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
WATCH=fm-wat
WATCH="${WATCH}ch" # keeps this file itself free of the protected word

install_entry() {  # <dir> [real]
  local dir=$1 name
  mkdir -p "$dir/bin"
  for name in fm-pretool-check.sh fm-pretool-prefilter-lib.sh fm-diag.sh fm-hook-host-lib.sh; do
    cp "$ROOT/bin/$name" "$dir/bin/$name"
  done
  chmod +x "$dir/bin/fm-pretool-check.sh"
  : > "$dir/AGENTS.md"
  [ "${2:-}" != real ] || cp "$ROOT"/bin/fm-*policy.mjs "$dir/bin/"
  for name in arm cd primary-write; do
    if [ "${2:-}" = real ]; then
      cp "$ROOT/bin/fm-$name-pretool-check.sh" "$dir/bin/fm-$name-pretool-check.sh"
    else
      printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "%%s\\n" "%s" >> "$RUNLOG"\n[ "${STUB_DENY:-}" = "%s" ] && { echo "{\\"stub\\":\\"%s\\"}" >&2; exit 2; }\nexit 0\n' "$name" "$name" "$name" > "$dir/bin/fm-$name-pretool-check.sh"
    fi
    chmod +x "$dir/bin/fm-$name-pretool-check.sh"
  done
}

make_primary() {  # <dir>
  git init -q "$1"; git -C "$1" commit -q --allow-empty -m init
  install_entry "$1" "${2:-}"
}

make_worker() {  # <primary> <worktree>
  git -C "$1" worktree add -q -b "w$RANDOM" "$2" >/dev/null 2>&1 || fail "worktree fixture"
  rm -rf "${2:?}/bin"; install_entry "$2" "${3:-}"
}

# run <home> <payload> [env...]: sets RC, leaves RUNLOG with the seatbelts that ran.
run() {
  local home=$1 payload=$2
  shift 2
  : > "$RUNLOG"; : > "$OUT"; : > "$ERR"
  RC=0
  printf '%s' "$payload" | env RUNLOG="$RUNLOG" FM_DIAGNOSTICS_HOME="$DIAGLOG" "$@" "$home/bin/fm-pretool-check.sh" --claude > "$OUT" 2> "$ERR" || RC=$?
  RAN=$(paste -sd, "$RUNLOG")
}

expect() {  # <label> <expected seatbelts, comma list or empty>
  [ "$RC" -eq 0 ] || fail "$1: exit $RC: $(cat "$ERR")"
  [ "$RAN" = "$2" ] || fail "$1: ran [$RAN], expected [$2]"
}

bash_payload() { printf '{"session_id":"s","cwd":"/x","tool_name":"Bash","tool_input":{"command":"%s","description":"d"}}' "$1"; }
tool_payload() { printf '{"tool_name":"%s","tool_input":{"file_path":"/x/y"}}' "$1"; }

test_primary_runs_only_what_the_action_can_touch() {
  local home="$TMP_ROOT/primary"
  make_primary "$home"
  run "$home" "$(bash_payload 'ls -la')";                        expect "plain command" ''
  run "$home" "$(bash_payload 'ls \"a b\" | wc -l')";            expect "quoted pipeline" ''
  run "$home" "$(bash_payload 'cd projects/x')";                 expect "cd" 'cd'
  run "$home" "$(bash_payload "bin/$WATCH.sh")";            expect "watcher" 'arm'
  run "$home" "$(bash_payload 'echo x > f')";                    expect "redirect" 'primary-write'
  run "$home" "$(bash_payload "cd p && bin/$WATCH.sh")";    expect "cd and watcher" 'arm,cd'
  run "$home" "$(bash_payload "sed -i s/a/b/ f\\nbin/fm-wat\\\\\\nch-arm.sh")"; expect "escaped newline join" 'arm,primary-write'
  run "$home" "$(bash_payload 'ls')" FM_ROOT_OVERRIDE="$home";   expect "root override" ''
  run "$home" "$(tool_payload Read)";                            expect "Read" 'primary-write'
  run "$home" "$(tool_payload Edit)";                            expect "Edit" 'primary-write'
  run "$home" '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n cd x\n*** End Patch"}}'; expect "apply_patch" 'primary-write'
  run "$home" "$(tool_payload Grep)";                            expect "other tool" ''
  pass "a primary runs a seatbelt only for an action that can touch what it protects"
}

test_worker_worktree_skips_home_scoped_seatbelts() {
  local home="$TMP_ROOT/primary2" wt="$TMP_ROOT/worker"
  make_primary "$home"; make_worker "$home" "$wt"
  run "$wt" "$(bash_payload 'ls -la')";                         expect "worker plain command" ''
  run "$wt" "$(bash_payload 'cd projects/x && echo x > f')";    expect "worker cd and write are inert" ''
  run "$wt" "$(bash_payload "bash bin/$WATCH.sh")";             expect "worker watcher still reviewed" 'arm'
  run "$wt" "$(tool_payload Edit)";                             expect "worker Edit" ''
  run "$wt" '{"tool_name":"apply_patch","tool_input":{"command":"x"}}'; expect "worker apply_patch" ''
  printf 'sm-1\n' > "$wt/.fm-secondmate-home"
  run "$wt" "$(bash_payload 'cd x')";                           expect "marked secondmate home is a primary" 'cd'
  rm -f "$wt/.fm-secondmate-home"
  pass "a linked task worktree skips the cd and write seatbelts and still gets the arm seatbelt"
}

test_undecodable_payload_runs_everything() {
  local home="$TMP_ROOT/primary3" wt="$TMP_ROOT/worker3"
  make_primary "$home"; make_worker "$home" "$wt"
  run "$home" "$(bash_payload "bin/fm-wat\\u0063h.sh")";        expect "unicode escape" 'arm,cd,primary-write'
  run "$wt" "$(bash_payload "bin/fm-wat\\u0063h.sh")";          expect "unicode escape in worker" 'arm'
  run "$home" '{"cwd":"/x"}';                                   expect "no tool name" 'arm,cd,primary-write'
  run "$home" 'not json';                                       expect "not json" 'arm,cd,primary-write'
  run "$home" '';                                               expect "empty payload" ''
  pass "a payload the entry cannot decode runs every seatbelt that applies, as the three hooks did"
}

test_first_deny_passes_through() {
  local home="$TMP_ROOT/primary4"
  make_primary "$home"
  run "$home" "$(bash_payload "cd p && echo x > f && bin/$WATCH.sh")" STUB_DENY=cd
  [ "$RC" -eq 2 ] || fail "deny must exit 2, got $RC"
  [ "$RAN" = 'arm,cd' ] || fail "later seatbelts must not run after a deny: [$RAN]"
  [ ! -s "$OUT" ] && [ "$(cat "$ERR")" = '{"stub":"cd"}' ] || fail "deny output must pass through untouched: $(cat "$OUT") / $(cat "$ERR")"
  pass "the first deny exits 2 with the seatbelt's own stderr and stops the review"
}

test_one_diagnostic_record_per_action() {
  local home="$TMP_ROOT/primary5"
  make_primary "$home"
  rm -rf "$DIAGLOG"
  run "$home" "$(bash_payload 'cd x')" FM_DIAGNOSTICS=1
  jq -e -s 'length == 1 and .[0].e == "hook.run" and .[0].hook == "pretool" and .[0].rc == 0' "$DIAGLOG/firstmate/events.jsonl" >/dev/null \
    || fail "one hook.run named pretool expected: $(cat "$DIAGLOG/firstmate/events.jsonl" 2>/dev/null)"
  pass "an action that reaches several seatbelts records one pretool hook.run, not one per seatbelt"
}

test_real_seatbelts_deny_end_to_end() {
  local home="$TMP_ROOT/real" wt="$TMP_ROOT/realworker"
  make_primary "$home" real; make_worker "$home" "$wt" real
  run "$home" "$(bash_payload 'cd projects/x')" FM_ROOT_OVERRIDE="$home"
  [ "$RC" -eq 2 ] && grep -q persistent-cd "$ERR" && [ ! -s "$OUT" ] || fail "real cd deny through the entry: rc=$RC $(cat "$ERR")"
  run "$wt" "$(bash_payload "bash bin/$WATCH.sh &")"
  [ "$RC" -eq 2 ] && grep -q 'watcher-' "$ERR" && [ ! -s "$OUT" ] || fail "real arm deny in a worker: rc=$RC $(cat "$ERR")"
  run "$home" "$(bash_payload 'ls')" FM_ROOT_OVERRIDE="$home"
  expect "real allow" ''
  pass "the real seatbelts still deny through the single entry with a Claude-shaped deny"
}

test_help_and_bad_argument() {
  "$ROOT/bin/fm-pretool-check.sh" --help 2>&1 | grep -q 'One PreToolUse review' || fail "--help text"
  if "$ROOT/bin/fm-pretool-check.sh" --bogus </dev/null >/dev/null 2>&1; then fail "unknown argument must fail"; fi
  pass "help prints the contract and an unknown argument is refused"
}

test_registrations_use_the_single_entry() {
  local n
  n=$(jq '[.hooks.PreToolUse[].hooks[].command | select(contains("fm-arm-pretool-check.sh") or contains("fm-cd-pretool-check.sh") or contains("fm-primary-write-pretool-check.sh"))] | length' "$ROOT/.claude/settings.json")
  [ "$n" = 0 ] || fail "Claude settings still register a separate seatbelt"
  n=$(jq '[.hooks.PreToolUse[].hooks[].command | select(contains("fm-arm-pretool-check.sh") or contains("fm-cd-pretool-check.sh") or contains("fm-primary-write-pretool-check.sh"))] | length' "$ROOT/.codex/hooks.json")
  [ "$n" = 0 ] || fail "Codex hooks still register a separate seatbelt"
  [ "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]] | length' "$ROOT/.claude/settings.json")" = 1 ] || fail "Claude Bash must run exactly one review"
  [ "$(jq '[.hooks.PreToolUse[] | select(.matcher | test("Bash")) | .hooks[]] | length' "$ROOT/.codex/hooks.json")" = 1 ] || fail "Codex Bash must run exactly one review"
  pass "Claude and Codex register one review per Bash action instead of three"
}

test_primary_runs_only_what_the_action_can_touch
test_worker_worktree_skips_home_scoped_seatbelts
test_undecodable_payload_runs_everything
test_first_deny_passes_through
test_one_diagnostic_record_per_action
test_real_seatbelts_deny_end_to_end
test_help_and_bad_argument
test_registrations_use_the_single_entry
