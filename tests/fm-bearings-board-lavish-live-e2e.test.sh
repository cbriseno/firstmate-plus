#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# liveness check is written against.
#
# Why this file exists: the build's "is this board actually live" verdict comes
# from what lavish-axi emits, which is a surface the vendor controls and changes
# without notice. The defect this guards was exactly that - opening a session
# the captain had ended from the browser EXITS 0 while refusing to reopen, so a
# build that trusted the exit status armed a poll against a dead session and the
# board read "not listening" with nobody watching it. A stubbed lavish-axi can
# only confirm the assumption already written into the stub, so the assumption
# itself needs a run against the real tool.
#
# The captain-ended state is reached through the same server route the browser's
# End session button calls, so no browser is needed and nothing here depends on
# a human. The artifact is a scratch page in a temporary directory, and the
# session it opens is ended again before the guard returns.
#
# Every lavish-axi call runs against a PRIVATE Lavish server: its own
# LAVISH_AXI_STATE_DIR inside the guard lab, its own free loopback port, a
# loopback-only bind, no browser, and no telemetry. lavish-axi selects its
# server by state directory and refuses a port another state directory owns, so
# the operator's shared Lavish server - the one their browser and phone review
# - never sees this session, and the private server is stopped on exit. That
# isolation is why this drift guard may run by default (tests/lib.sh,
# fm_live_gate); tests/fm-live-gate.test.sh pins it.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's logic
# in CI against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi jq curl python3

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
PRIVATE_LAVISH=0
cleanup() {
  fm_test_reap_procevent_homes
  [ -z "$LAB" ] || {
    # Only the private server is ever ended or stopped; before it exists, a bare
    # lavish-axi call would address the operator's shared server instead.
    if [ "$PRIVATE_LAVISH" = 1 ]; then
      [ ! -f "$LAB/.lavish/bearings-board.html" ] \
        || lavish-axi end "$LAB/.lavish/bearings-board.html" >/dev/null 2>&1 || true
      lavish-axi stop >/dev/null 2>&1 || true
    fi
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data" "$LAB/lavish-state"

# The private Lavish server. Exported, so the board build and the poll it arms
# resolve the same private session store and endpoint as the guard itself.
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()') \
  || fail "cannot reserve a free loopback port for the private Lavish server"
unset LAVISH_AXI_ALLOWED_HOSTS LAVISH_AXI_LINK_HOST LAVISH_AXI_HERDR_CHIME
export LAVISH_AXI_STATE_DIR="$LAB/lavish-state" LAVISH_AXI_PORT="$PORT" LAVISH_AXI_HOST=127.0.0.1 \
  LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_TELEMETRY=0
PRIVATE_LAVISH=1

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

fm_test_track_procevent_home "$LAB" "$LAB/procevent-claims"

cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "lavish-live-guard",
  "generated": "2026-01-01T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-live-guard-call",
      "type": "decision",
      "repo": "sample",
      "title": "Guard placeholder",
      "options": [{ "value": "yes", "label": "Yes" }]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON

run_board() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" "$@"
}

BOARD="$LAB/.lavish/bearings-board.html"
run_board build "$LAB/payload.json" >/dev/null 2>&1 || fail "the guard board did not build"
[ -f "$BOARD" ] || fail "the guard board was not published"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  "http://127.0.0.1:$PORT/session/"*) ;;
  *) fail "the guard board session is not on its private Lavish server (127.0.0.1:$PORT): $url" ;;
esac
key=${url##*/}
base=${url%/session/*}
jq -e --arg key "$key" '.sessions[$key] != null' "$LAVISH_AXI_STATE_DIR/state.json" >/dev/null 2>&1 \
  || fail "the guard board session is not recorded in the private Lavish state directory"
pass "lavish-axi ${VERSION:-version-unknown} serves the guard board from a private server and state directory"

# End it exactly as the browser's End session button does.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain"

# ASSUMPTION UNDER GUARD: this exits 0 while reporting the session is not live.
set +e
ended_out=$(lavish-axi "$BOARD" 2>&1)
ended_rc=$?
set -e
[ "$ended_rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown} now exits $ended_rc on a captain-ended session; the board build's liveness check must be revisited"
ended_status=$(printf '%s\n' "$ended_out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
[ "$ended_status" != opened ] \
  || fail "lavish-axi ${VERSION:-version-unknown} silently reopened a captain-ended session; the board build's liveness check must be revisited"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  && fail "lavish-axi ${VERSION:-version-unknown} still lists a captain-ended session as open; the board build's liveness check must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session without reopening it and without failing"

# THE BEHAVIOR UNDER GUARD: the build must not accept that, and must recover.
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "the board build refused a recoverable captain-ended session: $out"
case "$out" in
  *"session: reopened"*) ;;
  *) fail "the board build did not reopen the captain-ended session: $out" ;;
esac
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  || fail "the board build reported success while the session was still not live"
pass "the board build reopens a captain-ended session against real lavish-axi instead of arming a dead one"
