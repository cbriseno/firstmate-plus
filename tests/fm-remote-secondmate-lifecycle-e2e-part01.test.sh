#!/usr/bin/env bash
# Run the remote provisioning part of the lifecycle suite.
FM_TEST_SUITE_PART=1 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
