# shellcheck shell=bash
# Integrate origin into the primary checkout while preserving local work.
# Called only after ff_target has fetched and identified dirt or divergence.
update_primary_drop_saved() {
  local dir=$1 saved=$2
  if [ -n "$saved" ] && [ "$(git -C "$dir" rev-parse -q --verify refs/stash 2>/dev/null || true)" = "$saved" ]; then
    git -C "$dir" stash drop -q 'stash@{0}' || true
  fi
}

update_primary_local() {
  local dir=$1 base=$2 before saved='' previous='' name email out instr conflicts
  before=$(git -C "$dir" rev-parse HEAD) || return 1
  if git -C "$dir" merge-base --is-ancestor "$base" HEAD; then
    FF_STATUS=current
    echo 'firstmate: already current (local work preserved)'
    return 0
  fi
  instr=$(changed_instr "$dir" "$base")
  if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
    previous=$(git -C "$dir" rev-parse -q --verify refs/stash 2>/dev/null || true)
    if ! out=$(git -C "$dir" stash push -q -m 'firstmate update' 2>&1); then
      echo "firstmate: skipped: could not preserve local changes: $out"
      return 1
    fi
    saved=$(git -C "$dir" rev-parse -q --verify refs/stash 2>/dev/null || true)
    if [ -z "$saved" ] || [ "$saved" = "$previous" ]; then
      echo 'firstmate: skipped: could not preserve local changes'
      return 1
    fi
  fi
  name=$(git -C "$dir" config user.name || git -C "$dir" show -s --format=%an HEAD)
  email=$(git -C "$dir" config user.email || git -C "$dir" show -s --format=%ae HEAD)
  if ! out=$(git -C "$dir" -c "user.name=$name" -c "user.email=$email" merge --no-edit --no-overwrite-ignore "$base" 2>&1); then
    conflicts=$(git -C "$dir" diff --name-only --diff-filter=U | paste -sd ", " -)
    if git -C "$dir" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
      git -C "$dir" merge --abort >/dev/null 2>&1 || {
        echo "firstmate: skipped: integration could not be aborted; saved changes: $saved"
        return 1
      }
    fi
    if [ -n "$saved" ] && ! git -C "$dir" stash apply --index "$saved" >/dev/null 2>&1; then
      echo "firstmate: skipped: integration failed and changes remain saved: $saved"
      return 1
    fi
    update_primary_drop_saved "$dir" "$saved"
    echo "firstmate: skipped: integration failed: ${conflicts:-$(first_line "$out")}"
    return 1
  fi
  if [ -n "$saved" ] && ! out=$(git -C "$dir" stash apply --index "$saved" 2>&1); then
    conflicts=$(git -C "$dir" diff --name-only --diff-filter=U | paste -sd ", " -)
    if ! git -C "$dir" reset --hard "$before" >/dev/null 2>&1 || ! git -C "$dir" stash apply --index "$saved" >/dev/null 2>&1; then
      echo "firstmate: skipped: restoration failed; changes remain saved: $saved"
      return 1
    fi
    update_primary_drop_saved "$dir" "$saved"
    echo "firstmate: skipped: local changes conflict with the update: ${conflicts:-$(first_line "$out")}"
    return 1
  fi
  update_primary_drop_saved "$dir" "$saved"
  # Consumed by fm-update.sh after this function returns.
  # shellcheck disable=SC2034
  FF_STATUS=updated
  # shellcheck disable=SC2034
  FF_INSTR=$instr
  echo "firstmate: updated with local work preserved $(git -C "$dir" rev-parse --short HEAD)"
}
