#!/usr/bin/env bash
# Read-only local prerequisite check, with no installs, network or fleet actions.
# Usage: bash bin/fm-doctor.sh [--backend <name>]
# Defaults to normal backend resolution (FM_BACKEND/config/ambient/tmux).
# Reports command availability, basic Unix capabilities and the selected route;
# bootstrap remains the owner of tool version/authentication compatibility.
# Exit 0: prerequisites found (not a live harness/backend certification).
# Exit 1: missing prerequisite/capability. Exit 2: unsupported platform/options.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-platform-lib.sh
. "$SCRIPT_DIR/fm-platform-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
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
for tool in bash git python3 perl jq node gh gh-axi no-mistakes chrome-devtools-axi tasks-axi quota-axi; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf 'available: %s\n' "$tool"
  else
    printf 'missing: %s\n' "$tool"
    result=1
  fi
done
for tool in $(fm_backend_required_tools "$backend"); do
  if fm_backend_required_tool_available "$backend" "$tool"; then
    printf 'available: %s\n' "$tool"
  else
    printf 'missing: %s\n' "$tool"
    result=1
  fi
done
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
