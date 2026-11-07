#!/usr/bin/env bash
# Portable executable regressions for unattended Lavish board supervision.
# Uses saved sessions, real blocking child processes, and a private clock; no
# Lavish server, agent harness, network service, or backend lifecycle is used.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-lavish-watch)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
lavish_session() {  # <artifact> [session-url]
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
    my ($path, $artifact, $url) = @ARGV;
    my $real = realpath($artifact) // die "missing fixture artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $state = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $state = decode_json(<$in>); }
    $state->{sessions}{$key} = {
      key => $key, file => decode("UTF-8", $real), status => "open", url => $url,
    };
    open my $out, ">", $path or die $!;
    print $out encode_json($state);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$1" "${2:-http://127.0.0.1:14387/session/0123456789abcdef}"
}

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
trigger=$1; shift
while [ ! -e "$trigger" ]; do
  [ "$SECONDS" -lt 120 ] || exit 75
  sleep 0.05
done
printf '%s\n' "$@"
SH
chmod +x "$BLOCKER"
pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
pe_register() {
  local home=$1
  shift
  fm_test_track_procevent_home "$home"
  pe "$home" register "$@"
}
new_task_endpoint() {
  mkdir -p "$1/state"
  printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$2" "$1" "$2" > "$1/state/$2.meta"
}
wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

# A zombie holder used to wedge both repair and coverage discovery forever.
# Retain real unreaped children, including a runner, rather than faking ps.
python3 - "$ROOT" "$TMP_ROOT/zombies" "$BLOCKER" <<'PY' || fail "zombie listener recovery"
import os
import pathlib
import signal
import subprocess as sp
import sys
import time

root, lab, blocker = map(pathlib.Path, sys.argv[1:])
(lab / "state").mkdir(parents=True)
env = dict(os.environ, FM_HOME=str(lab), FM_STATE_OVERRIDE=str(lab / "state"),
           FM_PROCEVENT_CLAIM_ROOT=str(lab / "claims"), FM_PROCEVENT_OWNER_CHECK_SECONDS="1")
pe = str(root / "bin/fm-procevent.sh")
source = "zombie-recovery"
children, groups, guards = [], [], []

def run(*args, timeout=45):
    return sp.check_output(args, env=env, text=True, stderr=sp.STDOUT, timeout=timeout)

def wait_for(test):
    for _ in range(200):
        if test():
            return
        time.sleep(.1)
    raise AssertionError("fixture condition did not arrive")

def zombie(p):
    return run("ps", "-o", "stat=", "-p", str(p.pid)).strip().startswith("Z")

try:
    run(pe, "register", "lavish", source, "--", "bash", "-c",
        'printf ready > "$1"; shift; exec "$@"', "_", str(lab / "started"),
        str(blocker), str(lab / "release"),
        "status: feedback", "prompts[1]{tag,prompt}:", "  message,recovered")
    with (lab / "runner.log").open("w") as log:
        runner = sp.Popen(["bash", "-c", 'export FM_PROCEVENT_RUNNER_GROUP=$$; exec "$@"',
                           "_", pe, "_start", source], env=env, stdout=log, stderr=log,
                          start_new_session=True)
    children.append(runner)
    groups.append(runner.pid)
    wait_for(lambda: (lab / "started").exists())
    # The guard is our runner's exact generation; never match another test's guard.
    needle = f"{pe} _owner-watchdog {source} {runner.pid} "
    def find_guard():
        for row in run("ps", "-e", "-o", "pid=", "-o", "args=").splitlines():
            pid, _, args = row.strip().partition(" ")
            if needle in args:
                guards.append(int(pid))
                return True
        return False
    wait_for(find_guard)
    runner.kill()
    wait_for(lambda: zombie(runner))
    assert "orphaned" in run(pe, "list"), "a live polling child lost ownership"
    assert "uncertain=1" in run(pe, "reconcile"), "an unproved live group was replaced"
    os.killpg(runner.pid, signal.SIGKILL)
    # Leave a second zombie owning the same source's lock, as in the incident.
    holder = sp.Popen(["bash", "-c", '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2"',
                       "_", str(root), str(lab / "claims/zombie-recovery.lock")], env=env)
    children.append(holder)
    wait_for(lambda: zombie(holder))
    for proc_root in ("/proc", str(lab / "no-proc")):
        fallback = dict(env, FM_PROC_ROOT_OVERRIDE=proc_root)
        dead = sp.run(["bash", "-c", '. "$1/bin/fm-wake-lib.sh"; fm_pid_alive "$2"',
                       "_", str(root), str(holder.pid)], env=fallback)
        assert dead.returncode == 1, "zombie is still considered live"
    assert "none" in run(pe, "list", timeout=5), "zombie-only group still owns source"
    assert "started=1" in run(pe, "reconcile", timeout=45), "dead listener did not recover"
    (lab / "release").touch()
    result = lab / "state/procevent-inbox/zombie-recovery.1.result"
    wait_for(result.exists)
    queue = lab / "state/.wake-queue"
    wait_for(lambda: queue.exists() and "procevent lavish zombie-recovery 1" in queue.read_text())
    assert "recovered" in result.read_text()

    # A genuinely live lock holder must remain untouched. Reconciliation must
    # time out, reject concurrent work, and let discovery report uncertainty.
    live_holder = sp.Popen(["bash", "-c", '. "$1/bin/fm-wake-lib.sh"; '
        'fm_lock_try_acquire "$2" || exit 1; touch "$3"; '
        'while [ ! -e "$4" ]; do sleep .1; done; fm_lock_release "$2"',
        "_", str(root), str(lab / "claims/zombie-recovery.lock"),
        str(lab / "held"), str(lab / "unlock")], env=env)
    children.append(live_holder)
    wait_for(lambda: (lab / "held").exists())
    bounded = dict(env, FM_PROCEVENT_RECONCILE_SECONDS="3")
    job = sp.Popen([pe, "reconcile"], env=bounded, text=True, stdout=sp.PIPE, stderr=sp.STDOUT)
    children.append(job)
    singleton = lab / "state/.procevent-reconcile.lock"
    wait_for(lambda: (singleton / "pid").exists())
    worker_pid = (singleton / "pid").read_text().strip()
    alias = lab / "state-alias"
    alias.symlink_to(lab / "state", target_is_directory=True)
    alias_env = dict(bounded, FM_STATE_OVERRIDE=str(alias))
    duplicate = sp.check_output([pe, "reconcile"], env=alias_env, text=True, timeout=3)
    assert "already running" in duplicate, duplicate
    assert "uncertain" in run(pe, "list", timeout=3)
    output = job.communicate(timeout=10)[0]
    assert job.returncode == 124 and "exceeded" in output, output
    assert not singleton.is_symlink() and not singleton.exists(), "singleton lock leaked"
    status = run("ps", "-e", "-o", "pid=", "-o", "stat=")
    assert all(row.split()[0] != worker_pid or row.split()[1].startswith("Z")
               for row in status.splitlines() if row.split()), "timed-out worker survived"
    assert live_holder.poll() is None, "deadline killed the independent lock holder"
    # The watcher previously discarded reconcile failures and then blocked in
    # discovery. Its ordinary durable coverage wake must now reach the owner.
    (lab / "state/.last-check").touch()
    (lab / "state/home-summary.json").write_text("{}")
    watcher_env = dict(bounded, FM_POLL="1", FM_HEARTBEAT="999999",
                       FM_HOME_SUMMARY_INTERVAL="999999", LAVISH_AXI_STATE_DIR=str(lab / "lavish"))
    watcher = sp.check_output([str(root / "bin/fm-watch.sh")], env=watcher_env,
                              text=True, stderr=sp.STDOUT, timeout=15)
    assert "unattended Lavish board" in watcher, watcher
    assert "reconciliation failed or exceeded" in queue.read_text()
    (lab / "unlock").touch()
    live_holder.wait(timeout=5)
    assert "reconciled:" in run(pe, "reconcile"), "next cycle did not recover"

    run(pe, "retire", source)
    # Bounded simulated load: postpone only each isolated source process's
    # exec, without stressing the host or delaying the timeout helper itself.
    slow_bin = lab / "slow-bin"
    slow_bin.mkdir()
    real_bash = run("bash", "-c", "command -v bash").strip()
    shim = slow_bin / "bash"
    shim.write_text('#!/bin/sh\n[ "${2-}" != _start ] || sleep 6\n'
                    'exec "$FM_TEST_REAL_BASH" "$@"\n')
    shim.chmod(0o755)
    slow_env = dict(env, PATH=str(slow_bin) + os.pathsep + env["PATH"],
                    FM_TEST_REAL_BASH=real_bash)
    slow_env.pop("FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS", None)
    for label, override, expected in (("short", "3", 1), ("default", None, 0)):
        slow_id = "slow-" + label
        run(pe, "register", "lavish", slow_id, "--", "/bin/echo", "status: ended")
        selected = dict(slow_env)
        if override:
            selected["FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS"] = override
        cold = sp.run([pe, "reconcile"], env=selected, text=True, stdout=sp.PIPE,
                      stderr=sp.STDOUT, timeout=30)
        print("simulated startup:", label, cold.returncode, cold.stdout.strip())
        assert cold.returncode == expected, cold.stdout
        assert ("failed=1" if expected else "failed=0") in cold.stdout, cold.stdout
        wait_for(lambda: (lab / ("state/procevent-inbox/" + slow_id + ".1.result")).exists())
        run(pe, "retire", slow_id)
finally:
    (lab / "unlock").touch()
    for pid in groups:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for child in children:
        child.wait(timeout=5)
    for pid in guards:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    sp.run([pe, "retire", source], env=env, stdout=sp.DEVNULL, stderr=sp.DEVNULL, timeout=15)
PY
pass "zombie locks and zombie-only groups recover and deliver captured feedback"

# Discovery must work before any registration, independently of agent memory.
# The clock stub advances only this private scan, avoiding timing sleeps.
(
  SW="$TMP_ROOT/lavish discovery"
  mkdir -p "$SW/home/.lavish" "$SW/home/data/host" "$SW/home/state" "$SW/bin" \
    "$SW/worktree space" "$SW/foreign/.lavish" "$SW/sessions"
  export LAVISH_AXI_STATE_DIR="$SW/sessions"
  export SCAN_CLOCK="$SW/clock"
  date +%s > "$SCAN_CLOCK"
  scan_now=$(cat "$SCAN_CLOCK")
  SCAN_DATE=$(command -v date); export SCAN_DATE
  cat > "$SW/bin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = +%s ]; then cat "$SCAN_CLOCK"; else exec "$SCAN_DATE" "$@"; fi
SH
  chmod +x "$SW/bin/date"
  scan() { PATH="$SW/bin:$PATH" FM_HOME="$SW/home" "$ROOT/bin/fm-lavish-watch.sh" scan; }
  needs_scan() { FM_HOME="$SW/home" FM_STATE_OVERRIDE="$SW/home/state" "$ROOT/bin/fm-lavish-watch.sh" needed; }
  scan_count() { grep -c 'unattended Lavish board:' "$SW/home/state/.wake-queue" 2>/dev/null || true; }
  advance_scan() { scan_now=$((scan_now + $1)); printf '%s\n' "$scan_now" > "$SCAN_CLOCK"; }
  first_board="$SW/home/.lavish/first.html"
  task_board="$SW/home/data/host/review.html"
  outside_board="$SW/worktree space/revisión.html"
  foreign_board="$SW/foreign/.lavish/review.html"
  for board in "$first_board" "$task_board" "$outside_board" "$foreign_board"; do
    printf '<h1>review</h1>\n' > "$board"
    lavish_session "$board"
  done
  printf 'window=fmtest:fm-host\nworktree=%s\nproject=fmtest\n' "$SW/worktree space" > "$SW/home/state/host.meta"
  needs_scan || fail "unregistered owned boards did not require supervision"
  [ ! -e "$SW/home/state/lavish-watch" ] || fail "needed wrote supervision state"
  scan || fail "initial discovery failed"
  [ ! -e "$SW/home/state/.wake-queue" ] || fail "discovery skipped its grace period"
  [ ! -d "$SW/home/state/procevent" ] || fail "discovery registered or polled a board"
  # Reproduce feedback arriving after publication without an arm call.
  perl -MJSON::PP -e '
    my ($p, $file) = @ARGV; open my $f, "<", $p or die $!; local $/; my $s = decode_json(<$f>);
    for (values %{$s->{sessions}}) { $_->{pending_prompts} = 1 if $_->{file} eq $file; }
    open my $o, ">", $p or die $!; print $o encode_json($s);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$task_board"
  saved_feedback=$(cat "$LAVISH_AXI_STATE_DIR/state.json")
  advance_scan 31
  scan || fail "discovery after grace failed"
  [ "$(scan_count)" = 3 ] || fail "discovery did not cover exactly the three home-owned boards"
  assert_not_contains "$(cat "$SW/home/state/.wake-queue")" "$foreign_board" "scan adopted another home board"
  assert_contains "$(cat "$SW/home/state/.wake-queue")" "$outside_board" "scan changed a Unicode artifact path"
  assert_contains "$(cat "$SW/home/state/.wake-queue")" 'recorded task: host' "worker board lost its owner"
  scan >/dev/null
  [ "$(scan_count)" = 3 ] || fail "scan duplicated an episode before reminder time"
  # Teardown removes endpoint metadata, but board ownership must survive it.
  rm -f -- "$SW/home/state/host.meta"
  advance_scan 300
  scan >/dev/null
  [ "$(scan_count)" = 6 ] || fail "restart/teardown lost an unattended board or its reminder"
  [ "$(cat "$LAVISH_AXI_STATE_DIR/state.json")" = "$saved_feedback" ] || fail "discovery changed saved feedback"
  pass "unregistered boards wake within a bound, preserve ownership, and ignore other homes"

  # A real registered blocking process is sufficient structural coverage.
  scan_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$first_board")
  pe_register "$SW/home" lavish "$scan_id" -- "$BLOCKER" "$SW/release" 'status: ended' >/dev/null
  pe "$SW/home" reconcile >/dev/null
  scan >/dev/null
  [ ! -e "$SW/home/state/lavish-watch/$scan_id.unattended" ] || fail "live listener did not close the unattended episode"
  pe "$SW/home" retire "$scan_id" >/dev/null
  scan >/dev/null
  advance_scan 31
  scan >/dev/null
  [ "$(scan_count)" = 7 ] || fail "a second listener-loss episode was suppressed"
  pass "restored listeners close episodes and later loss receives a fresh wake"

  # A round waiting for acknowledgement must never be auto-rearmed or handled.
  new_task_endpoint "$SW/home" host
  pe "$SW/home" register-task lavish "$scan_id" host -- "$BLOCKER" "$SW/feedback" 'status: feedback' 'prompts[1]{tag,prompt}:' '  message,review me' >/dev/null
  touch "$SW/feedback"
  pe "$SW/home" reconcile >/dev/null
  wait_for "$SW/home/state/procevent-inbox/$scan_id.1.result" || fail "discovery fixture did not capture a worker round"
  cat > "$SW/bin/crew-state" <<'SH'
#!/usr/bin/env bash
cat "$SCAN_CREW_STATE"
SH
  chmod +x "$SW/bin/crew-state"
  export FM_CREW_STATE_BIN="$SW/bin/crew-state" SCAN_CREW_STATE="$SW/crew-state"
  printf 'state: working · source: pane · handling feedback\n' > "$SCAN_CREW_STATE"
  prior_count=$(grep -Fc "procevent:$scan_id:unattended:" "$SW/home/state/.wake-queue")
  scan >/dev/null
  advance_scan 301
  scan >/dev/null
  [ "$(grep -Fc "procevent:$scan_id:unattended:" "$SW/home/state/.wake-queue")" = "$prior_count" ] \
    || fail "working round owner woke supervision"
  printf 'state: stopped · source: pane · agent exited\n' > "$SCAN_CREW_STATE"
  scan >/dev/null
  advance_scan 300
  scan >/dev/null
  assert_contains "$(cat "$SW/home/state/.wake-queue")" 'Verify the worker is handling it' "open round did not wake supervision"
  [ ! -e "$SW/home/state/procevent-inbox/$scan_id.1.handled" ] || fail "scan acknowledged a worker round"
  [ -f "$SW/home/state/procevent/$scan_id.source" ] || fail "scan retired the worker owner"
  assert_contains "$(pe "$SW/home" list)" 'round-open' "scan restarted a listener over an open round"
  pass "unacknowledged worker rounds remain with their owner while supervision is reminded"

  # Ended sessions with queued final feedback still need attention; an empty
  # ended session does not. Neither may be reopened by discovery.
  perl -MJSON::PP -e '
    my $p = shift; open my $f, "<", $p or die $!; local $/; my $s = decode_json(<$f>);
    for (values %{$s->{sessions}}) { $_->{status} = "ended"; $_->{pending_prompts} = 0; }
    open my $o, ">", $p or die $!; print $o encode_json($s);
  ' "$LAVISH_AXI_STATE_DIR/state.json"
  scan >/dev/null
  if needs_scan; then fail "empty ended sessions required supervision"; fi
  perl -MJSON::PP -e '
    my ($p, $file) = @ARGV; open my $f, "<", $p or die $!; local $/; my $s = decode_json(<$f>);
    for (values %{$s->{sessions}}) { $_->{pending_prompts} = 1 if $_->{file} eq $file; }
    open my $o, ">", $p or die $!; print $o encode_json($s);
  ' "$LAVISH_AXI_STATE_DIR/state.json" "$task_board"
  needs_scan || fail "unregistered ended board with final feedback was ignored"
  scan >/dev/null
  advance_scan 31
  scan >/dev/null
  assert_contains "$(cat "$SW/home/state/.wake-queue")" "$task_board" "final feedback had no recovery wake"
  pass "empty terminal boards stop discovery while queued final feedback stays supervised"

  # Every primary adapter's common predicate must keep an otherwise empty
  # fleet supervised, including a board hosted by firstmate rather than a task.
  pe "$SW/home" handled "$scan_id" 1 >/dev/null
  pe "$SW/home" retire "$scan_id" >/dev/null
  rm -f -- "$SW/home/state/host.meta"
  FM_HOME="$SW/home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$SW/home" \
    || fail "a board-only home did not retain fleet supervision"
  # A watcher must actually run discovery and surface its dedicated headline,
  # rather than misreporting this as feedback that has already been captured.
  # Prime unrelated refresh cadence so this test does not launch a detached
  # home-summary producer whose inherited output keeps command capture open.
  printf '{}\n' > "$SW/home/state/home-summary.json"
  touch "$SW/home/state/.last-check"
  watcher_out=$(FM_HOME="$SW/home" FM_POLL=1 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    fm_exec_timed 60 2 "$ROOT/bin/fm-watch.sh" 2>&1) || fail "watcher did not finish its discovery wake within the bound"
  assert_contains "$watcher_out" 'unattended Lavish board:' "watcher did not surface discovery wakes"
  assert_not_contains "$watcher_out" 'result captured: procevent:lavish-' "watcher labeled missing coverage as captured feedback"
  pass "board-only homes retain supervision and watcher surfaces unattended-board wakes"

  printf 'malformed session store\n' > "$LAVISH_AXI_STATE_DIR/state.json"
  bad_status=0
  needs_scan >/dev/null 2>&1 || bad_status=$?
  [ "$bad_status" = 2 ] || fail "corrupt discovery data did not report a distinct error"
  FM_HOME="$SW/home" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2/state"' _ "$ROOT" "$SW/home" \
    || fail "corrupt discovery data silently disabled supervision"
  watcher_out=$(FM_HOME="$SW/home" FM_POLL=1 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    fm_exec_timed 60 2 "$ROOT/bin/fm-watch.sh" 2>&1) || fail "watcher did not finish its discovery-error wake within the bound"
  assert_contains "$watcher_out" 'unavailable-' "watcher hid a failed discovery sweep"
  assert_contains "$(cat "$SW/home/state/.wake-queue")" 'coverage unavailable' "discovery failure had no durable recovery wake"
  pass "discovery errors retain supervision and wake instead of silently losing coverage"
) || fail "Lavish discovery regression failed"

printf '\nall Lavish discovery tests passed\n'
