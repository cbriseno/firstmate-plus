#!/usr/bin/env bash
# fm-close-delivered.sh - see which finished workers are safe to close, and close them in a batch.
#
# Usage: fm-close-delivered.sh list
#        fm-close-delivered.sh close <task-id>... | --all-safe
#
# list prints one row per ship, scout and host task: whether its result was
# delivered, whether its pane is still open, which open review board it owns
# (bin/fm-lavish-watch.sh owned) and a verdict, `safe` or `keep: <reason>`.
# A task is safe to close when its last declaration is done and it is not
# working again, it owns no open board, has no open decision and no unread steer.
# close re-reads those facts for each named task (or every safe one with
# --all-safe) and closes it the way the watcher does, printing one progress
# line per task: fm-teardown.sh, which refuses work that has not landed, then,
# for a ship, fm-control.sh park, which closes the pane and keeps the record,
# copy and branch for landing. Nothing is discarded and a task that is not
# safe stays open. Exit 1 when any named task was refused or kept.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }
case "${1:-}" in list|close) cmd=$1; shift ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo "fm-close-delivered: jq not found" >&2; exit 1; }

snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?
boards=$(FM_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/fm-lavish-watch.sh" owned 2>/dev/null) && boards_ok=1 || boards_ok=0

# <id> -> "<kind>\t<delivery>\t<pane>\t<board>\t<verdict>"
facts() {
  local id=$1 row kind decl cur ep decisions delivery pane board verdict
  row=$(printf '%s\n' "$snapshot" | jq -r --arg id "$id" '
    .tasks[] | select(.id == $id) |
    [.kind, (.declaration.state // ""), .current_state.state, .endpoint.status, ((.hints.open_decisions // []) | length)] | @tsv')
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r kind decl cur ep decisions <<EOF
$row
EOF
  case "$ep" in present) pane=open ;; absent) pane=closed ;; *) pane=unknown ;; esac
  [ "$cur" != parked ] || pane=closed
  delivery=$cur
  [ "$decl" != "done" ] || [ "$cur" = working ] || delivery=delivered
  board=$(printf '%s\n' "$boards" | awk -F'\t' -v t="$id" '$1 == t { print $2; exit }')
  if [ "$kind" = secondmate ]; then return 1
  elif [ "$delivery" != delivered ]; then verdict="keep: no result delivered yet ($cur)"
  elif [ "$boards_ok" = 0 ]; then verdict='keep: board ownership could not be read'
  elif [ -n "$board" ]; then verdict="keep: owns open board ${board##*/}"
  elif [ "$decisions" != 0 ]; then verdict='keep: open decision'
  elif [ -n "$(find "$STATE/$id.inbox" -maxdepth 1 -name '*.msg' -print -quit 2>/dev/null)" ]; then verdict='keep: unread steering'
  else verdict=safe
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$delivery" "$pane" "${board:--}" "$verdict"
}

ids=$(printf '%s\n' "$snapshot" | jq -r '.tasks[] | select(.kind != "secondmate") | .id')

if [ "$cmd" = list ]; then
  printf '%s\n' 'task | kind | result | pane | board | verdict'
  for id in $ids; do
    f=$(facts "$id") || continue
    printf '%s | %s\n' "$id" "$(printf '%s' "$f" | sed 's/\t/ | /g')"
  done
  exit 0
fi

[ "$#" -gt 0 ] || { usage >&2; exit 2; }
if [ "$1" = --all-safe ]; then
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  targets=''
  for id in $ids; do
    f=$(facts "$id") || continue
    [ "${f##*$'\t'}" != safe ] || targets="$targets $id"
  done
else
  targets="$*"
fi
read -r -a targets_arr <<< "$targets"
set -- "${targets_arr[@]}"
total=$#
[ "$total" -gt 0 ] || { echo 'nothing safe to close'; exit 0; }

n=0 closed=0 parked=0 kept=0 refused=0
for id in "$@"; do
  n=$((n + 1))
  printf '[%d/%d] %s: ' "$n" "$total" "$id"
  f=$(facts "$id") || { echo 'kept: not a closable task'; kept=$((kept + 1)); continue; }
  verdict=${f##*$'\t'}
  if [ "$verdict" != safe ]; then echo "$verdict"; kept=$((kept + 1)); continue; fi
  kind=${f%%$'\t'*}
  rc=0
  out=$(FM_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/fm-teardown.sh" "$id" 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then echo 'closed'; closed=$((closed + 1)); continue; fi
  if [ "$kind" = ship ]; then
    prc=0
    pout=$(FM_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/fm-control.sh" "$id" park 2>&1) || prc=$?
    if [ "$prc" = 0 ]; then echo 'parked (work kept for landing; record, copy and branch stay)'; parked=$((parked + 1)); continue; fi
    out=$pout
  fi
  echo "refused: $(printf '%s\n' "$out" | tail -1)"
  refused=$((refused + 1))
done
echo "closed $closed, parked $parked, kept open $kept, refused $refused"
[ $((kept + refused)) -eq 0 ]
