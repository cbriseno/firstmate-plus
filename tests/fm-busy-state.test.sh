#!/usr/bin/env bash
# Behavior tests for the semantic busy-state contract (bin/fm-busy-lib.sh and
# its only writer bin/fm-busy-event.sh).
#
# Covers the captain-approved redesign invariants: busy/idle/unknown/dead with
# explicit source attribution; missing, malformed, stale (gen-mismatch), and
# untrusted (source-mismatch) semantic data classify unknown - never idle;
# adapter isolation (one adapter's writer or Grok's regex can never classify
# another adapter); endpoint death is the only process-level override and
# yields dead, never busy; converted adapters never classify from rendered
# footer text. All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-state)
EV="$ROOT/bin/fm-busy-event.sh"

new_state_dir() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- writer: arm and apply ---------------------------------------------------

test_arm_seeds_busy_spawn() {
  local state gen out
  state=$(new_state_dir arm-seed)
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ -f "$state/t1.busy-gen" ] || fail "arm did not write the gen sidecar"
  [ "$(cat "$state/t1.busy-gen")" = "$gen" ] || fail "sidecar gen does not match printed gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed should classify 'busy fm-spawn', got '$out'"
  pass "arm mints a gen sidecar and seeds busy fm-spawn at seq=1"
}

test_apply_advances_seq_and_source() {
  local state gen out seq
  state=$(new_state_dir apply-seq)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply idle failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "expected 'idle claude-hook', got '$out'"
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "apply busy failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy claude-hook" ] || fail "expected 'busy claude-hook', got '$out'"
  seq=$(fm_busy_record_read "$state" t1 | awk '{print $4}')
  [ "$seq" = 3 ] || fail "expected seq 3 after seed + two applies, got '$seq'"
  pass "apply advances seq under the armed gen and attributes the writing source"
}

test_apply_current_gen_reset() {
  local state out
  state=$(new_state_dir apply-current)
  "$EV" arm "$state" t1 >/dev/null
  "$EV" apply "$state" t1 idle --current-gen --source fm-interrupt --event interrupt \
    || fail "apply --current-gen failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle fm-interrupt" ] || fail "expected 'idle fm-interrupt', got '$out'"
  "$EV" apply "$state" t1 unknown --current-gen --source fm-recovery --event relaunch \
    || fail "apply unknown failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown fm-recovery" ] || fail "expected 'unknown fm-recovery', got '$out'"
  pass "firstmate-owned interrupt and recovery events bind to the current gen"
}

test_apply_unarmed_refused() {
  local state
  state=$(new_state_dir apply-unarmed)
  if "$EV" apply "$state" t1 busy --gen g1.2.3 --source claude-hook --event x 2>/dev/null; then
    fail "apply against an unarmed task must be refused"
  fi
  [ ! -f "$state/t1.busy-state" ] || fail "refused apply must not write a record"
  pass "apply is refused for a task whose busy contract was never armed"
}

test_retire_serializes_and_rejects_stale_gen() {
  local state old_gen new_gen out retire_pid i=0
  state=$(new_state_dir retire)
  old_gen=$("$EV" arm "$state" t1)
  mkdir "$state/t1.busy-state.lock"
  "$EV" retire "$state" t1 --gen "$old_gen" >/dev/null 2>&1 &
  retire_pid=$!
  while [ "$i" -lt 20 ] && ! kill -0 "$retire_pid" 2>/dev/null; do
    i=$((i + 1))
  done
  [ -e "$state/t1.busy-state" ] || fail "retire bypassed the writer lock"
  rmdir "$state/t1.busy-state.lock"
  wait "$retire_pid" || fail "retire failed after acquiring the writer lock"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"

  new_gen=$("$EV" arm "$state" t1)
  if "$EV" retire "$state" t1 --gen "$old_gen" 2>/dev/null; then
    fail "retire accepted a superseded incarnation"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale retirement changed the new incarnation, got '$out'"
  [ "$(cat "$state/t1.busy-gen")" = "$new_gen" ] || fail "stale retirement changed the new gen"
  pass "retire waits for the writer lock and cannot remove a new incarnation"
}

# Regression for issue #2625: the writer lock's stale-lock branch resolved the
# lock's mtime with `stat -f %m ... || stat -c %Y ...`. On GNU coreutils `-f` is
# *filesystem* stat, so it consumes the format string as a path, complains on
# stderr, prints "  File: ..." on stdout, and still exits 0 - the GNU form in the
# fallback never ran. The following `$((now - mtime))` then evaluated the word
# `File`, which under `set -u` aborted the writer with "File: unbound variable".
# fm-teardown.sh died there after returning the worktree, leaving state/<id>.meta
# and friends behind to generate stale wakes forever, and every re-run died
# identically because the abandoned lock directory was never broken.
#
# The stat and uname stubs make this deterministic on any host: the writer must
# take the Linux path and still break a provably stale lock.
test_stale_lock_broken_under_gnu_stat() {
  local state gen fakebin real_uname out status
  state=$(new_state_dir gnu-stat-lock)
  gen=$("$EV" arm "$state" t1)
  fakebin=$(fm_fakebin "$TMP_ROOT/gnu-stat-lock")
  real_uname=$(command -v uname)

  # GNU coreutils semantics, self-contained so no real stat is consulted.
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %Y ]; then
  printf '%s\n' 1000000000   # long-abandoned lock
  exit 0
fi
if [ "${1:-}" = -f ]; then
  echo "stat: cannot read file system information for '$2': No such file or directory" >&2
  shift 2
  printf '  File: "%s"\n' "${1:-}"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/stat"
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
if [ \$# -eq 0 ]; then printf 'Linux\n'; exit 0; fi
exec "$real_uname" "\$@"
SH
  chmod +x "$fakebin/uname"

  mkdir "$state/t1.busy-state.lock"
  out=$(PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --gen "$gen" 2>&1) && status=0 || status=$?
  case "$out" in
    *'unbound variable'*) fail "the writer still dies on GNU stat output: $out" ;;
  esac
  [ "$status" = 0 ] || fail "retire did not break a provably stale writer lock: $out"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"
  [ ! -e "$state/t1.busy-state.lock" ] || fail "retire left the stale lock behind"

  # Teardown must be able to run again over the same task without failing.
  PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --current-gen \
    || fail "a repeated retire over already-cleaned state was not idempotent"
  pass "the writer breaks a stale lock instead of dying on GNU stat output"
}

test_retire_missing_sidecar_is_idempotent() {
  local state gen
  state=$(new_state_dir retire-missing)
  gen=$("$EV" arm "$state" t1)
  rm -f "$state/t1.busy-gen"

  "$EV" retire "$state" t1 --gen "$gen" || fail "exact-gen retire rejected a missing sidecar"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left an orphan record behind"
  "$EV" retire "$state" t1 --gen "$gen" || fail "repeated exact-gen retire was not idempotent"
  "$EV" retire "$state" t1 --current-gen || fail "current-gen retire was not idempotent"

  printf 'malformed gen\n' > "$state/t1.busy-gen"
  printf 'orphan\n' > "$state/t1.busy-state"
  if "$EV" retire "$state" t1 --gen "$gen" 2>/dev/null; then
    fail "retire accepted a malformed existing sidecar"
  fi
  [ -e "$state/t1.busy-state" ] || fail "retire removed the record for a malformed existing sidecar"
  pass "retire treats only an absent sidecar as already retired"
}

# --- stale event rejection ----------------------------------------------------

test_stale_gen_event_rejected() {
  local state old_gen new_gen out
  state=$(new_state_dir stale-event)
  old_gen=$("$EV" arm "$state" t1)
  new_gen=$("$EV" arm "$state" t1)
  [ "$old_gen" != "$new_gen" ] || fail "re-arm must mint a fresh gen"
  if "$EV" apply "$state" t1 idle --gen "$old_gen" --source claude-hook --event stop 2>/dev/null; then
    fail "an event carrying a stale gen must be rejected"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale event must not change the record, got '$out'"
  pass "a late event from a previous incarnation is rejected, record unchanged"
}

test_stale_gen_record_unknown() {
  local state gen out
  state=$(new_state_dir stale-record)
  gen=$("$EV" arm "$state" t1)
  # Simulate a record left behind by a superseded incarnation.
  printf 'g-superseded.1.1\n' > "$state/t1.busy-gen.new"
  mv "$state/t1.busy-gen.new" "$state/t1.busy-gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown gen-mismatch" ] || fail "stale record must classify 'unknown gen-mismatch', got '$out'"
  pass "a record from a stale incarnation classifies unknown, never idle"
}

# --- missing and malformed semantic data --------------------------------------

test_missing_record_unknown_not_idle() {
  local state out h
  state=$(new_state_dir missing)
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state")
    [ "$out" = "unknown missing" ] || fail "$h with no record must be 'unknown missing', got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex with no verified source must be 'unknown codex-unverified', got '$out'"
  pass "a converted adapter with no record classifies unknown, never idle"
}

test_malformed_record_unknown() {
  local state gen out
  state=$(new_state_dir malformed)
  gen=$("$EV" arm "$state" t1)
  for bad in \
    'garbage' \
    "v0 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=NaN state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=frobbing source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=bad source event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1 rogue=1"; do
    printf '%s\n' "$bad" > "$state/t1.busy-state"
    out=$(fm_busy_classify tmux w1 claude t1 "$state")
    [ "$out" = "unknown malformed" ] || fail "malformed record '$bad' must be 'unknown malformed', got '$out'"
  done
  printf 'v1 gen=%s seq=1 state=busy source=claude-hook event=x ts=1\nsecond line\n' "$gen" > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "multi-line record must be 'unknown malformed', got '$out'"
  pass "malformed records classify unknown malformed, never busy or idle"
}

test_record_without_sidecar_unknown() {
  local state out
  state=$(new_state_dir orphan-record)
  printf 'v1 gen=g1.1.1 seq=1 state=busy source=claude-hook event=x ts=1\n' > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "record without an armed gen must be unknown, got '$out'"
  pass "a record with no armed gen sidecar classifies unknown"
}

# --- adapter isolation ---------------------------------------------------------

test_source_mismatch_cross_adapter() {
  local state gen out
  state=$(new_state_dir cross-adapter)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "pi-ext record on a claude task must be untrusted, got '$out'"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "pi-ext record on a pi task must classify, got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "grok trusts no semantic source, got '$out'"
  pass "a record is trusted only by the adapter whose source wrote it"
}

test_converted_adapters_ignore_footer_text() {
  local state out h
  state=$(new_state_dir no-footer)
  local tail='• Working (6s • esc to interrupt)
   ■■■■⬝⬝⬝⬝  esc interrupt
Working...
Ctrl+c:cancel'
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" "$tail")
    [ "$out" = "unknown missing" ] || fail "$h must never classify from footer text, got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state" "$tail")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must never classify from footer text, got '$out'"
  pass "converted adapters never classify busy from rendered footer text"
}

# --- launch-prompt backstop (a launch pinned at fm-spawn, parked on a
# recognized interactive prompt, must classify unknown rather than busy) ------

test_launch_prompt_claude_trust_dialog() {
  local state out
  state=$(new_state_dir launch-prompt-claude)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 claude t1 "$state" 'Accessing workspace: /tmp/wt-a
Quick safety check: Is this a project you created or one you trust?
Claude Code'"'"'ll be able to read, edit, and execute files here.
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a launch pinned at fm-spawn parked on Claude's trust dialog must classify unknown launch-prompt, got '$out'"
  out=$(fm_busy_classify tmux w1 claude t1 "$state" 'Allow external CLAUDE.md file imports?
This project'"'"'s CLAUDE.md imports files outside the current working directory.
> No, disable external imports
  Yes, allow external imports')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a launch pinned at fm-spawn parked on Claude's external-imports dialog must classify unknown launch-prompt, got '$out'"
  pass "a Claude launch parked on its trust or external-imports dialog classifies unknown launch-prompt"
}

test_launch_prompt_pi_trust_dialog() {
  local state out h
  for h in pi pi-signed omp; do
    state=$(new_state_dir "launch-prompt-$h")
    "$EV" arm "$state" t1 >/dev/null
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" ' Trust project folder?
 /tmp/fm-pi-trust-check/wt

 This allows pi to load .pi settings and resources, install missing project packages, and execute project extensions.

 > Trust
   Trust parent folder (/tmp/fm-pi-trust-check)
   Trust (this session only)
   Do not trust
   Do not trust (this session only)

 up/down navigate  enter select  escape/ctrl+c cancel')
    [ "$out" = "unknown launch-prompt" ] \
      || fail "a $h launch pinned at fm-spawn parked on the project-trust dialog must classify unknown launch-prompt, got '$out'"
  done
  pass "a Pi-family launch (pi, pi-signed, omp) parked on the project-trust dialog classifies unknown launch-prompt"
}

test_launch_prompt_pi_requires_both_markers() {
  local state out
  state=$(new_state_dir launch-prompt-pi-partial)
  "$EV" arm "$state" t1 >/dev/null
  # "trust" alone, with neither the dialog heading nor its decline option, must
  # not be read as the dialog - it is an ordinary word a worker's own output
  # could easily contain.
  out=$(fm_busy_classify tmux w1 pi t1 "$state" 'I trust this approach and will proceed.')
  [ "$out" = "busy fm-spawn" ] \
    || fail "ordinary prose containing 'trust' must not classify as a parked launch, got '$out'"
  pass "the Pi signature requires both the dialog heading and its decline option, not the bare word trust"
}

test_launch_prompt_never_shortens_a_working_launch() {
  local state out
  state=$(new_state_dir launch-prompt-working)
  "$EV" arm "$state" t1 >/dev/null
  # A genuinely working launch (Claude's ordinary busy footer, rendered before
  # its own hook has posted a single event yet) must keep the normal busy
  # bound rather than being shortened by this backstop.
  out=$(fm_busy_classify tmux w1 claude t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "busy fm-spawn" ] \
    || fail "a genuinely busy launch must not be reclassified, got '$out'"
  pass "the launch-prompt backstop never reclassifies a genuinely working launch"
}

test_launch_prompt_scoped_to_armed_harnesses() {
  local state out
  # opencode ships no trust dialog (fm-busy-lib.sh header), so it has no
  # signature at all: even Claude's own dialog text must not reclassify it.
  state=$(new_state_dir launch-prompt-opencode)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 opencode t1 "$state" \
    'Quick safety check: Is this a project you created or one you trust?')
  [ "$out" = "busy fm-spawn" ] \
    || fail "opencode has no launch-prompt signature and must stay busy fm-spawn, got '$out'"
  pass "the launch-prompt backstop is scoped to harnesses with a verified signature"
}

test_launch_prompt_never_reclassifies_an_advanced_record() {
  local state gen out
  state=$(new_state_dir launch-prompt-advanced)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 claude t1 "$state" \
    'Quick safety check: Is this a project you created or one you trust?')
  [ "$out" = "busy claude-hook" ] \
    || fail "a record that has advanced past fm-spawn must never be reclassified by pane text, got '$out'"
  pass "the launch-prompt backstop only ever touches the untouched fm-spawn seed"
}

test_launch_prompt_requires_a_captured_tail() {
  local state out
  state=$(new_state_dir launch-prompt-no-tail)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] \
    || fail "with no captured tail the record's own state must stand, got '$out'"
  pass "the launch-prompt backstop never runs without a captured tail"
}

test_grok_regex_isolated() {
  local state out
  state=$(new_state_dir grok-arm)
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'thinking hard
Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok busy tail must classify 'busy grok-regex', got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'done.
> ')
  [ "$out" = "idle grok-regex" ] || fail "grok idle tail must classify 'idle grok-regex', got '$out'"
  # Another adapter's footer never makes grok busy either.
  out=$(fm_busy_classify tmux w1 grok t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "idle grok-regex" ] || fail "a claude footer must not classify grok busy, got '$out'"
  pass "the grok fallback is regex-scoped to grok and classifies only grok tasks"
}

# --- kimi verification gate -----------------------------------------------------

test_codex_unverified_gate() {
  local state gen out
  state=$(new_state_dir codex-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source codex-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "unverified codex must classify unknown, got '$out'"
  [ -z "$(fm_busy_sources_for_harness codex)" ] \
    || fail "codex must trust no semantic source until one is verified"
  pass "codex classifies unknown until a semantic source passes its verification gate"
}

# A real holder process opens both files. The fixture pins the kernel/session
# join and fold through the executable interface, not vendor behavior (the live
# Codex guard proves that separately). No harness, account, or backend is used.
test_codex_process_owned_rollout() {
  CODEX_ACTIVITY_ROOT="$ROOT" CODEX_ACTIVITY_TMP="$TMP_ROOT" python3 - <<'PY' || fail 'Codex process-owned rollout regression failed'
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(os.environ['CODEX_ACTIVITY_ROOT'])
base = pathlib.Path(os.environ['CODEX_ACTIVITY_TMP']) / 'codex-rollout'
base.mkdir()
state = base / 'state'; state.mkdir()
home = base / 'codex'; workspace = base / 'workspace'; workspace.mkdir()
session = '11111111-2222-3333-4444-555555555555'
log = home / 'sessions/2026/10/30' / ('rollout-test-' + session + '.jsonl')
log.parent.mkdir(parents=True)
lock = home / 'thread-writer-locks' / (session + '.lock'); lock.parent.mkdir()
meta = {'type':'session_meta','payload':{'id':session,'cwd':str(workspace),'cli_version':'0.166.0','source':'cli'}}
def row(kind, turn='turn-1', **extra):
    return {'type':'event_msg','payload':dict(type=kind,turn_id=turn,**extra)}
def write(*rows):
    log.write_text(''.join(json.dumps(r)+'\n' for r in rows))
def append(*rows):
    with log.open('a') as f:
        f.write(''.join(json.dumps(r)+'\n' for r in rows))
write(meta)
ready = base / 'ready'
session2 = '66666666-2222-3333-4444-555555555555'
log2 = log.parent / ('rollout-test-' + session2 + '.jsonl')
lock2 = lock.parent / (session2 + '.lock')
ready2 = base / 'switched'
review_id = '77777777-2222-3333-4444-555555555555'
review_log = log.parent / ('rollout-test-' + review_id + '.jsonl')
review_lock = lock.parent / (review_id + '.lock')
review_ready = base / 'review-open'
holder = subprocess.Popen([sys.executable,'-c',
    '''import fcntl,json,pathlib,signal,subprocess,sys,time
a=open(sys.argv[1],"ab"); b=open(sys.argv[2],"a")
fcntl.flock(b,fcntl.LOCK_EX)
def switch(*_):
    global a,b
    a.close(); b.close()
    a=open(sys.argv[4],"ab"); b=open(sys.argv[5],"a")
    fcntl.flock(b,fcntl.LOCK_EX); pathlib.Path(sys.argv[6]).touch()
signal.signal(signal.SIGUSR1,switch)
reviews=[]
def notify(path):
    session=json.loads(pathlib.Path(path).read_text().splitlines()[0])["payload"]["id"]
    program=[sys.executable,"-c","import pathlib,sys;pathlib.Path(sys.argv[1]).touch()",sys.argv[13]]
    subprocess.run([sys.executable,sys.argv[10],"notify",sys.argv[11],"codex",
        (pathlib.Path(sys.argv[11])/"codex.busy-gen").read_text().strip(),sys.argv[12],
        json.dumps(program),json.dumps({"thread-id":session})],check=True)
def review(*_):
    if reviews:
        for f in reviews:f.close()
        reviews.clear();notify(sys.argv[1]);pathlib.Path(sys.argv[9]).unlink()
    else:
        reviews.extend([open(sys.argv[7],"ab"),open(sys.argv[8],"a")])
        fcntl.flock(reviews[1],fcntl.LOCK_EX);notify(sys.argv[7]);pathlib.Path(sys.argv[9]).touch()
signal.signal(signal.SIGUSR2,review)
pathlib.Path(sys.argv[3]).touch()
time.sleep(120)
''', str(log),str(lock),str(ready),str(log2),str(lock2),str(ready2),str(review_log),str(review_lock),str(review_ready),
    str(root/'bin/fm-codex-activity.py'),str(state),str(workspace),str(base/'notified')])
try:
    for _ in range(100):
        if ready.exists(): break
        time.sleep(.05)
    assert ready.exists(), 'holder did not open both kernel descriptors'
    def arm():
        return subprocess.check_output(['bash',str(root/'bin/fm-busy-event.sh'),'arm',str(state),'codex',
            '--state','unknown'],text=True).strip()
    gen = arm()
    sessions = base / 'data/codex/sessions.jsonl'
    (state/'codex.meta').write_text('harness=codex\nmodel=test-model\neffort=high\nspawned_at=2026-11-09T00:00:00Z\nbusy_gen='+gen+'\nsessions_file='+str(sessions)+'\n')
    subprocess.run([sys.executable,str(root/'bin/fm_task_sessions.py'),'start',str(state),'codex'],check=True)
    proc = pathlib.Path('/proc') / str(holder.pid)
    if not proc.is_dir():
        print('skip: Codex rollout kernel binding requires Linux /proc')
        sys.exit(0)
    binding = dict(schema=1,gen=gen,pid=holder.pid,
        identity=[pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                  (proc/'stat').read_text().rsplit(')',1)[1].split()[19],os.readlink(proc/'ns/pid')],
        executable=str((proc/'exe').resolve()),workspace=str(workspace),codex_home=str(home),version='0.166.0')
    owner = state / ('codex.codex-owner.'+gen+'.json')
    owner.write_text(json.dumps(binding))
    def check(expected):
        actual = subprocess.check_output(['bash','-c',
            '. "$1"; fm_busy_classify tmux fixture codex codex "$2"',
            'bash',str(root/'bin/fm-busy-lib.sh'),str(state)],text=True).strip()
        assert actual == expected, (expected, actual)
    check('unknown codex-rollout')  # no start is not idle
    append(row('task_started')); check('busy codex-rollout')
    saved = [json.loads(line) for line in sessions.read_text().splitlines()]
    assert len(saved)==1 and saved[0]['session']==str(log), saved
    # A long, completely quiet tool has no synthetic activity or refresh events.
    time.sleep(.2); check('busy codex-rollout')
    append(row('task_complete')); check('idle codex-rollout')
    append(row('task_started','turn-2')); check('busy codex-rollout')
    append(row('turn_aborted','turn-2')); check('idle codex-rollout')
    append(row('task_started','turn-3'),row('error','turn-3')); check('unknown codex-rollout')
    append(row('task_complete','turn-3')); check('idle codex-rollout')
    append(row('task_complete','foreign-turn')); check('unknown codex-rollout')
    write(meta,row('task_started'))
    with log.open('a') as f:f.write('{"type":"event_msg","payload":{"type":"token_count"}}')
    check('unknown codex-rollout')
    with log.open('a') as f:f.write('\n')
    check('busy codex-rollout')
    append(row('task_started','overlap')); check('unknown codex-rollout')
    write(meta,row('task_started'))
    with log.open('a') as f:f.write('{"type":"event_msg","payload":{"type":"task_complete","turn_id":"foreign","turn_id":"turn-1"}}\n')
    check('unknown codex-rollout')
    wrong = json.loads(json.dumps(meta)); wrong['payload']['id']='different-session'
    write(wrong,row('task_started')); check('unknown codex-rollout')
    wrong = json.loads(json.dumps(meta)); wrong['payload']['cli_version']='future'
    write(wrong,row('task_started')); check('unknown codex-rollout')
    write(meta,row('task_started',thread_id='other')); check('unknown codex-rollout')
    write(meta,row('task_started',turn_attribution={'turn_id':'other'}));check('unknown codex-rollout')
    write(meta,row('task_started'))
    with log.open('ab') as f:f.truncate(32*1024*1024+1)
    check('unknown codex-rollout')
    write(meta,row('task_started'))
    original = binding.copy()
    for key,value in [('identity',['other-boot','other-start']),('workspace','/wrong'),('version','future'),('gen','old')]:
        binding = dict(original,**{key:value});owner.write_text(json.dumps(binding));check('unknown codex-rollout')
    owner.write_text(json.dumps(original));check('busy codex-rollout')
    # A dedicated native server labels its UI session vscode and also holds
    # the guardian's rollout. Only the parent's events determine its state.
    remote_meta=json.loads(json.dumps(meta));remote_meta['payload']['source']='vscode'
    owner.write_text(json.dumps(dict(original,source='vscode')))
    write(remote_meta,row('task_started'))
    review_meta={'type':'session_meta','payload':dict(id=review_id,cwd=str(workspace),cli_version='0.166.0',
        source={'subagent':{'other':'guardian'}},thread_source='guardian_review',parent_thread_id=session)}
    def write_review(parent):
        review_meta['payload']['parent_thread_id']=parent
        review_log.write_text('\n'.join(json.dumps(r) for r in
            (review_meta,row('task_started','review-turn'),row('task_complete','review-turn')))+'\n')
    write_review(session);holder.send_signal(signal.SIGUSR2)
    for _ in range(100):
        if review_ready.exists():break
        time.sleep(.05)
    assert review_ready.exists(), 'holder never opened the concurrent review descriptors'
    assert not (base/'notified').exists(), 'guardian completion invoked the parent notification'
    check('busy codex-rollout')  # the guardian completion cannot settle its parent
    append(row('task_complete'));check('idle codex-rollout')
    write_review('unrelated-parent');check('unknown codex-rollout')
    write_review(session);check('idle codex-rollout')
    holder.send_signal(signal.SIGUSR2)
    for _ in range(100):
        if not review_ready.exists():break
        time.sleep(.05)
    assert not review_ready.exists(), 'holder did not close the review descriptors'
    assert (base/'notified').exists(), 'parent completion lost its original notification'
    owner.write_text(json.dumps(original));write(meta,row('task_started'));check('busy codex-rollout')
    # A replaced file at the same pathname cannot stand in for the held inode.
    log.rename(log.with_suffix('.old'));write(meta,row('task_started'));check('unknown codex-rollout')
    log.unlink();log.with_suffix('.old').rename(log)
    new_gen = arm();check('unknown codex-unverified')
    # A late old-session completion cannot select the old immutable owner record.
    append(row('task_complete'));check('unknown codex-unverified')
    binding = dict(original,gen=new_gen)
    newer = state / ('codex.codex-owner.'+new_gen+'.json');newer.write_text(json.dumps(binding))
    check('idle codex-rollout')
    # Even a valid second session in the same workspace and process cannot
    # silently replace the session already pinned to this launch generation.
    second_meta=json.loads(json.dumps(meta));second_meta['payload']['id']=session2
    log2.write_text(json.dumps(second_meta)+'\n'+json.dumps(row('task_started','turn-next'))+'\n')
    holder.send_signal(signal.SIGUSR1)
    for _ in range(100):
        if ready2.exists():break
        time.sleep(.05)
    assert ready2.exists(), 'holder never switched its descriptors'
    check('unknown codex-rollout')
    holder.terminate();holder.wait();check('unknown codex-rollout')
    print('ok - Codex rollout source proves lifecycle, kernel/session binding and replacement; invalid evidence stays unknown')
finally:
    if holder.poll() is None:holder.terminate();holder.wait()
PY
}

test_kimi_unverified_gate() {
  local state gen out
  state=$(new_state_dir kimi-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source kimi-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 kimi t1 "$state")
  [ "$out" = "unknown kimi-unverified" ] || fail "unverified kimi must classify unknown, got '$out'"
  out=$(fm_busy_classify tmux w1 kimi t1 "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must not classify from footer text, got '$out'"
  pass "standalone kimi classifies unknown until the live verification gate opens"
}

test_cursor_ignores_rendered_and_native_signals() {
  local state out
  state=$(new_state_dir cursor-gate)
  # Cursor's verdict comes from its own transcript, never from rendered text.
  # With no binding to fold, the honest answer is unknown - and a rendered
  # busy-looking footer must not change that.
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'Working')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from its rendered footer, got '$out'"
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'ctrl+c to stop')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from the ctrl+c busy token either, got '$out'"
  # Herdr's narrower native streaming state is not cursor's turn lifecycle.
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' busy; }
  out=$(fm_busy_classify herdr s:p cursor t1 "$state")
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not borrow herdr's native busy verdict, got '$out'"
  unset -f fm_backend_busy_state
  # The fold is a PULL source: nothing is armed, so no stored record is trusted.
  [ -z "$(fm_busy_sources_for_harness cursor)" ] \
    || fail "cursor must trust no stored record source; its fold has no writer"
  pass "cursor classifies only from its transcript fold, never rendered text or native state"
}

# --- endpoint death and native fallbacks ----------------------------------------

test_dead_endpoint_overrides() {
  local state gen out
  state=$(new_state_dir dead)
  gen=$("$EV" arm "$state" t1)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 1; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "dead endpoint-gone" ] || fail "gone endpoint must classify dead, got '$out'"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 0; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "live endpoint must fall through to the record, got '$out'"
  out=$(fm_busy_classify_live tmux '' claude t1 "$state")
  [ "$out" = "unknown no-target" ] || fail "empty target must classify unknown, got '$out'"
  unset -f fm_backend_target_exists
  pass "endpoint death is the only process-level override and yields dead, never busy"
}

test_herdr_native_busy_only() {
  local state out
  state=$(new_state_dir herdr-native)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' "$FAKE_NATIVE"; }
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "busy herdr-native" ] || fail "native busy with no record must classify busy, got '$out'"
  FAKE_NATIVE=idle
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "unknown missing" ] || fail "native idle must NOT classify idle, got '$out'"
  # A valid record outranks the native verdict.
  local gen
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "the adapter record must outrank herdr's native verdict, got '$out'"
  unset -f fm_backend_busy_state
  pass "herdr's native verdict is trusted for busy only, and records outrank it"
}

# The record parser runs inside sourcing callers (the watcher, the daemon, the
# crew-state reader), so it must not disturb their shell: no clobbered
# positional parameters and no changed glob setting.
test_record_read_leaves_caller_shell_intact() {
  local state out
  state=$(new_state_dir parser-isolation)
  "$EV" arm "$state" t1 >/dev/null
  out=$(bash -c '
    set -f
    . "$1/bin/fm-busy-lib.sh"
    set -- keepme second
    fm_busy_record_read "$2" t1 >/dev/null
    printf "%s|%s|%s" "$1" "$#" "$-"
  ' _ "$ROOT" "$state")
  case "$out" in
    keepme\|2\|*f*) : ;;
    *) fail "record parsing disturbed the caller's shell: $out" ;;
  esac
  # A glob-shaped field must survive parsing literally rather than expanding.
  printf 'v1 gen=%s seq=1 state=busy source=* event=x ts=1\n' "$(cat "$state/t1.busy-gen")" \
    > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "a glob-shaped source must be rejected, not expanded, got '$out'"
  pass "record parsing never clobbers the caller's positional parameters, glob setting, or fields"
}

test_boolean_view_never_promotes_unknown() {
  local state gen
  state=$(new_state_dir boolean)
  gen=$("$EV" arm "$state" t1)
  fm_busy_is_busy tmux w1 claude t1 "$state" || fail "busy record must read busy"
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "idle record must not read busy"
  fi
  printf 'garbage\n' > "$state/t1.busy-state"
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "malformed record must not read busy"
  fi
  pass "the boolean view reports busy only on an exact busy verdict"
}

test_progress_is_generation_bound_and_not_semantic_state() {
  local state gen replacement before
  state=$(new_state_dir native-progress)
  gen=$("$EV" arm "$state" t1)
  before=$(cat "$state/t1.busy-state")
  "$EV" progress "$state" t1 --gen "$gen" || fail "current progress was refused"
  [ -f "$state/t1.progress" ] || fail "progress marker missing"
  [ ! -e "$state/t1.turn-ended" ] || fail "progress emitted a completed turn"
  [ "$(cat "$state/t1.busy-state")" = "$before" ] || fail "progress changed semantic state"
  replacement=$("$EV" arm "$state" t1)
  [ ! -e "$state/t1.progress" ] || fail "arm retained the previous incarnation's progress"
  if "$EV" progress "$state" t1 --gen "$gen" 2>/dev/null; then fail "stale progress was accepted"; fi
  [ ! -e "$state/t1.progress" ] || fail "stale progress wrote a marker"
  "$EV" progress "$state" t1 --gen "$replacement" || fail "replacement progress was refused"
  "$EV" retire "$state" t1 --gen "$replacement" || fail "retire failed"
  [ ! -e "$state/t1.progress" ] || fail "retire retained progress"
  pass "native progress is generation-bound, separately recorded, and cleared on arm and retire"
}

test_turn_ended_notification_is_generation_bound() {
  local state gen
  state=$(new_state_dir turn-ended)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "current idle event was refused"
  [ ! -e "$state/t1.turn-ended" ] || fail "an idle event without --turn-ended notified"
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop --turn-ended \
    || fail "current turn-ended event was refused"
  [ -f "$state/t1.turn-ended" ] || fail "turn-ended notification missing"
  rm "$state/t1.turn-ended"
  "$EV" arm "$state" t1 >/dev/null
  if "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop --turn-ended 2>/dev/null; then
    fail "stale turn-ended event was accepted"
  fi
  [ ! -e "$state/t1.turn-ended" ] || fail "stale turn-ended event woke the replacement"
  if "$EV" progress "$state" t1 --gen "$gen" --turn-ended 2>/dev/null; then fail "--turn-ended accepted outside apply"; fi
  pass "the turn-ended notification rides the apply generation check"
}

test_progress_is_generation_bound_and_not_semantic_state
test_turn_ended_notification_is_generation_bound

test_arm_seeds_busy_spawn
test_apply_advances_seq_and_source
test_apply_current_gen_reset
test_apply_unarmed_refused
test_retire_serializes_and_rejects_stale_gen
test_retire_missing_sidecar_is_idempotent
test_stale_lock_broken_under_gnu_stat
test_stale_gen_event_rejected
test_stale_gen_record_unknown
test_missing_record_unknown_not_idle
test_malformed_record_unknown
test_record_without_sidecar_unknown
test_source_mismatch_cross_adapter
test_converted_adapters_ignore_footer_text
test_launch_prompt_claude_trust_dialog
test_launch_prompt_pi_trust_dialog
test_launch_prompt_pi_requires_both_markers
test_launch_prompt_never_shortens_a_working_launch
test_launch_prompt_scoped_to_armed_harnesses
test_launch_prompt_never_reclassifies_an_advanced_record
test_launch_prompt_requires_a_captured_tail
test_grok_regex_isolated
test_codex_unverified_gate
test_codex_process_owned_rollout

# The migration reads real transcript shapes through its CLI, scoped to the
# exact worker contract. No agent, backend, or external home is involved.
ROOT="$ROOT" SESSIONS_TMP="$TMP_ROOT/sessions-backfill" python3 - <<'PY' || fail 'task session backfill failed'
import json, os, pathlib, subprocess, sys
root=pathlib.Path(os.environ['ROOT']); base=pathlib.Path(os.environ['SESSIONS_TMP'])
home=base/'home'; claude=base/'claude/project'; codex=base/'codex/2026/11/09'
claude.mkdir(parents=True); codex.mkdir(parents=True)
def contract(task, owner=home):
    return f'Your steering inbox is `{owner}/state/{task}.inbox`; this exact path belongs to your current task'
def write(path, rows):
    path.write_text(''.join(json.dumps(row)+'\n' for row in rows))
write(claude/'main.jsonl', [dict(type='last-prompt'), dict(type='user',timestamp='2026-11-09T00:00:00Z',message=dict(content=[dict(type='tool_result',content=contract('old'))])),
    dict(type='api-request',params=dict(model='claude-test',output_config=dict(effort='high')))])
write(codex/'rollout-main.jsonl', [dict(type='session_meta',timestamp='2026-11-09T01:00:00Z',payload=dict(source='cli')),
    dict(type='response_item',payload=dict(role='user',content=[dict(type='input_text',text=contract('old'))])),
    dict(type='turn_context',payload=dict(model='codex-test',effort='low'))])
write(claude/'other-home.jsonl',[dict(type='user',message=dict(content=contract('foreign',base/'other')))])
write(claude/'loose-path.jsonl',[dict(type='user',message=dict(content=str(home/'state/wrong.inbox')))])
write(claude/'late.jsonl',[dict(type='system')]*60+[dict(type='user',message=dict(content=contract('late')))])
command=[sys.executable,str(root/'bin/fm_task_sessions.py'),'backfill',str(home),str(claude.parent),str(base/'codex')]
subprocess.run(command,check=True)
sessions=home/'data/old/sessions.jsonl'; first=sessions.read_text()
rows=[json.loads(line) for line in first.splitlines()]
assert [(r['harness'],r['model'],r['effort']) for r in rows]==[('claude','claude-test','high'),('codex','codex-test','low')], rows
assert all(pathlib.Path(r['session']).is_absolute() for r in rows)
assert rows[0]['started_at']=='2026-11-09T00:00:00Z'
subprocess.run(command,check=True); assert sessions.read_text()==first
assert list((home/'data').iterdir())==[home/'data/old']
# Relaunches, including one resuming the same transcript, each keep a row.
state=home/'state';state.mkdir(); meta=state/'old.meta'
meta.write_text('harness=claude\nmodel=default\neffort=low\nspawned_at=2026-11-09T02:00:00Z\nbusy_gen=new\nsessions_file='+str(sessions)+'\n')
start=[sys.executable,str(root/'bin/fm_task_sessions.py'),'start',str(state),'old']
bind=[sys.executable,str(root/'bin/fm_task_sessions.py'),'bind',str(state),'old']
subprocess.run(start,check=True)
payload=json.dumps(dict(transcript_path=rows[0]['session']))
subprocess.run(bind+['stale'],input=payload,text=True,check=True)
assert json.loads(sessions.read_text().splitlines()[-1])['session'] is None
for _ in range(2):subprocess.run(bind+['new'],input=payload,text=True,check=True)
assert len(sessions.read_text().splitlines())==3
assert json.loads(sessions.read_text().splitlines()[-1])['session']==rows[0]['session']
meta.unlink(); assert sessions.exists()
print('ok - durable sessions preserve relaunches and migrate exact historical worker contracts once')
PY
test_claude_session_launch() {
  local dir home fakebin sessions hook
  dir="$TMP_ROOT/claude-session-launch"
  home="$dir/home"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" proof
  fm_git_worktree "$dir/project" "$dir/wt" proof
  fm_test_run_spawn "$home" "$dir/wt" "$fakebin" proof "$dir/project" --mode local-only --yolo off >"$dir/spawn.log" \
    || fail "session launch failed: $(cat "$dir/spawn.log")"
  sessions="$home/data/proof/sessions.jsonl"
  jq -e '.harness == "claude" and .session == null and (.started_at | length > 0)' "$sessions" >/dev/null || fail "launch metadata missing"
  hook=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$home/state/proof.claude-settings.json")
  printf '{"transcript_path":"/tmp/transcript with spaces.jsonl"}\n' | bash -c "$hook" || fail "emitted hook failed"
  printf '{"transcript_path":"/tmp/transcript with spaces.jsonl"}\n' | bash -c "$hook" || fail "repeated hook failed"
  [ "$(wc -l < "$sessions" | tr -d ' ')" = 1 ] || fail "hook duplicated launch"
  jq -e '.session == "/tmp/transcript with spaces.jsonl"' "$sessions" >/dev/null || fail "hook lost transcript path"
  pass "Claude's generated launch hook completes one durable session record"
}
test_claude_session_launch
test_kimi_unverified_gate
test_cursor_ignores_rendered_and_native_signals
test_dead_endpoint_overrides
test_herdr_native_busy_only
test_record_read_leaves_caller_shell_intact
test_boolean_view_never_promotes_unknown

echo "all fm-busy-state tests passed"
