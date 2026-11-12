#!/usr/bin/env bash
# fm-heavy-run.sh - run one heavy session at a time across homes and worktrees.
# Usage: fm-heavy-run.sh <command> [args...]
# Wrap the entire browser walkthrough or real-agent session, including cleanup,
# in the command (for example, fm-heavy-run.sh bash walkthrough.sh).
# Linux and macOS share /tmp/firstmate-heavy-<uid>.lock, independent of TMPDIR.
# A waiting invocation prints the holder PID and the one-line bypass:
#   FM_HEAVY_SKIP_HOST_LOCK=1 fm-heavy-run.sh <command> [args...]
# Nested commands inherit the session. Exit status and stdin are preserved;
# the wrapper owns the lock so background children cannot retain it after exit.
# FM_HEAVY_LOCK_DIR overrides /tmp for isolated regression fixtures only.
set -eu
case "${1:-}" in
  -h|--help|'') sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
esac
if [ "${FM_HEAVY_SKIP_HOST_LOCK:-0}" = 1 ] || [ "${FM_HEAVY_HOST_LOCKED:-0}" = 1 ]; then
  exec "$@"
fi
# Preserve the caller's stdin while Python reads its program from the heredoc.
exec python3 - "$@" 3<&0 <<'PYHEAVY'
import fcntl
import os
import signal
import subprocess
import sys

path = os.path.join(os.environ.get("FM_HEAVY_LOCK_DIR", "/tmp"),
                    f"firstmate-heavy-{os.getuid()}.lock")
fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    holder = os.read(fd, 32).decode(errors="replace") or "unknown"
    print(f"fm-heavy-run.sh: waiting for heavy session held by PID {holder}; "
          "skip: FM_HEAVY_SKIP_HOST_LOCK=1", file=sys.stderr, flush=True)
    fcntl.flock(fd, fcntl.LOCK_EX)
os.ftruncate(fd, 0)
os.lseek(fd, 0, os.SEEK_SET)
os.write(fd, str(os.getpid()).encode())
os.environ["FM_HEAVY_HOST_LOCKED"] = "1"
# close_fds keeps the lock in this wrapper, including when the command starts
# background children. Signals follow the foreground command before we wait.
child = subprocess.Popen(sys.argv[1:], stdin=3, close_fds=True)
def forward(signum, _frame):
    try:
        child.send_signal(signum)
    except ProcessLookupError:
        pass
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, forward)
rc = child.wait()
sys.exit(rc if rc >= 0 else 128 - rc)
PYHEAVY
