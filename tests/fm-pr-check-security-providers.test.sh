#!/usr/bin/env bash
# PR check security: providers cases; shared fixtures own each behavior case.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

test_gitlab_merge_watch
test_forgejo_merge_watch
test_forgejo_login_list_shapes
test_gerrit_merge_watch
test_gerrit_arming_records_no_patch_set_revision
test_gerrit_ready_gate_reads_the_published_tree
test_gerrit_nm_ready_gate_requires_recovered_custody
