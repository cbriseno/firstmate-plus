#!/usr/bin/env bash
# Run remote restart and liveness recovery checks.
FM_TEST_SUITE_PART=11 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
