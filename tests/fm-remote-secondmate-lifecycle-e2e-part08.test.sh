#!/usr/bin/env bash
# Run the concurrent remote spawn and inheritance part.
FM_TEST_SUITE_PART=8 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
