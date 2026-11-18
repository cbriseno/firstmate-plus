#!/usr/bin/env bash
# Run unreachable-host and legacy remote endpoint checks.
FM_TEST_SUITE_PART=12 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
