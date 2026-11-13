#!/usr/bin/env bash
# Read-only local prerequisite check, with no installs, network or fleet actions.
# Usage: bash bin/fm-doctor.sh [--backend <name> | --tools]
# Defaults to normal backend resolution (FM_BACKEND/config/ambient/tmux).
# Reports command availability, basic Unix capabilities and the selected route;
# missing feature tools are optional and report their effect without failing.
# bootstrap remains the owner of tool version/authentication compatibility.
# Exit 0: prerequisites found (not a live harness/backend certification).
# Exit 1: missing prerequisite/capability. Exit 2: unsupported platform/options.
set -eu
# Inventory mode performs no fleet, authentication, network, or installation work.
if [ "${1:-}" = --tools ] && [ "$#" = 1 ]; then
  printf '%-21s | %-24s | %-12s | %-12s | %s\n' 'Tool (scope)' 'Found version' 'Minimum' 'macOS ships' 'Unavailable if missing'
  inventory() {
    local tool=$1 scope=$2 minimum=$3 shipped=$4 effect=$5 version
    if command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        tmux) version=$("$tool" -V 2>/dev/null) || version= ;;
        *) version=$("$tool" --version 2>/dev/null) || version= ;;
      esac
      version=${version%%$'\n'*}
      [ -n "$version" ] || version='present; unknown'
    else
      version=missing
    fi
    printf '%-21s | %-24.24s | %-12s | %-12s | %s\n' "$tool ($scope)" "$version" "$minimum" "$shipped" "$effect"
  }
  inventory bash core 3.2 yes 'shell entry points'
  inventory python3 core 3.9 'not assured' 'work API and POSIX locking'
  inventory git core unknown 'shim' 'project and task branches'
  inventory perl core unknown yes 'text processing'
  inventory jq core unknown no 'JSON-dependent operations'
  inventory node core 'unknown' no 'Node-based tooling'
  inventory ps core unknown yes 'process inspection'
  for tool in awk basename cat chmod cp cut date dirname find grep head id ln ls mkdir mktemp mv od rm sed sort stat tail touch tr uname; do
    inventory "$tool" core unknown yes 'shell operations using this utility'
  done
  inventory shasum core unknown yes 'home identity (sha256sum is an alternative)'
  inventory tmux backend unknown no 'tmux backend'
  inventory treehouse backend 'lease support' no 'isolated tmux worktrees'
  inventory herdr backend unknown no 'Herdr backend'
  inventory cmux backend unknown no 'cmux backend'
  inventory gh forge unknown no 'GitHub operations'
  inventory gh-axi forge 0.1.29 no 'GitHub integration'
  inventory tasks-axi backlog 0.2.6 no 'tasks-axi backlog'
  inventory quota-axi quota 0.1.51 no 'quota-array selection'
  inventory no-mistakes delivery 1.46.0 no 'no-mistakes delivery'
  inventory chrome-devtools-axi browser unknown no 'browser operations'
  inventory curl optional unknown yes 'network probes and integrations'
  inventory ssh optional unknown yes 'remote workers'
  inventory lsof optional unknown yes 'some teardown process checks'
  inventory launchctl optional unknown yes 'macOS remote worker service'
  inventory osascript optional unknown yes 'macOS automation'
  inventory timeout optional unknown no 'GNU timeout; portable fallback available'
  inventory sha256sum optional unknown no 'SHA-256 alternative to shasum'
  inventory openssl optional unknown yes 'optional cryptographic helpers'
  inventory lavish-axi optional unknown no 'visual review'
  inventory glab optional unknown no 'GitLab operations'
  inventory tea optional unknown no 'Forgejo operations'
  inventory gerrit-axi optional unknown no 'Gerrit operations'
  inventory shellcheck development 0.11.0 no 'shell lint'
  inventory actionlint development 1.7.12 no 'workflow lint'
  inventory codex agent unknown no 'Codex agent'
  inventory claude agent unknown no 'Claude agent'
  inventory pi agent unknown no 'Pi agent'
  for tool in opencode grok kimi cursor gemini muse rovo omp agy devin commandcode polytoken; do
    inventory "$tool" agent unknown no "$tool agent"
  done
  printf '%s\n' 'Extensions and agent-specific helpers are conditional; see docs/configuration.md. Versions marked unknown are not established minimums.'
  exit 0
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-platform-lib.sh
. "$SCRIPT_DIR/fm-platform-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
backend=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backend) [ "$#" -ge 2 ] || exit 2; backend=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    *) printf 'fm-doctor: unknown option\n' >&2; exit 2 ;;
  esac
done
printf 'platform: %s\n' "$(fm_platform_name)"
fm_platform_require || exit 2
[ -n "$backend" ] || backend=$(fm_backend_name)
fm_backend_validate "$backend" || exit 2
printf 'backend: %s\n' "$backend"
result=0
# Directory claims, wake writes and checkpoint deadlines rely on GNU semantics
# on Linux. A kernel classification alone cannot establish that tool contract.
case "$(fm_platform_name)" in
  linux|wsl2)
    for tool in mkdir timeout cat; do
      version=$("$tool" --version 2>/dev/null || true)
      case "$version" in
        *'(GNU coreutils)'*) printf 'available: GNU %s\n' "$tool" ;;
        *)
          printf 'unsupported: Linux requires GNU %s on PATH; see docs/platforms.md\n' "$tool"
          result=1
          ;;
      esac
    done
    ;;
esac
required_tools='bash git python3 perl jq node'
config=${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}/config}
fm_backlog_backend_manual "$config" || required_tools="$required_tools tasks-axi"
for tool in $required_tools; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'available: %s\n' "$tool"
  else
    printf 'missing: %s\n' "$tool"
    result=1
  fi
done
for tool in $(fm_backend_required_tools "$backend"); do
  # Worktree allocation is a dispatch prerequisite, not a startup prerequisite.
  [ "$tool" != treehouse ] || continue
  if fm_backend_required_tool_available "$backend" "$tool"; then
    printf 'available: %s\n' "$tool"
  else
    printf 'missing: %s\n' "$tool"
    result=1
  fi
done
optional() {
  local tool=$1 effect=$2 availability=missing
  command -v "$tool" >/dev/null 2>&1 && availability=available
  printf 'optional: %s (%s; unavailable if missing: %s)\n' "$tool" "$availability" "$effect"
}
optional gh 'GitHub operations'
optional gh-axi 'GitHub integration'
optional no-mistakes 'no-mistakes delivery when explicitly requested'
optional chrome-devtools-axi 'browser operations'
optional quota-axi 'quota-based dispatch selection'
optional treehouse 'isolated task dispatch'
optional lavish-axi 'visual review'
fm_backlog_backend_manual "$config" && optional tasks-axi 'tasks-axi backlog operations'
if ! python3 -c 'import fcntl, os, sys; sys.exit(0 if sys.version_info >= (3, 9) and hasattr(os, "killpg") else 1)' >/dev/null 2>&1; then
  printf 'missing: Python 3.9+ with POSIX locking and process groups\n'
  result=1
fi
if ! ps -p "$$" -o pid= -o ppid= >/dev/null 2>&1; then
  printf 'missing: POSIX process inspection\n'
  result=1
fi
if [ "$backend" = cmux ] && [ "$(fm_platform_name)" != macos ]; then
  printf 'unsupported: cmux requires macOS; select an available runtime explicitly\n'
  result=1
fi
printf 'native-codex: optional Linux-only binding; no transport acceptance implied\n'
printf 'scope: prerequisite check only; bootstrap owns versions/auth and backend guides own live acceptance\n'
exit "$result"
