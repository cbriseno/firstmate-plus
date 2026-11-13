#!/usr/bin/env bash
# Remote secondmate spawn, sourced by fm-spawn.sh.

spawn_remote_secondmate() {
  local id=$1 remote host root home harness positional model effort backend out rc meta tmp
  local remote_backend remote_target remote_harness remote_herdr_session registry_lock remote_lock remote_generation
  local remote_traceparent remote_recorded_traceparent sm_primary_head sync_out sync_rc account_config
  local -a launch_args
  id=${POS[0]:-}
  fm_task_id_creation_valid "$id" || {
    echo "error: invalid task id" >&2
    return 2
  }
  mkdir -p "$STATE" || {
    echo "error: could not create parent state directory" >&2
    return 1
  }
  SPAWN_TASK_LOCK="$STATE/.spawn-$id.lock"
  if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
    echo "error: another spawn is already creating task $id" >&2
    return 1
  fi
  registry_lock=$(secondmate_registry_lock_path "$STATE")
  if ! fm_lock_acquire_wait "$registry_lock"; then
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: secondmate registry could not be locked for remote spawn" >&2
    return 1
  fi
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)
  if [ "$remote" != 1 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 3
  fi
  host=$(secondmate_registry_field "$DATA/secondmates.md" "$id" host)
  root=$(secondmate_registry_field "$DATA/secondmates.md" "$id" root)
  home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home)
  positional=${POS[1]:-}
  if [ "${#POS[@]}" -gt 2 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate spawn accepts no local home positional argument" >&2
    return 2
  fi
  if [ -n "$HARNESS_ARG" ]; then
    harness=$HARNESS_ARG
  elif [ -n "$positional" ]; then
    harness=$positional
  else
    harness=$("$FM_ROOT/bin/fm-harness.sh" secondmate "$id")
  fi
  case "$harness" in
  claude | codex) ;;
  *)
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate spawn requires a verified harness adapter, not a raw launch command: $harness" >&2
    return 1
    ;;
  esac
  account_config=$(fm_worker_account_config "$harness" "$CONFIG" "$id") || {
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 1
  }
  if [ "$account_config" != "$CONFIG" ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: $account_config/$(fm_worker_account_file "$harness") cannot pin remote secondmate $id from this host; configure config/$(fm_worker_account_file "$harness") in its home $home on $host instead" >&2
    return 1
  fi
  model=${MODEL:--}
  effort=${EFFORT:--}
  if [ -z "$HARNESS_ARG" ] && [ -z "$positional" ]; then
    if [ "$MODEL_SET" -eq 0 ]; then
      model=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model "$id")
      [ -n "$model" ] || model=-
    fi
    if [ "$EFFORT_SET" -eq 0 ]; then
      effort=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort "$id")
      [ -n "$effort" ] || effort=-
    fi
  fi
  # A remote second mate always runs on Herdr: its server belongs to the host's
  # own GUI login session, so the endpoint outlives every SSH connection that
  # supervises it. bin/fm-remote-doctor.sh gates that host on the same
  # requirement, and the remote home's config/backend never overrides it.
  case "${BACKEND_ARG:--}" in
  - | herdr) backend=herdr ;;
  *)
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: a remote secondmate runs only on the herdr backend, not '$BACKEND_ARG'" >&2
    return 1
    ;;
  esac
  case "$effort" in
  - | low | medium | high | xhigh | max | ultra) ;;
  *)
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: invalid configured remote secondmate effort: $effort" >&2
    return 1
    ;;
  esac
  if [ "$effort" = ultra ] && ! "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort"; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    return 1
  fi
  meta="$STATE/$id.meta"
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if ! fm_backlog_record_present "$meta" "task record" "$STATE" ||
      [ "$(fm_meta_get "$meta" kind)" != secondmate ] ||
      [ "$(fm_meta_get "$meta" remote_host)" != "$host" ] ||
      [ "$(fm_meta_get "$meta" remote_root)" != "$root" ] ||
      [ "$(fm_meta_get "$meta" home)" != "$home" ]; then
      fm_lock_release "$registry_lock" || true
      fm_lock_release "$SPAWN_TASK_LOCK" || true
      echo "error: existing metadata for $id does not identify this remote secondmate route" >&2
      return 1
    fi
  fi
  # Gate the host before anything is published or transferred, so a host that
  # cannot hold a durable Herdr endpoint refuses here rather than half-way
  # through a launch. This is also the readiness gate every liveness relaunch
  # passes through, because recovery respawns through this same route.
  rc=0
  fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    # Summary first, then the doctor's own text: a caller that reports only the
    # first line, such as the startup liveness sweep, must still say something
    # actionable.
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id readiness could not be confirmed; preserved route $host:$home" >&2
    else
      echo "error: remote secondmate $id host $host is not ready for a remote second mate; launch refused" >&2
    fi
    [ -z "$FM_REMOTE_READINESS_OUT" ] || printf '%s\n' "$FM_REMOTE_READINESS_OUT" >&2
    [ "$rc" -ne 255 ] || return 255
    return 1
  fi
  # Pre-launch sync, the remote twin of the local-HEAD sync below: this home
  # follows THIS primary's default-branch commit, not the Firstmate copy on that
  # host, so the commit is resolved here and handed over for the host to import
  # and fast-forward to. A skipped sync warns and launches the home unchanged.
  if sm_primary_head=$(primary_head_commit "$FM_ROOT"); then
    if sync_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh sync "$id" \
      "$sm_primary_head" </dev/null 2>&1); then
      :
    else
      sync_rc=$?
      echo "warning: remote secondmate $id sync skipped before launch: $(remote_sync_failure_reason "$sync_rc" "$sync_out")" >&2
    fi
  else
    echo "warning: remote secondmate $id sync skipped before launch: primary default-branch commit cannot be resolved" >&2
  fi
  remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id")
  if ! fm_lock_acquire_wait "$remote_lock"; then
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id inheritance transaction could not be locked" >&2
    return 1
  fi
  remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
  if [ -z "$remote_generation" ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id inheritance generation could not be published" >&2
    return 1
  fi
  if "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$id" "$remote_generation" >/dev/null; then
    :
  else
    rc=$?
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id inheritance completion is unknown; launch refused and route preserved for reconciliation" >&2
    else
      echo "error: remote secondmate $id inheritance failed; launch refused" >&2
    fi
    return "$rc"
  fi
  # This parent home owns the remote secondmate's task identity because it holds
  # the task metadata an observer reads, exactly as for a local spawn: the
  # carrier is resolved against THIS task's own meta (reused verbatim on
  # relaunch, freshly rooted otherwise, never adopting this process's ambient
  # TRACEPARENT) under this home's frozen decision, then handed to the remote
  # host to export into the agent's pane. Disabled resolves to empty and the
  # remote launch call stays byte-identical to the untraced one.
  remote_traceparent=
  if [ "$(fm_trace_context_session_effective "$STATE/.trace-context-effective")" = on ]; then
    remote_traceparent=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CONFIG" "$meta" || true)
  fi
  launch_args=("$id" "$harness" "$model" "$effort" "$backend")
  [ -z "$remote_traceparent" ] || launch_args+=("$remote_traceparent")
  if out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh launch \
    "${launch_args[@]}" </dev/null 2>&1); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    if [ "$rc" -eq 255 ]; then
      echo "error: remote secondmate $id is unavailable or launch completion is unknown; preserved route $host:$home" >&2
    fi
    return "$rc"
  fi
  remote_backend=$(printf '%s\n' "$out" | sed -n 's/^backend=//p' | tail -1)
  remote_target=$(printf '%s\n' "$out" | sed -n 's/^target=//p' | tail -1)
  remote_harness=$(printf '%s\n' "$out" | sed -n 's/^harness=//p' | tail -1)
  remote_herdr_session=$(printf '%s\n' "$out" | sed -n 's/^herdr_session=//p' | tail -1)
  if [ "$remote_backend" != herdr ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned backend '${remote_backend:-missing}', expected herdr; preserving the remote route for reconciliation" >&2
    return 1
  fi
  [ -n "$remote_target" ] && [ "$remote_harness" = "$harness" ] || {
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned malformed route metadata; preserving the remote route for reconciliation" >&2
    return 1
  }
  if [ "$remote_herdr_session" != fm-remote ] || [ "${remote_target%%:*}" != "$remote_herdr_session" ]; then
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote launch returned Herdr session '${remote_herdr_session:-missing}', expected 'fm-remote'; preserving the remote route for reconciliation" >&2
    return 1
  fi
  # Record what the remote endpoint ACTUALLY carries, read back from its own
  # launch, rather than what this side hoped to deliver. That keeps the #995
  # guarantee that the recorded carrier is the identity the child received even
  # when the remote host already had a live agent and reused its endpoint. An
  # off decision delivers no carrier, but an endpoint already holding one still
  # reports it here so the parent does not deny the agent's actual identity.
  remote_recorded_traceparent=$(printf '%s\n' "$out" | sed -n 's/^traceparent=//p' | tail -1)
  fm_trace_context_valid "$remote_recorded_traceparent" || remote_recorded_traceparent=
  tmp="$meta.tmp.$$"
  {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$home"
    echo "project=$root"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "tasktmp="
    echo "model=${model#-}"
    echo "effort=${effort#-}"
    echo "home=$home"
    echo "projects=$(secondmate_registry_field "$DATA/secondmates.md" "$id" projects)"
    echo "remote_host=$host"
    echo "remote_root=$root"
    echo "remote_backend=$remote_backend"
    echo "remote_herdr_session=$remote_herdr_session"
    echo "remote_target=$remote_target"
    [ -z "$remote_recorded_traceparent" ] || echo "traceparent=$remote_recorded_traceparent"
  } >"$tmp"
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
      SPAWN_TASK_SET_LOCK_HELD=0
      fm_lock_release "$SPAWN_TASK_SET_LOCK" || true
    fi
    fm_lock_release "$remote_lock" || true
    fm_lock_release "$registry_lock" || true
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: remote secondmate $id launched, but its task record could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    return 1
  fi
  if [ "$SPAWN_TASK_SET_LOCK_HELD" = 1 ]; then
    SPAWN_TASK_SET_LOCK_HELD=0
    fm_lock_release "$SPAWN_TASK_SET_LOCK"
  fi
  fm_lock_release "$remote_lock" || true
  fm_lock_release "$registry_lock" || true
  fm_lock_release "$SPAWN_TASK_LOCK" || true
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort || true
  if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$id" >/dev/null; then
    echo "error: remote secondmate $id launched, but its reply source could not be armed; endpoint metadata is preserved" >&2
    return 1
  fi
  [ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" dispatched "$id" secondmate "" "$harness" "${model#-}" || true
  echo "spawned $id harness=$harness kind=secondmate mode=secondmate yolo=off window=remote:$id worktree=$home remote=$host backend=$remote_backend"
  return 0
}
