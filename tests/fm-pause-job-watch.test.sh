#!/usr/bin/env bash
# The watcher resumes paused workers when their declared dependency clears.
set -u
# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"
# Used by make_case in watch-triage-helpers.sh.
# shellcheck disable=SC2034
TMP_ROOT=$(fm_test_tmproot fm-pause-job-watch)
[ -z "${FM_TEST_WATCH_OVERRIDE:-}" ] || WATCH=$FM_TEST_WATCH_OVERRIDE
dir=$(make_case job); state="$dir/state"; window=test:fm-parked
mkdir -p "$dir/data" "$dir/config"
fm_test_tasks_toml "$dir/.tasks.toml" || fail 'cannot configure backlog fixture'
printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
export FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config"
printf 'window=%s\nkind=scout\nharness=claude\nbackend=tmux\n' "$window" > "$state/parked.meta"
printf 'paused [at=%s]: [wait-job=build] wait for build until 2099-01-01T00:00Z\n' "$(date +%s)" > "$state/parked.status"
printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
printf 'building' > "$dir/pane.txt"
mkdir -p "$state/parked.jobs"
sleep 900 & job=$!
trap 'kill "$job" 2>/dev/null || true; wait "$job" 2>/dev/null || true; fm_test_cleanup' EXIT
printf '{"state":"running","pid":%s}\n' "$job" > "$state/parked.jobs/build.json"
round() {
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · parked' \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" >> "$dir/watch.out" &
  local watcher=$!
  wait_poll_cycle "$state" "$watcher" 600 || { reap "$watcher"; return 1; }
  reap "$watcher"
}
round || fail 'watcher failed during live job'
[ ! -f "$state/parked.inbox/001.msg" ] || fail 'live job resumed prematurely'
# A worker still in its turn sees its own job end; the resume waits for the turn.
"$ROOT/bin/fm-busy-event.sh" arm "$state" parked --state busy --source claude-hook --event prompt >/dev/null \
  || fail 'cannot arm busy fixture'
kill "$job"; wait "$job" 2>/dev/null || true
round || fail 'watcher failed after job exit during a turn'
[ ! -f "$state/parked.inbox/001.msg" ] || fail 'worker in a turn was steered to resume'
[ ! -e "$state/.obligation-pause-parked" ] || fail 'worker in a turn opened an unattended wait'
"$ROOT/bin/fm-busy-event.sh" apply "$state" parked idle --current-gen --source claude-hook --event stop >/dev/null \
  || fail 'cannot end busy fixture turn'
round || fail 'watcher failed after job exit'
[ -f "$state/parked.inbox/001.msg" ] || fail 'dead job did not cause a resume after the turn ended'
mv "$state/parked.inbox/001.msg" "$state/parked.inbox/handled/"
printf 'paused: waiting for an old background command\n' > "$state/parked.status"
set_mtime "$(( $(date +%s) - 120 ))" "$state/parked.status"
printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
round || fail 'watcher failed during legacy migration'
[ -f "$state/parked.inbox/002.msg" ] || fail 'legacy pause was not rechecked'
mv "$state/parked.inbox/002.msg" "$state/parked.inbox/handled/"
round || fail 'watcher failed after legacy recheck'
[ ! -f "$state/parked.inbox/003.msg" ] || fail 'legacy recheck repeated for the same wait'
pass 'watcher resumes a dead job and rechecks a legacy pause once'

target=separate-front
project="$dir/project"
fm_git_init_commit "$project" || fail 'cannot initialize the dependency project'
git -C "$project" checkout -qb "fm/$target" || fail 'cannot create dependency branch'
printf 'dependency result\n' > "$project/result"
git -C "$project" add result || fail 'cannot stage the dependency result'
git -C "$project" commit -qm 'finish dependency' || fail 'cannot commit the dependency'
git -C "$project" checkout -q main || fail 'cannot return to the integration branch'
printf 'kind=ship\nmode=local-only\nproject=%s\nbranch=fm/%s\nbase_branch=main\n' \
  "$project" "$target" > "$state/$target.meta"
FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-task-status.sh" "$target" 'done' 'ready for integration' ||
  fail 'cannot report dependency ready'
FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-task-status.sh" parked paused \
  "[wait-task=$target] waiting for $target to land in main" || fail 'cannot declare the task wait'
printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
round || fail 'watcher failed before integration'
[ ! -f "$state/parked.inbox/003.msg" ] || fail 'a ready branch released the wait before integration'
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-merge-local.sh" "$target" ||
  fail 'cannot integrate the dependency'
round || fail 'watcher failed after integration'
[ -f "$state/parked.inbox/003.msg" ] || fail 'integrating the named task did not deliver a resume notice'
assert_contains "$(cat "$state/parked.inbox/003.msg")" 'Your declared pause condition has been reached.' \
  'the notice is not from the pause watcher'
mv "$state/parked.inbox/003.msg" "$state/parked.inbox/handled/"
round || fail 'watcher failed after task wait acknowledgement'
[ ! -f "$state/parked.inbox/004.msg" ] || fail 'the same task wait sent a duplicate resume notice'
pass 'watcher resumes a task wait once after actual local integration'

target=closed-front
"$ROOT/bin/fm-tasks-axi.sh" add "$target" 'A separate host task' --kind host >/dev/null ||
  fail 'cannot register the dependency for the close case'
"$ROOT/bin/fm-tasks-axi.sh" 'done' "$target" >/dev/null || fail 'cannot close the dependency'
"$ROOT/bin/fm-tasks-axi.sh" prune --keep 0 >/dev/null || fail 'cannot archive the closed dependency'
grep -Fq -- "- [x] $target " "$dir/data/done-archive.md" || fail 'closed dependency was not archived'
FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-task-status.sh" parked paused \
  "[wait-task=$target] waiting for the other task" || fail 'cannot declare a wait after closure'
printf '%s' "$(seen_sig "$state/parked.status")" > "$state/.seen-parked_status"
round || fail 'watcher failed for a task already closed'
[ -f "$state/parked.inbox/004.msg" ] || fail 'a task already closed did not release the wait'
assert_contains "$(cat "$state/parked.inbox/004.msg")" "wait-task=$target" 'the notice names another dependency'
pass 'watcher resumes a task wait declared after the other task closed and was archived'
