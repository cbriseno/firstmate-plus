# shellcheck shell=bash
# Shared supervision predicates.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_main_clear <home> <state-dir>
# Read the existing outcome/inbox owners without advancing either cursor.
# Return 0 only with no pending primary obligation, 1 when one is present,
# 2 when an owner read cannot be completed. Each read has a 10-second bound.
fm_supervision_main_clear() {
  local sup_home=$1 sup_state=$2 sup_bin=${BASH_SOURCE[0]%/*} outcomes inbox
  if ! command -v fm_run_timed >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$sup_bin/fm-timeout-lib.sh" || return 2
  fi
  outcomes=$(FM_HOME="$sup_home" FM_STATE_OVERRIDE="$sup_state" \
    fm_run_timed 10 bash "$sup_bin/fm-branch-outcome.sh" present 2>/dev/null) || return 2
  inbox=$(FM_HOME="$sup_home" FM_STATE_OVERRIDE="$sup_state" \
    fm_run_timed 10 bash "$sup_bin/fm-inbox.sh" receipts 2>/dev/null) || return 2
  printf '%s\n' "$outcomes" | jq -e -s 'all(.[]; .verdict == "routine")' >/dev/null 2>&1 || return 1
  printf '%s\n' "$inbox" | jq -e -s 'length == 1 and .[0].pending == []' >/dev/null 2>&1 || return 1
}

# fm_supervision_relay_handoff <home> <state-dir> <delivered-session-id>
# Read-only intent from the external relay owner, bound to the current lock PID
# and delivered SID (or its recorded client SID). Reuse its active phase or
# matching stow-ready nonce; never write a ticket or drive a session here.
fm_supervision_relay_handoff() {
  local sup_home=$1 sup_state=$2 sup_sid=$3 sup_pid sup_ready='' sup_file
  local sup_config="$sup_home/config/relay-lite.json" sup_ticket="$sup_state/relay-lite/ticket.json"
  case "$sup_sid" in ''|unknown) return 1 ;; esac
  for sup_file in "$sup_config" "$sup_ticket" "$sup_state/.lock"; do
    [ -f "$sup_file" ] && [ ! -L "$sup_file" ] || return 1
  done
  sup_pid=$(cat "$sup_state/.lock" 2>/dev/null) || return 1
  case "$sup_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -f "$sup_state/relay-lite/stow-ready" ] && [ ! -L "$sup_state/relay-lite/stow-ready" ]; then
    read -r sup_ready < "$sup_state/relay-lite/stow-ready" || true
  fi
  jq -e --slurpfile settings "$sup_config" --arg sid "$sup_sid" --arg pid "$sup_pid" --arg ready "$sup_ready" '
    . as $ticket |
    ($settings | length) == 1 and $settings[0].enabled == true and
    (.old_pid | type) == "number" and (.old_pid | tostring) == $pid and
    (.sid == $sid or .lock_sid == $sid) and
    (.nonce | type) == "string" and (.nonce | length) > 0 and
    ((["stowing", "stowed", "opening", "opened", "exiting"] | index($ticket.phase)) != null or
      ($ready != "" and .nonce == $ready))
  ' "$sup_ticket" >/dev/null 2>&1
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of metadata tasks without a proven backlog hold
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/fm-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         a registered custom check, or an owned Lavish board
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check id beat m age lavish_status lavish_script lavish_home snapshot owner home
  FM_SUP_IN_FLIGHT=0
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  # The work owner resolves own and inherited holds, including a requested
  # pause still awaiting its safe point. An unreadable or missing row counts.
  snapshot=
  owner="${BASH_SOURCE[0]%/*}/fm-tasks-axi.sh"
  home=${state%/state}
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    if [ -z "$snapshot" ] && [ -x "$owner" ]; then
      snapshot=$(FM_HOME="$home" bash "$owner" work snapshot 2>/dev/null) || snapshot=
      [ -n "$snapshot" ] || snapshot=unavailable
    fi
    id=${meta##*/}
    id=${id%.meta}
    if [ -n "$snapshot" ] && printf '%s' "$snapshot" | jq -e --arg key "task:$id" '
      .schema == "fm-work-snapshot.v1" and
      ([.tasks[] | select(.key == $key and .state != "stopping" and
        .pause.safe_point != "pending" and
        (.pause.own != null or .pause.inherited != null))] | length == 1)
    ' >/dev/null 2>&1; then
      continue
    fi
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  FM_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ]; then
      continue
    fi
    [ -e "$state/$id.check-trust" ] || continue
    FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi
  # A published board can precede its first source registration, or outlive its
  # task. All primary turn-end/auto-arm adapters share this predicate, so even
  # an otherwise empty fleet must keep the discovery sweep alive. Errors fail
  # closed to supervision, where the sweep reports its diagnostic durably.
  if [ "$FM_SUP_NEEDED" = false ] && [ -e "${LAVISH_AXI_STATE_DIR:-$HOME/.lavish-axi}/state.json" ]; then
    lavish_script="${BASH_SOURCE[0]%/*}/fm-lavish-watch.sh"
    lavish_home=${FM_HOME:-${state%/*}}
    case "$state" in */state) lavish_home=${state%/state} ;; esac
    if [ -x "$lavish_script" ]; then
      lavish_status=0
      FM_HOME="$lavish_home" FM_STATE_OVERRIDE="$state" "$lavish_script" needed >/dev/null 2>&1 || lavish_status=$?
      [ "$lavish_status" -eq 1 ] || FM_SUP_NEEDED=true
    fi
  fi

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
