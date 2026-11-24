#!/usr/bin/env bash
# Resolve the live primary from its session lock, then send an instruction.
# Usage: FM_HOME=<home> bash bin/fm-overseer-primary.sh <text>
#        bash bin/fm-overseer-primary.sh --help
# The target is re-resolved on every call so a primary relay is followed.
set -u
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set -u/p' "$0" | sed '$d;s/^# \{0,1\}//'
  exit 0
fi
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
FM_HOME=${FM_HOME:-${script_dir%/bin}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ "$#" -gt 0 ] && [ -n "$*" ] || { echo 'usage: fm-overseer-primary.sh <text>' >&2; exit 2; }
# shellcheck source=bin/fm-backend.sh
. "$script_dir/fm-backend.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$script_dir/fm-session-lock-lib.sh"
fm_session_lock_inspect "$STATE"
[ "$FM_LOCK_INSPECT_STATE" = held ] || { echo 'primary session lock is not held by a live harness' >&2; exit 1; }
lock_pid=$FM_LOCK_INSPECT_PID
backend=$(fm_backend_name)
fm_backend_source "$backend" || exit 1
# A pane's shell must be an ancestor of the locked harness process.
ancestors=" $lock_pid "
pid=$lock_pid
depth=0
while [ "$depth" -lt 32 ]; do
  depth=$((depth + 1))
  pid=$(fm_ps_ppid "$pid") || break
  case "$pid" in ''|*[!0-9]*|0|1) break ;; esac
  ancestors="$ancestors$pid "
done
candidates=''
case "$backend" in
  tmux)
    candidates=$(tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_pid}' 2>/dev/null) || exit 1
    ;;
  herdr)
    session=$(fm_backend_herdr_session)
    panes=$(fm_backend_herdr_cli "$session" pane list 2>/dev/null) || exit 1
    ids=$(printf '%s' "$panes" | jq -er '.result.panes | if type == "array" then .[].pane_id else error("invalid pane list") end' 2>/dev/null) || exit 1
    for pane in $ids; do
      info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || continue
      shell_pid=$(printf '%s' "$info" | jq -er --arg pane "$pane" 'select(.result.process_info.pane_id == $pane) | .result.process_info.shell_pid | select(type == "number")' 2>/dev/null) || continue
      candidates="$candidates
$pane $session:$pane $shell_pid"
    done
    ;;
  *) echo "unsupported primary backend: $backend" >&2; exit 1 ;;
esac
target=''
target_id=''
while read -r candidate_id candidate shell_pid; do
  [ -n "$candidate" ] || continue
  case "$shell_pid" in ''|*[!0-9]*) continue ;; esac
  case "$ancestors" in *" $shell_pid "*) ;; *) continue ;; esac
  if [ -n "$target_id" ] && [ "$target_id" != "$candidate_id" ]; then
    echo 'primary session maps to more than one endpoint' >&2; exit 1
  fi
  target_id=$candidate_id
  target=$candidate
done <<EOT
$candidates
EOT
[ -n "$target" ] || { echo 'primary endpoint not found from session lock' >&2; exit 1; }
fm_session_lock_inspect "$STATE"
[ "$FM_LOCK_INSPECT_STATE" = held ] && [ "$FM_LOCK_INSPECT_PID" = "$lock_pid" ] || {
  echo 'primary session changed before delivery; retry with the current session' >&2; exit 1;
}
FM_BACKEND="$backend" FM_HOME="$FM_HOME" bash "$script_dir/fm-send.sh" "$target" "$*"
