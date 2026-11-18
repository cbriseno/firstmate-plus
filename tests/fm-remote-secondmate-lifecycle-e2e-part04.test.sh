#!/usr/bin/env bash
# Run the legacy endpoint refusal part.
FM_TEST_SUITE_PART=4 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
