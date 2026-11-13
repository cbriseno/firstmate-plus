#!/usr/bin/env bash
# Opt-in real Codex regression: buffered /quit must submit even when Codex
# consumes the paste and Enter together. All Herdr calls use the lab helper.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_HERDR_CODEX_DELAYED_LIVE herdr jq codex python3
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
SESSION=$("$HELPER" name herdr-codex-delayed-live)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-codex-delayed.XXXXXX")
PID=
sender=
cleanup() {
  local rc=$?
  trap - EXIT
  [ -z "$PID" ] || kill -CONT "$PID" 2>/dev/null || true
  if [ -n "$sender" ]; then kill "$sender" 2>/dev/null || true; wait "$sender" 2>/dev/null || true; fi
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  rm -rf -- "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
fail() { echo "not ok - Codex delayed submit: $*" >&2; exit 1; }
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/herdr" <<EOF2
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
args=("\${args[@]:0:\$((n-2))}")
printf '%s\n' "\${args[*]}" >> "$TMP_ROOT/transport"
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]}"
EOF2
chmod +x "$TMP_ROOT/fakebin/herdr"
"$HELPER" provision "$SESSION" || fail 'provision failed'
ws=$(lab workspace create --cwd "$ROOT" --label delayed-codex --no-focus) || fail 'workspace failed'
pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || fail 'no pane'
lab pane run "$pane" 'set +m; env -u FM_TASK_ID -u FM_TASK_INBOX -u CODEX_THREAD_ID codex --no-alt-screen -c hooks.enabled=false -c check_for_update_on_startup=false' >/dev/null || fail 'launch failed'
ready=0
for ((i=0;i<60;i++)); do
  screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
  case "$screen" in *'Ask Codex to do anything'*) ready=1; break ;; esac
  sleep 1
done
[ "$ready" = 1 ] || fail "composer unavailable: $(codex --version) / $(herdr --version)"
info=$(lab pane process-info --pane "$pane") || fail 'process inspection failed'
PID=$(printf '%s' "$info" | jq -er '.result.process_info.foreground_processes[] | select(.name=="codex") | .pid') || fail 'Codex process missing'
export PATH="$TMP_ROOT/fakebin:$ORIGINAL_PATH"
. "$ROOT/bin/backends/herdr.sh"
: > "$TMP_ROOT/transport"
kill -STOP "$PID" || fail 'could not delay Codex'
fm_backend_herdr_send_text_submit "$SESSION:$pane" /quit 2 0.4 1.2 > "$TMP_ROOT/verdict" &
sender=$!
# Let the helper read the stale screen while Codex cannot consume input.
queued=0
for ((i=0;i<300;i++)); do
  if grep -Eq 'agent prompt .* /quit|pane send-keys .* enter' "$TMP_ROOT/transport"; then queued=1; break; fi
  sleep 0.1
done
sleep 2
kill -CONT "$PID" || fail 'could not resume Codex'
[ "$queued" = 1 ] || { wait "$sender" || true; fail 'submission was not queued'; }
wait "$sender" || fail 'submit helper failed'
sender=
exited=0
for ((i=0;i<30;i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then exited=1; break; fi
  sleep 1
done
PID=
[ "$exited" = 1 ] || fail "buffered /quit remained unsubmitted: $(codex --version) / $(PATH="$ORIGINAL_PATH" herdr --version)"
echo "ok - delayed Codex /quit submitted: $(codex --version) / $(PATH="$ORIGINAL_PATH" herdr --version)"
