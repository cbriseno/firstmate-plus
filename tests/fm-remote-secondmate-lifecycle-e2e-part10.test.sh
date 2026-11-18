#!/usr/bin/env bash
# Run the remote retirement and safety checks part.
FM_TEST_SUITE_PART=10 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
