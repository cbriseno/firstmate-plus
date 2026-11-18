#!/usr/bin/env bash
# Run concurrent remote config convergence checks.
FM_TEST_SUITE_PART=14 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
