#!/usr/bin/env bash
# Apply the primary's configured effort to every start of its harness.
#
# Usage: fm-primary-effort.sh <home>
#
# config/primary-effort holds one level (low|medium|high|xhigh) for the home's
# primary. Only the automatic relay passed it on the command line, so any other
# start (reboot, Herdr pane restore, `claude --resume`, by hand) fell back to
# the harness's global default. Both harnesses read project-local settings at
# every start and resume, so the level is written there, once per bootstrap:
#   Claude  <home>/.claude/settings.local.json   "effortLevel"
#   Codex   <home>/.codex/config.toml            top-level model_reasoning_effort
# Other keys in those files are kept. An absent file, `configured`, `default`
# or any other token changes nothing. Silent when already applied; one
# BOOTSTRAP_INFO line when a file is written. Needs python3 (stdlib only) for
# the JSON merge; the TOML edit is line-based and has no OS-specific tools.
set -eu

home=${1:?usage: fm-primary-effort.sh <home>}
cfg=$home/config/primary-effort
[ -f "$cfg" ] || exit 0
level=
read -r level _ <"$cfg" || true
case "$level" in
low | medium | high | xhigh) ;;
*) exit 0 ;;
esac

mkdir -p "$home/.claude" "$home/.codex"

# Claude: merge effortLevel into the project-local settings.
python3 -I - "$home/.claude/settings.local.json" "$level" <<'PY' || echo "BOOTSTRAP_INFO: could not apply primary effort to $home/.claude/settings.local.json" >&2
import json, os, sys
path, level = sys.argv[1:3]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
if data.get("effortLevel") == level:
    sys.exit(0)
data["effortLevel"] = level
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("BOOTSTRAP_INFO: set primary effort %s in %s" % (level, path))
PY

# Codex: replace or insert the top-level key (before the first table header).
toml=$home/.codex/config.toml
want="model_reasoning_effort = \"$level\""
if [ -f "$toml" ] && grep -qxF "$want" "$toml" && ! awk '/^\[/{exit} /^model_reasoning_effort[ \t]*=/{n++} END{exit !(n>1)}' "$toml"; then
  exit 0
fi
tmp=$toml.tmp.$$
if [ -f "$toml" ]; then
  awk -v want="$want" '
    !intable && /^\[/ { if (!done) { print want; done = 1 } intable = 1 }
    !intable && /^model_reasoning_effort[ \t]*=/ { if (!done) { print want; done = 1 } next }
    { print }
    END { if (!done) print want }' "$toml" >"$tmp"
else
  printf '%s\n' "$want" >"$tmp"
fi
mv "$tmp" "$toml"
echo "BOOTSTRAP_INFO: set primary effort $level in $toml"
