#!/usr/bin/env bash
# tests/git-config-helpers.sh - fixture Git isolation from the host's global and
# system configuration and from an inherited repository location.
#
# Source this before a fixture's first Git operation:
#   # shellcheck source=tests/git-config-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"
#
# Fixture Git processes must not inherit host signing, hooks, or other global and
# system preferences: with commit.gpgsign=true set globally and no secret key for
# the fixture identities, every fixture commit fails before its assertion.
# An inherited command-scope core.hooksPath is removed as well, so worker hooks
# do not govern fixture pushes. Other command-scope settings, repository-local
# config, inline `git -c`, and configuration supplied after sourcing remain
# authoritative - the Git-config suites assert on them.
# The export reaches only the sourcing shell and its children, so the developer's
# own config files are never written and real project commits made outside the
# fixtures keep their configuration and signing.
#
# The repository-location variables are cleared too: an absolute GIT_DIR (as a
# linked-worktree hook exports) overrides the discovery `git -C <fixture>`
# implies, so fixture refs, commits, and worktree registrations would land in
# the caller's repository instead. A suite that wants one sets it after sourcing.
#
# tests/lib.sh and tests/herdr-test-safety.sh source this for every suite that
# uses them, bin/fm-test-run.sh sources it per suite in run_script_bounded, and a
# suite reaching none of those sources it directly so a hand-run invocation is
# isolated too. tests/fm-test-fixtures.test.sh is the regression - it drives the
# shared helpers, the runner, and the standalone entry points that run without a
# live vendor - and the changed-file map selects it for a change to this file.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
fm_test_clear_inherited_hooks() {
  local count=${GIT_CONFIG_COUNT:-0} read=0 write=0 keyvar valuevar key value
  case "$count" in ''|*[!0-9]*) return ;; esac
  while [ "$read" -lt "$count" ]; do
    keyvar=GIT_CONFIG_KEY_$read valuevar=GIT_CONFIG_VALUE_$read
    key=${!keyvar-} value=${!valuevar-}
    case "$key" in
      [cC][oO][rR][eE].[hH][oO][oO][kK][sS][pP][aA][tT][hH]) ;;
      *) printf -v "GIT_CONFIG_KEY_$write" '%s' "$key"
         printf -v "GIT_CONFIG_VALUE_$write" '%s' "$value"
         export "GIT_CONFIG_KEY_$write" "GIT_CONFIG_VALUE_$write"
         write=$((write + 1)) ;;
    esac
    read=$((read + 1))
  done
  if [ "$write" -ne "$count" ]; then export GIT_CONFIG_COUNT=$write; fi
}
fm_test_clear_inherited_hooks
unset -f fm_test_clear_inherited_hooks
