#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|pi|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate [id]  print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed. With a
#                                        secondmate id, a "mate <id>:" override line wins
#                                        over the default line.
#        fm-harness.sh secondmate-model [id]
#                                        print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#                                        An id selects that mate's override line first.
#        fm-harness.sh secondmate-effort [id]
#                                        print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
#                                        An id selects that mate's override line first.
#        fm-harness.sh validate-native-effort <harness> <model> <effort>
#                                        Refuse ultra unless the harness is pi or
#                                        and the model explicitly names
#                                        codex-native/<id>. Other efforts retain
#                                        their adapter's existing policy. Native
#                                        Codex validates model support at startup.
#        fm-harness.sh ancestry [<pid>] print "<strength> <harness>" for the nearest
#                                        harness process at or above <pid> (default this
#                                        process), or nothing when the walk finds none.
#                                        Ancestry evidence only, with no marker layer, so
#                                        a real harness process can be asked what the walk
#                                        makes of it (tests/fm-harness-liveness-drift-live-e2e.test.sh).
#        fm-harness.sh ancestry-descent [<pid>] [<leaf-pid>...]
#                                        print each DISTINCT "<strength> <harness>" the walk
#                                        reaches from the vantages on the UPWARD path
#                                        between the deepest descendant of <pid> and <pid>
#                                        itself, deepest first. Same evidence-only purpose
#                                        as `ancestry`, asked from the vantage point a tool
#                                        subprocess actually occupies rather than from the
#                                        top of the session, which is the only place a
#                                        harness behind an interpreter shim can be seen at
#                                        comm strength. Optional <leaf-pid> values restrict
#                                        which descendants may be chosen as the deepest one,
#                                        so a caller that knows the terminal's foreground
#                                        process group can keep a backgrounded process out
#                                        of the selection.
# docs/configuration.md "Choose the secondmate harness" owns the pin-file schema
# and resolution contract; the usage above owns the resolver command arguments.
# Detection evidence and precedence:
#   Markers  - verified environment variables a harness publishes about itself.
#              Cheap and unambiguous about WHICH harness set them, but they are
#              ordinary environment state: a child inherits them, and a terminal
#              multiplexer can replay a stale one into an unrelated session.
#   Ancestry - the nearest harness process in this process's parent chain. This
#              is the structural fact about who actually owns the process tree,
#              so it is what settles a disagreement.
# detect_own is the single owner of how the two combine; harness_marker and
# harness_ancestry only report evidence. Record each newly verified env marker
# in harness_marker, and each newly verified command name in harness_ancestry.
# Supervision-branch primary pin: a supervision branch running as its own
# process under another harness (a Pi engine under a Claude primary detects as
# pi) would otherwise resolve "own" - and with it an absent or "default"
# config/crew-harness or config/secondmate-harness - to its own harness and
# dispatch crew there. While FM_SUPERVISION_ACTOR=branch, a non-empty
# FM_SUPERVISION_PRIMARY_HARNESS names the primary's harness and replaces
# detection for the own, crew, and secondmate resolutions; a value that names
# no known harness refuses (exit 2, nothing on stdout) instead of resolving.
# Outside the branch actor the pin is ignored, and the evidence-only ancestry
# verbs never consult it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"


# Print the harness named by a verified environment marker, or nothing when no
# marker is present. Markers only report what the environment CLAIMS; detect_own
# decides whether that claim survives contradicting ancestry.
harness_marker() {
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    echo pi
    return
  fi
  # codex, opencode, and kimi publish no harness-identity marker at all, so
  # they are never named here and are identified by ancestry alone. That is the
  # whole reason a foreign marker must not outrank ancestry: with markers winning
  # unconditionally, any retained CLAUDECODE would silently rename one of them.
  return 0
}

# Print "<strength> <harness>" when one process identifies a harness, or nothing.
# Strength records how the match was made:
#   comm - the ancestor's own executable name identifies the harness. This is a
#          structural fact about the running program, so it outranks a marker.
#   args - a bare interpreter matched only because a harness name appears in the
#          script path it was handed. This is the weakest inference in this file
#          (any node process holding a harness-shaped path matches it), so it is
#          used only when no marker is present.
harness_process_verdict() {  # <pid>
  local pid=$1 comm args argv0
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  case "$(basename -- "$comm")" in
    *claude*) echo "comm claude"; return ;;
    *codex*) echo "comm codex"; return ;;
    # Both Pi identities share this launcher name. Ancestry can only prove the
    # FAMILY; only the launch-boundary marker selects the signed identity, which
    # is why detect_own keeps a marker that agrees on the family.
    pi) echo "comm pi"; return ;;
    node*|python*)
      # Bare interpreter: match the harness name in its script path.
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      case "$args" in
        *claude*) echo "args claude"; return ;;
        *codex*) echo "args codex"; return ;;
        *" pi "*|*/pi) echo "args pi"; return ;;
      esac ;;
  esac
}

# Print the verdict for the NEAREST harness process in the parent chain, or
# nothing when the walk finds none. The nearest match wins, so a worker nested
# inside another harness resolves to its own harness. The walk reaches sixteen
# parents, as the session-lock walk does: a Codex SessionStart hook puts codex
# nine parents above session start's probe (login shell, run wrapper, the
# timeout stage, and a command substitution).
harness_ancestry() {  # [<pid>]
  local pid=${1:-$$} verdict
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    verdict=$(harness_process_verdict "$pid")
    [ -z "$verdict" ] || { echo "$verdict"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Stop only once the walk has EXAMINED the top of the chain. Inside a PID
    # namespace the harness itself is pid 1 - a container, or the `codex sandbox`
    # this boundary was proven in - so breaking as soon as the next pid is 1
    # skips the one process that identifies the session and hands the verdict
    # straight back to a retained marker. A host's real pid 1 (init, systemd,
    # launchd) matches no harness name above, so examining it costs one ps call
    # and can introduce no false positive.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  return 0
}

# Print the pids on the UPWARD path between the deepest descendant of <root> and
# <root> itself, deepest first. Optional <eligible-leaf-pid> values restrict which
# descendants may be chosen as that deepest one; with none given every descendant
# is eligible. Bounded to its own eight levels of descent, so a deep or
# pathological tree cannot make this walk unbounded.
process_descent_path() {  # <root> [<eligible-leaf-pid>...]
  local root=${1:-$$} eligible any hit pairs frontier next pid child parent verdict
  local parents='' depth=0 best best_depth=0 best_strength='' hops=0
  case "$root" in '' | *[!0-9]*) return 0 ;; esac
  shift 2>/dev/null || true
  eligible=" ${*+$*} "
  any=0
  [ "$#" -eq 0 ] && any=1
  pairs=$(ps -eo pid=,ppid= 2>/dev/null) || { printf '%s\n' "$root"; return 0; }
  best=$root
  frontier=$root
  while [ -n "$frontier" ] && [ "$depth" -lt 8 ]; do
    next=
    for pid in $frontier; do
      while read -r child parent; do
        [ "$parent" = "$pid" ] || continue
        [ "$child" != "$pid" ] || continue
        parents="$parents $child:$pid"
        next="$next $child"
        if [ "$any" = 1 ]; then
          hit=1
        else
          case "$eligible" in
            *" $child "*) hit=1 ;;
            *) hit=0 ;;
          esac
        fi
        if [ "$hit" = 1 ]; then
          verdict=$(harness_process_verdict "$child")
          if [ $((depth + 1)) -gt "$best_depth" ]; then
            best=$child
            best_depth=$((depth + 1))
            best_strength=${verdict%% *}
          # At equal depth, prefer the leaf whose own executable reaches comm
          # strength. Otherwise an earlier MCP interpreter carrying a foreign
          # harness path can hide a native harness sibling purely through ps
          # ordering. This repairs the chosen path's comm-strength guarantee;
          # args-strength foreign verdicts remain excluded from cross-checking.
          elif [ $((depth + 1)) -eq "$best_depth" ] \
            && [ "$best_strength" != comm ] && [ "${verdict%% *}" = comm ]; then
            best=$child
            best_strength='comm'
          fi
        fi
      done <<EOF
$pairs
EOF
    done
    frontier=$next
    depth=$((depth + 1))
  done

  pid=$best
  while [ -n "$pid" ] && [ "$hops" -le 8 ]; do
    printf '%s\n' "$pid"
    [ "$pid" != "$root" ] || break
    parent=
    case "$parents" in
      *" $pid:"*)
        parent=${parents##*" $pid:"}
        parent=${parent%% *} ;;
    esac
    pid=$parent
    hops=$((hops + 1))
  done
}

# Print each DISTINCT "<strength> <harness>" verdict harness_ancestry reaches from
# the vantages on the upward path between the deepest descendant of <root> and
# <root>, one per line, deepest first.
#
# Why a descent path and not <root> alone: detect_own always runs from a TOOL
# SUBPROCESS inside a session, never from the process at the top of it, and that
# difference decides whether a retained foreign marker can rename the session. A
# harness that ships as an interpreter shim spawning its native binary as a CHILD
# is only args strength when asked from the shim, and detect_own hands an
# args-strength verdict straight back to the marker; the native child is comm
# strength and outranks it. Asking from below is what puts the question at the
# vantage point a real session uses, so a guard built on this can assert the
# strength the shipped guarantee actually depends on
# (tests/fm-harness-liveness-drift-live-e2e.test.sh).
#
# Why the upward path and not the whole subtree: harness_ancestry only ever climbs,
# so a SIBLING branch is a vantage firstmate's own detection can never occupy. A
# harness-spawned MCP server running as `node <home>/.claude/mcp/<server>.js` matches
# *claude* on its script path in the bare-interpreter branch above and would report a
# foreign harness from a process no real tool subprocess ever asks from.
harness_ancestry_descent() {  # <root> [<eligible-leaf-pid>...]
  local pid verdict seen=
  for pid in $(process_descent_path "$@"); do
    verdict=$(harness_ancestry "$pid")
    [ -n "$verdict" ] || continue
    case "$seen" in *"|$verdict|"*) continue ;; esac
    seen="$seen|$verdict|"
    printf '%s\n' "$verdict"
  done
}

# Collapse a verdict to the harness FAMILY its evidence can actually prove, so a
# marker's more specific verdict and ancestry's coarser one are not read as a
# disagreement. Only Pi has two identities behind one launcher name.
harness_family() {
  case "$1" in
    *) printf '%s\n' "$1" ;;
  esac
}

# Print the supervision-branch primary pin when it applies (header), or
# nothing. Returns 2, with the reason on stderr, for a pin naming no harness.
supervision_primary_pin() {
  local pin=${FM_SUPERVISION_PRIMARY_HARNESS:-}
  [ "${FM_SUPERVISION_ACTOR:-}" = branch ] && [ -n "$pin" ] || return 0
  case "$pin" in
    claude|codex|pi)
      printf '%s\n' "$pin"
      ;;
    *)
      echo "error: FM_SUPERVISION_PRIMARY_HARNESS='$pin' names no known harness; refusing to resolve the supervision branch's harness" >&2
      return 2
      ;;
  esac
}

# Combine the two evidence layers. The precedence boundary, in one rule: a
# marker names its harness, but only ancestry proves which harness owns this
# process tree, so a structural (comm) ancestor of a DIFFERENT harness wins.
#   - No ancestry match: the marker is the only evidence there is.
#   - No marker: ancestry is the only evidence there is.
#   - Same family: keep the marker's verdict, which is the more specific one
#     (pi-signed, which ancestry can only see as pi).
#   - Different harness, structural ancestor: ancestry wins. This is what stops
#     an inherited or multiplexer-retained CLAUDECODE from renaming a markerless
#     codex, opencode, kimi, or session, and symmetrically stops a retained
#     CURSOR_AGENT from renaming a claude worker nested under cursor.
#   - Different harness, interpreter-args ancestor only: the marker wins, because
#     a harness-shaped path in some node process's arguments is weaker evidence
#     than a harness publishing its own identity.
# The supervision-branch primary pin, when it applies, answers before either
# evidence layer is read.
detect_own() {
  local marker ancestry strength harness pin
  pin=$(supervision_primary_pin) || exit 2
  [ -z "$pin" ] || { echo "$pin"; return; }
  marker=$(harness_marker)
  ancestry=$(harness_ancestry)
  if [ -z "$ancestry" ]; then
    if [ -n "$marker" ]; then echo "$marker"; else echo unknown; fi
    return
  fi
  strength=${ancestry%% *}
  harness=${ancestry#* }
  [ -n "$marker" ] || { echo "$harness"; return; }
  if [ "$(harness_family "$marker")" = "$(harness_family "$harness")" ]; then
    echo "$marker"
    return
  fi
  if [ "$strength" = comm ]; then echo "$harness"; else echo "$marker"; fi
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Preserve first-line-wins parsing unless the file declares a mate override.
# A file that declares no "mate <secondmate-id>:" line is read exactly as it
# was before this grammar existed: the first non-empty, non-comment line
# supplies the default, later lines and extra tokens are ignored, and nothing
# is refused. A file that does declare an override validates completely before
# selecting a mate, so an invalid override cannot silently migrate that mate
# onto the default runtime.
# Fills SM_DEFAULT_LINE and the parallel SM_MATE_IDS, SM_MATE_VALS and
# SM_MATE_LINES arrays for the reader below.
secondmate_parse() {
  local file="$CONFIG/secondmate-harness"
  SM_DEFAULT_LINE=
  SM_DEFAULT_LINE_NUM=
  SM_MATE_IDS=()
  SM_MATE_VALS=()
  SM_MATE_LINES=()
  [ -f "$file" ] || return 0
  local line num=0 id rest i ntok
  local override_pattern='^mate[[:space:]]+([^:[:space:]]+)[[:space:]]*:[[:space:]]*(.*)$'
  # First pass: the legacy default line, and whether the file declares any
  # override at all. A file that declares none stops here, so a home that never
  # wrote an override keeps the legacy parse byte for byte.
  local legacy_line='' legacy_num=0 declares_override=0
  while IFS= read -r line || [ -n "$line" ]; do
    num=$((num + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    if [ -z "$legacy_line" ]; then legacy_line=$line; legacy_num=$num; fi
    if [[ "$line" =~ $override_pattern ]]; then
      declares_override=1
      break
    fi
  done < "$file"
  if [ "$declares_override" -eq 0 ]; then
    SM_DEFAULT_LINE=$legacy_line
    SM_DEFAULT_LINE_NUM=$legacy_num
    return 0
  fi
  # Second pass: a file that declares an override. Every line is validated
  # before any mate is selected, so an invalid override is never skipped in
  # favor of the default runtime.
  num=0
  while IFS= read -r line || [ -n "$line" ]; do
    num=$((num + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    if [[ "$line" =~ $override_pattern ]]; then
      id=${BASH_REMATCH[1]}
      rest=${BASH_REMATCH[2]}
      if [[ ! "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "error: config/secondmate-harness line $num: 'mate $id:' names an invalid secondmate id (letters, digits, dot, underscore, hyphen)" >&2
        return 1
      fi
      for i in "${!SM_MATE_IDS[@]}"; do
        if [ "${SM_MATE_IDS[$i]}" = "$id" ]; then
          echo "error: config/secondmate-harness line $num: duplicate 'mate $id:' override (already set on line ${SM_MATE_LINES[$i]})" >&2
          return 1
        fi
      done
      ntok=$(printf '%s\n' "$rest" | wc -w)
      if [ "$ntok" -lt 1 ] || [ "$ntok" -gt 3 ]; then
        echo "error: config/secondmate-harness line $num: 'mate $id:' needs '<harness> [<model>] [<effort>]' after the colon" >&2
        return 1
      fi
      # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the override into fields
      set -- $rest
      SM_MATE_IDS+=("$id")
      SM_MATE_VALS+=("$*")
      SM_MATE_LINES+=("$num")
      continue
    fi
    case "$line" in
      mate|mate[[:space:]]*|mate:*)
        echo "error: config/secondmate-harness line $num: malformed 'mate <secondmate-id>: ...' override" >&2
        return 1 ;;
    esac
    if [ -n "$SM_DEFAULT_LINE" ]; then
      echo "error: config/secondmate-harness line $num: '$line' is neither the default line (already set on line $SM_DEFAULT_LINE_NUM) nor a 'mate <secondmate-id>: ...' override" >&2
      return 1
    fi
    ntok=$(printf '%s\n' "$line" | wc -w)
    if [ "$ntok" -gt 3 ]; then
      echo "error: config/secondmate-harness line $num: the default line takes '<harness> [<model>] [<effort>]', not $ntok tokens" >&2
      return 1
    fi
    SM_DEFAULT_LINE=$line
    SM_DEFAULT_LINE_NUM=$num
  done < "$file"
}

# Echo the line that governs a secondmate id: its "mate <id>:" override when the
# file names one, otherwise the file's default line. Nothing is echoed when the
# file is absent or holds neither. A malformed override file errors on every
# read path, whether or not an id was passed, so the refusal never depends on
# the caller asking about the right mate. A file that declares no override is
# never malformed here: it keeps the legacy first-line parse.
secondmate_line() {
  local id=${1:-} i
  secondmate_parse || return 1
  if [ -n "$id" ]; then
    for i in "${!SM_MATE_IDS[@]}"; do
      if [ "${SM_MATE_IDS[$i]}" = "$id" ]; then
        printf '%s\n' "${SM_MATE_VALS[$i]}"
        return 0
      fi
    done
  fi
  if [ -n "$SM_DEFAULT_LINE" ]; then
    printf '%s\n' "$SM_DEFAULT_LINE"
  fi
  return 0
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
# The optional second argument is the secondmate id whose override wins.
secondmate_field() {
  local idx=$1 id=${2:-} line
  line=$(secondmate_line "$id") || return 1
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
# An override line for the passed id replaces the default line outright.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1 "${1:-}") || return 1
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then sm=$(resolve_crew) || exit; fi
  echo "$sm"
}

# Print the optional model token (2nd field) for a secondmate id, or empty when
# the resolved line is harness-only (the older format, so still empty) or when
# its harness token defers to the crew chain.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1 "${1:-}") || return 1
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2 "${1:-}"
}

# Print the optional effort token (3rd field) for a secondmate id, the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1 "${1:-}") || return 1
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3 "${1:-}"
}

validate_native_effort() {
  local harness=${1:-} model=${2:-} effort=${3:-}
  [ "$effort" = ultra ] || return 0
  case "$harness" in
    pi)
      case "$model" in codex-native/?*) return 0 ;; esac
      ;;
  esac
  echo "error: ultra effort requires pi or with an explicit codex-native/<model> model" >&2
  return 1
}

case "${1:-}" in
  validate-native-effort) shift; validate_native_effort "$@" ;;
  ancestry)
    case "${2:-}" in
      ''|*[!0-9]*) [ -z "${2:-}" ] || { echo "error: ancestry takes a numeric pid" >&2; exit 2; } ;;
    esac
    harness_ancestry "${2:-$$}"
    ;;
  ancestry-descent)
    shift
    for arg in ${1+"$@"}; do
      case "$arg" in
        ''|*[!0-9]*) echo "error: ancestry-descent takes numeric pids" >&2; exit 2 ;;
      esac
    done
    descent_pid="${1:-$$}"
    [ "$#" -eq 0 ] || shift
    harness_ancestry_descent "$descent_pid" ${1+"$@"}
    ;;
  crew) resolve_crew ;;
  secondmate) resolve_secondmate "${2:-}" ;;
  secondmate-model) resolve_secondmate_model "${2:-}" ;;
  secondmate-effort) resolve_secondmate_effort "${2:-}" ;;
  *) detect_own ;;
esac
