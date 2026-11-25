#!/usr/bin/env bash
# fm-overseer.sh - prepare and manage the captain's overseer session.
#
# The overseer (in Spanish, "supervisor") is one long-running Claude or Codex
# session that watches a Firstmate home's primary on the captain's behalf. Its
# role contract is overseer/AGENTS.md in this repository; this script owns the
# mechanics around it.
#
# Usage:
#   fm-overseer.sh setup <dir>   prepare <dir> so an agent started there loads
#                                the overseer contract natively
#   fm-overseer.sh adopt <dir> [--handoff FILE]... [--old-watch-pid PID]
#                                move an existing hand-made overseer directory
#                                onto the official contract (see below)
#   fm-overseer.sh intervention record --category TOKEN --observed TOKEN
#       --evidence REF --action TOKEN [--root-task TASK-ID] [--level captain]
#       The category is the general cause; each record is also a correction
#       in the home's correction ledger (bin/fm_nudge.py).
#   fm-overseer.sh intervention export OUTPUT.zip
#       Tokens are anonymous short identifiers (letters, digits, dot, dash,
#       underscore; at most 40 characters). The reference is anonymized.
#       Review every summary and reference for private information before
#       recording or exporting; the bounded automated scan is not sufficient
#       to detect names or all private content.
#   fm-overseer.sh alert TEXT    tell the captain through the installation's
#                                notification command (event overseer-alert;
#                                requires a delivery receipt; held alerts
#                                report pending delivery, see bin/fm-notify.py);
#                                TEXT is one plain line
#                                of at most 240 characters, never a secret
#   fm-overseer.sh status        report configuration and session liveness
#   fm-overseer.sh doctor        read prerequisites and local diagnostic evidence
#   fm-overseer.sh start         start the configured overseer if absent
#   fm-overseer.sh place         keep the overseer beside the primary (Herdr):
#                                move its pane right of the primary's pane in
#                                the primary's tab when they are apart; the
#                                watch runs this on every poll
#   fm-overseer.sh relay         outgoing overseer (Herdr): after updating
#                                state/overseer/handoff.md, start a successor
#                                through the optional extensions relay with the
#                                configured harness, model and effort; it
#                                waits RELAY_WAIT_SECONDS (default 90) for the
#                                successor's readiness
#   fm-overseer.sh relay-ready START_FILE
#                                successor: take over the session record and
#                                confirm readiness to the outgoing overseer
#       Run relay-ready as the successor session’s first background watch.
#       Pending events remain in the installation across relay. The
#       relay script is FM_RELAY_LITE, else the extensions runtime under
#       $XDG_DATA_HOME (default ~/.local/share).
#   fm-overseer.sh stop          close the recorded overseer session
#   fm-overseer.sh watch         run inside a native background task in the overseer session
#   fm-overseer.sh -h|--help     print this text
#
# setup creates <dir> when missing and writes three untracked entries in it:
#   CLAUDE.md       symlink to <code-root>/overseer/AGENTS.md (Claude loads it)
#   AGENTS.md       symlink to the same file (Codex loads it)
#   firstmate-home  one line: the physical path of the home being overseen,
#                   FM_HOME when set, otherwise this script's code root
# setup retires the previous generated Stop hooks and their detached wait.
# Both loaders are symlinks to the contract itself, so a repository update
# reaches the next overseer session without rerunning setup. They are not an
# @-import: Claude treats an import that resolves outside its directory as an
# external include and skips it until approved, while a symlinked CLAUDE.md
# loads directly.
# setup refuses, changing nothing, when <dir> or any ancestor holds
# SUPERVISOR.md (an agent there would also load a home's or a task copy's
# instructions), or when an entry exists with other content. An entry that
# already matches is left alone. Setup prints one line per
# entry written and a final OVERSEER_READY line.
#
# adopt is for a directory where a person already runs a hand-made overseer.
# It copies each regular CLAUDE.md/AGENTS.md and every --handoff file to
# state/overseer/adopted/<stamp>/ (proved identical with cmp; handoff originals
# stay where they are), removes only the two hand-made contract files, runs
# setup, restores them if setup refuses, and writes config/overseer when absent.
# It never starts a session and never touches the old watcher unless
# --old-watch-pid names it: that process is stopped only once status shows the
# new overseer alive with its watch armed; otherwise it is left running and the
# command can be repeated after start. Repeating is safe.
#
# Interface for later pieces:
#   - The overseer finds the home through <dir>/firstmate-home; tools that act
#     for an overseer directory read the same file.
#   - The overseer's runtime records live in <home>/state/overseer/. The relay
#     writes the successor's handoff to state/overseer/handoff.md (the contract
#     reads it at session start and keeps it under 4 KB).
#   - Each new subcommand (watch, start, status, stop, doctor) is added to the
#     usage above; the contract points at this --help and names no command
#     itself, so only this header changes.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
code_root=${script_dir%/bin}

# Read configuration as data, never as shell code. A missing file is opt-out.
read_config() {
  local file=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$code_root}/config}/overseer line key value
  overseer_enabled=off overseer_harness=claude overseer_model='' overseer_effort='' overseer_dir='' overseer_permission=default
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; *=*) ;; *) refuse "invalid overseer configuration line" ;; esac
    key=${line%%=*} value=${line#*=}
    case "$key" in
      enabled) overseer_enabled=$value ;;
      harness) overseer_harness=$value ;;
      model) overseer_model=$value ;;
      effort) overseer_effort=$value ;;
      permission) overseer_permission=$value ;;
      directory) overseer_dir=$value ;;
      # Read by the optional extensions supervisor relay; validated here only.
      relay_tokens) case "$value" in ''|*[!0-9]*) refuse "relay_tokens must be a whole number" ;; esac ;;
      *) refuse "unknown overseer configuration key: $key" ;;
    esac
  done < "$file"
  case "$overseer_enabled" in on|off) ;; *) refuse "enabled must be on or off" ;; esac
  case "$overseer_harness" in claude|codex) ;; *) refuse "harness must be claude or codex" ;; esac
  case "$overseer_permission" in default|auto|bypass) ;; *) refuse "permission must be default, auto or bypass" ;; esac
  case "$overseer_dir" in ''|/*) ;; *) refuse "directory must be an absolute path" ;; esac
  case "$overseer_model$overseer_effort" in *[!a-zA-Z0-9._-]*) refuse "model and effort must be plain names" ;; esac
}

# The overseer's own Herdr workspace label, in the installation language.
overseer_workspace_label() {
  local language
  language=${FM_LANGUAGE:-$(cat "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$code_root}/config}/language" 2>/dev/null || true)}
  case "$language" in es|es-*|es_*|ES|ES-*|ES_*) printf 'supervisor' ;; *) printf 'overseer' ;; esac
}

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'
}

refuse() {
  printf 'fm-overseer: %s\n' "$1" >&2
  exit 1
}

# Print the first ancestor of physical directory $1, or $1 itself, that holds
# SUPERVISOR.md; print nothing when none does.
supervisor_ancestor() {
  local d=$1
  while :; do
    if [ -e "$d/SUPERVISOR.md" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    [ "$d" = / ] && return 0
    d=$(dirname -- "$d")
  done
}

# Check entry $1 against symlink target $2; print "write" when it is absent,
# refuse when it holds anything else.
check_link() {
  local entry=$1 target=$2
  if [ -L "$entry" ]; then
    [ "$(readlink -- "$entry")" = "$target" ] && return 0
    refuse "$entry already links to $(readlink -- "$entry"), not $target; move it away first"
  fi
  [ -e "$entry" ] && refuse "$entry already exists and is not the overseer contract link; move it away first"
  printf 'write\n'
}

setup() {
  local dir=${1:?usage: fm-overseer.sh setup <dir>} home contract existing ancestor claude agents homefile settings
  contract="$code_root/overseer/AGENTS.md"
  [ -f "$contract" ] || refuse "contract missing: $contract"
  home=${FM_HOME:-$code_root}
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) && [ -f "$home/SUPERVISOR.md" ] ||
    refuse "not a Firstmate home: ${FM_HOME:-$code_root}"
  case $dir in /*) ;; *) dir=$PWD/$dir ;; esac
  existing=$dir
  while [ ! -d "$existing" ]; do existing=$(dirname -- "$existing"); done
  existing=$(CDPATH='' cd -- "$existing" && pwd -P)
  ancestor=$(supervisor_ancestor "$existing")
  [ -z "$ancestor" ] ||
    refuse "$dir is inside $ancestor, which holds SUPERVISOR.md; an overseer there would load that contract too; choose a directory outside any Firstmate home or copy"
  mkdir -p -- "$dir"
  dir=$(CDPATH='' cd -- "$dir" && pwd -P)

  claude=$(check_link "$dir/CLAUDE.md" "$contract")
  agents=$(check_link "$dir/AGENTS.md" "$contract")
  homefile=
  if [ -L "$dir/firstmate-home" ] || { [ -e "$dir/firstmate-home" ] && [ ! -f "$dir/firstmate-home" ]; }; then
    refuse "$dir/firstmate-home exists and is not a regular file; move it away first"
  elif [ -f "$dir/firstmate-home" ]; then
    [ "$(cat -- "$dir/firstmate-home")" = "$home" ] ||
      refuse "$dir/firstmate-home names $(cat -- "$dir/firstmate-home"), not $home; this directory oversees another home"
  else
    homefile=1
  fi
  for settings in .codex .claude; do
    [ ! -L "$dir/$settings" ] || refuse "$dir/$settings is a symlink"
    [ ! -e "$dir/$settings" ] || [ -d "$dir/$settings" ] || refuse "$dir/$settings is not a directory"
  done
  [ ! -e "$dir/.codex/config.toml" ] && [ ! -L "$dir/.codex/config.toml" ] ||
    refuse "$dir/.codex/config.toml carries separate settings; choose another directory"
  for settings in .codex/hooks.json .claude/settings.json; do
    python3 "$script_dir/fm-overseer-arm.py" remove-hook "$dir/$settings" --check || refuse "cannot read $dir/$settings"
  done
  FM_HOME="$home" python3 "$script_dir/fm-overseer-arm.py" stop-legacy || refuse 'could not retire the legacy overseer watch'
  for settings in .codex/hooks.json .claude/settings.json; do
    python3 "$script_dir/fm-overseer-arm.py" remove-hook "$dir/$settings" || refuse "cannot update $dir/$settings"
  done
  if [ -n "$claude" ]; then
    ln -s -- "$contract" "$dir/CLAUDE.md"
    echo "OVERSEER_SETUP: linked $dir/CLAUDE.md to $contract"
  fi
  if [ -n "$agents" ]; then
    ln -s -- "$contract" "$dir/AGENTS.md"
    echo "OVERSEER_SETUP: linked $dir/AGENTS.md to $contract"
  fi
  if [ -n "$homefile" ]; then
    printf '%s\n' "$home" >"$dir/firstmate-home"
    echo "OVERSEER_SETUP: wrote $dir/firstmate-home naming $home"
  fi
  echo "OVERSEER_READY: $dir oversees $home; a Claude or Codex session started there loads the overseer contract"
}

# Copy $1 to $2 and prove the copy identical; refuse otherwise.
archive_copy() {
  if ! cp -p -- "$1" "$2" || ! cmp -s -- "$1" "$2"; then refuse "could not archive $1 intact"; fi
}

# adopt: move a hand-made overseer directory onto the official contract.
adopt() {
  local dir='' pid='' file stamp home archive name rc out
  local handoffs moved
  handoffs=()
  moved=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --handoff) [ "$#" -ge 2 ] || refuse '--handoff needs a file'; handoffs+=("$2"); shift 2 ;;
      --old-watch-pid) [ "$#" -ge 2 ] || refuse '--old-watch-pid needs a process id'; pid=$2; shift 2 ;;
      -*) refuse "unknown adopt option: $1" ;;
      *) [ -z "$dir" ] || refuse 'adopt takes one directory'; dir=$1; shift ;;
    esac
  done
  [ -n "$dir" ] || refuse 'usage: adopt <dir> [--handoff FILE]... [--old-watch-pid PID]'
  case $pid in ''|*[!0-9]*) [ -z "$pid" ] || refuse 'the process id must be a number' ;; esac
  [ -d "$dir" ] || refuse "$dir does not exist; use setup for a new overseer directory"
  dir=$(CDPATH='' cd -- "$dir" && pwd -P)
  home=$(CDPATH='' cd -- "${FM_HOME:-$code_root}" 2>/dev/null && pwd -P) && [ -f "$home/SUPERVISOR.md" ] ||
    refuse "not a Firstmate home: ${FM_HOME:-$code_root}"
  for file in ${handoffs[@]+"${handoffs[@]}"}; do
    [ -f "$file" ] || refuse "handoff file not found: $file"
  done
  stamp=$(date +%Y%m%d%H%M%S)
  archive=${FM_STATE_OVERRIDE:-$home/state}/overseer/adopted/$stamp
  # Hand-made contracts are regular files; the official links and anything
  # else are left for setup to accept or refuse.
  for name in CLAUDE.md AGENTS.md; do
    if [ -f "$dir/$name" ] && [ ! -L "$dir/$name" ]; then moved+=("$name"); fi
  done
  if [ "${#moved[@]}" -gt 0 ] || [ "${#handoffs[@]}" -gt 0 ]; then
    mkdir -p -- "$archive"
    for name in ${moved[@]+"${moved[@]}"}; do archive_copy "$dir/$name" "$archive/$name"; done
    for file in ${handoffs[@]+"${handoffs[@]}"}; do archive_copy "$file" "$archive/handoff-$(basename -- "$file")"; done
    for name in ${moved[@]+"${moved[@]}"}; do rm -f -- "$dir/$name"; done
    echo "OVERSEER_ADOPT: archived ${moved[*]:-no contract file}${handoffs[*]:+ and ${#handoffs[@]} handoff file(s)} in $archive; originals of handoffs untouched"
  fi
  rc=0
  (setup "$dir") || rc=$?
  if [ "$rc" -ne 0 ]; then
    for name in ${moved[@]+"${moved[@]}"}; do [ -e "$dir/$name" ] || cp -p -- "$archive/$name" "$dir/$name"; done
    refuse 'setup refused; the hand-made contract files were restored'
  fi
  if [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/overseer" ]; then
    mkdir -p -- "${FM_CONFIG_OVERRIDE:-$home/config}"
    printf 'enabled=on\ndirectory=%s\n' "$dir" > "${FM_CONFIG_OVERRIDE:-$home/config}/overseer"
    echo "OVERSEER_ADOPT: wrote config/overseer with enabled=on; edit it to choose harness, model and effort"
  fi
  if [ -n "$pid" ]; then
    out=$(FM_HOME=$home status 2>&1) || out=
    case $out in
      *'session: alive'*'watch: armed'*)
        if kill -0 "$pid" 2>/dev/null; then
          kill -TERM "$pid" && echo "OVERSEER_ADOPT: the new overseer is alive with its watch armed; stopped the old watch $pid"
        else
          echo "OVERSEER_ADOPT: the old watch $pid is already gone"
        fi ;;
      *) echo "OVERSEER_ADOPT: the new overseer is not yet alive with its watch armed; old watch $pid left running; run start, wait for its first turn, then repeat this command" ;;
    esac
  fi
  echo "OVERSEER_ADOPT_NOTE: ask the primary to remove the old captain-alert line from the captain's notes (data/captain.md); alerts now go through fm-overseer.sh alert"
}

status() {
  local state backend target extra live
  read_config
  printf 'configured: %s\n' "$overseer_enabled"
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$code_root}/state}/overseer/session
  if [ ! -f "$state" ]; then
    printf 'session: not started\n'
    return 0
  fi
  IFS=' ' read -r backend target extra < "$state" || refuse "cannot read session record"
  case "$backend" in tmux|herdr) ;; *) refuse "invalid session backend" ;; esac
  [ -n "$target" ] && [ -z "$extra" ] || refuse "invalid session target"
  # shellcheck source=bin/fm-backend.sh
  . "$script_dir/fm-backend.sh"
  live=$(fm_backend_agent_state "$backend" "$target")
  printf 'session: %s (%s: %s)\n' "$live" "$backend" "$target"
  python3 "$script_dir/fm-overseer-arm.py" status
}

session_action() {
  local action=$1 state record backend target extra live ses name ident container seeded ids pane command prompt arg quoted located session setting harness_bin
  read_config
  [ "$action" != start ] || [ "$overseer_enabled" = on ] || { echo 'overseer is disabled'; return 0; }
  [ "$action" != start ] || [ -f "$script_dir/fm-overseer-watch.sh" ] || refuse 'overseer watch is unavailable; update the installation'
  if [ "$action" = start ]; then
    [ -n "$overseer_dir" ] || refuse 'set directory in config/overseer'
  fi
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$code_root}/state}/overseer
  mkdir -p "$state"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$script_dir/fm-wake-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$script_dir/fm-backend.sh"
  OVERSEER_SESSION_LOCK="$state/session.lock"
  fm_lock_acquire_wait_max "$OVERSEER_SESSION_LOCK" 10 || refuse 'session is busy; retry'
  trap 'fm_lock_release "$OVERSEER_SESSION_LOCK"' EXIT
  record="$state/session"
  if [ "$action" = start ]; then
    if python3 "$script_dir/fm-overseer-arm.py" locked; then
      echo 'overseer watch is already running; preserving its session'
      return 0
    else
      [ "$?" -eq 3 ] || refuse 'cannot inspect the overseer watch lock'
    fi
  fi
  [ "$action" != start ] || setup "$overseer_dir"
  [ "$action" != stop ] || : > "$state/stopping"
  if [ -f "$record" ]; then
    IFS=' ' read -r backend target extra < "$record" || refuse 'cannot read session record'
    case "$backend" in tmux|herdr) ;; *) refuse 'invalid session backend' ;; esac
    [ -n "$target" ] && [ -z "$extra" ] || refuse 'invalid session target'
    live=$(fm_backend_agent_state "$backend" "$target")
    if [ "$action" = start ]; then
      case "$live" in
        alive) [ ! -e "$state/stopping" ] || refuse 'a previous stop did not finish'; echo 'overseer is already running'; return 0 ;;
        dead|missing) : > "$state/stopping" ;;
        *) refuse "session state is $live; inspect it before starting another" ;;
      esac
    else
      case "$live" in alive|dead|missing) ;; *) refuse "session state is $live; cannot safely stop it" ;; esac
    fi
    python3 "$script_dir/fm-overseer-arm.py" stop || refuse 'could not stop the overseer watch'
    fm_backend_kill "$backend" "$target" || refuse 'could not close the recorded session'
    rm -f -- "$record"
  elif [ "$action" = stop ]; then
    python3 "$script_dir/fm-overseer-arm.py" stop || refuse 'could not stop the overseer watch'
    echo 'overseer is not running'
    return 0
  fi
  if [ "$action" = stop ]; then echo 'overseer stopped'; return 0; fi
  overseer_dir=$(CDPATH='' cd -- "$overseer_dir" && pwd -P)
  FM_HOME=${FM_HOME:-$code_root}
  FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
  export FM_HOME
  harness_bin=$(command -v "$overseer_harness") || refuse "$overseer_harness is unavailable"
  if [ "$overseer_harness" = claude ]; then
    "$script_dir/fm-claude-trust.sh" --overseer-dir "$overseer_dir" "$FM_HOME" >/dev/null || refuse 'could not register workspace trust'
  fi
  backend=$(fm_backend_name)
  fm_backend_source "$backend" || refuse "unsupported backend: $backend"
  name="fm-overseer-$$-$RANDOM"
  case "$backend" in
    tmux)
      ses=$(fm_backend_tmux_container_ensure) || refuse 'cannot find tmux session'
      fm_backend_tmux_create_task "$ses" "$name" "$overseer_dir" >/dev/null || refuse 'cannot create overseer window'
      target="$ses:$name"
      ;;
    herdr)
      # Beside the primary, in its tab, whoever runs start; place keeps it
      # there after either side relays.
      target=
      located=$(bash "$script_dir/fm-overseer-primary.sh" --locate 2>/dev/null) || located=
      case "$located" in
        "herdr "*:*)
          session=${located#herdr }; session=${session%%:*}
          pane=$(fm_backend_herdr_cli "$session" pane split "${located#herdr "$session":}" --direction right --cwd "$overseer_dir" --no-focus |
            jq -r '.result.pane.pane_id // empty') || pane=
          [ -n "$pane" ] || refuse 'cannot split the primary pane'
          target="$session:$pane"
          ;;
      esac
      if [ -z "$target" ]; then
        # Without a live primary, its own workspace labeled for the captain,
        # never the caller's, which a worker teardown would close.
        container=$(FM_BACKEND_HERDR_WORKSPACE_LABEL=$(overseer_workspace_label) fm_backend_herdr_container_ensure "$overseer_dir" other-home) ||
          refuse 'cannot find Herdr workspace'
        seeded=${container#*$'\t'}; container=${container%%$'\t'*}
        ids=$(fm_backend_herdr_create_task "$container" "$name" "$overseer_dir" "$seeded") || refuse 'cannot create overseer tab'
        IFS=' ' read -r ident pane <<EOF
$ids
EOF
        [ -n "$pane" ] || refuse 'Herdr returned no pane'
        target="${container%%:*}:$pane"
      fi
      ;;
    *) refuse "unsupported backend: $backend" ;;
  esac
  if ! printf '%s %s\n' "$backend" "$target" > "$record"; then
    fm_backend_kill "$backend" "$target" || true
    refuse 'cannot record overseer session'
  fi
  rm -f -- "$state/stopping"
  printf -v prompt 'Read your overseer contract and start a native background command in this session: bash %q watch. Handle the result and rearm the background command after each event.' "$script_dir/fm-overseer.sh"
  printf -v command 'export FM_HOME=%q' "$FM_HOME"
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then printf -v arg ' FM_STATE_OVERRIDE=%q' "$FM_STATE_OVERRIDE"; command=$command$arg; fi
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then printf -v arg ' FM_CONFIG_OVERRIDE=%q' "$FM_CONFIG_OVERRIDE"; command=$command$arg; fi
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then printf -v arg ' FM_DATA_OVERRIDE=%q' "$FM_DATA_OVERRIDE"; command=$command$arg; fi
  if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then printf -v arg ' FM_PROJECTS_OVERRIDE=%q' "$FM_PROJECTS_OVERRIDE"; command=$command$arg; fi
  for setting in FM_OVERSEER_POLL FM_OVERSEER_WAIT FM_OVERSEER_ROUND; do
    if [ -n "${!setting:-}" ]; then
      printf -v arg ' %s=%q' "$setting" "${!setting}"
      command=$command$arg
    fi
  done
  printf -v arg '; %q' "$harness_bin"; command=$command$arg
  [ "$overseer_harness" != codex ] || command="$command --no-daemon"
  case "$overseer_harness:$overseer_permission" in
    codex:auto) command="$command --approve-for-me" ;;
    codex:bypass) command="$command --dangerously-bypass-approvals-and-sandbox" ;;
    claude:auto) command="$command --permission-mode auto" ;;
    claude:bypass) command="$command --dangerously-skip-permissions" ;;
  esac
  if [ -n "$overseer_model" ]; then printf -v arg ' --model %q' "$overseer_model"; command=$command$arg; fi
  if [ -n "$overseer_effort" ]; then
    if [ "$overseer_harness" = claude ]; then printf -v arg ' --effort %q' "$overseer_effort"
    else printf -v arg ' -c %q' "model_reasoning_effort=\"$overseer_effort\""; fi
    command=$command$arg
  fi
  printf -v quoted ' %q' "$prompt"; command=$command$quoted
  case "$backend" in
    tmux) fm_backend_tmux_send_text_line "$target" "$command" ;;
    herdr) fm_backend_herdr_send_text_line "$target" "$command" ;;
  esac || refuse 'could not send the launch command; session record retained'
  "$script_dir/fm-startup-dialogs.sh" "$backend" "$target" "$overseer_harness" "$overseer_dir" 45 "$name"
  live=$(fm_backend_agent_state "$backend" "$target")
  [ "$live" = alive ] || refuse "overseer launch state is $live; session record retained"
  echo 'overseer started; its session arms its own background watch'
}

# place: keep the overseer's Herdr pane right of the primary's, in its tab.
# A move gives the pane a new id, so the session record follows it.
relay_script() {
  printf '%s\n' "${FM_RELAY_LITE:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate-extensions/runtime/context-relay-lite/relay}"
}

# Outgoing overseer. The installation's watch is passed as '-' so the relay
# never stops it, and the pane comes from process ancestry because
# HERDR_PANE_ID goes stale once place has moved the pane.
relay_out() {
  local state relay located
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$code_root}/state}/overseer
  read_config
  [ -n "$overseer_dir" ] || refuse 'config/overseer names no directory'
  relay=$(relay_script)
  [ -x "$relay" ] || refuse "the extensions relay is not installed at $relay"
  [ -f "$state/handoff.md" ] || refuse "write $state/handoff.md before relaying"
  located=$(bash "$script_dir/fm-overseer-primary.sh" --locate "$$") || refuse 'cannot find the pane this overseer runs in'
  case "$located" in "herdr "*:*) ;; *) refuse 'the overseer relay needs Herdr' ;; esac
  # A successor needs tens of seconds to start; the relay's own 5 s default
  # always returned before readiness and forced a manual resume.
  RELAY_WAIT_SECONDS=${RELAY_WAIT_SECONDS:-90} HERDR_PANE_ID=${located#herdr *:} exec "$relay" --supervisor "$overseer_dir" "$overseer_harness" \
    "${overseer_model:--}" "${overseer_effort:--}" "$state/handoff.md" -
}

# Retire a wait owned by the predecessor before changing the endpoint.
relay_ready() {
  local state relay located
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$code_root}/state}/overseer
  read_config
  relay=$(relay_script)
  [ -x "$relay" ] || refuse "the extensions relay is not installed at $relay"
  located=$(bash "$script_dir/fm-overseer-primary.sh" --locate "$$") || refuse 'cannot find the successor pane'
  case "$located" in "herdr "*:*) ;; *) refuse 'the overseer relay needs Herdr' ;; esac
  setup "$overseer_dir"
  python3 "$script_dir/fm-overseer-arm.py" stop || refuse 'could not stop the predecessor watch'
  printf '%s\n' "$located" > "$state/session.tmp"
  mv -f -- "$state/session.tmp" "$state/session"
  exec python3 "$script_dir/fm-overseer-arm.py" watch "$relay" --ready "$overseer_dir" "$1"
}

place() {
  local state record backend target extra located session pane ppane right tab out moved
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$code_root}/state}/overseer
  record="$state/session"
  [ -f "$record" ] || return 0
  IFS=' ' read -r backend target extra < "$record" || return 0
  [ "$backend" = herdr ] && [ -z "$extra" ] || return 0
  # shellcheck source=bin/fm-backend.sh
  . "$script_dir/fm-backend.sh"
  fm_backend_source herdr || return 0
  [ "$(fm_backend_herdr_pane_presence_state "${target%%:*}" "${target#*:}")" = present ] || return 0
  located=$(bash "$script_dir/fm-overseer-primary.sh" --locate 2>/dev/null) || return 0
  case "$located" in "herdr "*:*) ;; *) return 0 ;; esac
  session=${target%%:*} pane=${target#*:}
  [ "${located#herdr }" != "$target" ] || return 0
  [ "${located#herdr "$session":}" != "$located" ] || return 0
  ppane=${located#herdr "$session":}
  right=$(fm_backend_herdr_cli "$session" pane neighbor --pane "$ppane" --direction right | jq -r '.result.neighbor.neighbor_pane_id // empty') || return 0
  [ "$right" != "$pane" ] || return 0
  tab=$(fm_backend_herdr_cli "$session" pane get "$ppane" | jq -r '.result.pane.tab_id // empty') || return 0
  [ -n "$tab" ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$script_dir/fm-wake-lib.sh"
  fm_lock_acquire_wait_max "$state/session.lock" 10 || return 0
  out=$(fm_backend_herdr_cli "$session" pane move "$pane" --tab "$tab" --target-pane "$ppane" --split right --no-focus) || out=
  moved=$(printf '%s' "$out" | jq -r '.result.move_result.pane.pane_id // empty' 2>/dev/null) || moved=
  [ -z "$moved" ] || { printf 'herdr %s:%s\n' "$session" "$moved" > "$record.tmp" && mv -f "$record.tmp" "$record"; }
  fm_lock_release "$state/session.lock"
  [ -n "$moved" ] || { echo 'fm-overseer: could not move the overseer beside the primary' >&2; return 1; }
  echo "OVERSEER_PLACED: $session:$moved right of the primary $ppane"
}

case "${1:-}" in
  setup) shift; setup "$@" ;;
  adopt) shift; adopt "$@" ;;
  intervention)
    shift
    if [ -n "${FM_HOME:-}" ]; then
      home=$FM_HOME
    elif [ -f firstmate-home ]; then
      home=$(cat firstmate-home)
    else
      refuse 'set FM_HOME or run from an overseer directory'
    fi
    [ -f "$home/SUPERVISOR.md" ] || refuse 'not a Firstmate home'
    exec python3 "$script_dir/fm-overseer-interventions.py" --home "$home" "$@" ;;

  alert)
    shift
    [ "$#" -eq 1 ] || refuse 'usage: alert TEXT'
    [ -n "${FM_HOME:-}" ] || refuse 'set FM_HOME'
    exec python3 "$script_dir/fm-notify.py" --home "$FM_HOME" --event overseer-alert --text "$1" ;;
  status) shift; [ "$#" -eq 0 ] || refuse "status takes no arguments"; status ;;
  doctor) shift; [ "$#" -eq 0 ] || refuse "doctor takes no arguments"; exec python3 "$script_dir/fm-overseer-doctor.py" ;;
  watch) shift; [ "$#" -eq 0 ] || refuse "watch takes no arguments"; exec python3 "$script_dir/fm-overseer-arm.py" watch ;;
  place) shift; [ "$#" -eq 0 ] || refuse "place takes no arguments"; place ;;
  relay) shift; [ "$#" -eq 0 ] || refuse "relay takes no arguments"; relay_out ;;
  relay-ready) shift; [ "$#" -eq 1 ] || refuse "usage: fm-overseer.sh relay-ready START_FILE"; relay_ready "$1" ;;
  start|stop) action=$1; shift; [ "$#" -eq 0 ] || refuse "$action takes no arguments"; session_action "$action" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
