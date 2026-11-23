#!/usr/bin/env bash
# A paused worker resumes when its named durable job ends, disappears, or dies.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp=$(fm_test_tmproot pause-job)
mkdir -p "$tmp/task.jobs"
sleep 120 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fm_test_cleanup' EXIT
printf '{"state":"running","pid":%s}\n' "$pid" > "$tmp/task.jobs/build.json"
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task 'paused [at=1]: [wait-job=build] build' && fail 'live job was considered finished'
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task "paused [wait-pid=$pid]: build" && fail 'live process was considered finished'
kill "$pid"
wait "$pid" 2>/dev/null || true
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task 'paused [at=1]: [wait-job=build] build' || fail 'dead job was not detected'
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task "paused [wait-pid=$pid]: build" || fail 'dead process was not detected'
printf '{"state":"done"}\n' > "$tmp/task.jobs/build.json"
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task 'paused [at=1]: [wait-job=build] build' || fail 'completed job was not detected'
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task 'paused [at=1]: [wait-job=missing] build' || fail 'missing job was not detected'
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task 'paused [at=1]: waiting for build' || fail 'legacy named job was not detected'
rc=0
python3 "$ROOT/bin/fm-pause-job.py" "$tmp" task 'paused [at=1]: waiting' || rc=$?
[ "$rc" = 2 ] || fail 'unstructured legacy wait was not identified'
pass 'paused durable job liveness'
