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
