#!/usr/bin/env bash
# fm-diag.sh - Firstmate's always-on, anonymized diagnostic event log.
#
# Usage: bin/fm-diag.sh path              print the log directory
#        bin/fm-diag.sh emit EVENT K=V...  append one event (for non-bash callers)
#        bin/fm-diag.sh export OUTPUT.zip  export anonymized events
#        bin/fm-diag.sh id TEXT           print the local anonymized id of TEXT
# Sourced by bash callers for fm_diag_emit, fm_diag_hook_begin and
# fm_diag_hook_end. Sourcing has no side effects.
#
# WHY. Slowness, stuck wakes and leaking workers were diagnosed by asking the
# captain what happened. These records let an agent answer from the log alone.
# They share the directory and line shape of the Deck and extension logs
# written by fm_diagnostics.py (firstmate-extensiones), as component
# "firstmate": <root>/firstmate/events.jsonl, where <root> is
# $FM_DIAGNOSTICS_HOME, else ~/Library/Logs/Firstmate/Diagnostics on macOS,
# else ${XDG_STATE_HOME:-~/.local/state}/firstmate/diagnostics. The Deck's own
# events (snapshot.read/error with duration_ms, anim.*, layout, overlay.*) are
# in <root>/deck/events.jsonl beside it.
#
# LINE: {"t":"<UTC ISO-8601 ms>","c":"firstmate","e":EVENT,"v":"unknown","r":"unknown",...fields}
# EVENTS AND FIELDS (the single owner of this schema; unknown events and
# fields are dropped):
#   hook.run        hook harness role session run ms rc
#                   one blocking PreToolUse or Stop hook; session is the
#                   harness pid, role primary|worker
#   operation.stage operation stage run ms rc - one completed diagnostic stage
#   session.stage   stage ms - one completed bin/fm-session-start.sh stage
#   session.start   ms rc last_stage budget_s source harness session - the
#                   whole run; last_stage only when it was cut short
#   wake.ack        kind age_s - a wake row acknowledged by fm-wake-drain.sh;
#                   age_s is its wait from queueing (attention latency)
#   obligation.overdue category obligation - one overdue page from
#                   bin/fm-obligation-lib.sh; obligation is its anonymized key
#   work.snapshot   caller ms lock_ms result tasks - one fm_work.py snapshot
#   worker.procs    task harness procs zombies rss_mb - one worker's process
#                   scope, sampled by the watcher every FM_DIAG_SAMPLE_SECS (300)
#   session.link    task harness result reason - launch/bind outcome; no transcript paths
#   integration.ok  task project request - the approved local default ref advanced
# Value kinds: integers stay numbers; `task` is replaced by "live-" plus 16
# hex of sha256(local salt + id), the same id kind fm_diagnostics uses (run
# `fm-diag.sh id <task-id>` to find a task's id on this machine); project,
# request and obligation use the same representation with a type prefix. Every other
# value must be a short token [A-Za-z0-9._-], else it is dropped. No paths,
# commands, titles or free text are ever written.
#
# NEVER CHANGES THE CALLER. Every helper ignores its own failures, writes one
# short O_APPEND line, and hook timing preserves the hook's exit status.
# FM_DIAGNOSTICS=0 disables recording. events.jsonl rotates to events.1.jsonl
# past 10 MB (checked on about one write in 64).
# Hook times start when the hook script starts, so interpreter startup is not
# included.

fm_diag_dir() {
  if [ -n "${FM_DIAGNOSTICS_HOME:-}" ]; then
    FM_DIAG_DIR=$FM_DIAGNOSTICS_HOME/firstmate
  else
    case "${OSTYPE:-}" in
      darwin*) FM_DIAG_DIR=$HOME/Library/Logs/Firstmate/Diagnostics/firstmate ;;
      *) FM_DIAG_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/diagnostics/firstmate ;;
    esac
  fi
}

fm_diag_now_ms() {  # sets FM_DIAG_MS
  local raw=${EPOCHREALTIME:-} sec frac
  case "$raw" in
    *[0-9][.,][0-9]*)
      sec=${raw%%[.,]*} frac=${raw#*[.,]}000
      FM_DIAG_MS=$(( sec * 1000 + 10#${frac:0:3} ))
      return 0 ;;
  esac
  FM_DIAG_MS=$(( $(date +%s) * 1000 ))
}

fm_diag_schema() {  # <event> -> FM_DIAG_FIELDS
  case "$1" in
    hook.run) FM_DIAG_FIELDS='hook harness role session run ms rc' ;;
    operation.stage) FM_DIAG_FIELDS='operation stage run ms rc' ;;
    session.stage) FM_DIAG_FIELDS='stage ms' ;;
    session.start) FM_DIAG_FIELDS='ms rc last_stage budget_s source harness session' ;;
    wake.ack) FM_DIAG_FIELDS='kind age_s' ;;
    obligation.overdue) FM_DIAG_FIELDS='category obligation' ;;
    work.snapshot) FM_DIAG_FIELDS='caller ms lock_ms result tasks' ;;
    worker.procs) FM_DIAG_FIELDS='task harness procs zombies rss_mb' ;;
    context.relay) FM_DIAG_FIELDS='task result reason' ;;
    session.link) FM_DIAG_FIELDS='task harness result reason' ;;
    integration.ok) FM_DIAG_FIELDS='task project request' ;;
    *) return 1 ;;
  esac
}

fm_diag_id() {  # <text> -> stdout live-<16 hex>
  local salt hash
  fm_diag_dir
  if [ ! -s "$FM_DIAG_DIR/.salt" ]; then
    mkdir -p "$FM_DIAG_DIR" 2>/dev/null || return 1
    ( umask 077; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$FM_DIAG_DIR/.salt" ) 2>/dev/null || return 1
  fi
  salt=$(cat "$FM_DIAG_DIR/.salt" 2>/dev/null) || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s%s' "$salt" "$1" | sha256sum)
  else
    hash=$(printf '%s%s' "$salt" "$1" | shasum -a 256)
  fi
  printf 'live-%s\n' "${hash:0:16}"
}

fm_diag_emit() {  # <event> [key=value ...]
  [ "${FM_DIAGNOSTICS:-1}" != 0 ] || return 0
  local event=$1 pair key value fields stamp file
  fm_diag_schema "$event" || return 0
  shift
  fields=''
  for pair in "$@"; do
    key=${pair%%=*} value=${pair#*=}
    case " $FM_DIAG_FIELDS " in *" $key "*) ;; *) continue ;; esac
    case "$key:$value" in *:'') continue ;; esac
    if [[ "$key" = task || "$key" = project || "$key" = request || "$key" = obligation ]]; then
      local identity=$value
      [ "$key" = task ] || identity="$key:$value"
      value=$(fm_diag_id "$identity") || continue
      fields+=",\"$key\":\"$value\""
    elif [[ $value =~ ^-?[0-9]{1,15}$ ]]; then
      fields+=",\"$key\":$((10#${value#-} * ${value%%[0-9]*}1))"
    elif [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$ ]]; then
      fields+=",\"$key\":\"$value\""
    fi
  done
  fm_diag_now_ms
  if ! TZ=UTC0 printf -v stamp '%(%Y-%m-%dT%H:%M:%S)T' "$(( FM_DIAG_MS / 1000 ))" 2>/dev/null; then
    stamp=$(date -u +%Y-%m-%dT%H:%M:%S)
  fi
  printf -v stamp '%s.%03d+00:00' "$stamp" "$(( FM_DIAG_MS % 1000 ))"
  fm_diag_dir
  [ -d "$FM_DIAG_DIR" ] || mkdir -p "$FM_DIAG_DIR" 2>/dev/null || return 0
  file=$FM_DIAG_DIR/events.jsonl
  if [ $(( RANDOM % 64 )) -eq 0 ] && [ -n "$(find "$file" -size +10240k 2>/dev/null)" ]; then
    mv -f "$file" "$FM_DIAG_DIR/events.1.jsonl" 2>/dev/null || true
  fi
  printf '{"t":"%s","c":"firstmate","e":"%s","v":"unknown","r":"unknown"%s}\n' \
    "$stamp" "$event" "$fields" >> "$file" 2>/dev/null || true
  return 0
}

# Harness name of a process word (comm, argv0 or a node script path).
_fm_diag_harness_word() {  # <word> -> FM_DIAG_HARNESS or return 1
  case "/$1/" in */claude/*) FM_DIAG_HARNESS=claude; return 0 ;; esac
  case "${1##*/}" in
    claude|codex)
      FM_DIAG_HARNESS=${1##*/}; return 0 ;;
  esac
  return 1
}

# Nearest harness ancestor: FM_DIAG_HARNESS and FM_DIAG_SESSION (its pid).
# Linux reads /proc without forking; other systems take one ps listing.
fm_diag_harness() {
  local pid=$PPID line rest comm argv
  FM_DIAG_HARNESS=unknown FM_DIAG_SESSION=
  if [ -r /proc/$$/stat ]; then
    for _ in 1 2 3 4 5 6 7 8; do
      [ -r "/proc/$pid/comm" ] || return 0
      read -r comm < "/proc/$pid/comm" 2>/dev/null || return 0
      argv=()
      mapfile -d '' -n 2 argv < "/proc/$pid/cmdline" 2>/dev/null || true
      if _fm_diag_harness_word "$comm" || _fm_diag_harness_word "${argv[0]:-}" \
        || _fm_diag_harness_word "${argv[1]:-}"; then
        FM_DIAG_SESSION=$pid
        return 0
      fi
      read -r line < "/proc/$pid/stat" 2>/dev/null || return 0
      rest=${line##*) }
      read -r _ pid _ <<< "$rest"
      [ "${pid:-0}" -gt 1 ] 2>/dev/null || return 0
    done
    return 0
  fi
  read -r FM_DIAG_SESSION FM_DIAG_HARNESS < <(ps -axo pid=,ppid=,comm= 2>/dev/null | awk -v start="$PPID" '
    { p = $1; parent[p] = $2; $1 = ""; $2 = ""; sub(/^ +/, ""); comm[p] = $0 }
    END {
      pid = start
      for (i = 0; i < 8 && pid > 1; i++) {
        c = comm[pid]; n = c; sub(/.*\//, "", n)
        if (("/" c "/") ~ /\/claude\//) { print pid, "claude"; exit }
        if (n ~ /^(claude|codex)$/) { print pid, n; exit }
        pid = parent[pid]
      }
      print "-", "unknown"
    }') || true
  [ "${FM_DIAG_SESSION:--}" != - ] || FM_DIAG_SESSION=
  [ -n "${FM_DIAG_HARNESS:-}" ] || FM_DIAG_HARNESS=unknown
}

# Stage clocks use monotonic time on both stock macOS Bash and Linux.
fm_diag_stage_begin() {  # <operation> <stage>
  [ "${FM_DIAGNOSTICS:-1}" != 0 ] || return 0
  FM_DIAG_OPERATION=$1 FM_DIAG_STAGE_NAME=$2
  FM_DIAG_STAGE_START=$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)' 2>/dev/null) || FM_DIAG_STAGE_START=
}

fm_diag_stage_end() {  # [status]
  local rc=${1:-0} now
  [ -n "${FM_DIAG_STAGE_START:-}" ] || return 0
  now=$(python3 -c 'import time; print(time.monotonic_ns() // 1000000)' 2>/dev/null) || return 0
  fm_diag_emit operation.stage operation="$FM_DIAG_OPERATION" stage="$FM_DIAG_STAGE_NAME" \
    run="$$" ms="$((now - FM_DIAG_STAGE_START))" rc="$rc"
  FM_DIAG_STAGE_START=
}

fm_diag_stage_next() {  # <stage> [previous-status]
  local operation=${FM_DIAG_OPERATION:-} rc=${2:-0}
  fm_diag_stage_end "$rc"
  [ -z "$operation" ] || fm_diag_stage_begin "$operation" "$1"
}

fm_diag_hook_begin() {  # <hook-name>; pair with an EXIT trap running fm_diag_hook_end
  [ "${FM_DIAGNOSTICS:-1}" != 0 ] || return 0
  FM_DIAG_HOOK=$1
  fm_diag_now_ms
  FM_DIAG_HOOK_START=$FM_DIAG_MS
}

fm_diag_hook_end() {  # [status]; returns the status it was given (default $?)
  local rc=${1:-$?} role=primary
  [ -n "${FM_DIAG_HOOK_START:-}" ] || return "$rc"
  fm_diag_now_ms
  fm_diag_harness
  [ -z "${FM_WORKER_PROCESS_SCOPE:-}" ] || role=worker
  fm_diag_emit hook.run hook="$FM_DIAG_HOOK" harness="$FM_DIAG_HARNESS" role="$role" \
    session="$FM_DIAG_SESSION" run="$$" ms="$(( FM_DIAG_MS - FM_DIAG_HOOK_START ))" rc="$rc"
  FM_DIAG_HOOK_START=''
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    path) fm_diag_dir; printf '%s\n' "$FM_DIAG_DIR" ;;
    emit) [ "$#" -ge 2 ] || exit 2; shift; fm_diag_emit "$@" ;;
    export) [ "$#" -eq 2 ] || exit 2; fm_diag_dir; python3 "$(dirname "${BASH_SOURCE[0]}")/fm-diag-export.py" "$FM_DIAG_DIR" "$2" ;;
    id) [ "$#" -eq 2 ] || exit 2; fm_diag_id "$2" ;;
    *) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
fi
