#!/usr/bin/env bash
# Shared deadline for a condition that an actor must resolve, not merely acknowledge.
# The caller observes the condition on every probe and clears it when resolved.
# STATE and CONFIG name the installation; watch_event_append and wake deliver it.

fm_obligation_observe() {  # <key> <category> <identity> <reason> [<prior-observation-file>]
  local key=$1 category=$2 identity=$3 reason=$4 prior=${5:-} period now file first last old elapsed message seed
  case "$key" in ''|*[!a-zA-Z0-9_.-]*) return 1 ;; esac
  period=${FM_OBLIGATION_SECONDS:-}
  if [ -z "$period" ] && [ -f "$CONFIG/obligation-seconds" ]; then
    period=$(cat "$CONFIG/obligation-seconds")
  fi
  case "$period" in ''|*[!0-9]*|0) period=900 ;; esac
  now=$(fm_platform_epoch) || return 1
  file="$STATE/.obligation-$key"
  first=; last=; old=
  if [ -f "$file" ]; then
    { IFS= read -r first; IFS= read -r last; IFS= read -r old; } < "$file" || true
  fi
  case "$first" in ''|*[!0-9]*) first= ;; esac
  case "$last" in ''|*[!0-9]*) first= ;; esac
  if [ -z "$first" ]; then
    seed=$now
    if [ -n "$prior" ] && [ -f "$prior" ] && [ ! -L "$prior" ]; then
      seed=$(fm_platform_mtime "$prior" 2>/dev/null) || seed=$now
      case "$seed" in ''|*[!0-9]*) seed=$now ;; esac
      [ "$seed" -le "$now" ] || seed=$now
    fi
    first=$seed; last=$seed
    printf '%s\n%s\n%s\n' "$first" "$last" "$identity" > "$file" || return 1
  elif [ "$old" != "$identity" ] || [ "$now" -lt "$last" ]; then
    printf '%s\n%s\n%s\n' "$now" "$now" "$identity" > "$file" || return 1
    return 0
  fi
  [ "$((now - last))" -ge "$period" ] || return 0
  elapsed=$(((now - first) / 60))
  message="check: still unattended for ${elapsed} min: $reason"
  watch_event_append check "obligation:$key" "$message" || return 1
  printf '%s\n%s\n%s\n' "$first" "$now" "$identity" > "$file" || return 1
  if declare -F fm_diag_emit >/dev/null; then fm_diag_emit obligation.overdue "category=$category" "obligation=$key" || true; fi
  wake "$message"
}

fm_obligation_clear() {  # <key>
  case "$1" in ''|*[!a-zA-Z0-9_.-]*) return 1 ;; esac
  [ -e "$STATE/.obligation-$1" ] || [ -L "$STATE/.obligation-$1" ] || return 0
  rm -f -- "$STATE/.obligation-$1"
}
