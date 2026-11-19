#!/usr/bin/env bash
# Ready, briefed ship work launches by itself when lanes are free: the watcher
# runs bin/fm-autodispatch.sh, which resolves the spawn from the brief, the
# registry and the dispatch rules, and leaves everything else to the primary.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-autodispatch)
export NODE_NO_WARNINGS=1

# A home whose bin/ is a copy with fm-spawn.sh replaced by a recorder.
make_home() {
  local dir=$1 home="$1/home" id
  mkdir -p "$home/data" "$home/config" "$home/state" "$dir/proj/.git" "$dir/fakebin"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/spawn.log"
case "\$1" in fail-*) echo 'error: boom' >&2; exit 1 ;; esac
exit 0
SH
  chmod +x "$dir/bin/fm-spawn.sh"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  printf '# Tasks\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '2\nmax-load1 1000\n' > "$home/config/lane-capacity"
  printf '%s\n' "- demo [local-only +yolo] - Fixture project at $dir/proj (added 2026-01-01)" > "$home/data/projects.md"
  cat > "$home/config/crew-dispatch.json" <<'J'
{"rules":[{"when":"std","category":"standard","use":{"harness":"claude","model":"m1","effort":"medium"}},
          {"when":"pick","category":"either","use":[{"harness":"claude","model":"a"},{"harness":"codex","model":"b"}]}]}
J
  for id in good fail-one held plain either; do
    FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" add "$id" "$id work" --repo demo >/dev/null 2>&1 || fail "fixture: add $id"
    mkdir -p "$home/data/$id"
    {
      printf '# Task\n## Captain'"'"'s intent\nx\n'
      if [ "$id" = plain ]; then printf 'Dispatch category: standard\n'; continue; fi
      printf 'Dispatch category: %s\n' "$([ "$id" = either ] && echo either || echo standard)"
      printf 'Delivery contract: mode=local-only\nShip branch: fm/%s\n' "$id"
    } > "$home/data/$id/brief.md"
  done
  FM_HOME="$home" bash "$ROOT/bin/fm-tasks-axi.sh" hold held --kind external --reason waiting >/dev/null 2>&1 || fail "fixture: hold"
}

test_autodispatch_resolves_the_spawn() {
  local dir=$TMP_ROOT/unit home rc
  mkdir -p "$dir"; make_home "$dir"; home="$dir/home"
  FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" good >/dev/null 2>&1 || fail "good ready task was not launched"
  grep -Fx "good $dir/proj --mode local-only --yolo on --harness claude --model m1 --effort medium" "$dir/spawn.log" >/dev/null \
    || fail "wrong spawn arguments: $(cat "$dir/spawn.log")"
  for id in plain either; do
    rc=0; FM_HOME="$home" bash "$dir/bin/fm-autodispatch.sh" "$id" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 3 ] || fail "$id must be left to the primary (exit $rc)"
  done
  [ "$(wc -l < "$dir/spawn.log")" -eq 1 ] || fail "a non-launchable task reached the spawn"
  pass "autodispatch launches a briefed ship with its category profile and leaves the rest to the primary"
}

test_watcher_launches_ready_work() {
  local dir=$TMP_ROOT/watch home state out child i
  mkdir -p "$dir"; make_home "$dir"; home="$dir/home"; state="$home/state"; out="$dir/watch.out"
  fm_test_track_watcher_state "$state"
  date +%s > "$state/.cleanup-low-disk"; date +%s > "$state/.last-info-summary"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_DIAGNOSTICS=0 \
    bash "$dir/bin/fm-watch.sh" > "$out" 2>&1 &
  child=$!
  for ((i=0; i<300; i++)); do
    grep -qF 'review and dispatch' "$state/.wake-queue" 2>/dev/null && break
    sleep 0.1
  done
  kill -TERM "$child" 2>/dev/null; for ((i=0; i<50; i++)); do kill -0 "$child" 2>/dev/null || break; sleep 0.1; done; kill -KILL "$child" 2>/dev/null; wait "$child" 2>/dev/null || true
  grep -q "^good " "$dir/spawn.log" || fail "watcher did not launch the ready task: $(cat "$out")"
  grep -q '^fail-one ' "$dir/spawn.log" || fail "watcher did not try the second ready task"
  grep -q '^held ' "$dir/spawn.log" && fail "held task was launched"
  [ "$(grep -c '^fail-one ' "$dir/spawn.log")" -eq 1 ] || fail "failed launch was retried"
  grep -F 'launched automatically' "$state/.wake-queue" | grep -F good >/dev/null || fail "no launch wake: $(cat "$state/.wake-queue" 2>&1; echo OUT; cat "$out"; ls -a "$state")"
  grep -F 'automatic launch of ready task fail-one failed: error: boom' "$state/.wake-queue" >/dev/null || fail "no failure wake: $(cat "$state/.wake-queue")"
  grep -F 'review and dispatch' "$state/.wake-queue" | grep -F plain >/dev/null || fail "unlaunchable task lost its primary wake"
  pass "watcher launches ready work itself, reports a failed launch once, and still wakes the primary for the rest"
}

test_autodispatch_resolves_the_spawn
test_watcher_launches_ready_work
