#!/usr/bin/env bash
# fm-upgrade.sh - offer and apply UPGRADING.md actions for an explicit FM_HOME.
# Usage: FM_HOME=/absolute/home bash bin/fm-upgrade.sh check|apply [--help]
# check creates one captain hold per newly encountered batch, never applies data
# changes, and records offered ids in data/upgrades/offered. Session startup
# calls check only with a verified lock; manual callers need the same authority.
# apply is for the primary/worker after the captain accepts and the primary
# records the answer through fm-captain-hold.sh. It runs pending Command entries
# in document order and appends successful ids to data/upgrades/applied.
# v11b unresolved evidence returns 2 and leaves the id pending for its worker;
# rerun apply after that worker completes the documented migration procedure.
# Failed commands are never marked. Declining resolves the hold, leaves the
# ids unapplied, and causes no repeated automatic offer; apply remains available.
# Format: ## <id> - YYYY-MM-DD, Action: <label>, Command: `<argv>`.
# Entries without Command are informational. Existing ids are immutable.
# No overrides: each invocation addresses exactly the named FM_HOME.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_upgrade.py" "$@"
