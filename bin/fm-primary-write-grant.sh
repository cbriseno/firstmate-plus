#!/usr/bin/env bash
# fm-primary-write-grant.sh - record a captain-approved direct write for the
# firstmate primary, so bin/fm-primary-write-pretool-check.sh lets it through.
#
# The primary write guard refuses every direct write outside the home's private
# operational paths, including project clones. AGENTS.md hard rule 1 keeps one
# narrow exception: a concrete project operation the captain approved in the
# moment, which firstmate then performs with its own tools. This script is how
# that approval becomes visible to the guard. A grant names one path, quotes the
# captain's approval, and expires on its own; the guard allows writes inside
# that path only while the grant is live.
#
# A grant can never reach the captain's personal environment or shared tracked
# material. The only grantable targets are:
#   - a path below the effective projects directory (a clone or a future clone
#     for project add, create, or removal intake); and
#   - an untracked path inside the home's own checkout (FM_HOME or the code
#     root), or that checkout's repository-local exclude file, for firstmate-
#     owned local material such as a stow-approved local skill or home-local
#     harness settings.
# Everything else - dotfiles, user configuration, installed tools, any path
# outside the home, and every tracked file - is delegated to a worker instead,
# and this script refuses it.
# docs/primary-write-guard.md owns the guard contract and its carve-outs.
#
# Usage:
#   fm-primary-write-grant.sh grant <path> --approval <captain's words> [--minutes <1-240>]
#   fm-primary-write-grant.sh revoke <path>
#   fm-primary-write-grant.sh revoke --all
#   fm-primary-write-grant.sh list
#   fm-primary-write-grant.sh active
#
# `grant` records or refreshes the grant for <path> (relative paths resolve
# against the caller's working directory) with a default lifetime of 30
# minutes. --approval must carry the captain's own words for this operation;
# it is stored on one line so the record shows what was approved.
# `revoke` removes a grant early; revoke grants as soon as the operation ends.
# `list` prints `<path>\t<expires-epoch>\t<approval>` for live grants.
# `active` prints only live grant paths, one per line, for the guard.
#
# Records live under the effective state directory in primary-write-grants/,
# one `<key>.grant` file per path with path=, granted=, expires=, and approval=
# lines. The guard refuses direct writes into that directory, so a grant is only
# ever created through this script. Expired records are ignored and pruned on
# the next grant or revoke.
#
# Exit status: 0 on success, 1 on a refused or failed request, 2 on bad usage.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
PROJECTS=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}
GRANT_DIR="$STATE/primary-write-grants"
DEFAULT_MINUTES=30
MAX_MINUTES=240

usage() {
  cat <<'EOF'
Usage:
  fm-primary-write-grant.sh grant <path> --approval <captain's words> [--minutes <1-240>]
  fm-primary-write-grant.sh revoke <path>
  fm-primary-write-grant.sh revoke --all
  fm-primary-write-grant.sh list
  fm-primary-write-grant.sh active

Records a captain-approved direct write for the firstmate primary so the
primary write guard allows writes inside <path> until the grant expires
(default 30 minutes). Grantable: a path below the projects directory, or an
untracked path inside the home's own checkout. Never the captain's personal
environment, a path outside the home, or a tracked file: delegate those.
EOF
}

die() {
  printf 'fm-primary-write-grant: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Absolute, lexically normalized path without requiring it to exist, with the
# deepest existing ancestor resolved through symlinks.
normalize_path() {
  local input=$1 dir rest=""
  case "$input" in
    /*) ;;
    *) input="$PWD/$input" ;;
  esac
  dir=$input
  while [ ! -d "$dir" ]; do
    rest="/${dir##*/}$rest"
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  [ "$dir" = / ] && dir=""
  # Collapse ./ and ../ in the nonexistent remainder.
  local part out="" parts=()
  IFS=/ read -r -a parts <<< "${dir#/}${rest}"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  printf '%s\n' "${out:-/}"
}

within() {  # <path> <root>
  [ "$1" = "$2" ] || case "$1" in "$2"/*) return 0 ;; *) return 1 ;; esac
}

# Return 0 when <path> is grantable, printing the refusal reason otherwise.
grantable() {
  local target=$1 projects home root exclude tracked
  projects=$(normalize_path "$PROJECTS") || projects=""
  if [ -n "$projects" ] && within "$projects" "$target"; then
    echo "a grant cannot cover the whole projects directory; name one project"
    return 1
  fi
  if [ -n "$projects" ] && within "$target" "$projects"; then
    return 0
  fi
  for home in "$FM_HOME" "$FM_ROOT"; do
    root=$(normalize_path "$home") || continue
    exclude=$(git -C "$root" rev-parse --git-path info/exclude 2>/dev/null) || exclude=""
    case "$exclude" in ''|/*) ;; *) exclude="$root/$exclude" ;; esac
    if [ -n "$exclude" ] && [ "$target" = "$(normalize_path "$exclude")" ]; then
      return 0
    fi
    within "$target" "$root" || continue
    [ "$target" != "$root" ] || { echo "the whole home checkout cannot be granted"; return 1; }
    case "$target" in
      "$root"/.git|"$root"/.git/*) echo "a path inside the home's .git directory cannot be granted"; return 1 ;;
    esac
    tracked=$(git -C "$root" ls-files -- "$target" 2>/dev/null | head -n 1)
    if [ -n "$tracked" ]; then
      echo "$target holds tracked shared material; delegate that change to a worker"
      return 1
    fi
    return 0
  done
  echo "$target is outside the projects directory and the home checkout; delegate that change to a worker"
  return 1
}

grant_key() {
  local sum
  sum=$(printf '%s' "$1" | cksum | awk '{print $1}')
  printf '%s\n' "$sum"
}

record_field() {  # <file> <name>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# Print `<path>\t<expires>\t<approval>` for every live, well-formed record.
live_records() {
  local now file target expires approval
  now=$(date +%s)
  [ -d "$GRANT_DIR" ] || return 0
  for file in "$GRANT_DIR"/*.grant; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    target=$(record_field "$file" path)
    expires=$(record_field "$file" expires)
    approval=$(record_field "$file" approval)
    case "$target" in /*) ;; *) continue ;; esac
    case "$expires" in ''|*[!0-9]*) continue ;; esac
    [ "$expires" -gt "$now" ] || continue
    printf '%s\t%s\t%s\n' "$target" "$expires" "$approval"
  done
}

prune_expired() {
  local now file expires
  now=$(date +%s)
  [ -d "$GRANT_DIR" ] || return 0
  for file in "$GRANT_DIR"/*.grant; do
    [ -f "$file" ] || continue
    expires=$(record_field "$file" expires)
    case "$expires" in ''|*[!0-9]*) rm -f -- "$file" ; continue ;; esac
    [ "$expires" -gt "$now" ] || rm -f -- "$file"
  done
}

cmd_grant() {
  local raw="" approval="" minutes=$DEFAULT_MINUTES target reason key now file tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --approval) [ "$#" -gt 1 ] || die "--approval requires a value" 2; approval=$2; shift 2 ;;
      --approval=*) approval=${1#--approval=}; shift ;;
      --minutes) [ "$#" -gt 1 ] || die "--minutes requires a value" 2; minutes=$2; shift 2 ;;
      --minutes=*) minutes=${1#--minutes=}; shift ;;
      -*) die "unknown option: $1" 2 ;;
      *) [ -z "$raw" ] || die "grant takes exactly one path" 2; raw=$1; shift ;;
    esac
  done
  [ -n "$raw" ] || die "grant requires a path" 2
  approval=$(printf '%s' "$approval" | tr '\r\n\t' '   ' | sed -e 's/^ *//' -e 's/ *$//')
  [ -n "$approval" ] || die "grant requires --approval with the captain's own words for this operation" 2
  case "$minutes" in ''|*[!0-9]*) die "--minutes must be a whole number from 1 to $MAX_MINUTES" 2 ;; esac
  [ "$minutes" -ge 1 ] && [ "$minutes" -le "$MAX_MINUTES" ] || die "--minutes must be a whole number from 1 to $MAX_MINUTES" 2
  target=$(normalize_path "$raw") || die "cannot resolve $raw"
  reason=$(grantable "$target") || die "refused: $reason"
  mkdir -p "$GRANT_DIR" || die "cannot create $GRANT_DIR"
  prune_expired
  key=$(grant_key "$target")
  now=$(date +%s)
  file="$GRANT_DIR/$key.grant"
  tmp="$file.tmp.$$"
  if ! printf 'path=%s\ngranted=%s\nexpires=%s\napproval=%s\n' "$target" "$now" "$((now + minutes * 60))" "$approval" > "$tmp" \
    || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    die "cannot write $file"
  fi
  printf 'granted: %s for %s minutes\n' "$target" "$minutes"
}

cmd_revoke() {
  [ "$#" -eq 1 ] || die "revoke takes one path or --all" 2
  if [ "$1" = "--all" ]; then
    [ -d "$GRANT_DIR" ] && rm -f -- "$GRANT_DIR"/*.grant
    echo "revoked: all"
    return 0
  fi
  local target
  target=$(normalize_path "$1") || die "cannot resolve $1"
  rm -f -- "$GRANT_DIR/$(grant_key "$target").grant"
  prune_expired
  printf 'revoked: %s\n' "$target"
}

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
case "$1" in
  grant) shift; cmd_grant "$@" ;;
  revoke) shift; cmd_revoke "$@" ;;
  list) live_records ;;
  active) live_records | cut -f1 ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
