#!/usr/bin/env bash
# Run the marked remote send and correlated reply part.
FM_TEST_SUITE_PART=9 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
