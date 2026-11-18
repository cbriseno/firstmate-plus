#!/usr/bin/env bash
# Run serialized remote retirement and archival checks.
FM_TEST_SUITE_PART=17 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
