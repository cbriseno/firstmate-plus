#!/usr/bin/env bash
# Spawn rollback and cleanup, sourced by fm-spawn.sh.

spawn_fresh_commit_rollback() {
  # Delivery may have started a worker; its original ownership is the only
  # safe handle for reconciliation while the endpoint remains open or unknown.
  if [ "$SPAWN_LAUNCH_SENT" = 1 ] && [ "$SPAWN_ENDPOINT_CLOSED" != 1 ]; then
    SPAWN_FRESH_COMMIT_PENDING=0
    echo "error: task $ID may be running at endpoint $T with local copy $WT; its original record at $STATE/$ID.meta and generation are retained. Reconcile this same worker and backlog before retrying; do not spawn a duplicate" >&2
    return 0
  fi
  if fm_backlog_atomic_transition rollback "$STATE/$ID.meta" \
    "$FM_ROOT/bin/fm-busy-event.sh" "$STATE" "$ID" "${BUSY_GEN:-}"; then
    SPAWN_FRESH_COMMIT_PENDING=0
    return 0
  fi
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  return 1
}

parse_orca_worktree_result() {
  local raw=$1 rest
  ORCA_WORKTREE_ID=${raw%%$'\t'*}
  if [ "$raw" = "$ORCA_WORKTREE_ID" ]; then
    WT=
    ORCA_TERMINAL=
    return 1
  fi
  rest=${raw#*$'\t'}
  WT=${rest%%$'\t'*}
  if [ "$rest" != "$WT" ]; then
    ORCA_TERMINAL=${rest#*$'\t'}
  else
    ORCA_TERMINAL=
  fi
}

# Non-forced unlink arbitration for a delivered Orca source-mode launch file:
# the pane unlinks it before launching the worker and refuses when that unlink
# fails, so exactly one side's unlink succeeds. Returns 0 when this spawn removed
# it (the worker is refused), 1 when the pane already had, and 2 when the file
# could not be removed.
spawn_orca_reclaim_launch_file() {
  rm -- "$SPAWN_STAGED_LAUNCH_FILE" 2>/dev/null && return 0
  if [ -e "$SPAWN_STAGED_LAUNCH_FILE" ] || [ -L "$SPAWN_STAGED_LAUNCH_FILE" ]; then
    return 2
  fi
  return 1
}

spawn_abort_cleanup() {
  local status=$?
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ] &&
    [ "$SPAWN_META_PUBLISH_STARTED" = 1 ] &&
    [ -n "$SPAWN_META_TMP" ] &&
    [ ! -e "$SPAWN_META_TMP" ] &&
    [ ! -L "$SPAWN_META_TMP" ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
  fi
  if [ "$RELAUNCH_REPLACEMENT_PENDING" = 1 ]; then
    RELAUNCH_REPLACEMENT_PENDING=0
    if ! clear_relaunch_harness_wiring \
      "$RELAUNCH_REPLACEMENT_HARNESS" \
      "$RELAUNCH_REPLACEMENT_WT" \
      "$RELAUNCH_REPLACEMENT_STATE" \
      "$ID" \
      "$KIND"; then
      echo "warning: could not remove replacement wiring after aborted relaunch of $ID" >&2
    fi
    if [ -n "$RELAUNCH_REPLACEMENT_BUSY_GEN" ]; then
      if ! "$FM_ROOT/bin/fm-busy-event.sh" retire \
        "$RELAUNCH_REPLACEMENT_STATE" "$ID" \
        --gen "$RELAUNCH_REPLACEMENT_BUSY_GEN"; then
        echo "warning: could not retire replacement busy generation after aborted relaunch of $ID" >&2
      fi
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ] &&
    [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" != 1 ]; then
    if ! spawn_herdr_presentation_order_lock_acquire "${HERDR_PROJECTION_ABORT_SESSION:-}"; then
      echo "warning: herdr presentation focus lock unavailable; retaining the projection journal and refusing concurrent abort cleanup" >&2
      HERDR_PROJECTION_ABORT_CLEANUP=0
    fi
  fi
  if [ "$HERDR_PROJECTION_ABORT_CLEANUP" = 1 ]; then
    HERDR_PROJECTION_ABORT_CLEANUP=0
    fm_backend_herdr_projection_cleanup_exact \
      "$HERDR_PROJECTION_ABORT_SESSION" \
      "$HERDR_PROJECTION_ABORT_TASK_PANE" \
      "$HERDR_PROJECTION_ABORT_SEEDED_PANE" || true
  fi
  if [ "$HERDR_PRESENTATION_ORDER_LOCK_HELD" = 1 ]; then
    HERDR_PRESENTATION_ORDER_LOCK_HELD=0
    fm_lock_release "$HERDR_PRESENTATION_ORDER_LOCK" || true
  fi
  if [ "$ORCA_ABORT_CLEANUP" = 1 ]; then
    ORCA_ABORT_CLEANUP=0
    if [ -n "${ORCA_TERMINAL:-}" ]; then
      fm_backend_kill orca "$ORCA_TERMINAL" 2>/dev/null && SPAWN_ENDPOINT_CLOSED=1 || true
    fi
    if [ -n "${ORCA_WORKTREE_ID:-}" ]; then
      if ! fm_backend_remove_worktree orca "$ORCA_WORKTREE_ID" 2>/dev/null; then
        if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
          if ! spawn_fresh_commit_rollback; then
            status=1
          fi
          SPAWN_FRESH_COMMIT_PENDING=0
        fi
        mkdir -p "$STATE" 2>/dev/null || true
        if [ -d "$STATE" ]; then
          SPAWN_META_TMP="$STATE/.$ID.meta.orca-recovery.${BASHPID:-$$}"
          {
            echo "window=$W"
            echo "endpoint_task_id=$ID"
            echo "cleanup_recovery=orca"
            echo "worktree=${WT:-}"
            echo "project=$PROJ_ABS"
            echo "harness=$HARNESS"
            echo "kind=$KIND"
            [ -z "${MODE:-}" ] || echo "mode=$MODE"
            [ -z "${YOLO:-}" ] || echo "yolo=$YOLO"
            [ -z "${BRANCH:-}" ] || echo "branch=$BRANCH"
            echo "tasktmp=${TASK_TMP:-}"
            echo "model=${MODEL:-default}"
            echo "effort=${EFFORT:-default}"
            echo "backend=orca"
            echo "orca_worktree_id=$ORCA_WORKTREE_ID"
            [ -z "${ORCA_TERMINAL:-}" ] || echo "terminal=$ORCA_TERMINAL"
          } >"$SPAWN_META_TMP" 2>/dev/null &&
            fm_backlog_atomic_transition publish "$SPAWN_META_TMP" "$STATE/$ID.meta" "task record" "$STATE" ||
            true
        fi
      fi
    fi
  fi
  if [ "$SPAWN_TASK_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  if [ "$SPAWN_FRESH_COMMIT_PENDING" = 1 ]; then
    if ! spawn_fresh_commit_rollback; then
      status=1
    fi
  fi
  if [ "$SPAWN_META_LOCK_HELD" = 1 ]; then
    SPAWN_META_LOCK_HELD=0
    fm_lock_release "$SPAWN_META_LOCK" || true
  fi
  # A fresh polytoken spawn that fails and leaves no record must leave the pool
  # as it found it. Before its launch is delivered, the endpoint it opened holds nothing but
  # the shell whose `treehouse get` leases the slot, so closing it returns the
  # slot to the pool and leaves no window or tab for a retry to trip over; the
  # Firstmate wiring, task temp root, and staged launch file it wrote go with it.
  # Once a launch was delivered into an endpoint still open, a worker may be
  # running there, so those stay for the operator, as the refusal says.
  if [ "$status" -ne 0 ] && [ "${HARNESS:-}" = polytoken ] &&
    { [ "$SPAWN_FRESH_ENDPOINT_OPENED" = 1 ] || [ "$SPAWN_FRESH_WIRING_PENDING" = 1 ] ||
      [ "$SPAWN_TASK_TMP_CREATED" = 1 ] || [ -n "$SPAWN_STAGED_LAUNCH_FILE" ]; } &&
    [ "$RELAUNCH" -eq 0 ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
    if [ "$SPAWN_FRESH_ENDPOINT_OPENED" = 1 ] && [ "$SPAWN_LAUNCH_SENT" = 0 ] && [ -n "${T:-}" ]; then
      SPAWN_FRESH_ENDPOINT_OPENED=0
      local abort_tab_id=
      [ "$BACKEND" != zellij ] || abort_tab_id=${ZELLIJ_TAB_ID:-}
      if fm_backend_kill "$BACKEND" "$T" "$abort_tab_id" "fm-$ID" 2>/dev/null; then
        SPAWN_ENDPOINT_CLOSED=1
      else
        echo "warning: could not close endpoint $T after the failed spawn of $ID; close it by hand so its slot returns to the pool" >&2
      fi
    fi
    # These paths are per task id, so the per-id spawn lock is retaken for them
    # exactly as for the strip dir below: a retry of the same id that took the
    # lock meanwhile may already be reusing them.
    if { [ "$SPAWN_LAUNCH_SENT" = 0 ] || [ "$SPAWN_ENDPOINT_CLOSED" = 1 ]; } &&
      { [ "$SPAWN_FRESH_WIRING_PENDING" = 1 ] || [ "$SPAWN_TASK_TMP_CREATED" = 1 ] ||
        [ -n "$SPAWN_STAGED_LAUNCH_FILE" ]; }; then
      if fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
        if [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
          if [ "$SPAWN_FRESH_WIRING_PENDING" = 1 ] && [ -n "${WT:-}" ] && [ -n "${STATE_REAL:-}" ]; then
            SPAWN_FRESH_WIRING_PENDING=0
            clear_relaunch_harness_wiring "$HARNESS" "$WT" "$STATE_REAL" "$ID" "$KIND" ||
              echo "warning: could not remove $HARNESS wiring after the failed spawn of $ID" >&2
          fi
          if [ "$SPAWN_TASK_TMP_CREATED" = 1 ] && [ -n "${TASK_TMP:-}" ]; then
            SPAWN_TASK_TMP_CREATED=0
            rm -rf -- "$TASK_TMP" 2>/dev/null || true
          fi
          if [ -n "$SPAWN_STAGED_LAUNCH_FILE" ] && [ "${ORCA_LAUNCH_ENV_ENABLED:-0}" != 1 ]; then
            rm -f -- "$SPAWN_STAGED_LAUNCH_FILE" 2>/dev/null || true
            rmdir -- "$(dirname "$SPAWN_STAGED_LAUNCH_FILE")" 2>/dev/null || true
          fi
        fi
        fm_lock_release "$SPAWN_TASK_LOCK" || true
      else
        echo "warning: another spawn of $ID holds its spawn lock; leaving its $HARNESS wiring, temp root, and staged launch file in place" >&2
      fi
    fi
  fi
  # A spawn that aborts after claiming its slot but before its record survives
  # must not leave a claim naming a task no record describes. The release is a
  # read-then-remove, so it runs only while the project lock that wrote the
  # claim is still held (aborts before metadata publication); a later abort has
  # already released that lock and leaves the claim for the next spawn's
  # atomic replacement rather than racing it. A polytoken spawn instead retakes
  # that lock once for a later failure whose record was rolled back. The
  # release itself never removes another task's claim.
  if [ "$SPAWN_SLOT_CLAIMED" = 1 ] && [ -n "${WT:-}" ] &&
    [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ] &&
    fm_treehouse_pool_slot "$PROJ_ABS" "$WT"; then
    SPAWN_SLOT_CLAIMED=0
    if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
      fm_treehouse_slot_owner_release "$WT" "$ID" || true
    elif [ "${HARNESS:-}" = polytoken ] && [ -n "$SPAWN_TREEHOUSE_PROJECT_LOCK" ] &&
      fm_lock_try_acquire "$SPAWN_TREEHOUSE_PROJECT_LOCK"; then
      fm_treehouse_slot_owner_release "$WT" "$ID" || true
      fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK" || true
    else
      echo "warning: leaving task $ID's slot claim on $WT in place; the Treehouse project lock is no longer held, so the next spawn's claim replaces it" >&2
    fi
  fi
  if [ "$SPAWN_TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
    fm_lock_release "$SPAWN_TREEHOUSE_PROJECT_LOCK" || true
  fi
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
  fi
  if [ "$SPAWN_CONTROL_LOCK_HELD" = 1 ]; then
    SPAWN_CONTROL_LOCK_HELD=0
    fm_lock_release "$SPAWN_CONTROL_LOCK" || true
  fi
  [ -z "$SPAWN_META_TMP" ] || rm -f "$SPAWN_META_TMP" 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ "${ORCA_LAUNCH_ENV_ENABLED:-0}" = 1 ] && [ -n "$SPAWN_STAGED_LAUNCH_FILE" ]; then
    if [ "$SPAWN_LAUNCH_SENT" = 0 ] || [ "$SPAWN_ENDPOINT_CLOSED" = 1 ]; then
      rm -f -- "$SPAWN_STAGED_LAUNCH_FILE" 2>/dev/null || true
    else
      # The open terminal may still source the delivered file, and no other
      # owner is left to remove it once this spawn exits, so arbitrate exactly
      # as the consume deadline does.
      local reclaim_status=0
      spawn_orca_reclaim_launch_file || reclaim_status=$?
      case "$reclaim_status" in
        0) kimi_spawn_fail "spawn ended before Orca terminal $T ran the launch command; removed the launch file and refused the worker launch" || true ;;
        2) echo "warning: could not remove Orca launch file $SPAWN_STAGED_LAUNCH_FILE; remove it by hand" >&2 ;;
      esac
    fi
  fi
  if [ "$CONFIG_INHERIT_LOCK_HELD" = 1 ]; then
    CONFIG_INHERIT_LOCK_HELD=0
    fm_lock_release "$CONFIG_INHERIT_LOCK" || true
  fi
  # The per-id spawn lock is retaken so a concurrent spawn of the same id, which
  # reinstalls this strip dir, is never undone. A launched agent whose endpoint
  # was not closed may still be committing, so it keeps its strip.
  if [ "$status" -ne 0 ] && [ -n "$GIT_HOOKS_DIR" ] &&
    { [ "$SPAWN_LAUNCH_SENT" = 0 ] || [ "$SPAWN_ENDPOINT_CLOSED" = 1 ]; } &&
    fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
    if [ ! -e "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
      chmod u+w "$GIT_HOOKS_DIR" 2>/dev/null || true
      rm -rf "$GIT_HOOKS_DIR" 2>/dev/null || true
    fi
    fm_lock_release "$SPAWN_TASK_LOCK" || true
  fi
  return "$status"
}
