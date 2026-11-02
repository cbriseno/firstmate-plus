#!/usr/bin/env bash
# Public delivery history/intake/activity and producer flow regressions.
# All mutations use temporary homes; no live hooks, models or endpoint control.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tests/deck_clarity_checks.py" "$ROOT"
