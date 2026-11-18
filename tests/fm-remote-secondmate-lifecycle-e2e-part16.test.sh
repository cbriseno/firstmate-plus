#!/usr/bin/env bash
# Run dead remote endpoint supervision and relaunch checks.
FM_TEST_SUITE_PART=16 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
