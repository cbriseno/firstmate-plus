#!/usr/bin/env bash
# Portable native-owner regressions over real processes, watcher and queue.
# The copied Bash named codex is a process fixture, never vendor evidence.
# Its queue subcommand is a local recorder; no installed Codex is executed.
# FM_CODEX_NATIVE_CASES selects focused scenarios; unset runs every case.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
OWNER="$ROOT/bin/fm-codex-stop-autoarm.sh"

if [ "$(uname -s)" != Linux ]; then
  unsupported=$(fm_test_tmproot fm-codex-native-unsupported)
  mkdir -p "$unsupported/config" "$unsupported/state"
  printf '{}\n' > "$unsupported/config/codex-native-supervision.json"
  chmod 600 "$unsupported/config/codex-native-supervision.json"
  FM_HOME="$unsupported" FM_CONFIG_OVERRIDE="$unsupported/config" FM_STATE_OVERRIDE="$unsupported/state" \
    bash "$OWNER" --capable && fail 'non-Linux selected native supervision'
  printf '{}\n' | FM_HOME="$unsupported" FM_CONFIG_OVERRIDE="$unsupported/config" FM_STATE_OVERRIDE="$unsupported/state" \
    bash "$OWNER" || fail 'unsupported Stop failed'
  [ ! -e "$unsupported/state/.codex-native.json" ] || fail 'unsupported platform created native ownership'
  pass 'non-Linux keeps native supervision disabled; Linux process cases not applicable'
  exit 0
fi

if [ "${1:-}" = --case ]; then
  CASE_HOME=$2
  scenario=$3
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  THREAD=11111111-1111-4111-8111-111111111111
  SESSION=$THREAD
  export CODEX_THREAD_ID=$THREAD
  printf '%s\n' "$$" > "$STATE/.lock"
  identity=$(fm_pid_identity "$$") || fail 'cannot identify the fixture process'
  hash=$(sha256sum "$CASE_HOME/codex" | awk '{print $1}')
  jq -n --arg thread "$THREAD" --arg session "$SESSION" --arg pid "$$" --arg identity "$identity" \
    --arg bin "$CASE_HOME/codex" --arg hash "$hash" --arg home "$CASE_HOME/user/codex" \
    '{schema:1,cli_version:"0.164.0",thread_id:$thread,session_id:$session,owner_pid:$pid,
      owner_identity:$identity,executable:$bin,executable_sha256:$hash,remote:"unix:///fixture.sock",codex_home:$home}' \
    > "$CONFIG/codex-native-supervision.json"
  chmod 600 "$CONFIG/codex-native-supervision.json"
  jq -n --arg session "$SESSION" '{hook_event_name:"Stop",session_id:$session,turn_id:"turn-one",stop_hook_active:false}' > "$CASE_HOME/payload"
  printf '#!/bin/bash\nexit 0\n' > "$STATE/native-need.check.sh"
  chmod 700 "$STATE/native-need.check.sh"
  bash "$ROOT/bin/fm-check-register.sh" native-need >/dev/null || fail 'cannot register fixture need'
  : > "$STATE/probe.status"
  # Adopt only the empty initial snapshot; later appended events must wake.
  fm_wake_status_mark_current "$STATE" "$STATE/probe.status" || fail 'cannot establish signal baseline'
  fm_wake_signal_seen_current "$STATE" "$STATE/probe.status" || fail 'signal baseline was not adopted'
  callback=
  foreground=
  # shellcheck disable=SC2329 # EXIT trap owns the private callback.
  cleanup_case() {
    if [ -n "$callback" ]; then
      kill -TERM "$callback" 2>/dev/null || true
      wait "$callback" 2>/dev/null || true
    fi
    if [ -n "$foreground" ]; then
      printf 'done: foreground fixture cleanup\n' >> "$STATE/probe.status"
      wait "$foreground" 2>/dev/null || true
    fi
  }
  trap cleanup_case EXIT
  run_owner() { bash "$OWNER" "$@"; }
  start_owner() {
    env -u CODEX_THREAD_ID bash "$OWNER" < "$CASE_HOME/payload" > "$CASE_HOME/owner.out" 2> "$CASE_HOME/owner.err" &
    callback=$!
  }
  wait_healthy() {
    local i
    for i in $(seq 200); do
      if fm_watcher_healthy "$STATE" "$ROOT/bin/fm-watch.sh" 300 "$FM_HOME"; then
        watcher_pid=$(cat "$STATE/.watch.lock/pid")
        watcher_identity=$(fm_pid_identity "$watcher_pid")
        return 0
      fi
      sleep 0.1
    done
    fail "fixture watcher did not start: $(cat "$CASE_HOME/owner.err")"
  }
  wait_closed() {
    local i
    for i in $(seq 200); do
      [ "$(fm_pid_identity "$watcher_pid" 2>/dev/null)" != "$watcher_identity" ] && break
      sleep 0.1
    done
    [ "$(fm_pid_identity "$watcher_pid" 2>/dev/null)" != "$watcher_identity" ] \
      || fail "watcher survived owner cleanup: $(cat "$CASE_HOME/owner.err")"
    fm_watcher_healthy "$STATE" "$ROOT/bin/fm-watch.sh" 300 "$FM_HOME" && fail 'dead watcher retained healthy supervision'
    [ "${1:-}" != watcher-only ] || return 0
    wait "$callback" 2>/dev/null || true
    callback=
  }
  wait_phase() {
    local i
    for i in $(seq 250); do
      [ "$(jq -r '.phase' "$STATE/.codex-native.json" 2>/dev/null)" != "$1" ] || return 0
      sleep 0.1
    done
    fail "phase $1 absent: $(cat "$STATE/.codex-native.json" "$CASE_HOME/owner.err" 2>/dev/null)"
  }
  acknowledge_event() {
    local drain sequence recovery
    drain=$(bash "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail 'cannot drain fixture event'
    [ -s "$STATE/.wake-queue" ] || fail 'presentation acknowledged the wake'
    printf 'one action\n' >> "$CASE_HOME/handled"
    sequence=$(printf '%s\n' "$drain" | sed -n 's/.*WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\).*/\1/p')
    recovery=$(printf '%s\n' "$drain" | sed -n 's/.*WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
    [ -n "$sequence" ] && [ -n "$recovery" ] || fail 'drain omitted bounded ACK command'
    bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$recovery" >/dev/null 2>&1 \
      || fail 'handled wake could not be acknowledged'
    [ ! -s "$STATE/.wake-queue" ] || fail 'ACK did not retire handled wake'
  }
  queue_count() { wc -l < "$CASE_HOME/calls" | tr -d ' '; }
  mutate_binding() {
    jq "$1" "$CONFIG/codex-native-supervision.json" > "$CASE_HOME/changed"
    cat "$CASE_HOME/changed" > "$CONFIG/codex-native-supervision.json"
  }
  case "$scenario" in
    protocol-primary-submit)
      python3 - "$ROOT/bin/fm-codex-native-rpc.py" "$CASE_HOME" "$THREAD" <<'PY' || fail 'guarded primary qualification failed'
import hashlib, json, os, pathlib, socket, subprocess, sys, threading, uuid
transport, directory, thread = sys.argv[1:]
home = pathlib.Path(directory)
(home / '.fm-secondmate-home').unlink()
subprocess.run(['git', 'init', '--quiet', str(home)], check=True)
(home / 'app-server').write_text('import runpy\nrunpy.run_path(' + repr(str(home / 'proxy.py')) + ', run_name="__main__")\n')
endpoint = home / 'primary.sock'
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(str(endpoint)); listener.listen()
received = []
def accept():
    while True:
        try:
            peer, _ = listener.accept()
        except OSError:
            return
        with peer:
            received.append(peer.recv(1))
threading.Thread(target=accept, daemon=True).start()
digest = hashlib.sha256(pathlib.Path(sys.executable).read_bytes()).hexdigest()
base = dict(home=str(home), owner_pid=str(os.getpid()), executable=sys.executable,
            executable_sha256=digest, remote='unix://' + str(endpoint), thread=thread)
def run(mode='submit', state='active', changes=None, missing_thread=False, wrong_thread=False, client=None):
    (home / 'state/.lock').write_text(str(os.getpid()) + '\n')
    (home / 'inspect-state').write_text(state)
    (home / 'mutations').write_text('')
    options = dict(base, client_id=client or str(uuid.uuid4()))
    options.update(changes or {})
    command = [sys.executable, transport, mode]
    for key, value in options.items():
        command.extend(['--' + key.replace('_', '-'), value])
    env = dict(os.environ, CODEX_THREAD_ID='foreign' if wrong_thread else thread)
    if missing_thread:
        env.pop('CODEX_THREAD_ID', None)
    result = subprocess.run(command, input='Direct diagnostic note only.\n', env=env,
                            text=True, capture_output=True, timeout=12, cwd=home)
    assert 'PRIVATE_' not in result.stdout + result.stderr, result.stdout
    calls = [json.loads(line) for line in (home / 'mutations').read_text().splitlines()]
    return result, json.loads(result.stdout), calls, options['client_id']
try:
    for state in ('active', 'idle'):
        result, value, calls, client = run(state=state)
        assert result.returncode == 0 and value == dict(turn_id='direct-turn', status='inProgress', client_id=client), (result.stdout, result.stderr)
        assert calls == [dict(method='turn/start', client_id=client)], calls
    (home / 'idle-after-read').touch()
    result, value, calls, client = run(changes=dict(wait_for_idle='4'))
    assert result.returncode == 0 and value.get('idle_observed_at') and len(calls) == 1, (value, calls)
    (home / 'idle-after-read').unlink()
    result, value, calls, _ = run(changes=dict(wait_for_idle='1'))
    assert result.returncode == 1 and not calls, 'bounded active-only wait submitted input'
    for options in [dict(missing_thread=True), dict(wrong_thread=True),
                    dict(changes=dict(owner_pid=str(os.getppid()))),
                    dict(changes=dict(executable_sha256='0'*64)),
                    dict(changes=dict(executable='/bin/sh')),
                    dict(state='notLoaded'), dict(state='systemError'), dict(state='wrong-cwd')]:
        result, value, calls, _ = run(**options)
        assert result.returncode == 1 and value['error_class'] == 'protocol-unproved' and not calls, (options, value, calls)
    (home / 'change-primary-lock').touch()
    result, value, calls, _ = run()
    assert result.returncode == 1 and not calls, 'changed owner dispatched input'
    (home / 'change-primary-lock').unlink()
    # A real wrong peer PID must fail despite a valid own process and binary.
    other = home / 'other.sock'
    peer_process = subprocess.Popen([sys.executable, '-c',
        'import socket,sys\ns=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen();print("ready",flush=True)\nwhile True:\n c,_=s.accept();c.close()\n', str(other)], stdout=subprocess.PIPE, text=True)
    try:
        assert peer_process.stdout.readline().strip() == 'ready'
        result, value, calls, _ = run(changes=dict(remote='unix://' + str(other)))
        assert result.returncode == 1 and not calls, 'another socket owner dispatched input'
    finally:
        peer_process.terminate(); peer_process.wait(timeout=3); peer_process.stdout.close()
    (home / 'queue-entries').write_text(json.dumps(['other', 'wanted']))
    result, value, calls, _ = run(mode='queue-remove', changes=dict(submission_id='wanted'), client='incorrect-client')
    assert result.returncode == 1 and not calls and json.loads((home / 'queue-entries').read_text()) == ['other','wanted'], 'wrong queue identity removed input'
    result, value, calls, _ = run(mode='queue-remove', changes=dict(submission_id='wanted'), client='client-wanted')
    assert result.returncode == 0 and value['queue_state'] == 'removed', value
    assert calls == [dict(method='thread/queue/delete', submission_id='wanted')], calls
    assert json.loads((home / 'queue-entries').read_text()) == ['other'], 'another draft was removed'
    result, value, calls, _ = run(mode='queue-remove', changes=dict(submission_id='wanted'), client='client-wanted')
    assert result.returncode == 0 and value['queue_state'] == 'not-found' and not calls, 'absence retried removal'
    inbox = home / 'state/inbox'
    inbox.mkdir()
    def note(name):
        (inbox / (name + '.note')).write_text('id=' + name + '\n--\nAdvisory only.\n')
    note('unconfigured')
    result, value, calls, _ = run(mode='deliver', changes=dict(note_id='unconfigured'), wrong_thread=True)
    assert result.returncode == 0 and value['state'] == 'unavailable' and not calls, value
    result, value, calls, _ = run(mode='register')
    assert result.returncode == 0 and value['state'] == 'registered' and not calls, value
    route = home / 'state/.codex-primary-ingress.json'
    before = route.read_bytes()
    result, value, calls, _ = run(mode='register', wrong_thread=True)
    assert result.returncode == 1 and route.read_bytes() == before, 'foreign sender registered a receiver'
    for state in ('active', 'idle'):
        name = 'event-' + state
        note(name)
        result, value, calls, _ = run(mode='deliver', changes=dict(note_id=name), state=state, missing_thread=True)
        assert result.returncode == 0 and value['state'] == 'accepted' and len(calls) == 1, (value, calls)
        client = value['client_id']
        result, value, calls, _ = run(mode='deliver', changes=dict(note_id=name), state=state, wrong_thread=True)
        assert result.returncode == 0 and value['state'] == 'accepted' and value['client_id'] == client and not calls, 'event replay resubmitted input'
    note('repair')
    route.chmod(0o644)
    result, value, calls, _ = run(mode='deliver', changes=dict(note_id='repair'), missing_thread=True)
    assert result.returncode == 1 and value['state'] == 'unavailable' and not calls, 'unsafe receiver dispatched'
    assert not (inbox / '.native/repair.json').exists(), 'unattempted event cannot be repaired'
    route.chmod(0o600)
    result, value, calls, _ = run(mode='deliver', changes=dict(note_id='repair'), missing_thread=True)
    assert result.returncode == 0 and value['state'] == 'accepted' and len(calls) == 1, 'safe explicit retry did not repair delivery'
    note('ambiguous')
    (home / 'fail-direct').touch()
    result, value, calls, _ = run(mode='deliver', changes=dict(note_id='ambiguous'), missing_thread=True)
    assert result.returncode == 1 and value['state'] == 'unproved' and len(calls) == 1, (value, calls)
    (home / 'fail-direct').unlink()
    result, value, calls, _ = run(mode='deliver', changes=dict(note_id='ambiguous'), missing_thread=True)
    assert result.returncode == 0 and value['state'] == 'unproved' and not calls and (inbox / 'ambiguous.note').exists(), 'ambiguous delivery replayed or lost the durable note'
    # The actual inbox producer delegates to this receiver without borrowing
    # the primary's thread environment and retains one note/wake/input on retry.
    (home / 'state/.lock').write_text(str(os.getpid()) + '\n')
    (home / 'inspect-state').write_text('active')
    (home / 'mutations').write_text('')
    inbox_env = dict(os.environ, FM_HOME=str(home))
    inbox_env.pop('CODEX_THREAD_ID', None)
    command = ['bash', str(pathlib.Path(transport).parent / 'fm-inbox.sh')]
    def capture():
        result = subprocess.run(command + ['note','--wake-primary','--json','--request-id','inbox-native-proof','Advisory only'],
                                env=inbox_env, cwd=home, text=True, capture_output=True, timeout=15)
        assert result.returncode == 0, (result.stdout, result.stderr)
        return json.loads(result.stdout)
    first = capture(); replay = capture()
    assert first['id'] == replay['id'] and first['native_delivery']['state'] == replay['native_delivery']['state'] == 'accepted', (first,replay)
    assert len((home / 'mutations').read_text().splitlines()) == 1, 'inbox retry duplicated native input'
    assert (home / 'state/.wake-queue').read_text().count('\tinbox:' + first['id'] + '\t') == 1, 'inbox retry duplicated durable wake'
    subprocess.run(command + ['reply',first['id'],'Handled without deletion.'], env=inbox_env, cwd=home, check=True, capture_output=True)
    subprocess.run(command + ['drain','--ack',first['id']], env=inbox_env, cwd=home, check=True, capture_output=True)
    assert capture()['native_delivery']['state'] == 'already-handled', 'handled note caused another native input'
    assert len((home / 'mutations').read_text().splitlines()) == 1
    # Exercise request_removal through the public work owner and the same
    # registered receiver, including its actual reply receipt and no deletion.
    data = home / 'data'; data.mkdir(exist_ok=True)
    (home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
    (data / 'projects.md').write_text('- sample [local-only] - Sample\n')
    (data / 'backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    wrapper = ['bash', str(pathlib.Path(transport).parent / 'fm-tasks-axi.sh')]
    def work(*arguments, payload=None, text=False):
        result = subprocess.run(wrapper + list(arguments), env=inbox_env, cwd=home, text=True,
            input=json.dumps(payload) if payload else None, capture_output=True, timeout=20)
        assert result.returncode == 0, (result.stdout, result.stderr)
        return result.stdout if text else json.loads(result.stdout)
    work('add','unit','Advisory unit','--repo','sample',text=True)
    before = (data / 'backlog.md').read_bytes()
    revision = work('work','snapshot')['rev']
    operation = dict(op='request_removal', target='task:unit', actor='captain', expected_rev=revision,
                     request_id='native-work-request-0001', note='Review, no deletion.')
    (home / 'mutations').write_text('')
    first = work('work','apply',payload=operation)
    replay = work('work','apply',payload=operation)
    assert first['state'] == replay['state'] == 'received' and first['consultation']['native_delivery']['state'] == 'accepted', (first,replay)
    assert first['consultation']['note_id'] == replay['consultation']['note_id'] and len((home / 'mutations').read_text().splitlines()) == 1
    subprocess.run(command + ['reply',first['consultation']['note_id'],'Reviewed, no deletion authorized.'], env=inbox_env, cwd=home, check=True, capture_output=True)
    answered = work('work','request-status','--request-id',operation['request_id'])
    assert answered['state'] == 'applied' and answered['consultation']['status'] == 'replied', answered
    assert (data / 'backlog.md').read_bytes() == before and not (data / 'work-structure.json').exists(), 'removal consultation changed work'
    assert not any(received), 'kernel peer check sent protocol input'
finally:
    listener.close()
print('primary qualification: active/idle direct input, real owner/socket guard, exact diagnostic removal and privacy verified')
PY
      ;;
    protocol-queue-status)
      printf 'active\n' > "$CASE_HOME/inspect-state"
      for state in queued not-found unknown; do
        case "$state" in
          queued) printf '["other","wanted"]\n' > "$CASE_HOME/queue-entries" ;;
          not-found) printf '["other"]\n' > "$CASE_HOME/queue-entries" ;;
          unknown) printf '["a","b","c","d","wanted"]\n' > "$CASE_HOME/queue-entries" ;;
        esac
        python3 "$ROOT/bin/fm-codex-native-rpc.py" queue-status --executable "$CASE_HOME/codex" \
          --remote unix:///fixture.sock --thread "$THREAD" --submission-id wanted \
          > "$CASE_HOME/queue-status.json" 2> "$CASE_HOME/queue-status.err" || fail 'queue metadata probe failed'
        jq -e --arg state "$state" --arg thread "$THREAD" \
          '.queue_state == $state and .thread_id == $thread and .thread_status == "active" and .submission_id == "wanted"' \
          "$CASE_HOME/queue-status.json" >/dev/null || fail 'queue presence or bounded unknown was misreported'
        if [ "$state" = queued ]; then
          jq -e '.client_id == "client-wanted"' "$CASE_HOME/queue-status.json" >/dev/null || fail 'own queue/client join missing'
        fi
        if grep -Eq 'PRIVATE_|other|client-[abcd]"' "$CASE_HOME/queue-status.json" "$CASE_HOME/queue-status.err"; then
          fail 'queue metadata probe exposed draft or another submission'
        fi
      done
      assert_equals 0 "$(queue_count)" 'queue metadata probe submitted input'
      ;;
    protocol-inspect)
      for state in active idle notLoaded systemError foreign invalid; do
        printf '%s\n' "$state" > "$CASE_HOME/inspect-state"
        rc=0
        python3 "$ROOT/bin/fm-codex-native-rpc.py" inspect --executable "$CASE_HOME/codex" \
          --remote unix:///fixture.sock --thread "$THREAD" \
          > "$CASE_HOME/inspect.json" 2> "$CASE_HOME/inspect.err" || rc=$?
        case "$state" in
          foreign|invalid) assert_equals 1 "$rc" 'unproved identity/status was accepted' ;;
          *)
            assert_equals 0 "$rc" 'exact thread metadata read failed'
            jq -e --arg state "$state" --arg thread "$THREAD" --arg cwd "$CASE_HOME" \
              '. == {thread_id:$thread,status:$state,cwd:$cwd}' "$CASE_HOME/inspect.json" >/dev/null \
              || fail 'inspection exposed more than exact thread identity/status/cwd'
            ;;
        esac
        if grep -q PRIVATE_ "$CASE_HOME/inspect.json" "$CASE_HOME/inspect.err"; then
          fail 'read-only inspection exposed private content'
        fi
      done
      assert_equals 0 "$(queue_count)" 'read-only inspection submitted input'
      ;;
    protocol-wire|protocol-fragment|protocol-bad-upgrade)
      printf '[{"id":"turn-two","client_id":"fixture-client"}]\n' > "$CASE_HOME/turns"
      [ "$scenario" != protocol-fragment ] || : > "$CASE_HOME/fragment"
      [ "$scenario" != protocol-bad-upgrade ] || : > "$CASE_HOME/bad-upgrade"
      rc=0
      python3 "$ROOT/bin/fm-codex-native-rpc.py" outcome --executable "$CASE_HOME/codex" \
        --remote unix:///fixture.sock --thread "$THREAD" --turn-id turn-two \
        > "$CASE_HOME/wire.json" 2> "$CASE_HOME/wire.err" || rc=$?
      if [ "$scenario" = protocol-bad-upgrade ]; then
        assert_equals 1 "$rc" 'invalid WebSocket accept was trusted'
        jq -e '.error_class == "protocol-unproved" and .diagnostic.phase == "upgrade"
          and .diagnostic.httpCode == 101' "$CASE_HOME/wire.json" >/dev/null || fail 'upgrade rejection lost safe phase'
      else
        assert_equals 0 "$rc" 'control-socket WebSocket wire format was not supported'
        jq -e '.turn_id == "turn-two" and .status == "inProgress"' "$CASE_HOME/wire.json" >/dev/null \
          || fail 'metadata outcome did not cross the WebSocket relay'
      fi
      assert_equals 0 "$(queue_count)" 'readonly wire probe submitted input'
      ;;
    protocol-diagnostic)
      : > "$CASE_HOME/initialize-error"
      rc=0
      python3 "$ROOT/bin/fm-codex-native-rpc.py" outcome --executable "$CASE_HOME/codex" \
        --remote unix:///fixture.sock --thread "$THREAD" --turn-id turn-two \
        > "$CASE_HOME/diagnostic.json" 2> "$CASE_HOME/diagnostic.err" || rc=$?
      assert_equals 1 "$rc" 'unproved initialize did not fail closed'
      jq -e '.error_class == "protocol-unproved" and .diagnostic.phase == "rpc"
        and .diagnostic.operation == "initialize" and .diagnostic.rpcCode == -32600
        and .diagnostic.deadline == false' "$CASE_HOME/diagnostic.json" >/dev/null \
        || fail 'RPC rejection lost its safe diagnostic'
      if grep -q PRIVATE_ "$CASE_HOME/diagnostic.json" "$CASE_HOME/diagnostic.err"; then
        fail 'diagnostic exposed arbitrary vendor text'
      fi
      assert_equals 0 "$(queue_count)" 'readonly diagnostic submitted input'
      ;;
    off)
      rm "$CONFIG/codex-native-supervision.json"
      run_owner < "$CASE_HOME/payload" || fail 'disabled hook failed'
      run_owner --capable && fail 'default selected native supervision'
      [ ! -e "$STATE/.codex-native.json" ] || fail 'disabled hook wrote a native receipt'
      [ "$(queue_count)" -eq 0 ] || fail 'disabled hook called queue'
      rc=0
      run_owner --guard < "$CASE_HOME/payload" > "$CASE_HOME/guard.out" 2>&1 || rc=$?
      assert_equals "$rc" 2 'default-off hook stopped enforcing the foreground guard'
      jq '.stop_hook_active = true' "$CASE_HOME/payload" > "$CASE_HOME/repeat-payload"
      run_owner --guard < "$CASE_HOME/repeat-payload" || fail 'default-off loop allowance changed'
      ;;
    handoff)
      # The bound must outlive every guard and displacement step below; the
      # controlled event ends this checkpoint early. A 90s bound expired before
      # the supervision-host step on slow runners.
      bash "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 600 > "$CASE_HOME/foreground.out" 2> "$CASE_HOME/foreground.err" &
      foreground=$!
      wait_healthy
      rc=0
      guard_started=$(date +%s)
      env -u CODEX_THREAD_ID bash "$ROOT/bin/fm-turnend-guard.sh" < "$CASE_HOME/payload" \
        > "$CASE_HOME/legacy.out" 2> "$CASE_HOME/legacy.err" || rc=$?
      printf '# legacy Stop with foreground only: exit=%s\n' "$rc"
      assert_equals 2 "$rc" 'legacy Stop allowed native root to finish with only a foreground checkpoint'
      guard_elapsed=$(($(date +%s) - guard_started))
      printf '# native guard returned in %ss; foreground checkpoint bound=600s\n' "$guard_elapsed"
      [ "$guard_elapsed" -lt 25 ] || fail "native guard exceeded its synchronous hook budget: ${guard_elapsed}s"
      assert_contains "$(cat "$CASE_HOME/legacy.err")" 'keep this turn open' 'missing foreground continuation instruction'
      for active in false true; do
        jq --argjson active "$active" '.stop_hook_active = $active' "$CASE_HOME/payload" > "$CASE_HOME/repeat-payload"
        for entry in legacy shim; do
          rc=0
          if [ "$entry" = legacy ]; then
            env -u CODEX_THREAD_ID bash "$ROOT/bin/fm-turnend-guard.sh" < "$CASE_HOME/repeat-payload" \
              > "$CASE_HOME/repeat.out" 2> "$CASE_HOME/repeat.err" || rc=$?
          else
            env -u CODEX_THREAD_ID bash "$OWNER" --guard < "$CASE_HOME/repeat-payload" \
              > "$CASE_HOME/repeat.out" 2> "$CASE_HOME/repeat.err" || rc=$?
          fi
          assert_equals 2 "$rc" "$entry allowed unproved native handoff with stop_hook_active=$active"
        done
      done
      cp "$CONFIG/codex-native-supervision.json" "$CASE_HOME/original-binding"
      mutate_binding '.owner_identity = "obsolete"'
      rc=0
      run_owner --guard < "$CASE_HOME/payload" > "$CASE_HOME/invalid.out" 2>&1 || rc=$?
      assert_equals 2 "$rc" 'invalid owner proof removed the native requirement'
      cat "$CASE_HOME/original-binding" > "$CONFIG/codex-native-supervision.json"
      jq '.turn_id = ""' "$CASE_HOME/payload" > "$CASE_HOME/invalid-turn"
      rc=0
      bash "$ROOT/bin/fm-turnend-guard.sh" < "$CASE_HOME/invalid-turn" > "$CASE_HOME/invalid.out" 2>&1 || rc=$?
      assert_equals 2 "$rc" 'invalid turn proof escaped through legacy Stop'
      if ! fm_watcher_healthy "$STATE" "$ROOT/bin/fm-watch.sh" 300 "$FM_HOME"; then
        cat "$CASE_HOME/foreground.out" "$CASE_HOME/foreground.err" >&2
        fail 'foreground fixture is no longer healthy after blocked finals'
      fi
      printf '# foreground fixture remains healthy after native blocks\n'
      [ ! -e "$STATE/.codex-native.json" ] || fail 'guard manufactured native ownership'
      [ "$(queue_count)" -eq 0 ] || fail 'guard submitted a queue message'
      jq '.session_id = "22222222-2222-4222-8222-222222222222"' "$CASE_HOME/payload" > "$CASE_HOME/foreign"
      run_owner --guard < "$CASE_HOME/foreign" || fail 'native requirement leaked to foreign root'
      jq '.hook_event_name = "SubagentStop"' "$CASE_HOME/payload" > "$CASE_HOME/child-payload"
      run_owner --guard < "$CASE_HOME/child-payload" || fail 'native requirement leaked to child'
      bash "$ROOT/bin/fm-turnend-guard.sh" --claude < "$CASE_HOME/payload" || fail 'native requirement leaked to Claude mode'
      # This is another copied Bash process, not an installed Claude runtime.
      cp /bin/bash "$CASE_HOME/claude"
      "$CASE_HOME/claude" "$ROOT/bin/fm-turnend-guard.sh" < "$CASE_HOME/payload" || fail 'native requirement leaked to another harness'
      # CI checks out a primary repository; construct the linked-worktree
      # boundary explicitly rather than assuming the suite's checkout is one.
      fm_git_worktree "$CASE_HOME/fixture-repo" "$CASE_HOME/crew" fm/crew
      : > "$CASE_HOME/crew/AGENTS.md"
      ln -s "$ROOT/bin" "$CASE_HOME/crew/bin"
      FM_ROOT_OVERRIDE="$CASE_HOME/crew" run_owner --guard < "$CASE_HOME/payload" || fail 'native requirement leaked to crew worktree'
      : > "$STATE/.afk"
      run_owner --guard < "$CASE_HOME/payload" || fail 'native requirement displaced away owner'
      rm "$STATE/.afk"
      : > "$CONFIG/supervision-host"
      run_owner --guard < "$CASE_HOME/payload" || fail 'native requirement displaced supervision host'
      rm "$CONFIG/supervision-host"
      rm "$CONFIG/codex-native-supervision.json"
      run_owner --guard < "$CASE_HOME/payload" || fail 'default path rejected live foreground'
      first_foreground_identity=$watcher_identity
      fm_watcher_healthy "$STATE" "$ROOT/bin/fm-watch.sh" 300 "$FM_HOME" || fail 'foreground ended before the controlled event'
      printf 'done: controlled foreground handoff event\n' >> "$STATE/probe.status"
      rc=0
      wait "$foreground" || rc=$?
      foreground=
      assert_equals 0 "$rc" 'controlled foreground event did not return normally'
      assert_contains "$(cat "$CASE_HOME/foreground.out")" 'signal:' 'foreground omitted controlled signal'
      [ -s "$STATE/.wake-queue" ] || fail 'foreground consumed controlled durable wake'
      drain=$(bash "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "cannot present foreground wake: $drain"
      assert_contains "$drain" 'controlled foreground handoff event' 'drain omitted controlled status event'
      [ -s "$STATE/.wake-queue" ] || fail 'foreground presentation acknowledged the wake'
      : > "$CASE_HOME/foreground-event-handled"
      sequence=$(printf '%s\n' "$drain" | sed -n 's/.*WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\).*/\1/p')
      recovery=$(printf '%s\n' "$drain" | sed -n 's/.*WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
      [ -n "$sequence" ] && [ -n "$recovery" ] || fail 'foreground drain omitted bounded ACK command'
      bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$recovery" >/dev/null 2>&1 \
        || fail 'handled foreground event could not be acknowledged'
      [ ! -s "$STATE/.wake-queue" ] || fail 'foreground ACK did not retire the handled wake'
      bash "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 90 > "$CASE_HOME/foreground.out" 2> "$CASE_HOME/foreground.err" &
      foreground=$!
      wait_healthy
      [ "$watcher_identity" != "$first_foreground_identity" ] || fail 'foreground successor reused completed watcher'
      [ "$(queue_count)" -eq 0 ] || fail 'foreground handling submitted a native queue message'
      printf '# controlled signal returned normally; durable wake drained and ACKed; foreground successor healthy\n'
      ;;
    binding)
      run_owner --capable || fail 'valid explicit root binding was refused'
      rendered=$(bash "$ROOT/bin/fm-supervision-instructions.sh" --harness codex)
      assert_contains "$rendered" 'Mode: Codex opt-in native Stop' 'explicit binding did not select native protocol'
      assert_not_contains "$rendered" 'Ordinary wake: take the next foreground' 'native protocol retained a second watcher owner'
      : > "$CONFIG/supervision-host"
      run_owner --capable && fail 'native owner displaced configured supervision host'
      rm "$CONFIG/supervision-host"
      CODEX_THREAD_ID=33333333-3333-4333-8333-333333333333 run_owner --capable && fail 'foreign thread accepted'
      env -u CODEX_THREAD_ID bash "$OWNER" --capable && fail 'tool probe accepted missing thread context'
      chmod 644 "$CONFIG/codex-native-supervision.json"
      run_owner --capable && fail 'public binding accepted'
      chmod 600 "$CONFIG/codex-native-supervision.json"
      cp "$CONFIG/codex-native-supervision.json" "$CASE_HOME/original-binding"
      for remote in unix:// unix:///tmp/firstmate-native.sock; do
        jq --arg remote "$remote" '.remote = $remote' "$CASE_HOME/original-binding" > "$CONFIG/codex-native-supervision.json"
        run_owner --capable || fail "valid remote rejected by binding: $remote"
        printf '# binding accepts remote %s\n' "$remote"
      done
      for control in 0 9 10 13 31; do
        jq --argjson control "$control" '.remote = ("unix:///tmp/native" + ([$control] | implode) + ".sock")' \
          "$CASE_HOME/original-binding" > "$CONFIG/codex-native-supervision.json"
        run_owner --capable && fail "binding accepted real control U+$control in remote"
        printf '# binding rejects remote control code %s\n' "$control"
      done
      cat "$CASE_HOME/original-binding" > "$CONFIG/codex-native-supervision.json"
      for invalid in '.executable_sha256 = ("0" * 64)' '.remote = "unix://relative"' '.cli_version = "0.163.0"' \
        '.session_id = "22222222-2222-4222-8222-222222222222"'; do
        mutate_binding "$invalid"
        run_owner --capable && fail "unproved capability accepted: $invalid"
        cat "$CASE_HOME/original-binding" > "$CONFIG/codex-native-supervision.json"
      done
      mutate_binding '.owner_identity = "obsolete"'
      run_owner --capable && fail 'reused or changed session identity accepted'
      [ "$(queue_count)" -eq 0 ] || fail 'capability invoked queue'
      ;;
    delayed-admission)
      # The vendor schedules async work independently of synchronous hooks.
      # Hold this portable callback until the guard has refused completion:
      # no amount of increasing its wait can admit work held behind this gate.
      rc=0
      env -u CODEX_THREAD_ID bash "$OWNER" --guard < "$CASE_HOME/payload" \
        > "$CASE_HOME/guard.out" 2> "$CASE_HOME/guard.err" || rc=$?
      assert_equals 2 "$rc" 'guard admitted a final before any native callback existed'
      [ ! -e "$STATE/.codex-native.json" ] || fail 'guard manufactured a native receipt'
      [ "$(queue_count)" -eq 0 ] || fail 'admission guard submitted input'
      [ ! -e "$STATE/.codex-native-fallback" ] || fail 'guard latched a missing callback before any delivery'
      printf '# guard refused final without poisoning delayed callback admission\n'
      start_owner
      wait_healthy
      generation=$(jq -r '.generation' "$STATE/.codex-native.json")
      for entry in legacy shim; do
        rc=0
        if [ "$entry" = legacy ]; then
          env -u CODEX_THREAD_ID bash "$ROOT/bin/fm-turnend-guard.sh" < "$CASE_HOME/payload" \
            > "$CASE_HOME/retry.out" 2> "$CASE_HOME/retry.err" || rc=$?
        else
          run_owner --guard < "$CASE_HOME/payload" > "$CASE_HOME/retry.out" 2> "$CASE_HOME/retry.err" || rc=$?
        fi
        assert_equals 0 "$rc" "$entry rejected the actual delayed native watcher"
      done
      assert_equals "$generation" "$(jq -r '.generation' "$STATE/.codex-native.json")" 'guard retry replaced native generation'
      [ "$(queue_count)" -eq 0 ] || fail 'guard retry submitted input'
      [ ! -e "$STATE/.codex-native-fallback" ] || fail 'guard retry wrote fallback despite a live owner'
      # Persistent fallback still belongs to failed or ambiguous delivery.
      # Never clear it merely because a live watcher could satisfy ready().
      sha256sum "$CONFIG/codex-native-supervision.json" | awk '{print $1}' > "$STATE/.codex-native-fallback"
      for active in false true; do
        jq --argjson active "$active" '.stop_hook_active = $active' "$CASE_HOME/payload" > "$CASE_HOME/repeat-payload"
        rc=0
        run_owner --guard < "$CASE_HOME/repeat-payload" > "$CASE_HOME/latched.out" 2> "$CASE_HOME/latched.err" || rc=$?
        assert_equals 2 "$rc" 'guard bypassed persistent delivery fallback'
        [ -s "$STATE/.codex-native-fallback" ] || fail 'guard erased delivery fallback'
      done
      wait_closed
      [ "$(queue_count)" -eq 0 ] || fail 'latched callback submitted input'
      ;;
    success|failure|interrupted-delivery)
      [ "$scenario" != interrupted-delivery ] || : > "$CASE_HOME/block-queue"
      [ "$scenario" != failure ] || : > "$CASE_HOME/fail-queue"
      start_owner
      wait_healthy
      [ "$(queue_count)" -eq 0 ] || fail 'native fixture queued before the controlled event'
      env -u CODEX_THREAD_ID bash "$OWNER" --guard < "$CASE_HOME/payload" || fail 'healthy native owner did not satisfy guard without tool environment'
      env -u CODEX_THREAD_ID bash "$ROOT/bin/fm-turnend-guard.sh" < "$CASE_HOME/payload" \
        || fail 'legacy Stop did not accept a verified native owner'
      CODEX_THREAD_ID=33333333-3333-4333-8333-333333333333 run_owner --guard < "$CASE_HOME/payload" \
        || fail 'inherited process environment displaced the root Stop identity'
      [ "$(queue_count)" -eq 0 ] || fail 'guard checks triggered an uncontrolled native event'
      generation=$(jq -r '.generation' "$STATE/.codex-native.json")
      run_owner < "$CASE_HOME/payload" || fail 'duplicate Stop failed'
      [ "$(jq -r '.generation' "$STATE/.codex-native.json")" = "$generation" ] || fail 'duplicate Stop replaced live generation'
      printf 'done: native fixture event\n' >> "$STATE/probe.status"
      if [ "$scenario" = interrupted-delivery ]; then
        for i in $(seq 200); do
          [ ! -e "$CASE_HOME/queue-started" ] || break
          sleep 0.1
        done
        [ -e "$CASE_HOME/queue-started" ] || fail 'queue did not enter interrupted dispatch'
        kill -KILL "$callback"
      fi
      if [ "$scenario" = success ]; then wait_closed watcher-only; wait_phase queued; else wait_closed; fi
      [ "$(queue_count)" -eq 1 ] || fail 'event was not submitted exactly once'
      assert_equals watcher "$(jq -r '.kind' "$CASE_HOME/calls")" 'queue omitted canonical operational watcher envelope'
      [ -s "$STATE/.wake-queue" ] || fail 'native owner consumed the durable wake'
      if [ "$scenario" = success ]; then
        run_owner --handling || fail 'accepted queue receipt did not explain handling gap'
        FM_SUPERVISION_MODEL=persistent fm_watcher_supervision_verdict "$STATE" "$ROOT/bin/fm-watch.sh" 300 "$FM_HOME" "$FM_HOME"
        assert_equals "$FM_WATCHER_VERDICT_OK" true 'bound accepted delivery did not explain pull-warning gap'
        run_owner < "$CASE_HOME/payload" || fail 'queued Stop replay failed'
        [ "$(queue_count)" -eq 1 ] || fail 'queued Stop replay resubmitted'
        FM_GUARD_GRACE=0 run_owner --handling && fail 'expired receipt retained handling health'
        run_owner < "$CASE_HOME/payload" || fail 'aged Stop replay failed'
        [ "$(queue_count)" -eq 1 ] || fail 'aged queued Stop replay resubmitted'
        drain=$(bash "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "cannot present native wake: $drain"
        assert_contains "$drain" 'probe' 'drain omitted native event'
        [ -s "$STATE/.wake-queue" ] || fail 'presentation acknowledged the wake'
        # The handler, never the Stop owner, acknowledges after its action.
        : > "$CASE_HOME/handled"
        sequence=$(printf '%s\n' "$drain" | sed -n 's/.*WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\).*/\1/p')
        recovery=$(printf '%s\n' "$drain" | sed -n 's/.*WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p')
        [ -n "$sequence" ] && [ -n "$recovery" ] || fail 'drain omitted bounded ACK command'
        bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$recovery" >/dev/null 2>&1 \
          || fail 'handled wake could not be acknowledged'
        [ ! -s "$STATE/.wake-queue" ] || fail 'ACK did not retire the handled wake'
        jq '.turn_id = "turn-two"' "$CASE_HOME/payload" > "$CASE_HOME/next-payload"
        mv "$CASE_HOME/next-payload" "$CASE_HOME/payload"
        old_callback=$callback
        start_owner
        wait_healthy
        wait "$old_callback" || fail 'correlated Stop did not retire previous observer cleanly'
        [ "$(jq -r '.generation' "$STATE/.codex-native.json")" != "$generation" ] || fail 'successor reused completed generation'
        printf 'done: successor event\n' >> "$STATE/probe.status"
        wait_closed watcher-only
        wait_phase queued
        [ "$(queue_count)" -eq 2 ] || fail 'successor cycle did not deliver exactly once'
        mutate_binding '.session_id = "44444444-4444-4444-8444-444444444444"'
        run_owner --handling && fail 'old binding receipt survived a session change'
        FM_SUPERVISION_MODEL=persistent fm_watcher_supervision_verdict "$STATE" "$ROOT/bin/fm-watch.sh" 300 "$FM_HOME" "$FM_HOME"
        assert_equals "$FM_WATCHER_VERDICT_OK" false 'changed binding retained a healthy persistent verdict'
      else
        run_owner --capable && fail 'failed delivery did not select foreground fallback'
        run_owner --handling && fail 'failed delivery looked like handling'
        run_owner < "$CASE_HOME/payload" || fail 'latched fallback Stop failed'
        [ "$(queue_count)" -eq 1 ] || fail 'ambiguous delivery was automatically retried'
        [ -s "$STATE/.wake-queue" ] || fail 'failed delivery lost durable event'
      fi
      ;;
    capacity|capacity-exhausted|outcome-inProgress|outcome-completed|outcome-interrupted|outcome-failed|foreign|lease|retry-interrupted|revoke-observer)
      [ "$scenario" != foreign ] || : > "$CASE_HOME/foreign"
      [ "$scenario" != retry-interrupted ] || : > "$CASE_HOME/block-retry"
      start_owner
      wait_healthy
      printf 'done: causal capacity event\n' >> "$STATE/probe.status"
      wait_closed watcher-only
      wait_phase queued
      [ "$(queue_count)" -eq 1 ] || fail 'initial delivery was not accepted once'
      fm_pid_alive "$callback" || fail 'accepted queue lost its owner before a turn result or Stop'
      if [ "$scenario" = capacity ]; then
        acknowledge_event
        printf 'capacity-once\n' > "$CASE_HOME/outcome"
        for i in $(seq 250); do
          [ "$(queue_count)" -lt 2 ] || break
          sleep 0.1
        done
        wait_phase queued
        assert_equals 2 "$(queue_count)" 'exact capacity failure without Stop did not recover'
        assert_equals 1 "$(jq -r '.attempts' "$STATE/.codex-native.json")" 'recovery count was not durable'
        assert_equals turn-two "$(jq -r '.failed_turn' "$STATE/.codex-native.json")" 'claim lost exact failed turn'
        assert_equals 2 "$(jq -r '.client_id' "$CASE_HOME/calls" | sort -u | wc -l | tr -d ' ')" 'retry reused a client ID'
        assert_equals true "$(tail -n 1 "$CASE_HOME/calls" | jq -r '.fresh_recovery')" 'retry replayed original wake message'
        assert_equals 1 "$(wc -l < "$CASE_HOME/handled" | tr -d ' ')" 'ACKed action ran twice'
        [ ! -s "$STATE/.wake-queue" ] || fail 'retry recreated an ACKed wake'
        run_owner < "$CASE_HOME/payload" || fail 'origin Stop replay failed'
        sleep 2
        assert_equals 2 "$(queue_count)" 'duplicate Stop replayed a recovery claim'
        fm_pid_alive "$callback" || fail 'capacity recovery lost its live observer'
      elif [ "$scenario" = retry-interrupted ]; then
        printf 'capacity-once\n' > "$CASE_HOME/outcome"
        for i in $(seq 250); do
          [ ! -s "$CASE_HOME/queue-pid" ] || break
          sleep 0.1
        done
        [ -s "$CASE_HOME/queue-pid" ] || fail 'retry did not reach dispatch'
        transport_pid=$(cat "$CASE_HOME/queue-pid")
        transport_identity=$(fm_pid_identity "$transport_pid") || fail 'owned proxy was not live'
        assert_equals 1 "$(jq -r '.attempts' "$STATE/.codex-native.json")" 'retry dispatch lacked durable budget claim'
        kill -KILL "$callback"
        wait "$callback" 2>/dev/null || true
        callback=
        for i in $(seq 200); do
          [ "$(fm_pid_identity "$transport_pid" 2>/dev/null)" != "$transport_identity" ] && break
          sleep 0.1
        done
        [ "$(fm_pid_identity "$transport_pid" 2>/dev/null)" != "$transport_identity" ] || fail 'proxy survived callback death'
        [ -s "$STATE/.codex-native-fallback" ] || fail 'interrupted retry lost ambiguity latch'
        run_owner < "$CASE_HOME/payload" || fail 'interrupted retry replay failed'
        assert_equals 2 "$(queue_count)" 'interrupted retry reset its claim and dispatched again'
      elif [ "$scenario" = revoke-observer ]; then
        rm "$CONFIG/codex-native-supervision.json"
        wait "$callback" 2>/dev/null || true
        callback=
        assert_equals 1 "$(queue_count)" 'revoked observer dispatched recovery'
        [ ! -e "$STATE/.codex-native.lock" ] || fail 'revoked observer retained singleton'
      elif [ "$scenario" = lease ]; then
        printf '4000\n' > "$CASE_HOME/clock-offset"
        wait_phase lease-ended
        wait "$callback" 2>/dev/null || true
        callback=
        assert_equals 1 "$(queue_count)" 'lease expiry retried without a failure'
        [ -s "$STATE/.codex-native-fallback" ] || fail 'lease expiry omitted latch'
        assert_contains "$(cat "$STATE/.wake-queue")" 'lease-ended' 'lease expiry omitted durable escalation'
      elif [ "$scenario" = capacity-exhausted ]; then
        printf 'capacity\n' > "$CASE_HOME/outcome"
        wait_phase retry-exhausted
        wait "$callback" 2>/dev/null || true
        callback=
        assert_equals 3 "$(queue_count)" 'chain budget did not stop at initial plus two recoveries'
        assert_equals 2 "$(jq -r '.attempts' "$STATE/.codex-native.json")" 'exhausted budget was not retained'
        [ -s "$STATE/.codex-native-fallback" ] || fail 'exhaustion omitted foreground latch'
        assert_contains "$(cat "$STATE/.wake-queue")" 'retry-exhausted' 'exhaustion omitted durable escalation'
        run_owner < "$CASE_HOME/payload" || fail 'terminal replay failed'
        assert_equals 3 "$(queue_count)" 'terminal replay reset chain budget'
      else
        if [ "$scenario" = foreign ]; then
          : > "$CASE_HOME/foreign"
          # Force a fresh unresolved join, before the first outcome query.
          printf 'capacity\n' > "$CASE_HOME/outcome"
          expected=correlation-unproved
        else
          outcome=${scenario#outcome-}
          printf '%s\n' "$outcome" > "$CASE_HOME/outcome"
          case "$outcome" in completed) expected=successor-unproved ;; interrupted) expected=turn-interrupted ;; failed) expected=turn-failed ;; *) expected=queued ;; esac
        fi
        if [ "$expected" = queued ]; then
          sleep 3
          fm_pid_alive "$callback" || fail 'inProgress lost observer'
          prior_generation=$(jq -r '.generation' "$STATE/.codex-native.json")
          jq '.turn_id = "unrelated-old-stop"' "$CASE_HOME/payload" > "$CASE_HOME/unrelated-stop"
          run_owner < "$CASE_HOME/unrelated-stop" || fail 'unrelated Stop did not stand down'
          assert_equals "$prior_generation" "$(jq -r '.generation' "$STATE/.codex-native.json")" 'unrelated Stop retired observer'
        else
          wait_phase "$expected"
          wait "$callback" 2>/dev/null || true
          callback=
          [ -s "$STATE/.codex-native-fallback" ] || fail 'terminal outcome omitted fallback'
          assert_contains "$(cat "$STATE/.wake-queue")" "$expected" 'terminal outcome omitted escalation'
        fi
        assert_equals 1 "$(queue_count)" 'unproved/non-capacity outcome retried delivery'
      fi
      # The peer emits private canaries, but no adapter/owner output retains
      # them, including arbitrary error text and foreign notifications.
      if grep -q 'PRIVATE_' "$CASE_HOME/owner.out" "$CASE_HOME/owner.err" "$STATE/.codex-native.json" "$CASE_HOME/calls"; then
        fail 'metadata projection leaked private content'
      fi
      ;;
    revoke|owner-death)
      start_owner
      wait_healthy
      if [ "$scenario" = revoke ]; then
        rm "$CONFIG/codex-native-supervision.json"
      else
        # Kill only the private callback, not a vendor or a fleet process.
        callback_pid=$(jq -r '.pid' "$STATE/.codex-native.json")
        kill -KILL "$callback_pid"
      fi
      wait_closed
      [ "$(queue_count)" -eq 0 ] || fail 'revoked/dead owner queued input'
      ;;
    payload)
      jq '.session_id = "22222222-2222-4222-8222-222222222222"' "$CASE_HOME/payload" > "$CASE_HOME/wrong-payload"
      run_owner < "$CASE_HOME/wrong-payload" || fail 'mismatched hook should stand down'
      jq '.hook_event_name = "SubagentStop"' "$CASE_HOME/payload" > "$CASE_HOME/child-payload"
      run_owner < "$CASE_HOME/child-payload" || fail 'descendant hook should stand down'
      jq '.turn_id = ""' "$CASE_HOME/payload" > "$CASE_HOME/empty-turn"
      run_owner < "$CASE_HOME/empty-turn" || fail 'invalid turn should stand down'
      [ ! -e "$STATE/.codex-native.json" ] || fail 'foreign session, descendant or invalid turn acquired native ownership'
      [ ! -e "$STATE/.codex-native-fallback" ] || fail 'foreign hook changed the root fallback latch'
      [ "$(queue_count)" -eq 0 ] || fail 'unverified hook target queued input'
      ;;
    *) fail 'unknown scenario' ;;
  esac
  pass "native Codex portable process fixture: $scenario"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-codex-native)
for scenario in ${FM_CODEX_NATIVE_CASES:-protocol-inspect protocol-queue-status protocol-primary-submit protocol-wire protocol-fragment protocol-bad-upgrade protocol-diagnostic off handoff binding delayed-admission success failure interrupted-delivery revoke owner-death payload capacity capacity-exhausted outcome-inProgress outcome-completed outcome-interrupted outcome-failed foreign lease retry-interrupted revoke-observer}; do
  home="$TMP_ROOT/$scenario"
  mkdir -p "$home/state" "$home/config" "$home/user/codex" "$home/fakebin"
  ln -s "$ROOT/bin" "$home/bin"
  : > "$home/AGENTS.md"
  printf 'native-fixture\n' > "$home/.fm-secondmate-home"
  cp /bin/bash "$home/codex"
  cp "$ROOT/tests/fixtures/codex-native-proxy.py" "$home/proxy.py"
  cat > "$home/app-server" <<'SH'
#!/bin/bash
exec python3 "$FM_HOME/proxy.py"
SH
  cat > "$home/queue" <<'SH'
# Counterfactual compatibility only: pre-repair CLI acceptance, no outcome.
printf '{"kind":"watcher","client_id":"legacy"}\n' >> "$FM_HOME/calls"
if [ -e "$FM_HOME/block-queue" ]; then
  : > "$FM_HOME/queue-started"
  sleep 30
fi
[ ! -e "$FM_HOME/fail-queue" ] || exit 1
printf 'Queued message fixture\n'
SH
  printf '#!/bin/bash\nexit 1\n' > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
  cat > "$home/fakebin/date" <<'SH'
#!/bin/bash
if [ "${1:-}" = +%s ] && [ -s "$FM_HOME/clock-offset" ]; then
  printf '%s\n' "$(($( /bin/date +%s ) + $(cat "$FM_HOME/clock-offset")))"
else
  exec /bin/date "$@"
fi
SH
  chmod +x "$home/fakebin/date"
  ln -s "$(command -v jq)" "$home/fakebin/jq"
  if [ "$scenario" = protocol-primary-submit ]; then
    for dependency in tasks-axi node; do
      if executable=$(command -v "$dependency"); then
        ln -s "$executable" "$home/fakebin/$dependency"
      else
        fail "public removal event case requires $dependency"
      fi
    done
  fi
  : > "$home/calls"
  (cd "$home" && exec env -i PATH="$home/fakebin:/usr/bin:/bin" HOME="$home/user" \
    XDG_CONFIG_HOME="$home/user/config" CODEX_HOME="$home/user/codex" LC_ALL=C \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_GATE_REFUSE_BYPASS=1 FM_WEDGE_ALARM_EXEC=discard \
    "$home/codex" "$ROOT/tests/fm-codex-stop-autoarm.test.sh" --case "$home" "$scenario") \
    || fail "portable native case failed: $scenario"
done
