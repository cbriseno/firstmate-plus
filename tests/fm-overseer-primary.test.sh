#!/usr/bin/env bash
# Resolve the current lock owner to a backend endpoint, including after a relay.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot fm-overseer-primary)
mkdir -p "$T/bin" "$T/fake" "$T/home/state"
for item in "$ROOT"/bin/*; do
  name=${item##*/}
  case "$name" in fm-send.sh|fm-overseer-primary.sh) continue ;; esac
  ln -s "$item" "$T/bin/$name"
done
cp "$ROOT/bin/fm-overseer-primary.sh" "$T/bin/fm-overseer-primary.sh"
cat > "$T/bin/fm-send.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_TEST_CAPTURE"
STUB
cat > "$T/fake/tmux" <<'STUB'
#!/usr/bin/env bash
cat "$FM_TEST_PANES"
STUB
cat > "$T/fake/ps" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  comm=) printf '/Applications/codex\n' ;;
  args=) printf '/Applications/codex\n' ;;
  stat=) printf 'S\n' ;;
  ppid=) case "$4" in "$FM_TEST_PID1") echo 701 ;; "$FM_TEST_PID2") echo 702 ;; *) echo 1 ;; esac ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/fake/herdr" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  list) printf '%s\n' '{"result":{"panes":[{"pane_id":"p1"},{"pane_id":"p2"}]}}' ;;
  process-info)
    case "$4" in p1) n=701 ;; p2) n=702 ;; *) exit 1 ;; esac
    printf '{"result":{"process_info":{"pane_id":"%s","shell_pid":%s}}}\n' "$4" "$n" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/fm-send.sh" "$T/fake/tmux" "$T/fake/ps" "$T/fake/herdr"
sleep 300 & pid1=$!
sleep 300 & pid2=$!
cleanup_primary_test() { kill "$pid1" "$pid2" 2>/dev/null || :; wait "$pid1" "$pid2" 2>/dev/null || :; fm_test_cleanup; }
trap cleanup_primary_test EXIT
export FM_TEST_PID1=$pid1 FM_TEST_PID2=$pid2 FM_TEST_CAPTURE="$T/sent" FM_TEST_PANES="$T/panes"
export FM_HOME="$T/home" FM_BACKEND=tmux PATH="$T/fake:$PATH"
printf '%%1 session:0.0 701\n%%2 session:1.0 702\n' > "$FM_TEST_PANES"
printf '%s\n' "$pid1" > "$FM_HOME/state/.lock"
bash "$T/bin/fm-overseer-primary.sh" 'continue the task' || fail 'first primary was not reached'
[ "$(cat "$FM_TEST_CAPTURE")" = 'session:0.0 continue the task' ] || fail 'wrong first primary target'
printf '%s\n' "$pid2" > "$FM_HOME/state/.lock"
bash "$T/bin/fm-overseer-primary.sh" 'resume after relay' || fail 'successor was not reached'
[ "$(cat "$FM_TEST_CAPTURE")" = 'session:1.0 resume after relay' ] || fail 'relay still targeted the old primary'
FM_BACKEND=herdr HERDR_SESSION=lab bash "$T/bin/fm-overseer-primary.sh" 'follow through' || fail 'Herdr successor was not reached'
[ "$(cat "$FM_TEST_CAPTURE")" = 'lab:p2 follow through' ] || fail 'Herdr selected the wrong primary'
printf '999999999\n' > "$FM_HOME/state/.lock"
if bash "$T/bin/fm-overseer-primary.sh" 'must not send' >/dev/null 2>&1; then fail 'dead lock was accepted'; fi
[ "$(cat "$FM_TEST_CAPTURE")" = 'lab:p2 follow through' ] || fail 'message was sent to an unverified target'
pass 'resolves each live lock owner on both backends with a macOS-shaped process fixture and refuses a dead owner'
