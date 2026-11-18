#!/usr/bin/env bash
# Run remote config reread retry checks.
FM_TEST_SUITE_PART=15 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
