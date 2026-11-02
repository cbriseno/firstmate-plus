#!/usr/bin/env bash
# Token-free installed-Codex protocol guard, confined to a disposable home,
# Unix socket and server. Never connects to the operator's daemon or prompts a
# model. Exercises native thread metadata and the production release classifier.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_LOCK_RELEASE_LIVE codex python3
[ "$(uname -s)" = Linux ] || { echo 'skip: lock release native proof requires Linux'; exit 0; }
scratch=$(fm_test_tmproot fm-lock-release-live)
python3 "$ROOT/tests/fixtures/lock-release-live.py" "$ROOT" "$scratch" "$(command -v codex)" \
  || fail 'installed Codex lock release protocol guard'
