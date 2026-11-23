#!/usr/bin/env bash
# Host tasks use disposable non-Git scratch and preserve authorized host files.
# shellcheck disable=SC1091
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-host-task)
TASK_HOME="$TMP_ROOT/home"
TASK_ID="host-test-$$"
fm_test_spawn_home "$TASK_HOME" codex
printf 'manual\n' > "$TASK_HOME/config/backlog-backend"
mkdir -p "$TASK_HOME/user-home"
FAKEBIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake")
# Host-task behavior is independent of the real machine's admission load.
cat > "$FAKEBIN/getconf" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = _NPROCESSORS_ONLN ]; then printf '4096\n'; else /usr/bin/getconf "$@"; fi
EOF
chmod +x "$FAKEBIN/getconf"
TARGET="$TMP_ROOT/host-file"
printf 'preserve\n' > "$TARGET"
run_brief() {
  FM_HOME="$TASK_HOME" HOME="$TASK_HOME/user-home" bash "$ROOT/bin/fm-brief.sh" "$@"
}
# A rejected incomplete brief must not create scratch and prevent its retry.
run_brief incomplete --host --path "$TARGET"
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/incomplete/work" "$FAKEBIN" incomplete --host --harness codex --model codex-test --effort high --backend tmux) && fail 'incomplete brief launched'
assert_contains "$OUT" '{CAPTAIN_REQUIREMENTS}' 'requirements placeholder named'
[ ! -e "$TASK_HOME/data/incomplete/work" ] || fail 'incomplete brief left scratch'
mkdir "$TASK_HOME/data/incomplete/work"
printf 'previous work\n' > "$TASK_HOME/data/incomplete/work/keep"
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/incomplete/work" "$FAKEBIN" incomplete --host --harness codex --model codex-test --effort high --backend tmux) && fail 'incomplete brief launched over prior work'
[ "$(cat "$TASK_HOME/data/incomplete/work/keep")" = 'previous work' ] || fail 'prior scratch changed'
for marker in TASK FIRSTMATE_SPEC CAPTAIN_REQUIREMENTS; do
  id="missing-$(printf '%s' "$marker" | tr 'A-Z_' 'a-z-')"
  run_brief "$id" --host --path "$TARGET"
  python3 - "$TASK_HOME/data/$id/brief.md" "$marker" <<'PYCODE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
replacements = {'TASK': 'Read a file.', 'FIRSTMATE_SPEC': 'Verify the result.', 'CAPTAIN_REQUIREMENTS': '1. Read a file.'}
s = p.read_text()
for name, value in replacements.items():
    if name != sys.argv[2]:
        s = s.replace('{' + name + '}', value)
p.write_text(s)
PYCODE
  OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/$id/work" "$FAKEBIN" "$id" --host --harness codex --model codex-test --effort high --backend tmux) && fail "missing $marker launched"
  assert_contains "$OUT" "{$marker}" "missing $marker named"
  [ ! -e "$TASK_HOME/data/$id/work" ] || fail "missing $marker left scratch"
done
run_brief bad-declaration --host --path "$TARGET"
python3 - "$TASK_HOME/data/bad-declaration/brief.md" "$TARGET" <<'PYCODE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('\n' + sys.argv[2] + '\n', '\n- ' + sys.argv[2] + '\n'))
PYCODE
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/bad-declaration/work" "$FAKEBIN" bad-declaration --host --harness codex --model codex-test --effort high --backend tmux) && fail 'bad path declaration launched'
assert_contains "$OUT" "$TARGET" 'failed path named'
assert_contains "$OUT" 'on its own line' 'exact path declaration format named'
assert_contains "$OUT" 'Allowed paths:' 'allowed paths named'
OUT=$(run_brief bad-path --host --path "$ROOT/bin" 2>&1) && fail 'protected path accepted'
assert_contains "$OUT" "$ROOT/bin" 'rejected path named'
OUT=$(FM_HOME="$TASK_HOME" bash "$ROOT/bin/fm-task-status.sh" incomplete bogus note 2>&1) && fail 'invalid status accepted'
assert_contains "$OUT" 'bogus' 'invalid state named'

run_brief "$TASK_ID" --host --path "$TARGET"
python3 - "$TASK_HOME/data/$TASK_ID/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Set up a host file.').replace('{FIRSTMATE_SPEC}','Verify the operation.').replace('{CAPTAIN_REQUIREMENTS}','1. Fixture requirement.'))
PY
export FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log"
export FM_FAKE_PANE_LOG="$TMP_ROOT/pane.log"
OUT=$(FM_MODEL_CATEGORY_OVERRIDE=1 fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/$TASK_ID/work" "$FAKEBIN" "$TASK_ID" --host --harness 'git rev-parse --show-toplevel > git-output 2>/dev/null && exit 99; printf fake-harness > harness-ran' --backend tmux) || fail "host spawn failed: $OUT"
LAUNCH=$(cat "$FM_FAKE_LAUNCH_LOG")
(cd "$TASK_HOME/data/$TASK_ID/work" && HOME="$TASK_HOME/user-home" /bin/sh -c "$LAUNCH") || fail 'fake harness command failed'
[ -f "$TASK_HOME/data/$TASK_ID/work/harness-ran" ] || fail 'host harness did not run'
[ ! -s "$TASK_HOME/data/$TASK_ID/work/git-output" ] || fail 'host Git discovery escaped scratch'
assert_contains "$OUT" 'kind=host' 'host kind recorded'
[ -d "$TASK_HOME/data/$TASK_ID/work" ] || fail 'host scratch missing'
[ ! -e "$TASK_HOME/data/$TASK_ID/work/.git" ] || fail 'host scratch must not be a Git repository'
[ "$(sed -n "s/^kind=//p" "$TASK_HOME/state/$TASK_ID.meta")" = host ] || fail 'host metadata kind missing'
[ -z "$(sed -n "s/^mode=//p" "$TASK_HOME/state/$TASK_ID.meta")" ] || fail 'host has a delivery mode'
[ -z "$(sed -n "s/^branch=//p" "$TASK_HOME/state/$TASK_ID.meta")" ] || fail 'host has a branch'
jq -e '.project == null and .status == "active" and .reason == "awaiting-transcript"' \
  "$TASK_HOME/data/$TASK_ID/sessions.jsonl" >/dev/null || fail 'host session invented a project'
printf 'done [at=100]: host operation verified\n' >> "$TASK_HOME/state/$TASK_ID.status"
touch "$TASK_HOME/state/$TASK_ID.relay-ready" "$TASK_HOME/state/$TASK_ID.relay-result"
OUT=$(FM_HOME="$TASK_HOME" HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 \
  FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
  FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_PROJECTS_OVERRIDE="$TASK_HOME/projects" \
  bash "$ROOT/bin/fm-teardown.sh" "$TASK_ID" 2>&1) || fail "host teardown failed: $OUT"
[ ! -e "$TASK_HOME/data/$TASK_ID/work" ] || fail 'teardown left host scratch'
[ ! -e "$TASK_HOME/state/$TASK_ID.relay-ready" ] && [ ! -e "$TASK_HOME/state/$TASK_ID.relay-result" ] || fail 'teardown left relay signals'
[ "$(cat "$TARGET")" = preserve ] || fail 'teardown changed host target'
pass 'first host assignment launches and tears down without a project or commit'

# Installation audits are scouts with their own scratch, not host operations.
run_brief install-audit --scout --installation
python3 - "$TASK_HOME/data/install-audit/brief.md" <<'PYCODE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Audit the installation read-only.').replace('{FIRSTMATE_SPEC}', 'Inspect configuration.').replace('{CAPTAIN_REQUIREMENTS}', '1. Audit the installation read-only.'))
PYCODE
OUT=$(FM_MODEL_CATEGORY_OVERRIDE=1 fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/install-audit/work" "$FAKEBIN" install-audit --scout --installation --harness 'printf audit' --backend tmux) || fail "audit spawn failed: $OUT"
assert_contains "$OUT" 'kind=scout' 'installation audit remains a scout'
[ "$(sed -n 's/^project=//p' "$TASK_HOME/state/install-audit.meta")" = '' ] || fail 'installation audit borrowed a project'
jq -e '.project == null' "$TASK_HOME/data/install-audit/sessions.jsonl" >/dev/null || fail 'audit session borrowed a project'
printf 'preserve audit\n' > "$TASK_HOME/data/install-audit/work/keep"
OUT=$(FM_HOME="$TASK_HOME" HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 \
  FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
  FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_PROJECTS_OVERRIDE="$TASK_HOME/projects" \
  bash "$ROOT/bin/fm-teardown.sh" install-audit --force 2>&1) || fail "audit teardown failed: $OUT"
backup=$(find "$TASK_HOME/data/install-audit" -name keep -type f -print)
[ -n "$backup" ] && [ "$(cat "$backup")" = 'preserve audit' ] || fail 'audit scratch was not preserved'
pass 'installation audit uses project-free scout and preserves its scratch'

# A load wait must be compatible with the admission policy at declaration.
printf '12\nmax-load1 40\nmax-load5-per-core 4\n' > "$TASK_HOME/config/lane-capacity"
mkdir -p "$TMP_ROOT/load-bin"
printf '#!/usr/bin/env bash\necho 4\n' > "$TMP_ROOT/load-bin/getconf"
chmod +x "$TMP_ROOT/load-bin/getconf"
OUT=$(FM_HOME="$TASK_HOME" PATH="$TMP_ROOT/load-bin:$PATH" bash "$ROOT/bin/fm-task-status.sh" load-wait paused 'wait for load1 < 4' 2>&1) && fail 'unreachable load wait accepted'
assert_contains "$OUT" 'admission ceiling' 'rejection explains admission'
[ ! -e "$TASK_HOME/state/load-wait.status" ] || fail 'rejected pause was recorded'
FM_HOME="$TASK_HOME" PATH="$TMP_ROOT/load-bin:$PATH" bash "$ROOT/bin/fm-task-status.sh" load-wait paused 'wait for load1 < 16' || fail 'admission boundary rejected'
rm -f -- "$TASK_HOME/config/lane-capacity"
pass 'load wait declaration compares against admission and preserves a valid boundary'

# A status publication must wake its owner without relying on a running watcher
# or a later turn-end. Routine appends cannot requeue an already published span.
publish_status() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" bash "$ROOT/bin/fm-task-status.sh" "$@"
}
export FM_TASK_ID=reversible
publish_status reversible working 'found a reversible design choice'
OUT=$(publish_status reversible failed 'still need to choose and implement' 2>&1) \
  && fail 'worker ended the task with recovery still available'
assert_contains "$OUT" 'choose a reversible step, record why, and continue' 'worker got no recovery guidance'
[ "$(wc -l < "$TASK_HOME/state/reversible.status")" -eq 1 ] || fail 'refused failure changed the status'
[ ! -s "$TASK_HOME/state/.wake-queue" ] || fail 'refused failure woke Firstmate'
publish_status reversible working 'chose the existing format because the change can be reverted locally'
publish_status reversible failed 'both authorized recovery paths exhausted' --exhausted-recovery
assert_grep 'both authorized recovery paths exhausted' "$TASK_HOME/state/reversible.status" 'terminal failure was lost'
[ "$(wc -l < "$TASK_HOME/state/.wake-queue")" -eq 1 ] || fail 'terminal failure did not wake Firstmate'
pass 'workers get a recovery prompt before a bare terminal failure can change state or wake Firstmate'

# Exercise the legacy owner path without a worker environment.
unset FM_TASK_ID
rm -f -- "$TASK_HOME/state/.wake-queue"
publish_status instant working setup
[ ! -s "$TASK_HOME/state/.wake-queue" ] || fail 'routine setup queued a wake'
for event in needs-decision blocked 'done' failed; do
  publish_status instant "$event" "event $event"
  count=$(wc -l < "$TASK_HOME/state/.wake-queue")
  publish_status instant working cleanup
  [ "$(wc -l < "$TASK_HOME/state/.wake-queue")" = "$count" ] \
    || fail 'routine progress requeued an old event'
done
[ "$(wc -l < "$TASK_HOME/state/.wake-queue")" -eq 4 ] || fail 'missing immediate status wake'
grep -F 'needs-decision:' "$TASK_HOME/state/.wake-queue" >/dev/null \
  || fail 'waiting status lost its decision routing'
grep -Eq '^done \[at=[0-9]+\]: event done$' "$TASK_HOME/state/instant.status" \
  || fail 'publication lost the timestamp or status text'
count=$(wc -l < "$TASK_HOME/state/.wake-queue")
publish_status instant paused 'intentional wait'
[ "$(wc -l < "$TASK_HOME/state/.wake-queue")" = "$count" ] || fail 'a pause queued an immediate wake'
pass 'decisions and terminal statuses queue immediately; progress and pauses stay informational'

# Use the live status fold and wake queue: acknowledgement alone cannot settle
# a decision or failure, but its resolved record must clear the deadline.
run_obligation_status_tick() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_OBLIGATION_SECONDS="${FM_OBLIGATION_SECONDS:-900}" FM_DIAGNOSTICS=0 \
    bash -c '. "$1"; wake() { printf "%s\n" "$1"; }; if [ "${FM_TEST_HELD:-0}" = 1 ]; then task_captain_call_open() { return 0; }; fi; if declare -F obligation_status_tick >/dev/null; then obligation_status_tick; fi' _ "$ROOT/bin/fm-watch.sh"
}
for event in blocked needs-decision failed; do
  id="obligation-$event"
  printf 'kind=host\n' > "$TASK_HOME/state/$id.meta"
  publish_status "$id" "$event" 'prerequisite missing'
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" bash "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/drain.out" 2> "$TMP_ROOT/drain.err" || true
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$TMP_ROOT/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$TMP_ROOT/drain.err")
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || fail 'status acknowledgement failed'
  FM_OBLIGATION_SECONDS=1 run_obligation_status_tick >/dev/null
  sleep 2
  OUT=$(FM_OBLIGATION_SECONDS=1 run_obligation_status_tick) || fail "status obligation check failed: $event"
  assert_contains "$OUT" "still unattended for" "$event was not reminded"
  publish_status "$id" resolved 'prerequisite supplied'
  publish_status "$id" working resumed
  run_obligation_status_tick >/dev/null
  [ ! -e "$TASK_HOME/state/.obligation-status-$id" ] || fail "$event remained after resolution"
  rm -f -- "$TASK_HOME/state/$id.meta"
done
pass 'acknowledged blocked, decision and failure statuses recur until resolved'

printf 'kind=host\n' > "$TASK_HOME/state/held-case.meta"
printf 'needs-decision: held for a human answer\n' > "$TASK_HOME/state/held-case.status"
FM_TEST_HELD=1 FM_OBLIGATION_SECONDS=1 run_obligation_status_tick >/dev/null
sleep 2
OUT=$(FM_TEST_HELD=1 FM_OBLIGATION_SECONDS=1 run_obligation_status_tick) || fail "held decision check failed: $OUT"
[ -z "$OUT" ] && [ ! -e "$TASK_HOME/state/.obligation-status-held-case" ] || fail 'an attended human decision was treated as unattended'
rm -f -- "$TASK_HOME/state/held-case.meta"
pass 'a decision already held for a human answer does not recur as unattended'

mkdir -p "$TASK_HOME/data/relay-case"
printf 'kind=host\nbusy_gen=gen1\nsessions_file=%s\n' "$TASK_HOME/data/relay-case/sessions.jsonl" > "$TASK_HOME/state/relay-case.meta"
printf 'working: handoff requested\n' > "$TASK_HOME/state/relay-case.status"
printf 'requested\n' > "$TASK_HOME/data/relay-case/relay-request-gen1"
FM_OBLIGATION_SECONDS=1 run_obligation_status_tick >/dev/null
sleep 2
OUT=$(FM_OBLIGATION_SECONDS=1 run_obligation_status_tick) || fail "relay obligation check failed: $OUT"
assert_contains "$OUT" 'context handoff remains unfinished' 'unfinished relay was not reminded'
printf 'handoff completed\n' > "$TASK_HOME/data/relay-case/relay-note-gen1.md"
run_obligation_status_tick >/dev/null
[ ! -e "$TASK_HOME/state/.obligation-relay-relay-case" ] || fail 'completed handoff retained its obligation'
rm -f -- "$TASK_HOME/state/relay-case.meta"
pass 'an unfinished handoff resurfaces and its note resolves the obligation'

printf 'kind=host\n' > "$TASK_HOME/state/dead-case.meta"
printf 'working: investigating\n' > "$TASK_HOME/state/dead-case.status"
run_dead_obligation() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_OBLIGATION_SECONDS=1 FM_DIAGNOSTICS=0 \
    bash -c '. "$1"; fm_busy_current_gen() { return 1; }; wake() { printf "%s\n" "$1"; }; wedge_dead_record fixture "$STATE/dead-since" stale 10 hash dead-case "$2"' _ "$ROOT/bin/fm-watch.sh" "$1"
}
OUT=$(run_dead_obligation dead) || fail "first dead-worker check failed: $OUT"
assert_contains "$OUT" 'agent dead' 'dead worker was not initially reported'
sleep 2
OUT=$(run_dead_obligation dead) || fail "dead-worker reminder failed: $OUT"
assert_contains "$OUT" 'still unattended for' 'unchanged dead worker was not reminded'
run_dead_obligation alive >/dev/null || true
[ ! -e "$TASK_HOME/state/.obligation-stale-dead-case" ] || fail 'recovered worker retained its obligation'
rm -f -- "$TASK_HOME/state/dead-case.meta"
pass 'a dead worker resurfaces until its endpoint recovers'

printf '100' > "$TASK_HOME/state/.paused-resumed-fixture"
run_pause_obligation() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_OBLIGATION_SECONDS=1 FM_DIAGNOSTICS=0 \
    bash -c '. "$1"; wake() { printf "%s\n" "$1"; }; paused_until_resume fixture pause-case "$2"' _ "$ROOT/bin/fm-watch.sh" "$1"
}
pause_line='paused [at=100]: waiting until 2020-01-01T00:00Z'
run_pause_obligation "$pause_line" >/dev/null
[ -e "$TASK_HOME/state/.obligation-pause-pause-case" ] || fail 'expired wait was not tracked'
# Legacy undated pauses receive one separate migration recheck.
touch "$TASK_HOME/state/.pause-legacy-checked-pause-case"
parked_line='paused [at=100]: parked, waiting for the captain order'
run_pause_obligation "$parked_line" >/dev/null
sleep 2
OUT=$(run_pause_obligation "$parked_line") || fail "undated wait check failed: $OUT"
[ -z "$OUT" ] && [ ! -e "$TASK_HOME/state/.obligation-pause-pause-case" ] \
  || fail 'undated parked wait was treated as expired'
future_line='paused [at=100]: waiting until 2099-01-01T00:00Z'
run_pause_obligation "$future_line" >/dev/null
[ ! -e "$TASK_HOME/state/.obligation-pause-pause-case" ] || fail 'future wait retained an expired obligation'
run_pause_obligation "$pause_line" >/dev/null
# This fixture has no endpoint: simulate the delivered notice before timing
# its reminder, rather than treating a failed send as a delivered message.
printf '100' > "$TASK_HOME/state/.paused-resumed-fixture"
run_pause_obligation "$pause_line" >/dev/null
sleep 2
OUT=$(run_pause_obligation "$pause_line") || fail "expired wait check failed: $OUT"
assert_contains "$OUT" 'declared wait for pause-case expired' 'expired wait was not reminded'
run_pause_obligation 'working: resumed' >/dev/null
[ ! -e "$TASK_HOME/state/.obligation-pause-pause-case" ] || fail 'resumed wait retained its obligation'
pass 'an expired declared wait resurfaces until the task resumes'

# The parked record is a snapshot; a later undated status is authoritative.
printf 'window=fixture\npark_wait=%s\n' "$pause_line" > "$TASK_HOME/state/pause-case.parked"
printf '%s\n%s\n' "$pause_line" 'paused [key=pausa-capitan] [at=101]: waiting for the captain' > "$TASK_HOME/state/pause-case.status"
printf '100' > "$TASK_HOME/state/.paused-resumed-fixture"
parked_loop=$(awk '$0 == "  for parked in \"$STATE\"/*.parked; do" { on=1 } on { print } on && $0 == "  done" { exit }' "$ROOT/bin/fm-watch.sh")
[ -n "$parked_loop" ] || fail 'parked worker watcher loop was not found'
run_parked_loop() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_OBLIGATION_SECONDS=1 FM_DIAGNOSTICS=0 \
    bash -c '. "$1"; wake() { printf "%s\n" "$1"; }; eval "$2"' _ "$ROOT/bin/fm-watch.sh" "$parked_loop"
}
run_parked_loop >/dev/null
sleep 2
OUT=$(run_parked_loop) || fail "current parked wait check failed: $OUT"
[ -z "$OUT" ] && [ ! -e "$TASK_HOME/state/.obligation-pause-pause-case" ] \
  || fail 'old parked snapshot overrode a newer undated pause'
rm -f -- "$TASK_HOME/state/pause-case.parked" "$TASK_HOME/state/pause-case.status"
pass 'a new undated pause supersedes the parked snapshot deadline'

# A later captain-ordered backlog hold supersedes the parked worker's old
# dated wait. The old parked record and resume marker can remain on disk.
FM_HOME="$TASK_HOME" bash "$ROOT/bin/fm-tasks-axi.sh" add pause-case 'Parked fixture' >/dev/null 2>&1 || fail 'fixture: add parked task'
FM_HOME="$TASK_HOME" bash "$ROOT/bin/fm-tasks-axi.sh" hold pause-case --kind parked --reason 'waiting for captain' >/dev/null 2>&1 || fail 'fixture: hold parked task'
printf 'park_phase=parked\npark_wait=%s\n' "$pause_line" > "$TASK_HOME/state/pause-case.parked"
printf '100' > "$TASK_HOME/state/.paused-resumed-fixture"
run_pause_obligation "$pause_line" >/dev/null
# This fixture has no endpoint: simulate the delivered notice before timing
# its reminder, rather than treating a failed send as a delivered message.
printf '100' > "$TASK_HOME/state/.paused-resumed-fixture"
run_pause_obligation "$pause_line" >/dev/null
sleep 2
OUT=$(run_pause_obligation "$pause_line") || fail "parked hold check failed: $OUT"
[ -z "$OUT" ] && [ ! -e "$TASK_HOME/state/.obligation-pause-pause-case" ] \
  || fail 'captain parked hold was overridden by an old expired worker wait'
[ -e "$TASK_HOME/state/pause-case.parked" ] || fail 'parked worker record was modified'
FM_HOME="$TASK_HOME" bash "$ROOT/bin/fm-tasks-axi.sh" hold pause-case --kind external --reason 'waiting for another actor' >/dev/null 2>&1 || fail 'fixture: replace parked hold'
OUT=$(FM_HOME="$TASK_HOME" bash "$ROOT/bin/fm-tasks-axi.sh" show pause-case) || fail 'fixture: inspect external hold'
assert_contains "$OUT" 'hold_kind: external' 'fixture did not change the hold category'
run_pause_obligation "$pause_line" >/dev/null
# This fixture has no endpoint: simulate the delivered notice before timing
# its reminder, rather than treating a failed send as a delivered message.
printf '100' > "$TASK_HOME/state/.paused-resumed-fixture"
run_pause_obligation "$pause_line" >/dev/null
sleep 2
OUT=$(run_pause_obligation "$pause_line") || fail "external hold check failed: $OUT"
[ -z "$OUT" ] && [ ! -e "$TASK_HOME/state/.obligation-pause-pause-case" ] \
  || fail 'current external hold was overridden by an old expired worker wait'
rm -f -- "$TASK_HOME/state/pause-case.parked"
pass 'a current backlog hold supersedes a parked worker old deadline'

mkdir -p "$TASK_HOME/data/progress-case/work"
printf 'kind=host\nworktree=%s\n' "$TASK_HOME/data/progress-case/work" > "$TASK_HOME/state/progress-case.meta"
printf 'working: started\n' > "$TASK_HOME/state/progress-case.status"
printf '{"presentation":{"phase":"implementation","progress":{"steps":[{"label":"Work","state":"active"}],"deliverables":[{"root":"worktree","path":"result.txt"}]}}}\n' > "$TASK_HOME/data/progress-case/presentation.json"
printf 'first result\n' > "$TASK_HOME/data/progress-case/work/result.txt"
FM_OBLIGATION_SECONDS=1 run_obligation_status_tick >/dev/null
printf 'improved result\n' > "$TASK_HOME/data/progress-case/work/result.txt"
OUT=$(FM_OBLIGATION_SECONDS=1 run_obligation_status_tick) || fail "progress check failed: $OUT"
[ -z "$OUT" ] || fail "deliverable progress was treated as a stall: $OUT"
sleep 2
printf 'working: activity without result\n' >> "$TASK_HOME/state/progress-case.status"
printf 'activity only\n' > "$TASK_HOME/data/progress-case/work/activity.log"
OUT=$(FM_OBLIGATION_SECONDS=1 run_obligation_status_tick) || fail "no-progress check failed: $OUT"
assert_contains "$OUT" 'no observable deliverable progress' 'activity without deliverable progress was not surfaced'
printf '{"presentation":{"phase":"implementation","progress":{"steps":[{"label":"Work","state":"active"}]}}}\n' > "$TASK_HOME/data/progress-case/presentation.json"
before=$(wc -l < "$TASK_HOME/state/.wake-queue")
run_obligation_status_tick >/dev/null
[ -e "$TASK_HOME/state/.progress-unknown-progress-case" ] && [ ! -e "$TASK_HOME/state/.obligation-progress-progress-case" ] \
  || fail 'legacy progress without declared deliverables was not unknown'
[ "$(wc -l < "$TASK_HOME/state/.wake-queue")" -eq "$before" ] || fail 'unknown progress created a wake'
FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" bash "$ROOT/bin/fm-wake-drain.sh" > "$TMP_ROOT/unknown.out" 2>/dev/null || true
assert_contains "$(cat "$TMP_ROOT/unknown.out")" 'DELIVERABLE PROGRESS UNKNOWN: progress-case' 'unknown progress was not reported on the next drain'
printf 'paused: waiting until 2099-01-01T00:00Z\n' >> "$TASK_HOME/state/progress-case.status"
run_obligation_status_tick >/dev/null
[ ! -e "$TASK_HOME/state/.obligation-progress-progress-case" ] && [ -e "$TASK_HOME/state/.progress-unknown-progress-case" ] || fail 'declared wait was timed or its unknown observation was lost'
rm -f -- "$TASK_HOME/state/progress-case.meta"
pass 'deliverable changes reset no-progress while status activity does not, and declared waits are exempt'

# Detection is unchanged; inject its verified-idle verdict and drive the real
# close policy and teardown against the same disposable host fixture.
run_completion_tick() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" \
    FM_DATA_OVERRIDE="$TASK_HOME/data" FM_CONFIG_OVERRIDE="$TASK_HOME/config" \
    HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" FM_TEST_ACTIVITY="${1:-idle fixture}" bash -c '
      . "$1"
      fm_busy_classify_meta() { printf "%s" "$FM_TEST_ACTIVITY"; }
      wake() { printf "%s\n" "$1"; }
      worker_completion_tick
    ' _ "$ROOT/bin/fm-watch.sh"
}
run_brief auto-close --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/auto-close/brief.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Finish host work.').replace('{FIRSTMATE_SPEC}', 'Close safely.').replace('{CAPTAIN_REQUIREMENTS}', '1. Fixture requirement.'))
PY
OUT=$(FM_MODEL_CATEGORY_OVERRIDE=1 fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/auto-close/work" "$FAKEBIN" auto-close --host --harness 'printf fixture' --backend tmux) || fail "auto-close spawn failed: $OUT"
publish_status auto-close 'done' verified
run_completion_tick 'unknown codex-unverified' >/dev/null
run_completion_tick 'unknown codex-unverified' >/dev/null
[ -e "$TASK_HOME/state/auto-close.meta" ] || fail 'unknown activity closed a worker'
[ "$(grep -c 'auto-close; turn completion could not be verified:' "$TASK_HOME/state/.watch-triage.log")" = 1 ] \
  || fail 'expected one explanation of the unknown turn completion'
OUT=$(run_completion_tick) || fail "completion tick failed: $OUT"
[ ! -e "$TASK_HOME/state/auto-close.meta" ] || fail "completed host remained open: $OUT"
[ ! -e "$TASK_HOME/data/auto-close/work" ] || fail 'completed host scratch remained'
[ "$(cat "$TARGET")" = preserve ] || fail 'automatic close changed the host target'
pass 'a verified idle done host closes through ordinary teardown and preserves its target'

run_brief close-report --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/close-report/brief.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Finish host work.').replace('{FIRSTMATE_SPEC}', 'Close safely.').replace('{CAPTAIN_REQUIREMENTS}', '1. Fixture requirement.'))
PY
OUT=$(FM_MODEL_CATEGORY_OVERRIDE=1 fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/close-report/work" "$FAKEBIN" close-report --host --harness 'printf fixture' --backend tmux) || fail "report fixture spawn failed: $OUT"
printf 'report\n' > "$TASK_HOME/data/close-report/report.md"
publish_status close-report 'done' verified
OUT=$(FM_OBLIGATION_SECONDS=9999 run_completion_tick) || fail "first close check failed: $OUT"
assert_contains "$OUT" 'no nonempty HTML report' 'first refusal names the missing report'
assert_contains "$OUT" 'deliver the HTML report' 'first refusal names the next step'
python3 - "$TASK_HOME/state/.worker-close-close-report" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time() - 301, time.time() - 301))
PY
OUT=$(FM_OBLIGATION_SECONDS=9999 run_completion_tick) || fail "second close check failed: $OUT"
[ -z "$OUT" ] || fail "unchanged close refusal repeated early: $OUT"
[ -e "$TASK_HOME/state/close-report.meta" ] && [ -d "$TASK_HOME/data/close-report/work" ] || fail 'refused close discarded work'
python3 - "$TASK_HOME/state/.obligation-close-close-report" "$TASK_HOME/state/.worker-close-close-report" <<'PY'
import os, pathlib, sys, time
p = pathlib.Path(sys.argv[1]); lines = p.read_text().splitlines(); lines[:2] = [str(int(time.time()) - 10000)] * 2
p.write_text('\n'.join(lines) + '\n')
os.utime(sys.argv[2], (time.time() - 301, time.time() - 301))
PY
OUT=$(FM_OBLIGATION_SECONDS=9999 run_completion_tick) || fail "overdue close check failed: $OUT"
assert_contains "$OUT" 'still unattended for' 'unchanged refusal resurfaces after the deadline'
[ -e "$TASK_HOME/state/close-report.meta" ] && [ -d "$TASK_HOME/data/close-report/work" ] || fail 'overdue refusal discarded work'
pass 'a missing report is explained once and resurfaces only at the obligation deadline'

# A synthetic pool record points both tasks at one ordinary fixture repository;
# no worktree-provider or pool lifecycle command is run.
OWNER_REPO="$TMP_ROOT/owner-pool/1/repo"
mkdir -p "$OWNER_REPO"
git -C "$OWNER_REPO" init -q -b main
printf '{"worktrees":[]}\n' > "$TMP_ROOT/owner-pool/treehouse-state.json"
printf 'window=firstmate:fm-owner-a\nendpoint_task_id=owner-a\nworktree=%s\nproject=%s\nkind=scout\n' "$OWNER_REPO" "$OWNER_REPO" > "$TASK_HOME/state/owner-a.meta"
printf 'worktree=%s\nkind=scout\n' "$OWNER_REPO" > "$TASK_HOME/state/owner-b.meta"
printf 'done: finished\n' > "$TASK_HOME/state/owner-a.status"
OUT=$(FM_OBLIGATION_SECONDS=900 run_completion_tick) || fail "owner collision check failed: $OUT"
assert_contains "$OUT" "also task owner-b's recorded worktree" 'owner collision reason'
assert_contains "$OUT" 'Reconcile whichever record is wrong' 'owner collision next step'
python3 - "$TASK_HOME/state/.worker-close-owner-a" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time() - 301, time.time() - 301))
PY
OUT=$(FM_OBLIGATION_SECONDS=900 run_completion_tick) || fail "repeat owner check failed: $OUT"
case "$OUT" in *'owner-a'*) fail "unchanged owner collision repeated early: $OUT" ;; esac
[ -f "$TASK_HOME/state/owner-a.meta" ] && [ -f "$TASK_HOME/state/owner-b.meta" ] && [ -d "$OWNER_REPO" ] || fail 'owner collision discarded work'
python3 - "$TASK_HOME/state/.obligation-close-owner-a" "$TASK_HOME/state/.worker-close-owner-a" <<'PY'
import os, pathlib, sys, time
p = pathlib.Path(sys.argv[1]); lines = p.read_text().splitlines(); lines[:2] = [str(int(time.time()) - 901)] * 2
p.write_text('\n'.join(lines) + '\n')
os.utime(sys.argv[2], (time.time() - 301, time.time() - 301))
PY
OUT=$(FM_OBLIGATION_SECONDS=900 run_completion_tick) || fail "overdue owner collision check failed: $OUT"
assert_contains "$OUT" 'still unattended for' 'owner collision did not resurface at its deadline'
[ -f "$TASK_HOME/state/owner-a.meta" ] && [ -f "$TASK_HOME/state/owner-b.meta" ] && [ -d "$OWNER_REPO" ] || fail 'overdue collision discarded work'
rm -f -- "$TASK_HOME/state/owner-a.meta" "$TASK_HOME/state/owner-b.meta"
pass 'ambiguous ownership is explained once, rechecked on deadline, and preserves both records'

printf 'kind=host\n' > "$TASK_HOME/state/unexplained.meta"
printf 'working: started\n' > "$TASK_HOME/state/unexplained.status"
run_completion_tick >/dev/null
python3 - "$TASK_HOME/state/.worker-idle-unexplained" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time() - 1801, time.time() - 1801))
PY
OUT=$(run_completion_tick) || fail "idle tick failed: $OUT"
assert_contains "$OUT" 'idle without a result or declared wait for over 30 minutes' 'unexplained idle individual wake'
assert_contains "$(cat "$TASK_HOME/state/.wake-queue")" 'worker-idle:unexplained' 'unexplained idle queued individually'
[ -e "$TASK_HOME/state/unexplained.meta" ] || fail 'idle alert discarded unfinished work'
printf 'blocked: needs an owner answer\n' >> "$TASK_HOME/state/unexplained.status"
run_completion_tick >/dev/null
[ ! -e "$TASK_HOME/state/.worker-idle-unexplained" ] || fail 'a declared wait kept the unexplained-idle timer'
rm "$TASK_HOME/state/unexplained.meta"
pass 'unexplained idle wakes individually without discarding work; a declared wait resets it'

printf 'kind=host\n' > "$TASK_HOME/state/kept.meta"
printf 'done: finished\n' > "$TASK_HOME/state/kept.status"
mkdir -p "$TASK_HOME/state/kept.inbox"
printf 'read me\n' > "$TASK_HOME/state/kept.inbox/001.msg"
run_completion_tick >/dev/null
run_completion_tick >/dev/null
[ "$(grep -c 'worker done but kept open: kept; unread steering 001.msg' "$TASK_HOME/state/.watch-triage.log")" = 1 ] \
  || fail 'a done worker kept open by unread steering was not explained exactly once'
[ -e "$TASK_HOME/state/kept.meta" ] || fail 'the kept-open explanation closed the worker'
rm -rf "$TASK_HOME/state/kept.meta" "$TASK_HOME/state/kept.inbox"
pass 'a done worker kept open by unread steering is explained once'

backdate() {  # <path>: 31 minutes old
  python3 -c 'import os,sys,time; t=time.time()-1860; os.utime(sys.argv[1],(t,t))' "$1"
}
printf 'kind=host\n' > "$TASK_HOME/state/waiting.meta"
printf 'needs-decision [key=name]: which name\n' > "$TASK_HOME/state/waiting.status"
(
  sleep 300 &
  background_pid=$!
  trap 'kill "$background_pid" 2>/dev/null || true; wait "$background_pid" 2>/dev/null || true' EXIT
  kill -0 "$background_pid" || fail 'background work did not start'
  OUT=$(run_completion_tick) || fail "waiting tick failed: $OUT"
  # Exercise the old 30-minute deadline with a pre-upgrade marker.
  touch "$TASK_HOME/state/.worker-wait-waiting"
  backdate "$TASK_HOME/state/.worker-wait-waiting"
  OUT=$(run_completion_tick) || fail "waiting tick failed: $OUT"
  kill -0 "$background_pid" || fail 'background work ended before the assertion'
  case "$OUT" in *'worker automatic park refused: waiting'*) fail "attempted to park while background activity is unknown: $OUT" ;; esac
  [ ! -e "$TASK_HOME/state/waiting.parked" ] || fail 'automatic park wrote a parked record without proof background work ended'
  [ -e "$TASK_HOME/state/waiting.meta" ] || fail 'automatic park discarded the waiting worker'
  if [ -f "$TASK_HOME/state/.wake-queue" ]; then
    ! grep -F 'worker-park:waiting' "$TASK_HOME/state/.wake-queue" >/dev/null || fail 'automatic park queued a wake'
  fi
)
rm -f "$TASK_HOME/state/waiting.meta" "$TASK_HOME/state/waiting.status"
pass 'an idle turn with unknown background activity is not automatically parked'

# A delivered worker that owns an open review board stays open until the board ends.
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-store"
mkdir -p "$LAVISH_AXI_STATE_DIR" "$TASK_HOME/data/hosting"
: > "$TASK_HOME/data/hosting/report.html"
printf 'kind=host\n' > "$TASK_HOME/state/hosting.meta"
printf 'done: finished\n' > "$TASK_HOME/state/hosting.status"
jq -n --arg f "$(realpath "$TASK_HOME/data/hosting/report.html")" \
  '{sessions:{one:{key:"one",file:$f,status:"open",url:"http://127.0.0.1:1/session/0123456789abcdef"}}}' \
  > "$LAVISH_AXI_STATE_DIR/state.json"
run_completion_tick >/dev/null
run_completion_tick >/dev/null
[ "$(grep -c 'worker done but kept open: hosting; it owns an open review board' "$TASK_HOME/state/.watch-triage.log")" = 1 ] \
  || fail 'a done worker owning an open board was not explained exactly once'
[ -e "$TASK_HOME/state/hosting.meta" ] || fail 'a worker owning an open board was closed'
rm -f "$TASK_HOME/state/hosting.meta" "$TASK_HOME/state/hosting.status" "$LAVISH_AXI_STATE_DIR/state.json"
unset LAVISH_AXI_STATE_DIR
pass 'a done worker that owns an open review board stays open and is explained once'

# The batch close runs the real snapshot, board list and teardown on a delivered host.
run_brief batch-close --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/batch-close/brief.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Finish host work.').replace('{FIRSTMATE_SPEC}', 'Close in a batch.').replace('{CAPTAIN_REQUIREMENTS}', '1. Fixture requirement.'))
PY
OUT=$(FM_MODEL_CATEGORY_OVERRIDE=1 fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/batch-close/work" "$FAKEBIN" batch-close --host --harness 'printf fixture' --backend tmux) || fail "batch-close spawn failed: $OUT"
publish_status batch-close 'done' verified
run_batch() {
  FM_HOME="$TASK_HOME" FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
    FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_PROJECTS_OVERRIDE="$TASK_HOME/projects" \
    HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 bash "$ROOT/bin/fm-close-delivered.sh" "$@"
}
OUT=$(run_batch list 2>&1) || fail "close list failed: $OUT"
assert_contains "$OUT" 'batch-close | host | delivered' 'the view lists the delivered host'
OUT=$(run_batch close batch-close 2>&1) || fail "batch close failed: $OUT"
assert_contains "$OUT" '[1/1] batch-close: closed' 'the batch close reports progress'
[ ! -e "$TASK_HOME/state/batch-close.meta" ] || fail 'the batch close left the worker open'
[ "$(cat "$TARGET")" = preserve ] || fail 'the batch close changed the host target'
pass 'the batch close closes a delivered host through the real snapshot and teardown'

# Run the emitted Claude command: a host grant must not swallow --settings.
run_brief claude-host --host --path "$TARGET" >/dev/null
python3 - "$TASK_HOME/data/claude-host/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Check Claude host launch.').replace('{FIRSTMATE_SPEC}','Preserve hooks.').replace('{CAPTAIN_REQUIREMENTS}','1. Fixture requirement.'))
PY
export FM_HOST_ARGV="$TMP_ROOT/claude-argv.json"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '2.1.325\n'; exit 0; fi
python3 -c 'import json,sys;json.dump(sys.argv[2:],open(sys.argv[1],"w"))' "$FM_HOST_ARGV" "$@"
SH
chmod +x "$FAKEBIN/claude"
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/claude-host/work" "$FAKEBIN" claude-host --host --harness claude --model claude-test --effort high --backend tmux) || fail "Claude host spawn failed: $OUT"
LAUNCH=$(cat "$FM_FAKE_LAUNCH_LOG")
(cd "$TASK_HOME/data/claude-host/work" && HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" /bin/sh -c "$LAUNCH") || fail 'Claude host command failed'
jq -e --arg settings "$TASK_HOME/state/claude-host.claude-settings.json" \
  'index("--settings") as $i | $i != null and .[$i+1] == $settings' \
  "$FM_HOST_ARGV" >/dev/null || fail 'Claude host launch lost its hook settings argument'
pass 'Claude host launch delivers hook settings as a separate argument'
# Exercise the relay adapter through its executable interface with a checker
# fixture. Real Codex/Claude callback and lifecycle evidence belongs to the lab.
python3 - "$ROOT" "$TMP_ROOT" <<'PYRELAY'
import json, os, pathlib, shutil, subprocess, sys, time
root, tmp = map(pathlib.Path, sys.argv[1:])
lab = tmp / 'relay'
bin_dir = lab / 'bin'
state, data = lab / 'state', lab / 'data' / 'worker'
for path in (bin_dir, state, data, lab / 'config'):
    path.mkdir(parents=True, exist_ok=True)
for name in ('fm-worker-relay.py', 'fm-redact-log.py'):
    shutil.copy(root / 'bin' / name, bin_dir / name)
for name, body in {
    'fm-send.sh': 'printf requested >> "$FM_HOME/requests"',
    'fm-control.sh': 'printf "%s\\n" "$@"; exit "${RELAY_FAIL:-0}"',
    'fm-diag.sh': 'exit 0',
}.items():
    (bin_dir / name).write_text('#!/usr/bin/env bash\n' + body + '\n')
checker = lab / 'checker'
status_args = [sys.executable, str(bin_dir/'fm-worker-relay.py'), '--status', str(lab), 'codex', 'chosen']
missing = subprocess.check_output(status_args, env=dict(os.environ, FM_RELAY_CHECK=str(checker)), text=True)
assert 'checker missing' in missing
(lab / 'config/relay-lite.json').write_text('{}')
checker.write_text('import json,os; print(json.dumps({"schema":"relay-lite.check.v1","role":"worker","harness":"codex","state":"below","threshold_tokens":int(os.environ["RELAY_LIMIT"])}))')
for limit, expected in [('0', 'worker thresholds disabled'), ('100', 'ready for requested model')]:
    result = subprocess.check_output(status_args, env=dict(os.environ, FM_RELAY_CHECK=str(checker), RELAY_LIMIT=limit), text=True)
    assert expected in result and 'fm-extension install' in result
checker.write_text('import json,os; print(json.dumps({"schema":"relay-lite.check.v1","state":os.environ.get("RELAY_STATE","reached")}))')
(lab / 'config/relay-lite.json').write_text('{}')
(data / 'sessions.jsonl').write_text(json.dumps({'status':'active','session':'old-session'})+'\n')
(state / 'worker.meta').write_text('kind=host\nbusy_gen=launch1\nworktree='+str(data)+'\nsessions_file='+str(data/'sessions.jsonl')+'\nharness=codex\nmodel=chosen\neffort=high\n')
args = [sys.executable, str(bin_dir/'fm-worker-relay.py'), str(lab), str(state), 'worker', 'launch1', str(checker)]
def run(extra=(), **env):
    subprocess.run(args+list(extra), env=dict(os.environ, **env), check=True)
def wait(path, contains=''):
    for _ in range(100):
        if path.exists() and contains in path.read_text(): return
        time.sleep(.05)
    raise AssertionError('missing '+str(path))
run(RELAY_STATE='unknown')
assert not (lab/'requests').exists()
native={'session_id':'one','transcript_path':'old-session','model':{'id':'claude-opus-5-5'},
        'context_window':{'context_window_size':1000000}}
(state/'worker.launch1.claude-context.json').write_text(json.dumps(native))
record=state/'worker.meta'
record.write_text(record.read_text().replace('harness=codex','harness=claude'))
checker.write_text('import json,os,pathlib,sys; p=json.load(sys.stdin); pathlib.Path(os.environ["RELAY_PAYLOAD"]).write_text(json.dumps(p)); print(json.dumps({"schema":"relay-lite.check.v1","state":"unknown"}))')
run(RELAY_PAYLOAD=str(lab/'payload'))
assert json.loads((lab/'payload').read_text())['statusline']==native
record.write_text(record.read_text().replace('harness=claude','harness=codex'))
checker.write_text('import json,os; print(json.dumps({"schema":"relay-lite.check.v1","state":os.environ.get("RELAY_STATE","reached")}))')
subprocess.run(args[:5]+['stale',str(checker)], check=True)
run()
wait(lab/'requests')
run()  # Replayed completion must not queue another handoff request.
time.sleep(.2)
assert (lab/'requests').read_text() == 'requested'
note=data/'relay-note-launch1.md'
note.write_text('Finished ONCE. Continue pending inbox; never repeat ONCE.')
run()
ready=state/'worker.relay-ready'
assert ready.exists()
subprocess.run([sys.executable,str(bin_dir/'fm-worker-relay.py'),'--dispatch',str(lab),str(state)],check=True)
result=state/'worker.relay-result'
wait(result, 'replacement launched')
assert 'replacement launched' in result.read_text()
control=(data/'relay-control-launch1.log').read_text()
assert '--note-file\n'+str(note) in control
assert '--harness\ncodex\n--model\nchosen\n--effort\nhigh' in control
result.unlink()
run()
subprocess.run([sys.executable,str(bin_dir/'fm-worker-relay.py'),'--dispatch',str(lab),str(state)],env=dict(os.environ,RELAY_FAIL='1'),check=True)
wait(result, 'incomplete')
assert 'incomplete' in result.read_text() and note.exists()
result.unlink()
(state/'worker.status').write_text('done [at=1]: complete\n')
run()
assert not ready.exists() and not result.exists()
# A legitimate slow delivery must finish through fm-send's own bounded protocol,
# rather than disappearing at an unrelated 90-second wrapper deadline.
(state/'worker.status').unlink()
(data/'relay-request-launch1').unlink()
(bin_dir/'fm-send.sh').write_text('#!/usr/bin/env bash\nsleep 91\nprintf delivered > "$FM_HOME/slow-delivered"\n')
run(('--request','999999999'))
assert (lab/'slow-delivered').read_text() == 'delivered'
assert (data/'relay-request-launch1').read_text() == 'requested\n'
assert 'handoff requested' in (state/'worker.relay-result').read_text()
# A turn that never ends never reaches the native callback; the watcher checks it mid-turn.
(bin_dir/'fm-send.sh').write_text('#!/usr/bin/env bash\nprintf requested >> "$FM_HOME/requests"\n')
for path in (data/'relay-request-launch1', lab/'requests', state/'worker.relay-result'): path.unlink()
(state/'worker.busy-state').write_text('v1 gen=launch1 seq=3 state=busy source=claude-hook event=user-prompt-submit ts=1\n')
dispatch = [sys.executable, str(bin_dir/'fm-worker-relay.py'), '--dispatch', str(lab), str(state)]
watcher = dict(os.environ, FM_RELAY_CHECK=str(checker))
subprocess.run(dispatch, env=watcher, check=True)  # A note written mid-turn is not a safe point.
time.sleep(1.5)
assert not ready.exists() and not (lab/'requests').exists()
os.utime(data/'relay-midturn-launch1', (0, 0))
note.unlink()
subprocess.run(dispatch, env=watcher, check=True)
wait(lab/'requests')
subprocess.run(dispatch, env=watcher, check=True)
time.sleep(.5)
assert (lab/'requests').read_text() == 'requested' and not ready.exists()
print('ok - relay checker gates requests, duplicate callbacks, note/profile preservation, owner control, failure, terminal work and mid-turn thresholds')
PYRELAY
# Feed the native vendor statusline through the public wrapper. Existing display
# receives unchanged JSON, local overrides user settings, and only native fields persist.
python3 - "$ROOT" "$TMP_ROOT" <<'PYCONTEXT'
import json, pathlib, shlex, subprocess, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
lab=tmp/'native-context'
store, project = lab/'store', lab/'project'
for p in (store, project/'.claude'): p.mkdir(parents=True)
settings=lab/'settings.json'; settings.write_text('{"feedbackDrafts":"off"}')
(store/'settings.json').write_text(json.dumps({'statusLine':{'type':'command','command':'printf user'}}))
display=shlex.join([sys.executable,'-c','import json,sys; print(json.load(sys.stdin)["model"]["id"])'])
(project/'.claude/settings.local.json').write_text(json.dumps({'statusLine':{'type':'command','command':display,'padding':2}}))
snapshot=lab/'launch1.claude-context.json'
subprocess.run([sys.executable,str(root/'bin/fm-claude-context.py'),'setup',str(settings),str(project),str(store),str(snapshot)],check=True)
configured=json.loads(settings.read_text())
assert configured['feedbackDrafts']=='off' and configured['statusLine']['padding']==2
native={'session_id':'one','transcript_path':'/one.jsonl','model':{'id':'claude-opus-5-5'},
        'context_window':{'context_window_size':1000000,'used_percentage':26},'unrelated':'omit'}
result=subprocess.run(configured['statusLine']['command'],shell=True,input=json.dumps(native),text=True,capture_output=True,check=True)
assert result.stdout.strip()=='claude-opus-5-5',result
assert json.loads(snapshot.read_text())=={k:v for k,v in native.items() if k!='unrelated'}
native.update(session_id='two',transcript_path='/two.jsonl')
subprocess.run(configured['statusLine']['command'],shell=True,input=json.dumps(native),text=True,capture_output=True,check=True)
assert json.loads(snapshot.read_text())['session_id']=='two'
print('ok - Claude native window capture preserves effective display, payload, settings and session identity')
PYCONTEXT
for target in relative/path "$ROOT/AGENTS.md" "$TASK_HOME/projects/new/file"; do
  if run_brief "bad-$RANDOM" --host --path "$target" >/dev/null 2>&1; then fail "unsafe host path accepted: $target"; fi
done
# A pre-existing scratch or a forged cleanup path must never be reused/deleted.
run_brief occupied --host --path "$TARGET" >/dev/null
mkdir "$TASK_HOME/data/occupied/work"
if FM_MODEL_CATEGORY_OVERRIDE=1 fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/occupied/work" "$FAKEBIN" occupied --host --harness 'echo fake' >/dev/null; then fail 'existing scratch was reused'; fi
printf 'off\n' > "$TASK_HOME/config/primary-direct-ops"
if run_brief disabled --host --path "$TARGET" >/dev/null 2>&1; then fail 'off must disable host tasks'; fi
pass 'host paths and disabled configuration refuse unsafe launch contracts'
