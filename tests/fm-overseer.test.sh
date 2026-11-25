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
  [ ! -e "$dir/.codex/hooks.json" ] && [ ! -e "$dir/.claude/settings.json" ] ||
    fail 'a fresh setup still installs a Stop hook'
  cmp -s "$dir/CLAUDE.md" "$CONTRACT" || fail "Claude's loader does not resolve to the contract text"
  assert_contains "$out" "OVERSEER_READY:" "setup did not report readiness"
  pass "setup links both harness loaders to the contract and names the home"

  out=$(FM_HOME="$home" bash "$OVERSEER" setup "$dir" 2>&1) || fail "a second setup failed: $out"
  assert_not_contains "$out" "OVERSEER_SETUP:" "a second setup rewrote an entry that already matched"
  pass "setup is idempotent"

  mkdir -p "$dir/.codex" "$dir/.claude"
  cat > "$dir/.codex/hooks.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"env FM_HOME='/old home' python3 '/old root/bin/fm-overseer-arm.py' guard","timeout":90}]}]}}
JSON
  jq '.permissions = {"allow":["Bash(date)"]} | .hooks.Stop[0].hooks += [{"type":"command","command":"date"}]' \
    "$dir/.codex/hooks.json" > "$dir/.claude/settings.json"
  out=$(FM_HOME="$home" bash "$OVERSEER" setup "$dir" 2>&1) || fail "upgrade setup refused old generated hooks: $out"
  [ ! -e "$dir/.codex/hooks.json" ] || fail 'upgrade setup retained the old Codex hook'
  jq -e '.permissions.allow == ["Bash(date)"] and [.hooks.Stop[].hooks[].command] == ["date"]' \
    "$dir/.claude/settings.json" >/dev/null || fail 'upgrade setup changed custom settings or retained the old hook'
  pass 'setup removes old generated Stop commands and preserves adjacent user settings'
}

test_watch_delivers_to_its_session() (
  local lab="$TMP_ROOT/watch-code" home="$TMP_ROOT/watch-home" out pid
  mkdir -p "$lab/bin" "$home/state/overseer"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  cat >"$lab/bin/fm-overseer-watch.sh" <<'SH'
while [ ! -f "$FM_HOME/ready" ]; do sleep 0.1; done
printf 'event_id=123-456\ntest event\n'
SH
  export FM_HOME="$home"
  python3 "$lab/bin/fm-overseer-arm.py" watch > "$home/output" &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
  for _ in $(seq 1 100); do [ -s "$home/state/overseer/watch.lock" ] && break; sleep 0.1; done
  out=$(python3 "$lab/bin/fm-overseer-arm.py" status)
  assert_contains "$out" 'watch: armed' 'status omitted the native background wait'
  if python3 "$lab/bin/fm-overseer-arm.py" watch >/dev/null 2>&1; then fail 'two session watches were accepted'; fi
  : > "$home/ready"
  wait "$pid" || fail 'native background wait failed'
  assert_contains "$(cat "$home/output")" 'test event' 'the event did not return to its own background job'
  out=$(python3 "$lab/bin/fm-overseer-arm.py" guard)
  assert_equals '' "$out" 'the legacy hook produced a reminder'
  out=$(python3 "$lab/bin/fm-overseer-arm.py" status)
  assert_contains "$out" 'watch: not armed' 'the legacy hook armed a background watch'
  pass 'a single native background job returns its event through stdout'
)

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

test_interventions_record_and_export() {
  local home archive
  home="$TMP_ROOT/intervention-home"
  archive="$TMP_ROOT/interventions.zip"
  make_home "$home"
  FM_DIAGNOSTICS_HOME="$TMP_ROOT/diagnostics" FM_HOME="$home" bash "$OVERSEER" intervention record --category scheduling --observed ready-work-unattended --evidence task-123 --action asked-primary-to-dispatch --root-task no || fail "record failed"
  FM_DIAGNOSTICS_HOME="$TMP_ROOT/diagnostics" FM_HOME="$home" bash "$OVERSEER" intervention record --category recovery --observed worker-stalled --evidence task-456 --action asked-primary-to-investigate --root-task yes || fail "second record failed"
  FM_DIAGNOSTICS_HOME="$TMP_ROOT/diagnostics" FM_HOME="$home" bash "$OVERSEER" intervention export "$archive" || fail "export failed"
  python3 - "$archive" <<'PYTEST' || fail "export lost records or structure"
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    assert z.testzip() is None
    assert set(z.namelist()) == {'events.jsonl', 'manifest.json'}
    rows = [json.loads(line) for line in z.read('events.jsonl').splitlines()]
    # root_task reports a linked root task in the correction ledger; a bare yes links none.
    assert len(rows) == 2 and rows[0]['root_task'] == 0 and rows[1]['root_task'] == 0
    assert rows[0]['observed'] == 'ready-work-unattended'
PYTEST
  if FM_DIAGNOSTICS_HOME="$TMP_ROOT/diagnostics" FM_HOME="$home" bash "$OVERSEER" intervention record --category recovery --observed 'person@example.com' --evidence task-1 --action asked-primary --root-task no >/dev/null 2>&1; then
    fail "record accepted an email"
  fi
  printf '%s\n' '{"t":"2026-01-01T00:00:00+00:00","c":"firstmate","e":"overseer.intervention","category":"recovery","observed":"person@example.com","task":"live-1234567890abcdef","action":"asked-primary","root_task":0}' >> "$home/state/overseer/interventions.jsonl"
  if FM_DIAGNOSTICS_HOME="$TMP_ROOT/diagnostics" FM_HOME="$home" bash "$OVERSEER" intervention export "$TMP_ROOT/unsafe.zip" >/dev/null 2>&1; then
    fail "export accepted an unsafe existing record"
  fi
  [ ! -e "$TMP_ROOT/unsafe.zip" ] || fail "unsafe export was created"
  pass "interventions persist and export, and unsafe records are rejected"
}

# A code copy whose primary resolver is stubbed and whose Herdr is a logging fake.
make_placement_lab() {  # <lab> <located-endpoint-or-empty>
  local lab=$1 item
  mkdir -p "$lab/bin" "$lab/fake"
  for item in "$ROOT"/bin/*; do ln -s "$item" "$lab/bin/${item##*/}"; done
  ln -s "$ROOT/overseer" "$lab/overseer"
  rm -f "$lab/bin/fm-overseer-primary.sh"
  if [ -n "$2" ]; then
    {
      cat <<'SH'
#!/usr/bin/env bash
[ "$1" = --locate ] || exit 1
SH
      printf 'echo %q\n' "$2"
    } > "$lab/bin/fm-overseer-primary.sh"
  else
    printf '#!/usr/bin/env bash\nexit 1\n' > "$lab/bin/fm-overseer-primary.sh"
  fi
  cat > "$lab/fake/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${0%/*}/log"
case "$1 $2" in
  'status --json') printf '{"client":{"protocol":999,"version":"t"},"server":{"running":true}}\n' ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n' ;;
  'pane split') printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s"}}}\n' "$3" "${3%%:*}:t1" ;;
  'pane neighbor') printf '{"result":{"neighbor":{"pane_id":"w1:p1"%s}}}\n' "$(cat "${0%/*}/neighbor" 2>/dev/null)" ;;
  'pane move') printf '{"result":{"move_result":{"pane":{"pane_id":"w1:p2"}}}}\n' ;;
  *) exit 1 ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$lab/fake/claude"
  chmod +x "$lab/fake/herdr" "$lab/fake/claude" "$lab/bin/fm-overseer-primary.sh"
}

test_start_preserves_armed_watch_without_session() (
  local lab="$TMP_ROOT/armed-code" home="$TMP_ROOT/armed-home" dir="$TMP_ROOT/outside/armed" pid out
  make_home "$home"; make_placement_lab "$lab" 'herdr fake:w1:p1'
  rm -f "$lab/bin/fm-overseer-arm.py" "$lab/bin/fm-overseer-watch.sh"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  printf 'while :; do sleep 1; done\n' > "$lab/bin/fm-overseer-watch.sh"
  mkdir -p "$home/config" "$home/state/overseer" "$TMP_ROOT/armed-user"
  printf 'enabled=on\nharness=claude\ndirectory=%s\n' "$dir" > "$home/config/overseer"
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" watch >/dev/null &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
  for _ in $(seq 1 100); do [ -s "$home/state/overseer/watch.lock" ] && break; sleep 0.1; done
  out=$(env -u TMUX HOME="$TMP_ROOT/armed-user" PATH="$lab/fake:$PATH" FM_HOME="$home" FM_BACKEND=herdr HERDR_SESSION=fake bash "$lab/bin/fm-overseer.sh" start 2>&1) || true
  [ ! -e "$home/state/overseer/session" ] || fail "start replaced a missing record despite an armed watch: $out"
  printf 'herdr fake:w1:p9\n' > "$home/state/overseer/session"
  out=$(env -u TMUX HOME="$TMP_ROOT/armed-user" PATH="$lab/fake:$PATH" FM_HOME="$home" FM_BACKEND=herdr HERDR_SESSION=fake bash "$lab/bin/fm-overseer.sh" start 2>&1) || fail "start refused the armed watch: $out"
  [ "$(cat "$home/state/overseer/session")" = 'herdr fake:w1:p9' ] || fail 'start changed the session record'
  kill -0 "$pid" 2>/dev/null || fail 'start stopped the armed watch'
  [ ! -s "$lab/fake/log" ] || fail 'start contacted the backend despite an armed watch'
  pass 'start preserves an armed watch even without a session record'
)

test_start_beside_the_primary_on_herdr() {
  local home dir lab out lang want
  # With a live primary: split its pane to the right, whoever runs start.
  lab="$TMP_ROOT/place-split" home="$TMP_ROOT/home-split" dir="$TMP_ROOT/outside/split"
  make_home "$home"; make_placement_lab "$lab" 'herdr fake:w1:p1'
  mkdir -p "$home/config" "$TMP_ROOT/user-split"
  printf 'enabled=on\nharness=claude\ndirectory=%s\n' "$dir" > "$home/config/overseer"
  out=$(env -u TMUX HOME="$TMP_ROOT/user-split" PATH="$lab/fake:$PATH" FM_HOME="$home" FM_BACKEND=herdr HERDR_SESSION=fake \
    HERDR_PANE_ID=w9:p1 bash "$lab/bin/fm-overseer.sh" start 2>&1) && fail "start succeeded against a fake Herdr: $out"
  grep -q "^pane split w1:p1 --direction right --cwd .* --no-focus" "$lab/fake/log" || fail "start did not split the primary pane: $(cat "$lab/fake/log")"
  [ "$(cat "$home/state/overseer/session")" = 'herdr fake:w1:p2' ] || fail 'start did not record the pane beside the primary'
  # Without one: its own workspace labeled in the installation language, never the caller's.
  for lang in es en; do
    lab="$TMP_ROOT/place-own-$lang" home="$TMP_ROOT/home-own-$lang" dir="$TMP_ROOT/outside/own-$lang"
    make_home "$home"; make_placement_lab "$lab" ''
    mkdir -p "$home/config" "$TMP_ROOT/user-$lang"
    printf '%s\n' "$lang" > "$home/config/language"
    printf 'enabled=on\nharness=claude\ndirectory=%s\n' "$dir" > "$home/config/overseer"
    out=$(env -u TMUX HOME="$TMP_ROOT/user-$lang" PATH="$lab/fake:$PATH" FM_HOME="$home" FM_BACKEND=herdr HERDR_SESSION=fake \
      HERDR_PANE_ID=w9:p1 bash "$lab/bin/fm-overseer.sh" start 2>&1) && fail "start succeeded against a fake Herdr: $out"
    case $lang in es) want=supervisor ;; *) want=overseer ;; esac
    grep -q "^workspace create --cwd .* --label $want " "$lab/fake/log" || fail "start did not create its own '$want' workspace: $(cat "$lab/fake/log")"
  done
  pass "start opens the overseer right of the primary pane, or in its own labeled workspace when no primary is found"
}

test_place_moves_the_overseer_beside_the_primary() {
  local home lab out
  lab="$TMP_ROOT/place-move" home="$TMP_ROOT/home-move"
  make_home "$home"; make_placement_lab "$lab" 'herdr fake:w1:p1'
  mkdir -p "$home/state/overseer"
  printf 'herdr fake:w5:p3\n' > "$home/state/overseer/session"
  out=$(PATH="$lab/fake:$PATH" FM_HOME="$home" FM_BACKEND=herdr bash "$lab/bin/fm-overseer.sh" place 2>&1) || fail "place failed: $out"
  grep -q '^pane move w5:p3 --tab w1:t1 --target-pane w1:p1 --split right --no-focus' "$lab/fake/log" || fail "place did not move the pane: $(cat "$lab/fake/log")"
  [ "$(cat "$home/state/overseer/session")" = 'herdr fake:w1:p2' ] || fail 'place did not follow the moved pane id'
  # Already right of the primary: nothing moves.
  printf ',"neighbor_pane_id":"w1:p2"' > "$lab/fake/neighbor"
  : > "$lab/fake/log"
  out=$(PATH="$lab/fake:$PATH" FM_HOME="$home" FM_BACKEND=herdr bash "$lab/bin/fm-overseer.sh" place 2>&1) || fail "place failed: $out"
  if grep -q '^pane move' "$lab/fake/log"; then fail 'place moved a pane already beside the primary'; fi
  pass 'place moves the overseer right of the primary in its tab and follows the new pane id'
}

test_relay_retires_legacy_watch() (
  local lab home dir out pid successor
  lab="$TMP_ROOT/relay-code" home="$TMP_ROOT/relay-home" dir="$TMP_ROOT/outside/relay"
  make_home "$home"; make_placement_lab "$lab" 'herdr fake:w1:p7'
  rm -f "$lab/bin/fm-overseer-arm.py" "$lab/bin/fm-overseer-watch.sh"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/new-arm.py"
  printf 'printf "event_id=123-456\\nretained event\\n"\n' > "$lab/bin/fm-overseer-watch.sh"
  cat > "$lab/fake/relay" <<'SH'
#!/usr/bin/env bash
printf '%s%s %s\n' "${RELAY_WAIT_SECONDS:-}" "${HERDR_PANE_ID:-}" "$*" >> "${0%/*}/relay.log"
SH
  chmod +x "$lab/fake/relay"
  mkdir -p "$home/config" "$home/state/overseer"
  printf 'enabled=on\nharness=claude\nmodel=m1\neffort=high\ndirectory=%s\n' "$dir" > "$home/config/overseer"
  printf 'herdr fake:w1:p2\n' > "$home/state/overseer/session"
  printf 'state\n' > "$home/state/overseer/handoff.md"
  cat >"$lab/bin/fm-overseer-arm.py" <<'PY'
import fcntl, os, pathlib, time
home = pathlib.Path(os.environ['FM_HOME'])
with (home / 'state/overseer/watch.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    lock.write(f'{os.getpid()}\nwatching\n')
    lock.flush()
    while (home / 'state/overseer/session').read_text().strip() == 'herdr fake:w1:p2':
        time.sleep(0.02)
    (home / 'typed-reminder').touch()
    time.sleep(30)
PY
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" run 1 &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
  for _ in $(seq 1 100); do [ -s "$home/state/overseer/watch.lock" ] && break; sleep 0.1; done
  mv "$lab/bin/new-arm.py" "$lab/bin/fm-overseer-arm.py"
  out=$(HERDR_PANE_ID=w9:p3 FM_RELAY_LITE="$lab/fake/relay" FM_HOME="$home" bash "$lab/bin/fm-overseer.sh" relay 2>&1) || fail "relay failed: $out"
  [ "$(cat "$lab/fake/relay.log")" = "90w1:p7 --supervisor $dir claude m1 high $home/state/overseer/handoff.md -" ] ||
    fail "relay did not pass the real pane: $(cat "$lab/fake/relay.log")"
  : > "$lab/fake/relay.log"
  out=$(env -u HERDR_PANE_ID FM_RELAY_LITE="$lab/fake/relay" FM_HOME="$home" bash "$lab/bin/fm-overseer.sh" relay-ready "$dir/state/relay-start.x" 2>&1) || fail "relay-ready failed: $out"
  [ "$(cat "$home/state/overseer/session")" = 'herdr fake:w1:p7' ] || fail 'the successor did not take over the session record'
  if kill -0 "$pid" 2>/dev/null; then fail 'predecessor wait survived relay-ready'; fi
  [ ! -e "$home/typed-reminder" ] || fail 'predecessor wrote into the successor session'
  successor=$(sed -n 1p "$home/state/overseer/watch.lock")
  [ "$successor" != "$pid" ] || fail 'the successor did not own a new wait'
  [ "$(cat "$lab/fake/relay.log")" = " --ready $dir $dir/state/relay-start.x $successor" ] ||
    fail "relay-ready did not confirm with the successor watch: $(cat "$lab/fake/relay.log")"
  assert_contains "$out" 'retained event' 'the successor background wait lost the pending event'
  pass 'relay-ready retires the detached legacy watch before handing the event to the successor job'
)

test_status_before_start() {
  local home out
  home="$TMP_ROOT/home-status"
  make_home "$home"
  out=$(FM_HOME="$home" bash "$OVERSEER" status 2>&1) || fail "status failed: $out"
  assert_contains "$out" 'configured: off' 'an existing installation must be opted out by default'
  assert_contains "$out" 'session: not started' 'status must distinguish a missing session'
  out=$(FM_HOME="$home" bash "$OVERSEER" start 2>&1) || fail "disabled start failed: $out"
  assert_contains "$out" 'overseer is disabled' 'an existing home must not start an unconfigured overseer'
  [ ! -e "$home/state/overseer/session" ] || fail 'disabled start created a session'
  out=$(FM_HOME="$home" bash "$OVERSEER" stop 2>&1) || fail "empty stop failed: $out"
  assert_contains "$out" 'overseer is not running' 'stop must handle an absent session'
  mkdir -p "$home/config"
  if [ ! -f "$ROOT/bin/fm-overseer-watch.sh" ]; then
    printf 'enabled=on\ndirectory=%s\n' "$TMP_ROOT/outside/not-started" > "$home/config/overseer"
    if out=$(FM_HOME="$home" bash "$OVERSEER" start 2>&1); then
      fail 'start accepted a missing watcher'
    fi
    assert_contains "$out" 'overseer watch is unavailable' 'start did not explain the missing watcher'
    [ ! -e "$home/state/overseer/session" ] || fail 'missing watcher left a launched session'
  fi
  printf 'enabled=invalid\n' > "$home/config/overseer"
  if out=$(FM_HOME="$home" bash "$OVERSEER" status 2>&1); then
    fail 'status accepted invalid configuration'
  fi
  assert_contains "$out" 'enabled must be on or off' 'status must explain invalid configuration'
  # The relay limit the extensions relay reads from this file is accepted here too.
  printf 'enabled=off\nrelay_tokens=400000\n' > "$home/config/overseer"
  out=$(FM_HOME="$home" bash "$OVERSEER" status 2>&1) || fail "status rejected relay_tokens: $out"
  printf 'enabled=off\nrelay_tokens=many\n' > "$home/config/overseer"
  if out=$(FM_HOME="$home" bash "$OVERSEER" status 2>&1); then
    fail 'status accepted a relay limit that is not a whole number'
  fi
  assert_contains "$out" 'relay_tokens must be a whole number' 'status must explain an invalid relay limit'
  pass 'status reports an existing installation before start and rejects invalid configuration'
}

test_doctor_uses_local_evidence() {
  local lab home out
  lab="$TMP_ROOT/doctor-code"
  home="$TMP_ROOT/doctor-home"
  mkdir -p "$lab/bin" "$home/state" "$TMP_ROOT/diagnostics/firstmate"
  cp "$ROOT/bin/fm-overseer-doctor.py" "$lab/bin/"
  printf 'printf "required: ok\\noptional: missing\\n"\n' > "$lab/bin/fm-doctor.sh"
  printf 'printf "capacity: free_lanes=0 reason=load\\n"\n' > "$lab/bin/fm-capacity.sh"
  printf 'print("wake_attention_p95_s 900 600 EXCEEDED 4 acknowledged wakes")\nprint("Test runs: 2, turns: 1, in use: 1, oldest wait (s): 10")\n' > "$lab/bin/fm-budgets.py"
  printf 'paused [at=1]: waiting for test turn\n' > "$home/state/example.status"
  python3 - "$TMP_ROOT/diagnostics/firstmate/events.jsonl" <<'PY'
import datetime, json, sys
with open(sys.argv[1], 'w') as stream:
    stream.write(json.dumps({'t': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'e': 'wake.ack'}) + '\n')
PY
  out=$(FM_HOME="$home" FM_DIAGNOSTICS_HOME="$TMP_ROOT/diagnostics" python3 "$lab/bin/fm-overseer-doctor.py" 2>&1) || fail "doctor failed: $out"
  assert_contains "$out" 'CPU load is limiting admission' 'doctor did not interpret capacity'
  assert_contains "$out" 'Wake attention is delayed' 'doctor did not identify the exceeded wake budget'
  assert_contains "$out" 'Test runs: 2, turns: 1' 'doctor omitted test contention'
  assert_contains "$out" 'Test runs are queued for host slots' 'doctor did not explain the observed test wait'
  assert_contains "$out" 'wake.ack: 1' 'doctor omitted local diagnostic events'
  assert_contains "$out" 'paused=1' 'doctor omitted declared waits'
  pass 'doctor relates local capacity, wake, test and wait evidence to leads and actions'
}

test_overseer_trust_scope() {
  local home other dir config out
  home="$TMP_ROOT/trust-home"
  other="$TMP_ROOT/trust-other"
  dir="$TMP_ROOT/outside/trust-session"
  config="$TMP_ROOT/trust-config"
  make_home "$home"
  make_home "$other"
  mkdir -p "$config"
  FM_HOME="$home" bash "$OVERSEER" setup "$dir" >/dev/null || fail 'setup for trust failed'
  if out=$(CLAUDE_CONFIG_DIR="$config" bash "$ROOT/bin/fm-claude-trust.sh" --overseer-dir "$dir" "$other" 2>&1); then
    fail 'trust accepted a different overseen home'
  fi
  assert_contains "$out" 'belongs to another home' 'trust refusal must explain the mismatch'
  CLAUDE_CONFIG_DIR="$config" bash "$ROOT/bin/fm-claude-trust.sh" --overseer-dir "$dir" "$home" >/dev/null || fail 'trust rejected a prepared overseer directory'
  python3 - "$config/.claude.json" "$dir" <<'PY' || fail 'trust flags were not limited to workspace trust'
import json, sys
entry = json.load(open(sys.argv[1]))['projects'][sys.argv[2]]
assert entry.get('hasTrustDialogAccepted') is True
assert entry.get('hasClaudeMdExternalIncludesApproved') is not True
PY
  pass 'workspace trust applies only to the overseer directory bound to this home'
}

test_adopt_hand_made_overseer() {
  local home dir lab out archive pid
  home="$TMP_ROOT/home-adopt"
  dir="$TMP_ROOT/outside/hand-made"
  make_home "$home"
  mkdir -p "$dir"
  printf 'my hand-made contract\n' >"$dir/CLAUDE.md"
  printf 'my hand-made agents\n' >"$dir/AGENTS.md"
  printf 'old handoff\n' >"$TMP_ROOT/traspaso.md"
  sleep 60 & pid=$!
  out=$(FM_HOME="$home" bash "$OVERSEER" adopt "$dir" --handoff "$TMP_ROOT/traspaso.md" --old-watch-pid "$pid" 2>&1) ||
    { kill "$pid" 2>/dev/null; fail "adopt failed: $out"; }
  archive=$(find "$home/state/overseer/adopted" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ "$(cat "$archive/CLAUDE.md")" = 'my hand-made contract' ] || fail 'the hand-made CLAUDE.md was not archived intact'
  [ "$(cat "$archive/AGENTS.md")" = 'my hand-made agents' ] || fail 'the hand-made AGENTS.md was not archived intact'
  cmp -s "$archive/handoff-traspaso.md" "$TMP_ROOT/traspaso.md" || fail 'the old handoff was not archived intact'
  [ -f "$TMP_ROOT/traspaso.md" ] || fail 'adopt removed the original handoff'
  [ "$(readlink "$dir/CLAUDE.md")" = "$CONTRACT" ] || fail 'adopt did not link the official contract'
  grep -q "^directory=$(cd -P -- "$dir" && pwd -P)\$" "$home/config/overseer" || fail 'adopt did not write the configuration'
  assert_contains "$out" 'OVERSEER_ADOPT_NOTE' 'adopt did not tell the primary about the old alert line'
  assert_contains "$out" 'left running' 'adopt must not stop the old watch before the new one is confirmed'
  kill -0 "$pid" 2>/dev/null || fail 'the old watch was stopped before the new overseer was confirmed'
  out=$(FM_HOME="$home" bash "$OVERSEER" adopt "$dir" 2>&1) || fail "a repeated adopt failed: $out"
  assert_not_contains "$out" 'archived' 'a repeated adopt archived again'

  lab="$TMP_ROOT/adopt-lab"
  mkdir -p "$lab/bin" "$lab/overseer"
  cp "$OVERSEER" "$lab/bin/"
  cp "$CONTRACT" "$lab/overseer/"
  printf 'fm_backend_agent_state() { printf alive; }\n' >"$lab/bin/fm-backend.sh"
  printf 'import sys\nprint("watch: armed")\n' >"$lab/bin/fm-overseer-arm.py"
  mkdir -p "$home/state/overseer"
  printf 'tmux x:y\n' >"$home/state/overseer/session"
  dir="$TMP_ROOT/outside/hand-made-two"
  mkdir -p "$dir"
  printf 'second hand-made contract\n' >"$dir/CLAUDE.md"
  out=$(FM_HOME="$home" bash "$lab/bin/fm-overseer.sh" adopt "$dir" --old-watch-pid "$pid" 2>&1) ||
    { kill "$pid" 2>/dev/null; fail "confirmed adopt failed: $out"; }
  assert_contains "$out" "stopped the old watch $pid" 'adopt did not stop the old watch after confirmation'
  wait "$pid" 2>/dev/null
  pass 'adopt archives a hand-made overseer intact and stops the old watch only after the new one is confirmed'
}

test_adopt_restores_on_refusal() {
  local home dir out
  home="$TMP_ROOT/home-adopt-refuse"
  dir="$TMP_ROOT/outside/adopt-refuse"
  make_home "$home"
  mkdir -p "$dir/.codex"
  printf 'my contract\n' >"$dir/CLAUDE.md"
  printf 'x = 1\n' >"$dir/.codex/config.toml"
  if out=$(FM_HOME="$home" bash "$OVERSEER" adopt "$dir" 2>&1); then fail 'adopt accepted a directory that setup refuses'; fi
  [ "$(cat "$dir/CLAUDE.md")" = 'my contract' ] || fail 'a refused adopt did not restore the hand-made contract'
  pass 'a refused adopt restores the hand-made contract'
}

test_setup_writes_native_loaders
test_setup_refuses_inside_a_firstmate_tree
test_setup_refuses_foreign_entries
test_setup_refuses_a_non_home
test_adopt_hand_made_overseer
test_adopt_restores_on_refusal

test_interventions_record_and_export
test_status_before_start
test_start_preserves_armed_watch_without_session
test_start_beside_the_primary_on_herdr
test_place_moves_the_overseer_beside_the_primary
test_relay_retires_legacy_watch
test_doctor_uses_local_evidence
test_overseer_trust_scope
test_watch_delivers_to_its_session
