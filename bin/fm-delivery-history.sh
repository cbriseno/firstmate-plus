#!/usr/bin/env bash
# Read retained local delivery records, including the configured Markdown archive.
# Usage: FM_HOME=/absolute/home bash bin/fm-delivery-history.sh [--json]
# Emits fm-delivery-history.v1; complete covers configured retained sources only,
# never lifetime history. No network, backlog mutation, or filesystem event dates.
# Needs Python 3, Node and the installed tasks-axi canonical Markdown exports.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_delivery.py" history "$@"
