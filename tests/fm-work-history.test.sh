#!/usr/bin/env bash
# Regression: canonical archived records can have a null body. The work snapshot
# must retain their identity/date without inventing progress or question origins.
set -euo pipefail
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'SKIP: tasks-axi required\n'; exit 0; }
export FM_LIVE=0
TASK_HOME=$(fm_test_tmproot fm-work-history)
mkdir -p "$TASK_HOME/data" "$TASK_HOME/state" "$TASK_HOME/config"
printf '%s\n' '- alpha [local-only] - Test project' > "$TASK_HOME/data/projects.md"
printf '%s\n' '## Queued' '- [ ] next - Next task (repo: alpha) (since 2026-10-31)' > "$TASK_HOME/data/backlog.md"
printf '%s\n' '## Archived 2026-10-31' '- [x] previous - Previous task (repo: alpha) (since 2026-10-29) (done 2026-10-30)' > "$TASK_HOME/data/done-archive.md"
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_BACKEND TASKS_AXI_FILE
FM_HOME="$TASK_HOME" bash "$ROOT/bin/fm-tasks-axi.sh" work snapshot | python3 -c '
import json,sys
s=json.load(sys.stdin)
assert s["schema"]=="fm-work-snapshot.v1",s
assert len(s["tasks"])==2,s
previous=next(t for t in s["tasks"] if t["key"]=="task:previous")
assert previous["state"]=="done",previous
assert previous["completed"]["value"]=="2026-10-30",previous
assert previous["completed"]["precision"]=="date",previous
assert previous["question"]["origin_task"] is None,previous
assert previous["progress"] is None,previous
assert s["sigue"]==["task:next"],s
print("PASS: archived null-body snapshot preserves completion date and unknown fields")
'
