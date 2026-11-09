#!/usr/bin/env bash
# Claude Code hook for a launched worker: while Claude Code holds the worker on
# a permission dialog, the worker's own status file says so, so the supervisor
# wakes on the ordinary status path instead of depending on the backend's pane
# events. Claude Code shows such a dialog even under
# --dangerously-skip-permissions for its built-in protected operations (for
# example the dangerous-rm check) and denies the operation when nobody answers.
#
# Usage: fm-permission-wait-hook.sh open|clear <state-dir> <task-id>
#   open   PermissionRequest hook. Reads the hook payload on stdin and appends
#          `blocked [key=permission-prompt] [at=<epoch>]: <tool>: <operation>`
#          to <state-dir>/<task-id>.status.
#   clear  Hook for any event that shows the dialog ended. Appends
#          `resolved [key=permission-prompt] [at=<epoch>]: ...` only when the
#          status file's last line is that open blocker, so it is a no-op on
#          every ordinary tool call.
# bin/fm-spawn.sh registers both in the worker's Claude settings.
# The script prints nothing and always exits 0, so it never answers the
# dialog or changes Claude Code's own decision.
key=permission-prompt
mode=${1-}
status="${2-}/${3-}.status"
[ -n "${2-}" ] && [ -n "${3-}" ] || exit 0
case "$mode" in
open)
  op=$(jq -r '
    (.tool_name // "tool") + ": " +
    ((.tool_input.command // .tool_input.file_path // .tool_input.path //
      (.tool_input | tostring)) | tostring)
  ' 2>/dev/null | tr '\n\r\t' '   ' | sed 's/ *$//' | cut -c1-200)
  printf 'blocked [key=%s] [at=%s]: Claude Code espera permiso: %s\n' \
    "$key" "$(date +%s)" "${op:-unknown operation}" >>"$status" 2>/dev/null
  ;;
clear)
  case "$(tail -n 1 "$status" 2>/dev/null)" in
  "blocked [key=$key] "*)
    printf 'resolved [key=%s] [at=%s]: el dialogo de permiso termino\n' \
      "$key" "$(date +%s)" >>"$status" 2>/dev/null
    ;;
  esac
  ;;
esac
exit 0
