#!/usr/bin/env bash
# PR check security: providers forgejo.
set -u

# shellcheck source=tests/pr-check-security-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-check-security-helpers.sh"

pr_security_run_cases \
  test_forgejo_merge_watch \
  test_forgejo_login_list_shapes
