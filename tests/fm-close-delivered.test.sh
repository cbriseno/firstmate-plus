#!/usr/bin/env bash
# fm-close-delivered.sh: the safe-to-close view and the batch close with progress.
# The fleet snapshot, board list, teardown and park are stubs so each verdict and
# each fallback is exercised deterministically; the real board list is covered below.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-close-delivered)

BIN="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$BIN" "$HOME_DIR/state"
cp "$ROOT/bin/fm-close-delivered.sh" "$BIN/"
cat > "$BIN/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/snapshot.json"
SH
cat > "$BIN/fm-lavish-watch.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_HOME/boards.fail" ] || exit 2
cat "$FM_HOME/boards.tsv"
SH
cat > "$BIN/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
echo "teardown $1" >> "$FM_HOME/calls.log"
case "$1" in
  unlanded-*|scout-refused) echo 'REFUSED: work has not landed' >&2; exit 1 ;;
esac
SH
cat > "$BIN/fm-control.sh" <<'SH'
#!/usr/bin/env bash
echo "control $1 $2" >> "$FM_HOME/calls.log"
SH
chmod +x "$BIN"/*.sh

task() {  # <id> <kind> <declaration> <current> <endpoint> <open-decisions>
  jq -n --arg id "$1" --arg kind "$2" --arg decl "$3" --arg cur "$4" --arg ep "$5" --argjson d "$6" \
    '{id:$id,kind:$kind,declaration:{state:$decl},current_state:{state:$cur},endpoint:{status:$ep},hints:{open_decisions:[range($d)|"x"]}}'
}
{
  task landed-ship ship "done" unknown absent 0
  task owns-board ship "done" unknown absent 0
  task unlanded-ship ship "done" unknown absent 0
  task scout-refused scout "done" unknown absent 0
  task still-working ship "done" working present 0
  task asking ship "done" unknown absent 1
  task steered ship "done" unknown absent 0
  task no-result ship working working present 0
  task a-secondmate secondmate "done" unknown absent 0
} | jq -s '{tasks: .}' > "$HOME_DIR/snapshot.json"
printf 'owns-board\t/x/data/owns-board/report.html\topen\t0\n-\t/x/.lavish/home.html\topen\t0\n' > "$HOME_DIR/boards.tsv"
mkdir -p "$HOME_DIR/state/steered.inbox"
printf 'read me\n' > "$HOME_DIR/state/steered.inbox/001.msg"

run() { FM_HOME="$HOME_DIR" bash "$BIN/fm-close-delivered.sh" "$@"; }

OUT=$(run list)
assert_contains "$OUT" 'landed-ship | ship | delivered | closed | - | safe' 'a delivered ship with no board is safe'
assert_contains "$OUT" 'owns-board | ship | delivered | closed | /x/data/owns-board/report.html | keep: owns open board report.html' 'a board owner is kept'
assert_contains "$OUT" 'still-working | ship | working | open | - | keep: no result delivered yet (working)' 'a worker working again after done is kept'
assert_contains "$OUT" 'asking | ship | delivered | closed | - | keep: open decision' 'an open decision is kept'
assert_contains "$OUT" 'steered | ship | delivered | closed | - | keep: unread steering' 'unread steering is kept'
assert_contains "$OUT" 'no-result | ship | working | open | - | keep: no result delivered yet (working)' 'an unfinished worker is kept'
case "$OUT" in *a-secondmate*) fail 'a persistent secondmate was listed as closable' ;; esac
pass 'list shows result, pane, board owner and a verdict for every worker'

touch "$HOME_DIR/boards.fail"
OUT=$(run list)
assert_contains "$OUT" 'landed-ship | ship | delivered | closed | - | keep: board ownership could not be read' 'an unreadable board list keeps workers open'
rm "$HOME_DIR/boards.fail"
pass 'an unreadable board list never reads as no boards'

rc=0
OUT=$(run close landed-ship owns-board unlanded-ship scout-refused no-result) || rc=$?
assert_contains "$OUT" '[1/5] landed-ship: closed' 'a landed worker closes with progress'
assert_contains "$OUT" '[2/5] owns-board: keep: owns open board report.html' 'a named board owner stays open'
assert_contains "$OUT" '[3/5] unlanded-ship: parked' 'unlanded ship work is parked, not discarded'
assert_contains "$OUT" '[4/5] scout-refused: refused: REFUSED: work has not landed' 'a refused scout is reported'
assert_contains "$OUT" '[5/5] no-result: keep: no result delivered yet (working)' 'an unfinished worker is not closed'
assert_contains "$OUT" 'closed 1, parked 1, kept open 2, refused 1' 'the batch ends with a summary'
[ "$rc" = 1 ] || fail "a batch with kept or refused tasks exited $rc"
CALLS=$(cat "$HOME_DIR/calls.log")
assert_contains "$CALLS" 'control unlanded-ship park' 'park ran for unlanded ship work'
case "$CALLS" in *'owns-board'*|*'no-result'*|*'control scout-refused'*) fail "closed something it must keep: $CALLS" ;; esac
pass 'batch close closes, parks, keeps and refuses per task with visible progress'

rm "$HOME_DIR/calls.log"
OUT=$(run close --all-safe) || true
CALLS=$(cat "$HOME_DIR/calls.log")
case "$CALLS" in *'owns-board'*|*'no-result'*|*'still-working'*|*asking*|*steered*|*a-secondmate*) fail "all-safe touched a worker the view keeps: $CALLS" ;; esac
assert_contains "$CALLS" 'teardown landed-ship' 'all-safe closed the landed worker'
pass '--all-safe closes only the workers the view calls safe'

# The real board list: a task-hosted open board is reported with its owner,
# an ended board without feedback is not, and an absent store is not an error.
LAB="$TMP_ROOT/lab"
mkdir -p "$LAB/state" "$LAB/data/hosting" "$LAB/data/finished" "$LAB/store"
export LAVISH_AXI_STATE_DIR="$LAB/store"
printf 'kind=host\n' > "$LAB/state/hosting.meta"
printf 'kind=host\n' > "$LAB/state/finished.meta"
: > "$LAB/data/hosting/report.html"
: > "$LAB/data/finished/report.html"
OUT=$(FM_HOME="$LAB" bash "$ROOT/bin/fm-lavish-watch.sh" owned) || fail 'owned failed without a store'
[ -z "$OUT" ] || fail 'owned printed boards without a store'
jq -n --arg a "$LAB/data/hosting/report.html" --arg b "$LAB/data/finished/report.html" '{sessions:{
  one:{key:"one",file:$a,status:"open",url:"http://127.0.0.1:1/session/0123456789abcdef"},
  two:{key:"two",file:$b,status:"ended",url:"http://127.0.0.1:1/session/0123456789abcdee"}}}' > "$LAB/store/state.json"
OUT=$(FM_HOME="$LAB" bash "$ROOT/bin/fm-lavish-watch.sh" owned) || fail 'owned failed with a store'
[ "$OUT" = "$(printf 'hosting\t%s\topen\t0' "$(realpath "$LAB/data/hosting/report.html")")" ] || fail "owned listed the wrong boards: $OUT"
pass 'owned lists a task-hosted open board with its owner and skips an ended one'
