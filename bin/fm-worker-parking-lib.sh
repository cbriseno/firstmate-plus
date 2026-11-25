#!/usr/bin/env bash
# Idle-worker park/resume mechanics sourced only by fm-control.sh under its
# per-task lifecycle lock. The parked file copies launch fields from metadata,
# plus park_phase, park_wait and (tmux only) park_tmux_socket. Work stays put.
# A failed stop/close retains phase=stopping for the next park or resume.
# Resume clears the parked file only after the replacement is confirmed alive.
# Globals below belong to the sourcing control command.
# shellcheck disable=SC2034,SC2153

do_park() {
  local pending wait_line state verdict process_check socket='' park_cause='' saved="$STATE/$ID.parked" note="$DATA/$ID/park-note.md"
  case "$KIND" in ship|scout|host) ;; *) die 'parking applies to task workers only' ;; esac
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  wait_line=$(status_current_line "$STATE/$ID.status" "$KIND")
  # The general pause (bin/fm-pause-general.sh) is itself the wait condition.
  if [ -e "$STATE/.pause-general" ]; then park_cause=general-pause; else park_cause=$(fm_meta_get "$saved" park_cause); fi
  case "$(status_line_verb "$wait_line")" in
    done|needs-decision|captain-held) ;;
    paused) [ -n "$park_cause" ] || status_paused_until "$wait_line" >/dev/null || status_paused_load1 "$wait_line" >/dev/null || die 'parking a pause requires an until date or load1 threshold' ;;
    *) [ -n "$park_cause" ] || die 'parking requires a declared done, needs-decision, captain-held or dated pause' ;;
  esac
  if [ -f "$saved" ] && [ "$(fm_meta_get "$saved" park_phase)" = parked ]; then
    echo "already-parked $ID"
    return
  fi
  state=$(agent_state)
  case "$state" in
    dead) ;;
    alive)
      verdict=$(busy_verdict)
      case "$PARK_WHEN_IDLE:$verdict" in
        1:idle*|0:*) ;;
        *) die "task $ID is not positively idle ($verdict); retry park once it is" ;;
      esac
      case "$verdict" in
        idle*) ;;
        'busy fm-spawn') echo "warning: $ID has only an unconfirmed launch seed; parking relies on Firstmate's verified operation-complete safe point" >&2 ;;
        busy*) die "task $ID is busy; retry park after its operation finishes" ;;
        *) echo "warning: $ID activity is unknown; parking relies on Firstmate's verified operation-complete safe point" >&2 ;;
      esac
      ;;
    missing)
      [ -f "$saved" ] || die 'cannot park an endpoint whose ownership is unproven'
      if [ "$BACKEND" = tmux ]; then
        socket=$(fm_meta_get "$saved" park_tmux_socket)
        [ -n "$socket" ] && [ "$(tmux display-message -p '#{socket_path}' 2>/dev/null)" = "$socket" ] \
          || die 'cannot finish parking from a different tmux socket'
      else
        [ "$(fm_control_endpoint_absence_verdict "$BACKEND" "$T" "$META")" = $'gone\t' ] \
          || die 'cannot prove the parked endpoint is gone'
      fi
      ;;
    *) die "cannot park an endpoint in state $state" ;;
  esac
  PARK_META_LOCK=$(fm_meta_lock_path "$META") || return 1
  fm_lock_acquire_wait "$PARK_META_LOCK" || die 'task metadata is busy; retry park'
  # A steer that arrived before this lock must be read before closing its pane.
  if [ ! -f "$saved" ]; then
    for pending in "$STATE/$ID.inbox"/*.msg; do
      [ ! -f "$pending" ] || die 'task has pending steering; let the worker read it before parking'
    done
  fi
  safe_checkpoint
  if [ "$PARK_WHEN_IDLE" = 1 ]; then
    process_check=park-safe
    [ "$state" != missing ] || process_check=park-gone
    python3 "$SCRIPT_DIR/fm-worker-processes.py" "$process_check" "$META" \
      || die 'worker process scope has active or unverified work; retry park when it is clear'
  fi
  mkdir -p "$DATA/$ID"
  if [ "$BACKEND" = tmux ]; then
    socket=$(tmux display-message -p '#{socket_path}') || die 'cannot save tmux socket identity'
  fi
  # Save the exact launch identity, wait and progress before stopping anything.
  {
    awk -F= '$1 ~ /^(harness|model|effort|kind|worktree|project|spawn_gen|spawned_at|sessions_file|window|backend|herdr_session|herdr_pane_id)$/ {print}' "$META"
    printf '\npark_phase=stopping\npark_wait=%s\npark_tmux_socket=%s\n' "$wait_line" "$socket"
    [ -z "$park_cause" ] || printf 'park_cause=%s\n' "$park_cause"
  } > "$saved.tmp"
  mv "$saved.tmp" "$saved"
  {
    printf 'Resume task %s in %s. Previous wait: %s\n\n' "$ID" "$WT" "$wait_line"
    printf 'Read the existing brief and pending steering inbox before continuing.\n'
    printf 'Saved launch metadata:\n'; cat "$saved"
    printf '\nProgress at parking:\n'
    [ ! -f "$DATA/$ID/presentation.json" ] || cat "$DATA/$ID/presentation.json"
  } > "$note"
  fm_lock_release "$PARK_META_LOCK"
  PARK_META_LOCK=
  if [ "$state" != missing ]; then
    do_exit >/dev/null || return 1
    fm_backend_kill "$BACKEND" "$T" || die 'agent stopped but endpoint close failed; retry park'
  fi
  case "$BACKEND" in
    herdr) fm_backend_herdr_endpoint_confirmed_gone "$T" || die 'endpoint close is unconfirmed; retry park' ;;
    tmux) [ "$(agent_state)" = missing ] || die 'endpoint is still present; retry park' ;;
  esac
  printf 'park_phase=parked\n' >> "$saved"
  echo "parked $ID backend=$BACKEND worktree=$WT"
}

# Natural-language dispatch selection belongs to Firstmate. A policy whose
# profiles all use one adapter is unambiguous without selecting a rule/model.
# For a mixed policy retain the saved adapter when it remains a candidate.
resume_policy_harness() {
  local config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  if [ -f "$config/crew-dispatch.json" ]; then
    jq -er --arg saved "$HARNESS" '
      [((.rules // [])[] | .use), (.default // empty)] | flatten |
      if length == 0 or any(.[]; type != "object" or (.harness | type) != "string")
      then error("invalid dispatch profiles") else map(.harness) | unique end |
      if length == 1 then .[0] elif index($saved) then $saved else error("resolve the current dispatch profile") end
    ' "$config/crew-dispatch.json" \
      || die 'resolve the current dispatch profile before resume; do not fall back to crew-harness'
  else
    "$SCRIPT_DIR/fm-harness.sh" crew
  fi
}

resume_check_policy() {
  local policy category profile model effort config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  [ "$HARNESS_SET" = 0 ] || return 0
  category=$(sed -n 's/^Dispatch category: //p' "$DATA/$ID/brief.md" 2>/dev/null | head -n 1)
  if [ -n "$category" ] && [ -f "$config/crew-dispatch.json" ]; then
    profile=$(jq -er --arg category "$category" '
      (if $category == "default" then .default else
       [.rules[]? | select(.category == $category) | .use] |
       if length == 1 then .[0] else error("category must select one rule") end end) |
      if type == "array" then if length == 1 then .[0] else error("profile selection required") end else . end |
      if type == "object" and (.harness | type) == "string" then
        [.harness, (.model // "__unset__"), (.effort // "__unset__")] | @tsv
      else error("invalid dispatch profile") end
    ' "$config/crew-dispatch.json") || die 'resolve the current dispatch profile before resume'
    IFS=$'\t' read -r policy model effort <<< "$profile"
    [ "$model" != __unset__ ] || model=$(sed -n 's/^Dispatch model: //p' "$DATA/$ID/brief.md" | head -n 1)
    [ "$effort" != __unset__ ] || effort=$(sed -n 's/^Dispatch effort: //p' "$DATA/$ID/brief.md" | head -n 1)
    if [ -n "$model" ] && [ "$MODEL_SET" = 0 ]; then NEW_MODEL=$model; MODEL_SET=1; fi
    if [ -n "$effort" ] && [ "$EFFORT_SET" = 0 ]; then NEW_EFFORT=$effort; EFFORT_SET=1; fi
  else
    policy=$(resume_policy_harness) || return 1
  fi
  fm_control_harness_supported "$policy" || die "unverified current usage policy: $policy"
  [ "$policy" != "$HARNESS" ] || return 0
  NEW_HARNESS=$policy
  HARNESS_SET=1
}

do_resume() {
  local saved="$STATE/$ID.parked" reason=native-session
  [ -f "$saved" ] || die "task $ID is not parked; use relaunch for ordinary recovery"
  case "$(fm_meta_get "$saved" park_phase)" in
    stopping) do_park || return 1 ;;
    parked) ;;
    *) die 'parking phase is unrecognized; inspect the saved record' ;;
  esac
  case "$(agent_state)" in
    missing|dead) ;;
    *) die 'parked endpoint is not confirmed agent-free; refusing duplicate worker' ;;
  esac
  resume_check_policy || return 1
  RESUME_SESSION=
  if [ "$HARNESS_SET" = 1 ] && [ "$NEW_HARNESS" != "$HARNESS" ]; then
    reason="usage-policy harness takeover: $HARNESS -> $NEW_HARNESS"
    echo "resume-fallback $ID: $reason; starting fresh with saved progress note" >&2
  elif RESUME_SESSION=$(python3 "$SCRIPT_DIR/fm_task_sessions.py" resume-id "$STATE" "$ID" 2>"$STATE/$ID.resume-reason"); then
    echo "resume $ID chat=$RESUME_SESSION" >&2
  else
    reason=$(cat "$STATE/$ID.resume-reason")
    echo "resume-fallback $ID: $reason; starting fresh with saved progress note" >&2
  fi
  NOTE=$(cat "$DATA/$ID/park-note.md")
  NOTE_SET=1
  do_relaunch || return 1
  rm -f "$saved" "$STATE/$ID.resume-reason"
  echo "resumed $ID chat=${RESUME_SESSION:-fresh-with-progress-note} reason=$reason"
}
