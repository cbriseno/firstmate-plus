#!/usr/bin/env bash
# Run the partial-inheritance launch refusal part.
FM_TEST_SUITE_PART=3 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
