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
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$root/diag/firstmate"
  export FM_HOME=$HOME_DIR FM_DIAGNOSTICS_HOME=$root/diag
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
  printf '{}\n' > "$state/home-summary.json"
  touch -t "$(date -d '-1 hour' +%Y%m%d%H%M.%S 2>/dev/null || date -v-1H +%Y%m%d%H%M.%S)" "$state/home-summary.json"
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

test_exceeded_limit_alarms_once_per_day
test_watcher_queues_the_alarm_for_firstmate
test_installation_file_moves_the_limit
test_missing_data_is_unmeasured
test_skip_switches
