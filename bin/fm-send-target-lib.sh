#!/usr/bin/env bash
# Target resolution and key helpers shared by fm-send.
# Inputs and result variables belong to the sourcing sender.
# shellcheck disable=SC2034,SC2153

fm_send_id_from_meta() { # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

# fm_send_clear_after_interrupt: muse RESTORES the interrupted prompt back into
# the composer when Escape cancels a turn, as real bright text (verified: fg
# 38;2;204;211;219, luminance ~210, muse 0.1.0-R708.1), not de-emphasised ghost
# text. Classifying that as pending input is correct - the text really is
# unsubmitted - but leaving it there means the NEXT steer types onto the end of
# it and submits both as one garbled message. Ctrl-U clears the composer
# (verified), so the interrupt is not complete until it has been sent. A failed
# clear is loud rather than silent, because the alternative is a corrupted steer.
# WHICH adapters need that clear, and which key clears them, comes from the one
# control-plane capability table (bin/fm-control-lib.sh) rather than a second
# copy here - the same table bin/fm-control.sh's interrupt verb reads.
fm_send_clear_after_interrupt() { # <key>
  local key=$1 family clear
  [ "$key" = Escape ] || return 0
  family=$(fm_control_harness_family "$TARGET_HARNESS") || return 0
  clear=$(fm_control_interrupt_clear_key "$family") || return 0
  [ -n "$clear" ] || return 0
  [ "$TARGET_BACKEND" != remote ] || return 0
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$clear" "$EXPECTED_LABEL"; then
    echo "error: Escape reached $T, but the $TARGET_HARNESS composer could not be cleared; it still holds the restored prompt. Clear it before sending the next message." >&2
    return 1
  fi
}

fm_send_normalize_key() { # <key>
  case "$1" in
  Escape | escape | Esc | esc) printf '%s' Escape ;;
  *) printf '%s' "$1" ;;
  esac
}

fm_send_record_interrupt() { # <key>
  local key=$1 id gen
  [ "$key" = Escape ] || return 0
  case "$TARGET_HARNESS" in claude*) : ;; *) return 0 ;; esac
  [ -n "$TARGET_META" ] || return 0
  id=$(fm_send_id_from_meta "$TARGET_META")
  [ -f "$STATE/$id.busy-gen" ] || return 0
  gen=$(fm_meta_get "$TARGET_META" busy_gen)
  if [ -n "$gen" ]; then
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --gen "$gen" --source fm-interrupt --event interrupt
  else
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --current-gen --source fm-interrupt --event interrupt
  fi || {
    echo "error: key '$key' reached $T, but the Claude interrupt state could not be recorded for $id" >&2
    return 1
  }
}

fm_send_meta_for_key_value() { # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() { # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $((${#s} - ${#no_colons}))
}

fm_send_resolve_target() { # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  TARGET_REMOTE_ID=""
  TARGET_REMOTE_HOST=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      id=$(fm_send_id_from_meta "$meta")
      RESOLVED_TARGET="remote:$id"
      TARGET_BACKEND=remote
      TARGET_META=$meta
      TARGET_HARNESS=$(fm_meta_get "$meta" harness)
      EXPECTED_LABEL="fm-$id"
      TARGET_SELECTOR=1
      TARGET_REMOTE_ID=$id
      TARGET_REMOTE_HOST=$(fm_meta_get "$meta" remote_host)
      RESOLUTION_TRIED="meta=$meta; placement=remote"
      return 0
    fi
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
  fm-*:*)
    # A named Herdr session may itself begin with "fm-". Keep that explicit
    # session:pane target on the validated backend-target path below rather
    # than mistaking it for an unresolved task selector.
    ;;
  fm-*)
    RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
    echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
    return 1
    ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
  *:*)
    colons=$(fm_send_count_colons "$raw")
    if [ "$colons" -ge 2 ]; then
      assumed=herdr
    else
      assumed=tmux
    fi
    if ! fm_backend_target_exists "$assumed" "$raw"; then
      echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
      return 1
    fi
    RESOLVED_TARGET=$raw
    TARGET_BACKEND=$assumed
    RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
    return 0
    ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}
