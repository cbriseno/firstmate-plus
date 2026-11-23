#!/usr/bin/env bash
# Behavior tests for bin/fm-budgets.py: limits come from the one installation
# file both tests and monitoring read, an exceeded limit writes one alarm per
# 24 h, missing data is unmeasured rather than within limit, and both skip
# switches work.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

BUDGETS="$ROOT/bin/fm-budgets.py"
TMP_ROOT=$(fm_test_tmproot fm-budgets-watch)

new_home() {  # -> sets HOME_DIR and exports the reader's paths
  local root
  root=$(fm_test_tmproot fm-budgets)
  HOME_DIR=$root/home
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$root/diag/firstmate" "$root/slots"
  export FM_HOME=$HOME_DIR FM_DIAGNOSTICS_HOME=$root/diag FM_TEST_LOCK_DIR=$root/slots
  unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_BUDGETS
}

hook_runs() {  # <count> <ms>
  local i stamp
  stamp=$(date -u +%Y-%m-%dT%H:%M:%S.000+00:00)
  for ((i = 0; i < $1; i++)); do
    printf '{"t":"%s","c":"firstmate","e":"hook.run","hook":"pretool-cd","ms":%s,"rc":0}\n' "$stamp" "$2"
  done >> "$FM_DIAGNOSTICS_HOME/firstmate/events.jsonl"
}

hook_limit() {
  python3 "$BUDGETS" limits | jq -r '.hook_run_p95_ms.limit'
}

test_exceeded_limit_alarms_once_per_day() {
  new_home
  local limit alarm
  limit=$(hook_limit)
  hook_runs 20 "$((limit + 1))"
  python3 "$BUDGETS" check >/dev/null || fail "check exits nonzero"
  alarm=$HOME_DIR/state/budget-hook_run_p95_ms.budget-alarm
  assert_present "$alarm"
  assert_grep "hook_run_p95_ms=$((limit + 1)) ms over limit $limit" "$alarm" "alarm names value and limit"
  assert_grep 'skip: FM_BUDGETS=0' "$alarm" "alarm prints how a human skips it"
  jq -e '.measures.hook_run_p95_ms.exceeded == true' "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail "published table does not mark the exceeded measure"
  assert_grep '"key": "hook_run_p95_ms"' "$HOME_DIR/state/budgets-history.jsonl" "hourly history line"
  rm -f -- "$alarm"
  python3 "$BUDGETS" check >/dev/null
  assert_absent "$alarm"
  pass "an exceeded limit alarms once and not again within 24 h"
}

test_installation_file_moves_the_limit() {
  new_home
  local limit
  limit=$(hook_limit)
  hook_runs 20 "$((limit + 1))"
  printf '{"measures":{"hook_run_p95_ms":{"limit":%s}}}\n' "$((limit + 5))" > "$HOME_DIR/config/budgets.json"
  assert_equals "$((limit + 5))" "$(hook_limit)" "limits reads the installation file"
  python3 "$BUDGETS" check >/dev/null
  assert_absent "$HOME_DIR/state/budget-hook_run_p95_ms.budget-alarm"
  jq -e '.measures.hook_run_p95_ms.exceeded == false' "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail "the raised limit was not applied"
  pass "the installation file is the one limit that tests and monitoring read"
}

test_missing_data_is_unmeasured() {
  new_home
  python3 "$BUDGETS" check >/dev/null
  jq -e '.measures.hook_run_p95_ms.value == null and .measures.hook_run_p95_ms.exceeded == null
    and .measures.home_summary_age_s.value == null' "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail "missing data was not published as unmeasured: $(cat "$HOME_DIR/state/budgets.json")"
  assert_equals "" "$(find "$HOME_DIR/state" -name '*.budget-alarm')" "no alarm without data"
  pass "a measure with no samples is unmeasured, never within limit"
}

test_skip_switches() {
  new_home
  local limit
  limit=$(hook_limit)
  hook_runs 20 "$((limit + 1))"
  FM_BUDGETS=0 python3 "$BUDGETS" check >/dev/null
  assert_absent "$HOME_DIR/state/budgets.json"
  printf '{"measures":{"hook_run_p95_ms":{"alarm":false}}}\n' > "$HOME_DIR/config/budgets.json"
  python3 "$BUDGETS" check >/dev/null
  assert_absent "$HOME_DIR/state/budget-hook_run_p95_ms.budget-alarm"
  jq -e '.measures.hook_run_p95_ms.exceeded == true' "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail "a silenced measure must still be measured"
  pass "FM_BUDGETS=0 disables the check and alarm=false keeps the measure without alarming"
}

test_watcher_queues_the_alarm_for_firstmate() {
  local dir state out pid
  dir=$(make_supercase budget-watch); state="$dir/state"; out="$dir/watch.out"
  new_home
  printf '{"age_seconds":3600,"observed_epoch":1}\n' > "$state/.home-summary-read.json"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_DATA_OVERRIDE="$dir/data" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  wait_for_exit "$pid" 300 || fail "watcher did not deliver the alarm: $(cat "$out")"
  assert_grep 'check: behavior budget exceeded: home_summary_age_s=' "$out" "watcher delivers the alarm"
  awk -F '\t' '$3 == "check" && $4 == "budget:home_summary_age_s"' "$state/.wake-queue" | grep -q . \
    || fail "alarm is not a queued check row: $(cat "$state/.wake-queue" 2>/dev/null)"
  assert_equals "" "$(find "$state" -name '*.budget-alarm')" "the alarm file is consumed"
  pass "the watcher turns an exceeded budget into one queued actionable check"
}

test_overdue_delivery_with_no_lanes() (
  command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; return 0; }
  local dir repo epoch state alarm pid task
  dir=$(make_supercase integration-clock)
  state="$dir/state"
  repo="$dir/projects/alpha"
  mkdir -p "$dir/data" "$dir/config" "$repo" "$dir/slots"
  export FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config"
  export FM_DATA_OVERRIDE="$dir/data" FM_DIAGNOSTICS_HOME="$dir/diag" FM_TEST_LOCK_DIR="$dir/slots"
  export FM_BUDGETS=1 FM_DIAGNOSTICS=1
  printf '{}\n' > "$state/home-summary.json"
  printf '1\nmin-avail-gb 1000000\n' > "$dir/config/lane-capacity"
  printf '%s\n' '- alpha [local-only +yolo] - Test project' > "$dir/data/projects.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"

  epoch=$(date +%s)
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name Test
  git -C "$repo" config user.email test@example.invalid
  GIT_COMMITTER_DATE="@$((epoch - 7500))" git -C "$repo" commit -q --allow-empty -m base
  for task in captain-request unrelated; do
    bash "$ROOT/bin/fm-tasks-axi.sh" add "$task" "$task" --repo alpha --kind ship >/dev/null \
      || fail "create task $task"
    git -C "$repo" checkout -qb "fm/$task" main
    GIT_COMMITTER_DATE="@$((epoch - 7470))" git -C "$repo" commit -q --allow-empty -m "$task"
  done
  git -C "$repo" checkout -q main
  printf '# Task\n\n## Captain\047s intent\n\nDeliver the fixture change.\n' > "$dir/data/captain-request/brief.md"
  python3 - "$dir/data/captain-request/creation.json" "$((epoch - 7260))" <<'PY' || fail "age the original request"
import datetime, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
record = json.loads(path.read_text())
record['created_at'] = datetime.datetime.fromtimestamp(int(sys.argv[2]), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
path.write_text(json.dumps(record))
PY
  for task in unrelated captain-request; do
    printf 'kind=ship\nproject=%s\nmode=local-only\nbranch=fm/%s\n' "$repo" "$task" > "$state/$task.meta"
  done
  bash "$ROOT/bin/fm-merge-local.sh" unrelated >/dev/null || fail "land the unrelated request"
  python3 "$BUDGETS" check >/dev/null || fail "reconcile integration clocks"
  alarm="$state/budget-operational-progress.budget-alarm"
  jq -e '.integration.projects.alpha.requests.unrelated.last_at != null
    and .integration.projects.alpha.requests["captain-request"].last_at == null
    and .integration.overdue[0].request == "captain-request"' "$state/budgets.json" >/dev/null \
    || fail "the other request's ref movement concealed the overdue request: $(cat "$state/budgets.json")"
  assert_present "$alarm"
  PATH="$dir/fakebin:$PATH" bash "$ROOT/bin/fm-capacity.sh" --json | jq -e '.verdict.admit == false' >/dev/null \
    || fail "fixture must refuse new lanes"
  PATH="$dir/fakebin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" &
  pid=$!
  wait_for_exit "$pid" 300 || fail "watcher withheld the delivery wake at zero lanes: $(cat "$dir/watch.out")"
  grep -q 'check: integration overdue .*request captain-request' "$dir/watch.out" \
    || fail "delivery wake names its own request: $(cat "$dir/watch.out")"
  assert_grep 'budget:operational-progress' "$state/.wake-queue" "wake is durable"
  python3 "$BUDGETS" check >/dev/null || fail "recheck the open obligation"
  jq -e '.integration.overdue[0].request == "captain-request"' "$state/budgets.json" >/dev/null \
    || fail "waking the owner settled a request whose branch did not move"

  # The already-authorized local landing still uses its normal guard. Its
  # current reflog time is distinct from the old author/commit timestamps.
  git -C "$repo" branch -f fm/captain-request main
  git -C "$repo" checkout -q fm/captain-request
  GIT_COMMITTER_DATE="@$((epoch - 7400))" git -C "$repo" commit -q --allow-empty -m delivery
  git -C "$repo" checkout -q main
  bash "$ROOT/bin/fm-merge-local.sh" captain-request >/dev/null || fail "land the overdue request"
  python3 "$BUDGETS" check >/dev/null || fail "reconcile the successful landing"
  jq -e --argjson recent "$epoch" '.integration.overdue == []
    and .integration.projects.alpha.requests["captain-request"].last_at >= $recent' "$state/budgets.json" >/dev/null \
    || fail "the successful landing must settle only its own overdue clock"
  assert_grep '"e":"integration.ok"' "$FM_DIAGNOSTICS_HOME/firstmate/events.jsonl" "the integration was diagnosed"
  assert_absent "$alarm"
  git -C "$repo" update-ref -m 'reset: simulated rewritten default' refs/heads/main HEAD^ \
    || fail "rewrite the disposable project reference"
  python3 "$BUDGETS" check >/dev/null || fail "reconcile the rewritten reference"
  jq -e '.integration.overdue == [] and .integration.projects.alpha.last_at == null' "$state/budgets.json" >/dev/null \
    || fail "a rewritten reference was counted as a successful integration"
  pass "the watcher brings forward due delivery with no lane, retaining it until its ref actually advances"
)

test_obligation_events_count_for_a_day() {
  new_home
  FM_DIAGNOSTICS=1 bash "$ROOT/bin/fm-diag.sh" emit obligation.overdue category=ready-work
  python3 "$BUDGETS" check >/dev/null || fail 'overdue obligation budget failed'
  jq -e '.measures.obligations_overdue_per_day.value == 1 and .measures.obligations_overdue_per_day.limit == 0 and .measures.obligations_overdue_per_day.exceeded == true' "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail 'overdue event was not counted against zero'
  jq -e 'select(.e == "obligation.overdue" and .category == "ready-work")' "${HOME_DIR%/home}/diag/firstmate/events.jsonl" >/dev/null \
    || fail 'diagnostic event lost its category'
  pass 'overdue obligations are diagnosed and counted against the daily limit'
}

test_obligation_events_count_for_a_day

# The watcher re-pages an unresolved obligation every period; the measure's
# unit is obligations, so repeated pages of one obligation count once.
test_repeated_pages_count_one_obligation() {
  new_home
  local prior=$HOME_DIR/state/prior events=${HOME_DIR%/home}/diag/firstmate/events.jsonl
  : > "$prior"
  touch -t 202001010000 "$prior"
  # A child shell loads the real emitter, as the watcher does.
  STATE=$HOME_DIR/state CONFIG=$HOME_DIR/config FM_OBLIGATION_SECONDS=1 FM_DIAGNOSTICS=1 \
    bash -c '
      . "$1/bin/fm-platform-lib.sh"; . "$1/bin/fm-obligation-lib.sh"; . "$1/bin/fm-diag.sh"
      watch_event_append() { :; }
      wake() { :; }
      for i in 1 2 3; do
        [ "$i" = 1 ] || sleep 1.1
        fm_obligation_observe ready-brief-alpha ready-work brief:alpha "alpha (prepare its brief)" "$2" || exit 1
      done
      fm_obligation_observe status-beta blocked blocked "beta: blocked" "$2"
    ' _ "$ROOT" "$prior" || fail 'fixture: page the obligations'
  [ "$(grep -c '"obligation.overdue"' "$events")" = 4 ] \
    || fail 'fixture: expected four overdue pages'
  python3 "$BUDGETS" check >/dev/null || fail 'overdue obligation budget failed'
  jq -e '.measures.obligations_overdue_per_day.value == 2 and .measures.obligations_overdue_per_day.exceeded == true' \
    "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail "repeated pages were counted as obligations: $(jq -c .measures.obligations_overdue_per_day "$HOME_DIR/state/budgets.json")"
  if grep -F 'alpha' "$events" >/dev/null; then
    fail 'the diagnostic log carries a raw obligation key'
  fi
  pass 'repeated pages of one overdue obligation count once against the daily limit'
}

test_repeated_pages_count_one_obligation
# Every message a worker receives is one inbox record. The first notice of a
# wait the worker declared is its own requested wake, so only a repeated notice
# of that wait counts; a Lavish result delivered to its owner is the same
# message as its procevent-inbox result, and an unowned result reached no worker.
test_worker_messages_count_steers_and_repeated_wait_notices() {
  new_home
  local notice i
  # The real watcher text, so a change to it cannot silently bypass the measure.
  # shellcheck disable=SC2016 # the pattern matches a literal $last
  notice=$(sed -n 's/^  message="\(Your declared pause condition has been reached[^$]*\)\$last"$/\1/p' "$ROOT/bin/fm-watch.sh")
  [ -n "$notice" ] || fail 'fixture: wait notice text not found in the watcher'
  STATE=$HOME_DIR/state NOTICE=$notice bash -c '
    . "$1/bin/fm-task-inbox-lib.sh"
    for i in 1 2 3 4 5 6 7; do
      fm_task_inbox_write "$STATE" alpha "${NOTICE}paused [at=$i]: [wait-job=job-$i] own test run" >/dev/null || exit 1
    done
    fm_task_inbox_write "$STATE" alpha "${NOTICE}paused [at=7]: [wait-job=job-7] own test run" >/dev/null || exit 1
    fm_task_inbox_write "$STATE" alpha "Rebase onto main before continuing." >/dev/null || exit 1
    fm_task_inbox_write "$STATE" beta "Lavish review feedback is captured for task beta." >/dev/null || exit 1
  ' _ "$ROOT" || fail 'fixture: write inbox records'
  mkdir -p "$HOME_DIR/state/procevent-inbox"
  : > "$HOME_DIR/state/procevent-inbox/lavish-b.1.result"
  printf 'beta\n' > "$HOME_DIR/state/procevent-inbox/lavish-b.1.owner-task"
  for i in 1 2 3; do : > "$HOME_DIR/state/procevent-inbox/lavish-u.$i.result"; done
  python3 "$BUDGETS" check >/dev/null || fail 'worker message budget failed'
  jq -e '.measures.worker_messages_per_h_max | .value == 2 and (.detail | test("busiest worker alpha \\(7 requested"))' \
    "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail "requested wait notices or duplicated results were counted: $(jq -c .measures.worker_messages_per_h_max "$HOME_DIR/state/budgets.json")"
  rm -rf "$HOME_DIR/state/alpha.inbox"
  python3 "$BUDGETS" check >/dev/null || fail 'worker message budget failed'
  jq -e '.measures.worker_messages_per_h_max.value == 1' "$HOME_DIR/state/budgets.json" >/dev/null \
    || fail "a delivered result counted twice or an unowned one counted: $(jq -c .measures.worker_messages_per_h_max "$HOME_DIR/state/budgets.json")"
  pass 'worker messages count steers and repeated wait notices, each delivered result once'
}

test_worker_messages_count_steers_and_repeated_wait_notices
test_summary_uses_observed_age() {
  new_home
  printf '{}\n' > "$HOME_DIR/state/home-summary.json"
  printf '{"age_seconds":1800,"observed_epoch":1}\n' > "$HOME_DIR/state/.home-summary-read.json"
  python3 "$BUDGETS" check >/dev/null || fail "summary budget check failed"
  jq -e '.measures.home_summary_age_s.value == 1800 and .measures.home_summary_age_s.exceeded' \
    "$HOME_DIR/state/budgets.json" >/dev/null || fail "budget did not report the age observed by the reader"
  assert_present "$HOME_DIR/state/budget-home_summary_age_s.budget-alarm"
  pass "summary budget uses the age observed at reading, even with a new file"
}

test_summary_uses_observed_age
test_exceeded_limit_alarms_once_per_day
test_watcher_queues_the_alarm_for_firstmate
test_installation_file_moves_the_limit
test_missing_data_is_unmeasured
test_skip_switches
test_overdue_delivery_with_no_lanes

test_nudge_record_import_and_alarm() {
  new_home
  local today
  today=$(date '+%Y-%m-%d')
  mkdir -p "$HOME_DIR/data/cero-empujones-20261120"
  cat > "$HOME_DIR/data/cero-empujones-20261120/empujones.md" <<TABLE
| Fecha hora | Categoría | Qué pidió | Tarea que lo corrige |
|---|---|---|---|
| $today 01:35 | despachar con carriles libres | lanzar U1 | tarea-existente |
| $today 01:36 | ERROR DEL SUPERVISOR, no cuenta | equivocación | ninguna |
| $today 01:37 | despachar / integrar | decidir | tarea-ambigua |
| 2020-01-01 01:37 | despachar / integrar | decidir ayer | tarea-antigua |
TABLE
  FM_ROOT_OVERRIDE="$HOME_DIR" bash "$ROOT/bin/fm-upgrade.sh" check || fail 'first update imports historical table'
  assert_present "$HOME_DIR/state/nudges.jsonl"
  python3 "$ROOT/bin/fm_nudge.py" import-legacy || fail 'import historical table'
  python3 "$ROOT/bin/fm_nudge.py" import-legacy || fail 'repeat historical import'
  if bash "$ROOT/bin/fm-nudge.sh" record --category resources --text 'check load'; then
    fail 'accepted a mechanical nudge without a detector class'
  fi
  bash "$ROOT/bin/fm-nudge.sh" record --category dispatch --gap ready-work --text 'launch work' --task task-42 || fail 'record mechanical nudge'
  bash "$ROOT/bin/fm-nudge.sh" record --category resources --new-gap stale-cpu-probe --task fix-probe --text 'check load' || fail 'file a new detector class'
  bash "$ROOT/bin/fm-nudge.sh" record --category new-orders --text 'new order' || fail 'record new order'
  python3 "$BUDGETS" check >/dev/null || fail 'measure nudges'
  jq -e '.measures.nudges_dispatch_per_day.value == 2 and .measures.nudges_dispatch_per_day.exceeded and .measures["nudges_new-orders_per_day"].value == 1 and .measures["nudges_new-orders_per_day"].limit == null' "$HOME_DIR/state/budgets.json" >/dev/null || fail 'daily category counts or limits'
  assert_grep 'task-42' "$HOME_DIR/state/budget-nudges_dispatch_per_day.budget-alarm" 'alarm contains task'
  assert_grep 'tarea-existente' "$HOME_DIR/state/budget-nudges_dispatch_per_day.budget-alarm" 'alarm includes historic task'
  jq -e '.measures.nudges_unclassified.value == 2' "$HOME_DIR/state/budgets.json" >/dev/null || fail 'old ambiguous nudges disappeared after their day'
  assert_grep 'tarea-antigua' "$HOME_DIR/state/budget-nudges_unclassified.budget-alarm" 'old ambiguous category is surfaced for classification'
  assert_absent "$HOME_DIR/state/budget-nudges_new-orders_per_day.budget-alarm"
  jq -e '.measures.supervisor_interventions_per_day | .value == 4 and .limit == 0 and
       (.detail | contains("ready-work: 1") and contains("stale-cpu-probe: 1"))' \
    "$HOME_DIR/state/budgets.json" >/dev/null || fail 'daily total did not preserve historical or classified interventions'
  pass 'nudges import once, count by category, and alarm only for mechanical nudges'
}
test_nudge_record_import_and_alarm
