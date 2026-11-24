#!/usr/bin/env bash
# Exercise the freshness budget against an in-flight real summary publication.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-summary-budget)
parent="$TMP_ROOT/parent"; child="$TMP_ROOT/child"; holder=; writer=
cleanup() {
  [ -z "$writer" ] || kill "$writer" 2>/dev/null || true
  [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
mkdir -p "$parent/state" "$parent/config" "$parent/data" "$parent/projects" \
  "$child/state" "$child/config" "$child/data" "$child/projects" "$child/bin" "$TMP_ROOT/diag/firstmate" "$TMP_ROOT/slots"
printf '# Fixture\n' > "$child/AGENTS.md"
printf 'mate\n' > "$child/.fm-secondmate-home"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$child/data/backlog.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$parent/data/backlog.md"
printf -- '- mate - fixture domain (home: %s; scope: fixture; projects: firstmate; added 2026-08-28)\n' "$child" > "$parent/data/secondmates.md"
fm_write_secondmate_meta "$parent/state/mate.meta" "$child" 'fmtest:fm-mate' firstmate claude
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_BUDGETS
export FM_DIAGNOSTICS_HOME="$TMP_ROOT/diag" FM_TEST_LOCK_DIR="$TMP_ROOT/slots" FM_HOME_SUMMARY_TIMEOUT=180
FM_HOME="$child" "$ROOT/bin/fm-home-summary-refresh.sh" || fail 'initial publication failed'
stale_epoch=$(( $(date +%s) - 1800 ))
jq --argjson epoch "$stale_epoch" '.generated_epoch=$epoch' "$child/state/home-summary.json" > "$TMP_ROOT/stale"
mv "$TMP_ROOT/stale" "$child/state/home-summary.json"
FM_HOME="$child" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3"
  sleep 15
  fm_lock_release "$2/state/.home-summary-refresh.lock"
' _ "$ROOT" "$child" "$TMP_ROOT/locked" &
holder=$!
i=0
while [ ! -e "$TMP_ROOT/locked" ] && [ "$i" -lt 600 ]; do
  kill -0 "$holder" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
[ -e "$TMP_ROOT/locked" ] || fail 'publication lock was not acquired'
FM_HOME="$child" "$ROOT/bin/fm-home-summary-refresh.sh" > "$TMP_ROOT/writer.out" 2>&1 &
writer=$!
kill -0 "$writer" 2>/dev/null || fail 'publication did not start'
printf '{"age_seconds":1800,"observed_epoch":1}\n' > "$parent/state/.home-summary-read.json"
FM_HOME="$parent" python3 "$ROOT/bin/fm-budgets.py" check >/dev/null || fail 'budget check failed'
wait "$holder" || fail 'publication lock failed'; holder=
wait "$writer" || fail 'publication failed'; writer=
jq -e '.measures.home_summary_age_s.value < 900 and .measures.home_summary_age_s.exceeded == false' \
  "$parent/state/budgets.json" >/dev/null || fail "recovered summary still raised a freshness alarm: $(jq -c '.measures.home_summary_age_s' "$parent/state/budgets.json")"
[ ! -e "$parent/state/budget-home_summary_age_s.budget-alarm" ] || fail 'recovered summary queued an alarm'
pass 'the budget rechecks after an in-flight publication'
cp "$parent/data/secondmates.md" "$TMP_ROOT/registered"
printf -- '- missing - fixture domain (home: %s; scope: fixture; projects: firstmate; added 2026-08-28)\n' "$TMP_ROOT/missing" >> "$parent/data/secondmates.md"
printf '{"age_seconds":1800,"observed_epoch":1}\n' > "$parent/state/.home-summary-read.json"
FM_HOME="$parent" python3 "$ROOT/bin/fm-budgets.py" check >/dev/null || fail 'incomplete budget check failed'
[ -e "$parent/state/budget-home_summary_age_s.budget-alarm" ] || fail 'an unavailable summary was hidden by a fresh sibling'
pass 'an incomplete recheck preserves the alarm'

# A publisher that remains blocked beyond its bound must still raise an alarm.
mv "$TMP_ROOT/registered" "$parent/data/secondmates.md"
rm -f -- "$parent/state/.budgets-cache.json" "$parent/state/budget-home_summary_age_s.budget-alarm"
stale_epoch=$(( $(date +%s) - 1800 ))
jq --argjson epoch "$stale_epoch" '.generated_epoch=$epoch' "$child/state/home-summary.json" > "$TMP_ROOT/stale"
mv "$TMP_ROOT/stale" "$child/state/home-summary.json"
FM_HOME="$child" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
  : > "$3/blocked"
  while [ ! -e "$3/release" ]; do sleep 0.1; done
  fm_lock_release "$2/state/.home-summary-refresh.lock"
' _ "$ROOT" "$child" "$TMP_ROOT" &
holder=$!
i=0
while [ ! -e "$TMP_ROOT/blocked" ] && [ "$i" -lt 600 ]; do
  kill -0 "$holder" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
[ -e "$TMP_ROOT/blocked" ] || fail 'stalled publication lock was not acquired'
printf '{"age_seconds":1800,"observed_epoch":1}\n' > "$parent/state/.home-summary-read.json"
FM_HOME="$parent" FM_HOME_SUMMARY_TIMEOUT=5 python3 "$ROOT/bin/fm-budgets.py" check >/dev/null \
  || fail 'stalled budget check failed'
[ -e "$parent/state/budget-home_summary_age_s.budget-alarm" ] || fail 'stalled publication did not alarm'
: > "$TMP_ROOT/release"
wait "$holder" || fail 'stalled publication lock failed'; holder=
pass 'a stalled publication preserves the freshness alarm'
