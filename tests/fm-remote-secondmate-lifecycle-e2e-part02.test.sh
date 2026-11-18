#!/usr/bin/env bash
# Run the remote seed and origin part of the lifecycle suite.
FM_TEST_SUITE_PART=2 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
