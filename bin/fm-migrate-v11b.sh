#!/usr/bin/env bash
# fm-migrate-v11b.sh - portable historical Deck declarations for FM_HOME.
# Usage: FM_HOME=/path/to/home bash bin/fm-migrate-v11b.sh --plan|--apply|--rollback
# Python 3.9+, bash 3.2+, and the existing tasks-axi/Node installation suffice.
# --plan is read-only; --apply backs up changes in data/migration-v11b/ and
# publishes through fm-tasks-axi presentation. --rollback restores unchanged
# migrated fields through the same owner, preserving subsequent owner edits.
# Missing/ambiguous projects and request grouping remain a worker's judgment:
# docs/configuration.md ("v11b migration") owns that operator procedure.
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec python3 "$ROOT/bin/fm_migrate_v11b.py" "$@"
