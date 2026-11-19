#!/usr/bin/env bash
# fm-startup-dialogs.sh - answer the harness start-up dialogs the operator has
# approved once and for all, so a freshly launched agent reaches its brief.
#
# Usage: fm-startup-dialogs.sh <backend> <target> <harness> <launch-dir> [timeout-seconds] [expected-label]
#
# The captain's standing approval (2026-11-08): any agent answers, on the
# operator's behalf, the start-up dialogs that ask to trust the operator's own
# or Firstmate's directory and hooks; nobody waits for the operator over them.
# This script does what a person does: watch the pane after the launch, name the
# dialog on screen, press the keys that accept it, check that the accepting row
# is selected before the last Enter, and stop once the agent is working or the
# window ends. It always exits 0; a dialog it does not answer stays on screen
# and one line on stderr says which and why.
#
# Answered (each recorded from a real pane, 2026-11-18):
#   Codex 0.169  "Folder access ... Trust and continue"  Enter. Only when the
#                path shown is <launch-dir>, the directory this spawn started in.
#   Codex 0.169  "Hooks need review"                     Down, Enter ("Trust
#                all and continue"). Only when <launch-dir> brings no hooks of
#                its own, or is itself a Firstmate checkout; otherwise the hooks
#                are the project's, and trusting them is the operator's call.
#   Claude 2.1   "Allow external CLAUDE.md file imports?" Down, Enter ("Yes").
#                Only when every listed file lives under the operator's Claude
#                config directory or under Firstmate; "Never allow this for
#                third-party repositories".
# Not answered, by design: Claude's workspace trust (bin/fm-claude-trust.sh
# registers it before launch) and the Claude bypass-permissions warning, whose
# acceptance is a permission-mode consent outside the approved scope.
# Updates: neither harness shows a blocking update dialog in the versions
# above (Codex prints a banner, Claude auto-update is off), so there is nothing
# to skip; a new blocking one needs its own recorded entry here.
#
# FM_STARTUP_DIALOGS_POLL (default 1) sets the seconds between screen reads;
# the spawn passes FM_STARTUP_DIALOGS_WINDOW (default 45) as the window, and the
# test library sets it to 0 so fake panes are not watched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

BACKEND=${1:?backend}
TARGET=${2:?target}
HARNESS=${3:?harness}
LAUNCH_DIR=${4:?launch-dir}
WINDOW=${5:-45}
LABEL=${6:-}
POLL=${FM_STARTUP_DIALOGS_POLL:-1}
LAUNCH_DIR=$(cd -P -- "$LAUNCH_DIR" 2>/dev/null && pwd -P) || exit 0

note() { echo "startup-dialog: $*" >&2; }

screen_now() { fm_backend_visible_capture "$BACKEND" "$TARGET" "$LABEL" 2>/dev/null; }

# classify <screen>: one dialog name, or nothing. Needs the heading, the
# selected row and the other choice, so quoted text in a conversation is not one.
classify() {
  printf '%s\n' "$1" | awk '
    /Folder access/ { f = 1 }
    /Trust this folder\?/ { ft = 1 }
    /^[ \t]*[›>] 1\. Trust and continue/ { fs = 1 }
    /Hooks need review/ { h = 1 }
    /^[ \t]*[›>] 1\. Review hooks/ { hs = 1 }
    /2\. Trust all and continue/ { h2 = 1 }
    /Allow external CLAUDE\.md file imports\?/ { c = 1 }
    /^[ \t]*❯ No, disable external imports/ { cs = 1 }
    /Yes, allow external imports/ { c2 = 1 }
    END {
      if (f && ft && fs) print "codex-folder"
      else if (h && hs && h2) print "codex-hooks"
      else if (c && cs && c2) print "claude-imports"
    }'
}

# Codex prints the directory on the line after "Folder access".
dialog_path() {  # <screen>
  printf '%s\n' "$1" | awk '/Folder access/ { f = 1; next } f && NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; exit }'
}

# Claude lists the imported files between "External imports:" and "Important:".
dialog_imports() {  # <screen>
  printf '%s\n' "$1" | awk '/External imports:/ { f = 1; next } /Important:/ { f = 0 } f && NF { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }'
}

under() {  # <path> <root>
  case "$1" in "$2"|"$2"/*) return 0 ;; esac
  return 1
}

# Why this dialog is not the operator's own or Firstmate's, or nothing when it is.
refusal() {  # <name> <screen>
  local p f ok
  case "$1" in
  codex-folder)
    p=$(dialog_path "$2")
    [ "$p" = "$LAUNCH_DIR" ] || echo "the folder shown (${p:-unreadable}) is not the launch directory $LAUNCH_DIR"
    ;;
  codex-hooks)
    if { [ -e "$LAUNCH_DIR/.codex/hooks.json" ] || [ -e "$LAUNCH_DIR/.codex/config.toml" ]; } \
      && [ ! -e "$LAUNCH_DIR/bin/fm-turnend-guard.sh" ]; then
      echo "$LAUNCH_DIR carries its own Codex hooks and is not a Firstmate checkout"
    fi
    ;;
  claude-imports)
    ok=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      ok=1
      under "$f" "${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}" && continue
      under "$f" "${HOME:-/nonexistent}/.claude" && continue
      under "$f" "$FM_ROOT" && continue
      echo "the import $f is outside the operator's Claude directory and Firstmate"
      return 0
    done <<EOF
$(dialog_imports "$2")
EOF
    [ "$ok" = 1 ] || echo "the imported files could not be read from the dialog"
    ;;
  esac
}

key() { fm_backend_send_key "$BACKEND" "$TARGET" "$1" "$LABEL" || return 1; }

# selected <ere>: whether the accepting row is the highlighted one right now.
selected() { screen_now | grep -Eq -- "$1"; }

answer() {  # <name>
  case "$1" in
  codex-folder) key Enter ;;
  codex-hooks)
    key Down || return 1
    sleep "$POLL"
    selected '^[ \t]*› 2\. Trust all and continue' || { note "codex-hooks: the accepting row is not selected after Down; left for the operator"; return 1; }
    key Enter
    ;;
  claude-imports)
    key Down || return 1
    sleep "$POLL"
    selected '^[ \t]*❯ Yes, allow external imports' || { note "claude-imports: the accepting row is not selected after Down; left for the operator"; return 1; }
    key Enter
    ;;
  esac
}

declare -A tries=()
deadline=$(( $(date +%s) + WINDOW ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  screen=$(screen_now) || { sleep "$POLL"; continue; }
  name=$(classify "$screen")
  case "$name:$HARNESS" in codex-*:codex*|claude-*:claude*) ;; *) name= ;; esac
  if [ -n "$name" ]; then
    why=$(refusal "$name" "$screen")
    if [ -n "$why" ]; then
      note "$name: left for the operator: $why"
      exit 0
    fi
    tries[$name]=$(( ${tries[$name]:-0} + 1 ))
    if [ "${tries[$name]}" -gt 3 ]; then
      note "$name: still on screen after 3 answers; left for the operator"
      exit 0
    fi
    if answer "$name"; then note "$name: answered for the operator ($LAUNCH_DIR)"; fi
  elif printf '%s\n' "$screen" | grep -Eq 'esc to interrupt'; then
    exit 0
  fi
  sleep "$POLL"
done
exit 0
