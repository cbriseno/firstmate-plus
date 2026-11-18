#!/usr/bin/env bash
# Run agreement table part 9 of fm-public-followup.
FM_AGREE_PART=9 FM_TEST_ONLY=test_emit_rules_agree_with_tasks_axi exec bash "$(dirname "$0")/fm-public-followup.test.sh"
