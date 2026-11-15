#!/usr/bin/env bash
# PR check security: providers gerrit tree.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_gerrit_ready_gate_reads_the_published_tree
