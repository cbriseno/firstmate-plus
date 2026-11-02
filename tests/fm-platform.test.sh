#!/usr/bin/env bash
# Platform route classification and early refusal before operational writes.
# Shim classifications are contract tests, never evidence of execution on an OS.
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TASK_TMP=$(fm_test_tmproot fm-platform)
mkdir -p "$TASK_TMP/fakebin"
cat > "$TASK_TMP/fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -r) printf '%s\n' "$TEST_RELEASE" ;;
  *) printf '%s\n' "$TEST_KERNEL" ;;
esac
SH
chmod +x "$TASK_TMP/fakebin/uname"
export PATH="$TASK_TMP/fakebin:$PATH"
export TEST_KERNEL TEST_RELEASE
TEST_RELEASE=generic
# shellcheck source=bin/fm-platform-lib.sh disable=SC1091
. "$ROOT/bin/fm-platform-lib.sh"
for pair in 'Linux linux' 'Darwin macos' 'MINGW64_NT windows-shell' 'MSYS_NT windows-shell' 'CYGWIN_NT windows-shell' 'FreeBSD unsupported'; do
  read -r TEST_KERNEL expected <<< "$pair"
  [ "$(fm_platform_name)" = "$expected" ] || fail "platform classification: $expected"
done
TEST_KERNEL=Linux
TEST_RELEASE=6.6.87.2-microsoft-standard-WSL2
[ "$(fm_platform_name)" = wsl2 ] || fail 'WSL2 route'
fm_platform_require || fail 'WSL2 classification acceptance'
TEST_RELEASE=4.4.0-Microsoft
[ "$(fm_platform_name)" = wsl1 ] || fail 'WSL1 classification'
if fm_platform_require 2>/dev/null; then fail 'WSL1 must refuse'; fi
TEST_KERNEL=MINGW64_NT
export FM_HOME="$TASK_TMP/untouched-home"
for command in fm-session-start.sh fm-bootstrap.sh fm-spawn.sh fm-doctor.sh; do
  rc=0
  bash "$ROOT/bin/$command" > "$TASK_TMP/result" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "$command unsupported-platform exit"
  [ ! -e "$FM_HOME" ] || fail "$command wrote an unsupported home"
  assert_contains "$(cat "$TASK_TMP/result")" PLATFORM_UNSUPPORTED "$command explains WSL2 route"
done
printf 'PASS: platform classifications and four fail-closed entry points (simulated kernels)\n'

# The Linux kernel route alone is insufficient when utilities report different
# lock ownership and deadline results. Doctor must expose the tool prerequisite
# without invoking a backend or changing the temporary operational home.
TEST_KERNEL=Linux
TEST_RELEASE=generic
for tool in node gh gh-axi no-mistakes chrome-devtools-axi tasks-axi quota-axi tmux treehouse; do
  printf '#!/bin/sh\nexit 0\n' > "$TASK_TMP/fakebin/$tool"
  chmod +x "$TASK_TMP/fakebin/$tool"
done
REAL_CAT=$(command -v cat)
export REAL_CAT
for tool in mkdir timeout cat; do
  cat > "$TASK_TMP/fakebin/$tool" <<'SH'
#!/bin/sh
if [ "${0##*/}" = cat ] && [ "${1:-}" != --version ]; then
  exec "$REAL_CAT" "$@"
fi
[ "${1:-}" = --version ] || exit 99
printf '%s\n' "${0##*/} (${TEST_COREUTILS}) 0.10.0"
SH
  chmod +x "$TASK_TMP/fakebin/$tool"
done
export TEST_COREUTILS='uutils coreutils'
rc=0
bash "$ROOT/bin/fm-doctor.sh" --backend tmux > "$TASK_TMP/result" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail 'doctor must refuse the unsupported Linux utility route'
for tool in mkdir timeout cat; do
  assert_contains "$(cat "$TASK_TMP/result")" "unsupported: Linux requires GNU $tool on PATH" \
    "doctor explains the $tool prerequisite"
done
TEST_COREUTILS='GNU coreutils'
bash "$ROOT/bin/fm-doctor.sh" --backend tmux > "$TASK_TMP/result" 2>&1 \
  || fail "doctor refused the complete GNU prerequisite fixture: $(cat "$TASK_TMP/result")"
[ ! -e "$FM_HOME" ] || fail 'doctor changed the operational home'
printf 'PASS: doctor distinguishes Linux utility prerequisites without runtime mutation (simulated versions)\n'
