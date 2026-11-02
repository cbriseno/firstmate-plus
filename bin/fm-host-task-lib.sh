#!/usr/bin/env bash
# Host-task path and scratch validation shared by brief, spawn and teardown.
# fm_host_paths <path>... prints canonical absolute targets, or refuses.
# Paths must be absolute or HOME-relative, outside projects and the checkout;
# linked worktrees of clones under projects are protected too.
# fm_host_scratch_valid <path> requires the exact real data/<id>/work directory.
# Callers supply SCRIPT_DIR, FM_ROOT, FM_HOME, CONFIG, DATA, PROJECTS and ID.

fm_host_paths() {
  local target line result mode=host
  local -a args
  if [ -e "$CONFIG/primary-direct-ops" ]; then
    mode=$(tr -d '[:space:]' < "$CONFIG/primary-direct-ops") || return 1
  fi
  [ "$mode" = host ] || { echo 'error: host tasks disabled by config/primary-direct-ops' >&2; return 1; }
  [ "$#" -gt 0 ] || { echo 'error: --host requires at least one --path' >&2; return 1; }
  args=(--tool HostPath --cwd "$FM_HOME" --projects "$PROJECTS" --home-checkout "$FM_ROOT" --home-checkout "$FM_HOME")
  while IFS= read -r line; do args+=(--project-root "$line"); done < <(fm_host_project_roots "$PROJECTS")
  if [ -f "$DATA/secondmates.md" ]; then
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
    while IFS= read -r line; do
      secondmate_registry_parse_line "$line" 2>/dev/null || continue
      [ "${SECONDMATE_REGISTRY_REMOTE:-0}" = 0 ] || continue
      case "${SECONDMATE_REGISTRY_HOME:-}" in /*) ;; *) continue ;; esac
      args+=(--home-checkout "$SECONDMATE_REGISTRY_HOME")
      while IFS= read -r target; do args+=(--project-root "$target"); done < <(fm_host_project_roots "$SECONDMATE_REGISTRY_HOME/projects")
    done < "$DATA/secondmates.md"
  fi
  for target in "$@"; do args+=(--path "$target"); done
  result=$(node "$SCRIPT_DIR/fm-primary-write-policy.mjs" "${args[@]}") || {
    printf 'error: invalid host paths: %s\n' "$result" >&2
    return 1
  }
  printf '%s\n' "$result"
}

fm_host_scratch_valid() {
  local expected actual
  [ ! -L "$DATA/$ID" ] && [ ! -L "$DATA/$ID/work" ] || return 1
  expected=$(CDPATH='' cd -- "$DATA/$ID" && pwd -P)/work || return 1
  actual=$(CDPATH='' cd -- "$1" && pwd -P) || return 1
  [ "$actual" = "$expected" ] && [ ! -e "$actual/.git" ]
}

# Print registered clone roots and their linked worktrees; never inherit an
# enclosing checkout when a projects entry is itself a non-repository folder.
fm_host_project_roots() {
  local project_dir=$1 clone clone_top line
  printf '%s\n' "$project_dir"
  for clone in "$project_dir"/*; do
    [ -d "$clone" ] || continue
    printf '%s\n' "$clone"
    clone_top=$(git -C "$clone" rev-parse --show-toplevel 2>/dev/null) || continue
    [ "$clone_top" = "$(CDPATH='' cd -- "$clone" && pwd -P)" ] || continue
    while IFS= read -r line; do
      case "$line" in 'worktree '*) printf '%s\n' "${line#worktree }" ;; esac
    done < <(git -C "$clone" worktree list --porcelain 2>/dev/null)
  done
}
