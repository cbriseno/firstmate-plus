#!/usr/bin/env bash
# Behavior test for task metadata on a Lavish reply.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-lavish-metadata)
export LAVISH_AXI_STATE_DIR="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_AXI_STATE_DIR"
lavish_session() {
  python3 - "$LAVISH_AXI_STATE_DIR/state.json" "$1" <<'PYSESSION'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'sessions': {'test': {
    'file': str(pathlib.Path(sys.argv[2]).resolve()),
    'url': 'http://127.0.0.1:14387/session/0123456789abcdef'}}}))
PYSESSION
}
# A task-owned reply carries the current launch identity when Lavish supports it.
META_REPLY="$TMP_ROOT/metadata-reply"
mkdir -p "$META_REPLY/bin" "$META_REPLY/home/state"
export META_REPLY
cat > "$META_REPLY/bin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-} ${2-}" in
  '--version ') printf '0.1.80\n' ;;
  'reply --help') printf '%s\n' '--model' ;;
  'reply '*) shift 4; printf '%s\n' "$@" > "$META_REPLY/received" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$META_REPLY/bin/lavish-axi"
meta_art="$META_REPLY/board.html"
printf '<h1>metadata</h1>\n' > "$meta_art"
lavish_session "$meta_art"
printf 'reply\n' > "$META_REPLY/reply"
cat > "$META_REPLY/home/state/worker.meta" <<META
model=example-model
effort=high
harness=codex
project=example-project
herdr_pane_id=pane-1
spawn_gen=launch-1
sessions_file=$META_REPLY/sessions.jsonl
META
printf '{"type":"session_meta","payload":{"id":"12345678-1234-1234-1234-123456789abc"}}\n' > "$META_REPLY/transcript"
printf '{"launch":"launch-1","status":"active","session":"%s"}\n' "$META_REPLY/transcript" > "$META_REPLY/sessions.jsonl"
PATH="$META_REPLY/bin:$PATH" FM_HOME="$META_REPLY/home" FM_PROCEVENT_REPLY_TASK=worker \
  "$ROOT/bin/fm-procevent-lavish.sh" deliver-reply poll "$meta_art" --agent-reply-file "$META_REPLY/reply" \
  || fail "metadata reply failed"
python3 - "$META_REPLY/received" <<'PYTEST'
import sys
args = open(sys.argv[1]).read().splitlines()
assert dict(zip(args[::2], args[1::2])) == {'--model': 'example-model', '--reasoning': 'high',
    '--harness': 'codex', '--project': 'example-project', '--task': 'worker',
    '--herdr-pane': 'pane-1', '--chat-id': '12345678-1234-1234-1234-123456789abc'}
PYTEST
pass "task-owned replies include available task and active chat metadata"

