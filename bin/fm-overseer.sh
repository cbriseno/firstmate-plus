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
#   fm-overseer.sh intervention record --category TOKEN --observed TOKEN
#       --evidence REF --action TOKEN --root-task yes|no
#   fm-overseer.sh intervention export OUTPUT.zip
#       Tokens are anonymous short identifiers (letters, digits, dot, dash,
#       underscore; at most 40 characters). The reference is anonymized.
#       Review every summary and reference for private information before
#       recording or exporting; the bounded automated scan is not sufficient
#       to detect names or all private content.
#   fm-overseer.sh status        report configuration and session liveness
#   fm-overseer.sh doctor        read prerequisites and local diagnostic evidence
#   fm-overseer.sh start         start the configured overseer if absent
#   fm-overseer.sh stop          close the recorded overseer session
#   fm-overseer.sh hook          print the generated Stop-hook settings
#   fm-overseer.sh -h|--help     print this text
#
# setup creates <dir> when missing and writes three untracked entries in it:
#   CLAUDE.md       symlink to <code-root>/overseer/AGENTS.md (Claude loads it)
#   AGENTS.md       symlink to the same file (Codex loads it)
#   firstmate-home  one line: the physical path of the home being overseen,
#                   FM_HOME when set, otherwise this script's code root
#   .codex/hooks.json  Stop hook that arms the overseer's event wait
# Both loaders are symlinks to the contract itself, so a repository update
# reaches the next overseer session without rerunning setup. They are not an
# @-import: Claude treats an import that resolves outside its directory as an
# external include and skips it until approved, while a symlinked CLAUDE.md
# loads directly.
# setup refuses, changing nothing, when <dir> or any ancestor holds
# SUPERVISOR.md (an agent there would also load a home's or a task copy's
# instructions), or when an entry exists with other content. An entry that
# already matches is left alone, so setup is idempotent; it prints one line per
# entry written and a final OVERSEER_READY line.
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
      *) refuse "unknown overseer configuration key: $key" ;;
    esac
  done < "$file"
  case "$overseer_enabled" in on|off) ;; *) refuse "enabled must be on or off" ;; esac
  case "$overseer_harness" in claude|codex) ;; *) refuse "harness must be claude or codex" ;; esac
  case "$overseer_permission" in default|auto|bypass) ;; *) refuse "permission must be default, auto or bypass" ;; esac
  case "$overseer_dir" in ''|/*) ;; *) refuse "directory must be an absolute path" ;; esac
  case "$overseer_model$overseer_effort" in *[!a-zA-Z0-9._-]*) refuse "model and effort must be plain names" ;; esac
}

usage() {
  sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'
}

refuse() {
  printf 'fm-overseer: %s\n' "$1" >&2
  exit 1
}

hook_definition() {
  python3 - "$script_dir/fm-overseer-arm.py" "${1:-${FM_HOME:-$code_root}}" "$code_root" "${FM_STATE_OVERRIDE:-}" "${FM_CONFIG_OVERRIDE:-}" "${FM_DATA_OVERRIDE:-}" "${FM_PROJECTS_OVERRIDE:-}" <<'PY'
import json, shlex, sys
env = ['FM_HOME=' + sys.argv[2], 'FM_ROOT_OVERRIDE=' + sys.argv[3]]
for key, value in zip(('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'), sys.argv[4:]):
    env.append(key + '=' + value)
command = 'env ' + ' '.join(shlex.quote(item) for item in env) + ' python3 ' + shlex.quote(sys.argv[1]) + ' guard'
print(json.dumps({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': command, 'timeout': 90}]}]}}))
PY
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
  local dir=${1:?usage: fm-overseer.sh setup <dir>} home contract existing ancestor claude agents homefile hook hooksfile hookswrite
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
  hook=$(hook_definition "$home") || refuse 'cannot construct the Codex Stop hook'
  hooksfile="$dir/.codex/hooks.json"
  hookswrite=
  [ ! -L "$dir/.codex" ] || refuse "$dir/.codex is a symlink"
  [ ! -e "$dir/.codex" ] || [ -d "$dir/.codex" ] || refuse "$dir/.codex is not a directory"
  [ ! -e "$dir/.codex/config.toml" ] && [ ! -L "$dir/.codex/config.toml" ] ||
    refuse "$dir/.codex/config.toml carries separate settings; choose another directory"
  if [ -e "$hooksfile" ] || [ -L "$hooksfile" ]; then
    [ ! -L "$hooksfile" ] && [ -f "$hooksfile" ] && [ "$(cat "$hooksfile")" = "$hook" ] ||
      refuse "$hooksfile already exists with different content; move it away first"
  else
    hookswrite=1
  fi
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
  if [ -n "$hookswrite" ]; then
    mkdir -p "$dir/.codex"
    printf '%s\n' "$hook" > "$hooksfile"
    echo "OVERSEER_SETUP: wrote $hooksfile"
  fi
  echo "OVERSEER_READY: $dir oversees $home; a Claude or Codex session started there loads the overseer contract"
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
  local action=$1 state record backend target extra live ses name ident container seeded ids pane command prompt arg quoted hooks
  read_config
  [ "$action" != start ] || [ "$overseer_enabled" = on ] || { echo 'overseer is disabled'; return 0; }
  [ "$action" != start ] || [ -f "$script_dir/fm-overseer-watch.sh" ] || refuse 'overseer watch is unavailable; update the installation'
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
  [ -n "$overseer_dir" ] || refuse 'set directory in config/overseer'
  setup "$overseer_dir"
  overseer_dir=$(CDPATH='' cd -- "$overseer_dir" && pwd -P)
  FM_HOME=${FM_HOME:-$code_root}
  FM_HOME=$(CDPATH='' cd -- "$FM_HOME" && pwd -P)
  export FM_HOME
  command -v "$overseer_harness" >/dev/null 2>&1 || refuse "$overseer_harness is unavailable"
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
      container=$(fm_backend_herdr_container_ensure "$overseer_dir" launcher-home) || refuse 'cannot find Herdr workspace'
      seeded=${container#*$'\t'}; container=${container%%$'\t'*}
      ids=$(fm_backend_herdr_create_task "$container" "$name" "$overseer_dir" "$seeded") || refuse 'cannot create overseer tab'
      IFS=' ' read -r ident pane <<EOF
$ids
EOF
      [ -n "$pane" ] || refuse 'Herdr returned no pane'
      target="${container%%:*}:$pane"
      ;;
    *) refuse "unsupported backend: $backend" ;;
  esac
  if ! printf '%s %s\n' "$backend" "$target" > "$record"; then
    fm_backend_kill "$backend" "$target" || true
    refuse 'cannot record overseer session'
  fi
  python3 - "$state/session-env.json" <<'PY' || refuse 'cannot record the session connection context'
import json, os, sys, tempfile
keys = ('PATH', 'TMUX', 'TMUX_TMPDIR', 'HERDR_SESSION', 'FM_BACKEND',
        'FM_OVERSEER_POLL', 'FM_OVERSEER_WAIT')
path = sys.argv[1]
fd, temporary = tempfile.mkstemp(prefix='.session-env-', dir=os.path.dirname(path))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump({key: os.environ.get(key, '') for key in keys}, stream)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
  rm -f -- "$state/stopping"
  prompt='Read your overseer contract and begin monitoring the Firstmate home named in firstmate-home. The Stop hook arms the watch at the end of each turn; you do not need to arm it during a turn.'
  printf -v command 'export FM_HOME=%q' "$FM_HOME"
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then printf -v arg ' FM_STATE_OVERRIDE=%q' "$FM_STATE_OVERRIDE"; command=$command$arg; fi
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then printf -v arg ' FM_CONFIG_OVERRIDE=%q' "$FM_CONFIG_OVERRIDE"; command=$command$arg; fi
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then printf -v arg ' FM_DATA_OVERRIDE=%q' "$FM_DATA_OVERRIDE"; command=$command$arg; fi
  if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then printf -v arg ' FM_PROJECTS_OVERRIDE=%q' "$FM_PROJECTS_OVERRIDE"; command=$command$arg; fi
  printf -v arg '; %q' "$overseer_harness"; command=$command$arg
  [ "$overseer_harness" != codex ] || command="$command --no-daemon"
  case "$overseer_harness:$overseer_permission" in
    codex:auto) command="$command --approve-for-me" ;;
    codex:bypass) command="$command --dangerously-bypass-approvals-and-sandbox" ;;
    claude:auto) command="$command --permission-mode auto" ;;
    claude:bypass) command="$command --dangerously-skip-permissions" ;;
  esac
  if [ "$overseer_harness" = claude ]; then
    hooks=$(cat "$overseer_dir/.codex/hooks.json")
    printf -v arg ' --settings %q' "$hooks"; command=$command$arg
  fi
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
  echo 'overseer started; its Stop hook arms the watch when the first turn ends'
}

case "${1:-}" in
  setup) shift; setup "$@" ;;
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

  status) shift; [ "$#" -eq 0 ] || refuse "status takes no arguments"; status ;;
  doctor) shift; [ "$#" -eq 0 ] || refuse "doctor takes no arguments"; exec python3 "$script_dir/fm-overseer-doctor.py" ;;
  hook) shift; [ "$#" -eq 0 ] || refuse "hook takes no arguments"; hook_definition ;;
  start|stop) action=$1; shift; [ "$#" -eq 0 ] || refuse "$action takes no arguments"; session_action "$action" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
