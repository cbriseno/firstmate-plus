#!/usr/bin/env bash
# Run remote config convergence and reread recovery checks.
FM_TEST_SUITE_PART=13 exec bash "$(dirname "$0")/fm-remote-secondmate-lifecycle-e2e.test.sh"
