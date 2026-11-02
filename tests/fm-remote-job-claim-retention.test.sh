#!/usr/bin/env bash
# The claim sweep must preserve the former numeric-name eligibility rules.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-job-claim-retention)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/state"
. "$ROOT/bin/fm-remote-job-lib.sh"
mkdir -p "$TMP_ROOT/account"
fm_remote_job_prepare_state "$TMP_ROOT/account" || fail "$FM_REMOTE_JOB_ERROR"
for name in 0 notes 1x .private 1 00 01; do
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
  fm_touch_epoch 946684800 "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
done
mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/2"
# Pin the sweep clock so claims can sit on either side of the whole-second
# cutoff without racing a real second boundary.
NOW=$(command date +%s)
date() {
  if [ "$*" = '+%s' ]; then printf '%s\n' "$NOW"; else command date "$@"; fi
}
touch_frac() { # <epoch> <fraction> <path>
  python3 - "$1" "$2" "$3" <<'PYTHON'
import os, sys
ns = int(sys.argv[1]) * 1000000000 + int(sys.argv[2].ljust(9, "0"))
os.utime(sys.argv[3], ns=(ns, ns))
PYTHON
}
CUTOFF=$((NOW - FM_REMOTE_JOB_SEQ_CLAIM_REAP_SECONDS))
for spec in 3:$CUTOFF:0 4:$CUTOFF:5 5:$((CUTOFF + 1)):0 6:$((CUTOFF + 1)):5; do
  IFS=: read -r name epoch frac <<< "$spec"
  mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
  touch_frac "$epoch" "$frac" "$FM_REMOTE_JOB_SEQ_CLAIMS/$name"
done
fm_remote_job_reap_stale "$TMP_ROOT/account" || fail "claim sweep failed"
for name in 0 notes 1x .private 2 5 6; do
  assert_present "$FM_REMOTE_JOB_SEQ_CLAIMS/$name" "ineligible or fresh claim $name was reaped"
done
for name in 1 00 01 3 4; do
  assert_absent "$FM_REMOTE_JOB_SEQ_CLAIMS/$name" "expired eligible claim $name survived"
done
pass "claim sweep preserves numeric-name eligibility and whole-second expiry"

# A host rejecting this touch form must leave claims and marker untouched so the
# next sweep retries, then recover when touch works again.
rm -f "$FM_REMOTE_JOB_STATE/.seq-claims-reaped"
mkdir "$FM_REMOTE_JOB_SEQ_CLAIMS/7"
fm_touch_epoch 946684800 "$FM_REMOTE_JOB_SEQ_CLAIMS/7"
touch() { return 1; }
fm_remote_job_reap_stale "$TMP_ROOT/account" || fail "rejected timestamp sweep failed"
assert_present "$FM_REMOTE_JOB_SEQ_CLAIMS/7" "rejected timestamp must retain claim"
assert_absent "$FM_REMOTE_JOB_STATE/.seq-claims-reaped" "rejected timestamp must not advance marker"
unset -f touch
fm_remote_job_reap_stale "$TMP_ROOT/account" || fail "retry sweep failed"
assert_absent "$FM_REMOTE_JOB_SEQ_CLAIMS/7" "retry must reap expired claim"
pass "claim sweep safely retries when touch rejects fractional ISO time"
