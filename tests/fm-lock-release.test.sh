#!/usr/bin/env bash
# Portable process/protocol regression; all homes and the native endpoint are
# disposable. The real installed protocol is checked by the separate live guard.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ "$(uname -s)" = Linux ] || { echo 'skip: native shared-runtime lock release requires Linux'; exit 0; }
scratch=$(fm_test_tmproot fm-lock-release)
mkdir -p "$scratch/bin"
ln -s "$(command -v python3)" "$scratch/bin/codex"
"$scratch/bin/codex" "$ROOT/tests/fixtures/lock-release-runtime.py" app-server "$ROOT" "$scratch" \
  || fail 'supported lock release regression'
