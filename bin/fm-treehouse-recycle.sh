#!/usr/bin/env bash
# Return one clean, unclaimed idle Treehouse slot whose HEAD is saved by a ref.
# Usage: FM_HOME=<home> fm-treehouse-recycle.sh <project> <state-dir>
# Caller holds the project's shared Treehouse lock. Exit 1 if none is safe.
set -u
project=$1
state=$2
script_dir=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-wake-lib.sh
. "$script_dir/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$script_dir/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$script_dir/fm-secondmate-registry-lib.sh"
fm_local_firstmate_state_dirs "$state" || exit 1
listing=$( (cd "$project" && treehouse status --json) 2>/dev/null) || exit 1
candidates=$(printf '%s' "$listing" | python3 -c '
import json, sys
try:
    slots = json.load(sys.stdin)
    for slot in slots:
        path = slot.get("path", "")
        if (slot.get("status") == "available" and "lease_id" in slot
                and not slot["lease_id"] and isinstance(slot.get("processes"), list)
                and not slot["processes"] and "\n" not in path):
            print(path)
except (ValueError, TypeError, AttributeError):
    sys.exit(1)
') || exit 1
while IFS= read -r slot; do
  [ -n "$slot" ] || continue
  fm_treehouse_pool_slot "$project" "$slot" || continue
  fm_treehouse_slot_owner_state "$slot" ''
  [ "$FM_TREEHOUSE_SLOT_OWNER" = absent ] || continue
  occupied=0
  for directory in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$directory" ] && { [ ! -d "$directory" ] || [ ! -r "$directory" ] || [ ! -x "$directory" ]; }; then
      exit 1
    fi
    for meta in "$directory"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || exit 1
      for field in worktree home; do
        recorded=$(fm_meta_get "$meta" "$field")
        [ -n "$recorded" ] && [ -d "$recorded" ] || continue
        [ "$recorded" -ef "$slot" ] && occupied=1
      done
    done
  done
  [ "$occupied" = 0 ] || continue
  changes=$(git -C "$slot" status --porcelain --untracked-files=all 2>/dev/null) || continue
  [ -z "$changes" ] || continue
  head=$(git -C "$slot" rev-parse --verify HEAD 2>/dev/null) || continue
  refs=$(git -C "$slot" for-each-ref --contains "$head" --format='%(refname)' refs/heads refs/tags refs/remotes 2>/dev/null) || continue
  [ -n "$refs" ] || continue
  # Firstmate holds the project lock across get, this recheck, and return.
  current=$( (cd "$project" && treehouse status --json) 2>/dev/null) || continue
  if ! printf '%s' "$current" | python3 -c '
import json, sys
try:
    slots = [s for s in json.load(sys.stdin) if s.get("path") == sys.argv[1]]
    safe = (len(slots) == 1 and slots[0].get("status") == "available"
            and "lease_id" in slots[0] and not slots[0]["lease_id"]
            and isinstance(slots[0].get("processes"), list) and not slots[0]["processes"])
    sys.exit(0 if safe else 1)
except (ValueError, TypeError, AttributeError):
    sys.exit(1)
' "$slot"; then
    continue
  fi
  (cd "$project" && treehouse return "$slot" </dev/null >/dev/null) || continue
  printf 'Recycled idle Treehouse slot %s; its commit remains referenced.\n' "$slot" >&2
  exit 0
done <<EOF_SLOTS
$candidates
EOF_SLOTS
exit 1
