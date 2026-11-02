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
TARGET="$TMP_ROOT/host-file"
printf 'preserve\n' > "$TARGET"
run_brief() {
  FM_HOME="$TASK_HOME" HOME="$TASK_HOME/user-home" bash "$ROOT/bin/fm-brief.sh" "$@"
}
run_brief "$TASK_ID" --host --path "$TARGET"
python3 - "$TASK_HOME/data/$TASK_ID/brief.md" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text().replace('{TASK}','Set up a host file.').replace('{FIRSTMATE_SPEC}','Verify the operation.'))
PY
export FM_FAKE_LAUNCH_LOG="$TMP_ROOT/launch.log"
export FM_FAKE_PANE_LOG="$TMP_ROOT/pane.log"
OUT=$(fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/$TASK_ID/work" "$FAKEBIN" "$TASK_ID" --host --harness 'git rev-parse --show-toplevel > git-output 2>/dev/null && exit 99; printf fake-harness > harness-ran' --backend tmux) || fail "host spawn failed: $OUT"
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
printf 'done [at=100]: host operation verified\n' >> "$TASK_HOME/state/$TASK_ID.status"
OUT=$(FM_HOME="$TASK_HOME" HOME="$TASK_HOME/user-home" PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 \
  FM_STATE_OVERRIDE="$TASK_HOME/state" FM_DATA_OVERRIDE="$TASK_HOME/data" \
  FM_CONFIG_OVERRIDE="$TASK_HOME/config" FM_PROJECTS_OVERRIDE="$TASK_HOME/projects" \
  bash "$ROOT/bin/fm-teardown.sh" "$TASK_ID" 2>&1) || fail "host teardown failed: $OUT"
[ ! -e "$TASK_HOME/data/$TASK_ID/work" ] || fail 'teardown left host scratch'
[ "$(cat "$TARGET")" = preserve ] || fail 'teardown changed host target'
pass 'first host assignment launches and tears down without a project or commit'
for target in relative/path "$ROOT/AGENTS.md" "$TASK_HOME/projects/new/file"; do
  if run_brief "bad-$RANDOM" --host --path "$target" >/dev/null 2>&1; then fail "unsafe host path accepted: $target"; fi
done
# A pre-existing scratch or a forged cleanup path must never be reused/deleted.
run_brief occupied --host --path "$TARGET" >/dev/null
mkdir "$TASK_HOME/data/occupied/work"
if fm_test_run_spawn "$TASK_HOME" "$TASK_HOME/data/occupied/work" "$FAKEBIN" occupied --host --harness 'echo fake' >/dev/null; then fail 'existing scratch was reused'; fi
printf 'off\n' > "$TASK_HOME/config/primary-direct-ops"
if run_brief disabled --host --path "$TARGET" >/dev/null 2>&1; then fail 'off must disable host tasks'; fi
pass 'host paths and disabled configuration refuse unsafe launch contracts'
