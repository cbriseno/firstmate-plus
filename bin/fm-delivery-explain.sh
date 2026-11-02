#!/usr/bin/env bash
# Queue an informational delivery question through the existing durable inbox.
# Usage: FM_HOME=/absolute/home bash bin/fm-delivery-explain.sh
#          --task ID --request-id ID [--json] [--status]
# --status reads receipts only. Retrying the same home/task/request never queues
# another note. Acknowledged means handled, not model processing or approval.
# Exit 3 means saved but not announced; repeat the same request to repair its wake.
# Refuses unsafe paths and unknown task identities; report content stays data.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/fm_delivery.py" explain "$@"
