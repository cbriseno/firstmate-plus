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

write_connection() {
  mkdir -p "$1/state/overseer"
  python3 - "$1/state/overseer/session-env.json" <<'PY'
import json, os, sys
keys = ('PATH', 'TMUX', 'TMUX_TMPDIR', 'HERDR_SESSION', 'FM_BACKEND', 'FM_OVERSEER_POLL', 'FM_OVERSEER_WAIT')
json.dump({key: os.environ.get(key, '') if key == 'PATH' else '' for key in keys}, open(sys.argv[1], 'w'))
PY
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
  [ -f "$dir/.codex/hooks.json" ] || fail 'setup did not install the Stop hook'
  cmp -s "$dir/.codex/hooks.json" "$dir/.claude/settings.json" || fail 'setup did not give Claude the same Stop hook'
  cmp -s "$dir/CLAUDE.md" "$CONTRACT" || fail "Claude's loader does not resolve to the contract text"
  assert_contains "$out" "OVERSEER_READY:" "setup did not report readiness"
  pass "setup links both harness loaders to the contract and names the home"

  out=$(FM_HOME="$home" bash "$OVERSEER" setup "$dir" 2>&1) || fail "a second setup failed: $out"
  assert_not_contains "$out" "OVERSEER_SETUP:" "a second setup rewrote an entry that already matched"
  pass "setup is idempotent"

  # A primary start passes explicit state/config paths: setup rewrites its own
  # earlier hook instead of refusing to start the overseer.
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" bash "$OVERSEER" setup "$dir" 2>&1) ||
    fail "setup refused the hook an earlier setup generated: $out"
  assert_contains "$(cat "$dir/.codex/hooks.json")" "FM_STATE_OVERRIDE=$home/state" 'setup did not rewrite its own Codex hook'
  cmp -s "$dir/.codex/hooks.json" "$dir/.claude/settings.json" || fail 'setup did not rewrite its own Claude hook'
  pass "setup rewrites the Stop hook an earlier setup generated"
}

test_watch_arm_and_stop() (
  local lab home out
  lab="$TMP_ROOT/watch-code"
  home="$TMP_ROOT/watch-home"
  mkdir -p "$lab/bin" "$lab/alias" "$home/state"
  write_connection "$home"
  printf 'tmux firstmate:overseer\n' > "$home/state/overseer/session"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  if FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" guard >/dev/null 2>&1; then
    fail 'turn guard accepted a missing watch'
  else
    [ "$?" -eq 2 ] || fail 'missing watch must block the turn'
  fi
  printf 'while :; do sleep 30; done\n' > "$lab/bin/fm-overseer-watch.sh"
  trap 'FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop >/dev/null 2>&1 || true' EXIT
  out=$(FM_HOME="$home" python3 "$lab/alias/../bin/fm-overseer-arm.py" arm 2>&1) || fail "watch did not start: $out"
  assert_contains "$out" 'watch armed' 'arm did not confirm a listener'
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" arm 2>&1) || fail "second arm failed: $out"
  assert_contains "$out" 'watch already' 'a second arm did not reuse the listener'
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" status)
  assert_contains "$out" 'watch: armed' 'status omitted the live listener'
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop || fail 'watch did not stop'
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" status)
  assert_contains "$out" 'watch: not armed' 'stopped listener remains active'
  : > "$home/state/overseer/stopping"
  if FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" guard >/dev/null 2>&1; then
    fail 'a late Stop hook restarted the watch after shutdown'
  fi
  pass 'watch arm is idempotent and stop reaps the listener'
)

test_watch_delivers_event() (
  local lab home out i
  lab="$TMP_ROOT/event-code"
  home="$TMP_ROOT/event-home"
  mkdir -p "$lab/bin" "$home/state/overseer"
  write_connection "$home"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  cat > "$lab/bin/fm-overseer-watch.sh" <<'SH'
if [ "${1:-}" = --ack ]; then printf '%s\n' "$2" > "$FM_EVENT_TEST_ACK"; rm -f -- "$FM_HOME/state/overseer/pending-event"; exit 0; fi
sleep 1
printf 'event_id=123-456\ntask needs attention\n' > "$FM_HOME/state/overseer/pending-event"
cat "$FM_HOME/state/overseer/pending-event"
SH
  cat > "$lab/bin/fm-backend.sh" <<'SH'
fm_backend_send_text_submit() { printf '%s\n' "$3" > "$FM_EVENT_TEST_OUTPUT"; printf empty; }
SH
  printf 'tmux firstmate:overseer\n' > "$home/state/overseer/session"
  export FM_EVENT_TEST_OUTPUT="$home/event"
  export FM_EVENT_TEST_ACK="$home/ack"
  trap 'FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop >/dev/null 2>&1 || true' EXIT
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" arm 2>&1) || fail "event wait failed to start: $out"
  for i in $(seq 1 120); do
    [ -s "$home/event" ] && break
    sleep 1
  done
  [ -s "$home/event" ] || fail 'watch event was not delivered to the session'
  assert_contains "$(cat "$home/event")" 'pending-event' 'doorbell did not point to the pending event'
  [ ! -e "$home/ack" ] || fail 'event was acknowledged before the agent acted'
  if FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" guard >/dev/null 2>&1; then fail 'pending event did not block the turn'; fi
  FM_HOME="$home" bash "$lab/bin/fm-overseer-watch.sh" --ack 123-456
  [ "$(cat "$home/ack")" = '123-456' ] || fail 'agent acknowledgement failed'
  for i in $(seq 1 120); do
    out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" status)
    case "$out" in *'watch: not armed'*) break ;; esac
    sleep 1
  done
  mv "$home/ack" "$home/ack-first"
  # shellcheck disable=SC2016 # the fake backend expands this variable at delivery time
  printf 'fm_backend_send_text_submit() { : > "$FM_EVENT_TEST_ATTEMPT"; printf unknown; }\n' > "$lab/bin/fm-backend.sh"
  export FM_EVENT_TEST_ATTEMPT="$home/attempt"
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" arm 2>&1) || fail "second event wait failed: $out"
  for i in $(seq 1 120); do
    [ -e "$home/state/overseer/unconfirmed-event" ] && break
    sleep 1
  done
  [ -e "$home/attempt" ] || fail 'the unconfirmed delivery was never attempted'
  [ ! -e "$home/ack" ] || fail 'an unconfirmed delivery was acknowledged'
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" status)
  assert_contains "$out" 'event: delivery unconfirmed' 'the uncertain delivery was not surfaced'
  if FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" guard >/dev/null 2>&1; then
    fail 'an uncertain delivery allowed a blind resend'
  fi
  pass 'watch delivers its event as evidence to the recorded session'
)

test_guard_rearms_after_delivery() (
  local lab="$TMP_ROOT/rearm-code" home="$TMP_ROOT/rearm-home" out i
  mkdir -p "$lab/bin" "$home/state/overseer"
  write_connection "$home"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  cat > "$lab/bin/fm-overseer-watch.sh" <<'SH'
if [ "${1:-}" = --ack ]; then : > "$FM_REARM_ACK"; exit 0; fi
if [ -e "$FM_REARM_ONCE" ]; then while :; do sleep 30; done; fi
: > "$FM_REARM_ONCE"
sleep 1
printf 'event_id=123-456\ntest event\n'
SH
  cat > "$lab/bin/fm-backend.sh" <<'SH'
fm_backend_send_text_submit() { : > "$FM_REARM_SENDING"; sleep 3; printf empty; }
SH
  printf 'tmux firstmate:overseer\n' > "$home/state/overseer/session"
  export FM_REARM_ACK="$home/ack" FM_REARM_ONCE="$home/once" FM_REARM_SENDING="$home/sending"
  trap 'FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop >/dev/null 2>&1 || true' EXIT
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" arm >/dev/null || fail 'initial watch failed'
  for i in $(seq 1 120); do [ -e "$home/sending" ] && break; sleep 1; done
  [ -e "$home/sending" ] || fail 'event delivery never began'
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" guard 2>&1) || fail "guard did not wait and rearm: $out"
  assert_equals '' "$out" 'a successful Stop hook must not print invalid hook output'
  [ -e "$home/sending" ] || fail 'guard returned before delivery began'
  out=$(FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" status)
  assert_contains "$out" 'watch: armed' 'guard failed to leave the next wait armed'
  pass 'turn guard waits for delivery before arming the next event wait'
)

test_stop_during_delivery() (
  local lab="$TMP_ROOT/stop-code" home="$TMP_ROOT/stop-home" i sender
  mkdir -p "$lab/bin" "$home/state/overseer"
  write_connection "$home"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  printf 'sleep 1\nprintf "event_id=123-456\\ntest event\\n"\n' > "$lab/bin/fm-overseer-watch.sh"
  cat > "$lab/bin/fm-backend.sh" <<'SH'
fm_backend_send_text_submit() { printf '%s\n' "$$" > "$FM_SENDER_PID"; sleep 30; printf empty; }
SH
  printf 'tmux firstmate:overseer\n' > "$home/state/overseer/session"
  export FM_SENDER_PID="$home/sender"
  trap 'FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop >/dev/null 2>&1 || true' EXIT
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" arm >/dev/null || fail 'watch failed to start'
  for i in $(seq 1 120); do [ -s "$home/sender" ] && break; sleep 1; done
  [ -s "$home/sender" ] || fail 'delivery never began'
  sender=$(cat "$home/sender")
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop || fail 'stop did not end an active delivery'
  if kill -0 "$sender" 2>/dev/null; then fail 'sender survived stop'; fi
  pass 'stop ends an in-progress event delivery'
)

test_stop_hook_uses_bound_home() (
  local lab="$TMP_ROOT/hook-code" home="$TMP_ROOT/hook-home" other="$TMP_ROOT/hook-other" dir="$TMP_ROOT/outside/hook-session" command out
  mkdir -p "$lab/bin" "$lab/overseer" "$home/state" "$other/state"
  write_connection "$home"
  printf 'tmux firstmate:overseer\n' > "$home/state/overseer/session"
  : > "$home/SUPERVISOR.md"
  cp "$ROOT/bin/fm-overseer.sh" "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  cp "$ROOT/overseer/AGENTS.md" "$lab/overseer/AGENTS.md"
  # shellcheck disable=SC2016 # the fake watch expands these variables when it runs
  printf 'printf "%%s\\n" "$TMUX_TMPDIR" > "$FM_CONTEXT_TEST"\nwhile :; do sleep 30; done\n' > "$lab/bin/fm-overseer-watch.sh"
  python3 - "$home/state/overseer/session-env.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value['TMUX_TMPDIR'] = '/tmp/firstmate-test-socket'
json.dump(value, open(path, 'w'))
PY
  trap 'env -u FM_STATE_OVERRIDE FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop >/dev/null 2>&1 || true' EXIT
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$home" bash "$lab/bin/fm-overseer.sh" setup "$dir" >/dev/null || fail 'hook setup failed'
  command=$(python3 - "$dir/.codex/hooks.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['hooks']['Stop'][0]['hooks'][0]['command'])
PY
  )
  out=$(FM_HOME="$other" FM_STATE_OVERRIDE="$other/state" TMUX_TMPDIR=/tmp/wrong FM_CONTEXT_TEST="$home/context" bash -c "$command" 2>&1) || fail "bound hook failed: $out"
  [ -f "$home/state/overseer/watch.lock" ] || fail 'hook did not arm the bound home'
  [ ! -e "$other/state/overseer/watch.lock" ] || fail 'hook armed the inherited foreign home'
  for _ in $(seq 1 120); do [ -s "$home/context" ] && break; sleep 1; done
  [ "$(cat "$home/context")" = /tmp/firstmate-test-socket ] || fail 'hook did not restore the session socket'
  pass 'Stop hook arms the bound home even when its process inherits another home'
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
    assert len(rows) == 2 and rows[0]['root_task'] == 0 and rows[1]['root_task'] == 1
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
    printf '#!/usr/bin/env bash\n[ "$1" = --locate ] && echo %q\n' "$2" > "$lab/bin/fm-overseer-primary.sh"
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

test_relay_keeps_the_installation_watch() (
  local lab home dir out pid
  lab="$TMP_ROOT/relay-code" home="$TMP_ROOT/relay-home" dir="$TMP_ROOT/outside/relay"
  make_home "$home"; make_placement_lab "$lab" 'herdr fake:w1:p7'
  rm -f "$lab/bin/fm-overseer-arm.py" "$lab/bin/fm-overseer-watch.sh"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  printf 'while :; do sleep 30; done\n' > "$lab/bin/fm-overseer-watch.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s%%s %%s\\n" "${RELAY_WAIT_SECONDS:-}" "$HERDR_PANE_ID" "$*" >> "${0%%/*}/relay.log"\n' > "$lab/fake/relay"
  chmod +x "$lab/fake/relay"
  mkdir -p "$home/config"
  printf 'enabled=on\nharness=claude\nmodel=m1\neffort=high\ndirectory=%s\n' "$dir" > "$home/config/overseer"
  write_connection "$home"
  printf 'herdr fake:w1:p2\n' > "$home/state/overseer/session"
  printf 'state\n' > "$home/state/overseer/handoff.md"
  trap 'FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop >/dev/null 2>&1 || true' EXIT
  # Outgoing: its real pane (not a stale HERDR_PANE_ID) and '-' for the watch.
  out=$(HERDR_PANE_ID=w9:p3 FM_RELAY_LITE="$lab/fake/relay" FM_HOME="$home" bash "$lab/bin/fm-overseer.sh" relay 2>&1) || fail "relay failed: $out"
  [ "$(cat "$lab/fake/relay.log")" = "90w1:p7 --supervisor $dir claude m1 high $home/state/overseer/handoff.md -" ] ||
    fail "relay did not hand over with the real pane and the installation watch: $(cat "$lab/fake/relay.log")"
  # Successor: takes the session record and confirms with the one running watch.
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" arm >/dev/null || fail 'the installation watch did not arm'
  pid=$(sed -n 1p "$home/state/overseer/watch.lock")
  : > "$lab/fake/relay.log"
  out=$(env -u HERDR_PANE_ID FM_RELAY_LITE="$lab/fake/relay" FM_HOME="$home" bash "$lab/bin/fm-overseer.sh" relay-ready "$dir/state/relay-start.x" 2>&1) || fail "relay-ready failed: $out"
  [ "$(cat "$home/state/overseer/session")" = 'herdr fake:w1:p7' ] || fail 'the successor did not take over the session record'
  if [ "$(sed -n 1p "$home/state/overseer/watch.lock")" != "$pid" ] || ! kill -0 "$pid"; then
    fail 'the relay replaced or stopped the installation watch'
  fi
  [ "$(cat "$lab/fake/relay.log")" = " --ready $dir $dir/state/relay-start.x $pid" ] ||
    fail "relay-ready did not confirm with the running watch: $(cat "$lab/fake/relay.log")"
  pass 'an overseer relay keeps the installation watch, uses the real pane, and points the watch at the successor'
)

test_guard_adopts_the_pane_its_turn_ends_in() (
  local lab home
  lab="$TMP_ROOT/adopt-code" home="$TMP_ROOT/adopt-home"
  mkdir -p "$lab/bin" "$home/state"
  write_connection "$home"
  printf 'tmux firstmate:overseer\n' > "$home/state/overseer/session"
  cp "$ROOT/bin/fm-overseer-arm.py" "$lab/bin/"
  printf 'while :; do sleep 30; done\n' > "$lab/bin/fm-overseer-watch.sh"
  printf '#!/usr/bin/env bash\n[ "$1" = --locate ] && [ -n "$2" ] && echo "tmux %%9"\n' > "$lab/bin/fm-overseer-primary.sh"
  trap 'FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" stop >/dev/null 2>&1 || true' EXIT
  FM_HOME="$home" python3 "$lab/bin/fm-overseer-arm.py" guard >/dev/null 2>&1 || fail 'guard did not arm'
  [ "$(cat "$home/state/overseer/session")" = 'tmux %9' ] || fail 'a relay successor did not take over the session record'
  pass 'the Stop guard records the endpoint its turn ends in, so a relay successor receives events'
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
test_start_beside_the_primary_on_herdr
test_place_moves_the_overseer_beside_the_primary
test_relay_keeps_the_installation_watch
test_guard_adopts_the_pane_its_turn_ends_in
test_doctor_uses_local_evidence
test_overseer_trust_scope
test_watch_arm_and_stop
test_watch_delivers_event
test_guard_rearms_after_delivery
test_stop_during_delivery
test_stop_hook_uses_bound_home
