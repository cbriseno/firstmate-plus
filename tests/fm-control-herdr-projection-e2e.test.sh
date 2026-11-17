#!/usr/bin/env bash
set -euo pipefail
# Real Herdr replacement placement: lost pane, surviving projection and flat
# legacy endpoint. Only disposable repositories and a guarded named lab exist.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_TEST_HERDR_PROJECTION_RELAUNCH herdr jq
TASK_TMP=$(fm_test_tmproot fm-herdr-relaunch)
export HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
export FM_HERDR_LAB_STATE_DIR=$TASK_TMP/lab-state
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name projection-relaunch)
export HERDR_LAB_SESSION
export ORIGINAL_PATH=$PATH
cleanup() {
  local result=$?
  trap - EXIT
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || result=1
  fm_test_cleanup
  exit "$result"
}
trap cleanup EXIT
# Route signals through the ordered lab teardown before lib.sh removes scratch.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
lab status --json | jq -e '.server.running == true' >/dev/null
export HERDR_SESSION=$HERDR_LAB_SESSION
export TMPDIR=$TASK_TMP/temp
mkdir -p "$TMPDIR"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_ENV HERDR_SOCKET_PATH
export FM_HOME=$TASK_TMP/lab-home-${HERDR_LAB_SESSION##*-}
mkdir -p "$TASK_TMP/lab-bin" "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data/repro" "$TASK_TMP/project" "$TASK_TMP/wt"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
git -C "$TASK_TMP/project" init -q
git -C "$TASK_TMP/project" config user.name Tests
git -C "$TASK_TMP/project" config user.email tests@example.invalid
printf 'fixture\n' > "$TASK_TMP/project/README.md"
git -C "$TASK_TMP/project" add README.md
git -C "$TASK_TMP/project" -c user.name=Tests -c user.email=tests@example.invalid diff --cached --quiet || git -C "$TASK_TMP/project" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
if [ ! -e "$TASK_TMP/wt/.git" ]; then git clone -q "$TASK_TMP/project" "$TASK_TMP/wt"; fi
git -C "$TASK_TMP/wt" config user.name Tests
git -C "$TASK_TMP/wt" config user.email tests@example.invalid
printf '# Task\n## Captain\x27s intent\nExercise relaunch.\n## Firstmate spec\nKeep projection.\n' > "$FM_HOME/data/repro/brief.md"
cat > "$TASK_TMP/lab-bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = "$HERDR_LAB_SESSION" ]; then unset 'args[n-1]' 'args[n-2]'; fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
EOF
cat > "$TASK_TMP/lab-bin/codex" <<'EOF'
#!/usr/bin/env bash
: # No harness prompt or credentials; exercise real endpoint placement only.
EOF
chmod +x "$TASK_TMP/lab-bin/herdr" "$TASK_TMP/lab-bin/codex"
export PATH=$TASK_TMP/lab-bin:$PATH
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
label=$(fm_backend_herdr_workspace_label)
container=$(fm_backend_herdr_container_ensure "$TASK_TMP/wt")
parent=${container%%$'\t'*}; parent=${parent#*:}
token=$(fm_backend_herdr_projection_journal_create "$FM_HOME/state" repro)
wslabel=$(fm_backend_herdr_projection_workspace_label repro "$token")
fm_backend_herdr_projection_create_task "$TASK_TMP/wt" "$wslabel" fm-repro
ws=$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
tab=$FM_BACKEND_HERDR_PROJECTION_TAB_ID
pane=$FM_BACKEND_HERDR_PROJECTION_PANE_ID
fm_backend_herdr_projection_order_best_effort "$HERDR_SESSION" "$ws" "$label" "$parent"
fm_backend_herdr_projection_journal_bind "$FM_HOME/state/repro.herdr-presentation" repro "$FM_HOME" "$HERDR_SESSION" "$ws" "$tab" "$pane" "$parent" "$label" "$wslabel" fm-repro
cat > "$FM_HOME/state/repro.meta" <<EOF
window=$HERDR_SESSION:$pane
endpoint_task_id=repro
worktree=$TASK_TMP/wt
project=$TASK_TMP/project
harness=codex
kind=ship
mode=local-only
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$HERDR_SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
EOF
lab pane close "$pane"
cat > "$TASK_TMP/extension.sh" <<'EXTENSION'
fm_spawn_extension() {
  if [ "$1" = launch ]; then
    LAUNCH="export PATH=$(shell_quote "$RELAUNCH_TEST_BIN"):\$PATH; $LAUNCH"
  fi
}
EXTENSION
relaunch() {
  HERDR_SESSION=default RELAUNCH_TEST_BIN="$TASK_TMP/lab-bin" FM_SPAWN_EXTENSION="$TASK_TMP/extension.sh" \
    FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" repro --relaunch --harness codex
  local i
  for i in $(seq 1 50); do
    [ "$(fm_backend_agent_state herdr "$(field window)")" != dead ] || return 0
    sleep 0.1
  done
  fail "inert fixture harness did not finish"
}
field() { sed -n "s/^$1=//p" "$FM_HOME/state/repro.meta"; }
relaunch
new_ws=$(field herdr_workspace_id)
new_pane=$(field herdr_pane_id)
[ "$new_ws" != "$parent" ] || fail "lost pane relaunched inside the parent's workspace"
[ "$new_pane" != "$pane" ] || fail "lost pane was not replaced"
[ "$(field worktree)" = "$TASK_TMP/wt" ] || fail "relaunch changed the worktree"
fm_backend_herdr_projection_journal_snapshot "$FM_HOME/state/repro.herdr-presentation" repro
[ "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" = "$new_ws" ] || fail "journal did not follow projection"
pass "real Herdr relaunch: a lost endpoint regains its own projected space"
relaunch
[ "$(field herdr_pane_id)" = "$new_pane" ] || fail "context handoff replaced a correctly projected endpoint"
pass "real Herdr relaunch: a surviving projection keeps its exact endpoint"
# Model the incident's already-flat metadata while retaining its old journal.
lab pane close "$new_pane"
flat=$(lab tab create --workspace "$parent" --cwd "$TASK_TMP/wt" --label fm-repro --no-focus)
flat_tab=$(printf '%s' "$flat" | jq -r '.result.tab.tab_id')
flat_pane=$(printf '%s' "$flat" | jq -r '.result.root_pane.pane_id')
python3 - "$FM_HOME/state/repro.meta" "$HERDR_SESSION" "$parent" "$flat_tab" "$flat_pane" <<'PYTHON'
import sys
p,session,ws,tab,pane=sys.argv[1:]
values={'window':session+':'+pane,'herdr_workspace_id':ws,'herdr_tab_id':tab,'herdr_pane_id':pane}
rows=open(p).read().splitlines()
open(p,'w').write(''.join(k+'='+values.get(k,v)+'\n' for k,v in (r.split('=',1) for r in rows)))
PYTHON
relaunch
[ "$(field herdr_workspace_id)" != "$parent" ] || fail "already-flat task stayed in the parent"
[ "$(fm_backend_herdr_pane_agent_state "$HERDR_SESSION" "$flat_pane")" = dead ] || fail "old flat pane survived"
pass "real Herdr relaunch: an already-flat task regains its own space"
