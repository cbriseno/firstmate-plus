#!/usr/bin/env bash
# fm-remote-land.sh <secondmate-id> <task-id>
# Returns a ready Firstmate branch to the primary, through the local merge gate.
# --tick processes the mirrored ready lines and retries per-route sync.
# --sync [already-syncing-mate] propagates the primary default branch to both
# checkouts of every registered remote route, even without a live endpoint.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_HOME
REG="$DATA/secondmates.md"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
on() { "$SCRIPT_DIR/fm-on.sh" "$@"; }

ready() (
  local mate=$1 task=$2 tmp last branch
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-land.XXXXXX") || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  on "$mate" fm-remote-file.sh get "state/$task.meta" 65536 > "$tmp/meta" || return 1
  [ "$(fm_meta_get "$tmp/meta" kind)" = ship ] &&
    [ "$(fm_meta_get "$tmp/meta" mode)" = local-only ] &&
    [ "$(fm_meta_get "$tmp/meta" project)" = "$SECONDMATE_REGISTRY_HOME" ] || return 1
  on "$mate" fm-remote-file.sh get "state/$task.status" 262144 > "$tmp/status" || return 1
  last=$(status_current_line "$tmp/status" ship)
  [ "$(status_line_verb "$last")" = "done" ] && [ -z "$(status_own_open_decisions "$tmp/status")" ] || return 1
  branch=$(fm_meta_get "$tmp/meta" branch)
  [ "$(status_line_note "$last")" = "ready in branch ${branch:-fm/$task}" ] || return 1
  printf '%s\n' "${branch:-fm/$task}"
)

load_route() {
  local mate=$1 mode=$2 meta="$STATE/$1.meta"
  valid_id "$mate" || return 1
  secondmate_registry_line_for_id "$REG" "$mate" && [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || return 1
  if [ "$mode" = land ] || [ -e "$meta" ] || [ -L "$meta" ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] &&
      [ "$(fm_meta_get "$meta" kind)" = secondmate ] &&
      [ "$(fm_meta_get "$meta" remote_host)" = "$SECONDMATE_REGISTRY_HOST" ] &&
      [ "$(fm_meta_get "$meta" remote_root)" = "$SECONDMATE_REGISTRY_ROOT" ] &&
      [ "$(fm_meta_get "$meta" home)" = "$SECONDMATE_REGISTRY_HOME" ] || return 1
  fi
  [[ "$SECONDMATE_REGISTRY_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
    [[ "$SECONDMATE_REGISTRY_ROOT" = /* && "$SECONDMATE_REGISTRY_HOME" = /* ]]
}

# Use the same SSH alias and noninteractive transport constraints as fm-on.
ROUTE_SSH_OPTIONS=(-o BatchMode=yes -o ForwardAgent=no -o ClearAllForwardings=yes -o 'SendEnv=-*'
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
route_git() {
  local ssh_command
  printf -v ssh_command '%q ' "${FM_SSH_BIN:-ssh}" "${ROUTE_SSH_OPTIONS[@]}"
  GIT_SSH_VARIANT=ssh GIT_SSH_COMMAND="$ssh_command" \
    git -C "$FM_ROOT" "$@"
}

sync_code_root() {
  local head=$1 root
  # Quote the path for the remote login shell. The only incoming data passed
  # to the fixed script are the configured root and the resolved commit id.
  root=${SECONDMATE_REGISTRY_ROOT//\'/\'\\\'\'}
  "${FM_SSH_BIN:-ssh}" "${ROUTE_SSH_OPTIONS[@]}" -- "$SECONDMATE_REGISTRY_HOST" \
    "bash -s -- '$root' '$head'" <<'SYNC_ROOT'
set -e
FM_ROOT=$1 FM_HOME=$1
# shellcheck disable=SC1091
. "$FM_ROOT/bin/fm-ff-lib.sh"
ff_target "$FM_ROOT" "remote code root" "$2"
[ "$FF_STATUS" = updated ] || [ "$FF_STATUS" = current ]
SYNC_ROOT
}

sync_route() {
  local mate=$1 head receipt="$STATE/.remote-main-$1"
  head=$(primary_head_commit "$FM_ROOT") || return 1
  [ ! -L "$receipt" ] || return 1
  # Old receipts covered only the home and must not suppress the root update.
  if [ -f "$receipt" ] && [ "$receipt" -nt "$REG" ] && [ "$receipt" -nt "$STATE/$mate.meta" ] &&
    [ "$(< "$receipt")" = "root+home:$head" ]; then
    return 0
  fi
  route_git push --quiet "$SECONDMATE_REGISTRY_HOST:$SECONDMATE_REGISTRY_ROOT" "$head:refs/fm/primary-main" || return 1
  sync_code_root "$head" || return 1
  on "$mate" fm-remote-secondmate-control.sh sync "$mate" "$head" || return 1
  printf 'root+home:%s\n' "$head" > "$receipt"
}

land() {
  local mate=$1 task=$2 expected=${3:-} receipt=${4:-} branch head ref out hold=0
  [ ! -e "$STATE/$task.meta" ] || die "a local task owns $task"
  [ "$("$SCRIPT_DIR/fm-project-mode.sh" firstmate)" = 'local-only on' ] || return 1
  if [ -n "$receipt" ] && [ -s "$receipt" ]; then
    head=$(< "$receipt")
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  else
    branch=$(ready "$mate" "$task") || return 1
    git check-ref-format "refs/heads/$branch" || return 1
    ref="refs/remotes/$mate/$branch"
    route_git fetch --quiet --no-tags --no-write-fetch-head "$SECONDMATE_REGISTRY_HOST:$SECONDMATE_REGISTRY_HOME" \
      "+refs/heads/$branch:$ref" || return 1
    head=$(git -C "$FM_ROOT" rev-parse --verify "$ref^{commit}") || return 1
    [ -z "$expected" ] || [ "$head" = "$expected" ] || return 1
    on "$mate" fm-captain-hold.sh open "$task" --distinguish-absent >/dev/null || hold=$?
    case "$hold" in 1|3) ;; *) return 1 ;; esac
    if ! out=$("$SCRIPT_DIR/fm-merge-local.sh" --remote "$task" "$ref" "$head" 2>&1); then
      printf '%s\n' "$out" >&2
      case "$out" in
        *'conflicts in:'*)
          sync_route "$mate" && "$SCRIPT_DIR/fm-send.sh" "$mate" --fire-and-forget "${head:0:16}" \
            "Integration of $task conflicts with the primary. Rebase its branch on the synchronized default and report a new ready result."
          return $?
          ;;
        *) return 1 ;;
      esac
    fi
    printf '%s\n' "$out"
    [ -z "$receipt" ] || printf '%s\n' "$head" > "$receipt" || return 1
  fi
  sync_route "$mate" || return 1
  "$SCRIPT_DIR/fm-send.sh" "$mate" --fire-and-forget "${head:0:16}" \
    "The primary integrated $task and synchronized its default branch. Confirm integrated content and close the worker through the normal teardown."
}

route_work() (
  local mode=$1 mate=$2 selected=${3:-} task line receipt key expected
  load_route "$mate" "$mode" || return 1
  local lock="$STATE/.remote-land-$mate.lock"
  fm_lock_try_acquire "$lock" || return 1
  trap 'fm_lock_release "$lock"' EXIT
  case "$mode" in
    --sync) sync_route "$mate" ;;
    --tick|land)
      [ "$mode" != --tick ] || sync_route "$mate" || true
      [ -f "$STATE/$mate.meta" ] || return 0
      [ "$("$SCRIPT_DIR/fm-project-mode.sh" firstmate)" = 'local-only on' ] || return 0
      [ -f "$STATE/$mate.status" ] && [ ! -L "$STATE/$mate.status" ] || return 0
      local ready_line='^done .*\[key=(child-outcome-[A-Za-z0-9._-]+)\].*: child ([A-Za-z0-9][A-Za-z0-9._-]*) done: ready in branch [^ ]+ mode=local-only( |$)'
      while IFS= read -r line; do
        [[ "$line" =~ $ready_line ]] || continue
        key=${BASH_REMATCH[1]} task=${BASH_REMATCH[2]}
        [ -z "$selected" ] || [ "$selected" = "$task" ] || continue
        receipt="$STATE/.remote-land-$mate-$key"
        [ ! -L "$receipt" ] || continue
        if [ -f "$receipt" ] && [ "$(< "$receipt")" = sent ]; then
          [ -z "$selected" ] || return 0
          continue
        fi
        expected=
        if [[ "$line" =~ [[:space:]]head=([0-9a-f]{40})([[:space:]]|$) ]]; then expected=${BASH_REMATCH[1]}; fi
        if land "$mate" "$task" "$expected" "$receipt"; then
          printf 'sent\n' > "$receipt" || return 1
          [ -z "$selected" ] || return 0
        fi
      done < "$STATE/$mate.status"
      [ -z "$selected" ] ;;
  esac
)

case "${1:-}" in
  --sync|--tick)
    [ "$#" -eq 1 ] || { [ "$1" = --sync ] && [ "$#" -eq 2 ] && valid_id "$2"; } || exit 2
    [ -f "$REG" ] && [ ! -e "$FM_HOME/.fm-secondmate-home" ] || exit 0
    route_pids=()
    while IFS= read -r line || [ -n "$line" ]; do
      secondmate_registry_parse_line "$line" && [ "$SECONDMATE_REGISTRY_REMOTE" = 1 ] || continue
      mate=$SECONDMATE_REGISTRY_ID
      [ "$mate" != "${2:-}" ] || continue
      route_work "$1" "$mate" &
      route_pids+=("$!")
    done < "$REG"
    rc=0
    for pid in ${route_pids[@]+"${route_pids[@]}"}; do
      wait "$pid" || rc=1
    done
    exit "$rc"
    ;;
  *)
    [ "$#" -eq 2 ] && valid_id "$2" || exit 2
    [ ! -e "$FM_HOME/.fm-secondmate-home" ] || die "only the primary can integrate remote work"
    route_work land "$@"
    ;;
esac
