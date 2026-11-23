#!/usr/bin/env bash
# Exercise recycling of an idle Treehouse slot and preservation of owned work.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
command -v treehouse >/dev/null || { echo 'skip: treehouse is unavailable'; exit 0; }
lab=$(fm_test_tmproot fm-pool-recycle)
repo="$lab/project"
export FM_HOME="$lab/home" TREEHOUSE_ROOT="$lab/pools"
mkdir -p "$repo" "$FM_HOME/state" "$FM_HOME/data" "$TREEHOUSE_ROOT"
git init -q -b main "$repo"
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base
printf 'max_trees = 1\n' > "$repo/treehouse.toml"
(cd "$repo" && SHELL=/bin/true treehouse get --no-fetch >/dev/null)
slot=$(cd "$repo" && treehouse status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["path"])')
git -C "$slot" switch -qc saved
git -C "$slot" -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m saved
saved=$(git -C "$slot" rev-parse HEAD)
recycle="$ROOT/bin/fm-treehouse-recycle.sh"
if (cd "$repo" && SHELL=/bin/true treehouse get --no-fetch >/dev/null 2>&1); then
  fail 'fixture did not exhaust the pool'
fi
printf 'worktree=%s\n' "$slot" > "$FM_HOME/state/owner.meta"
if bash "$recycle" "$repo" "$FM_HOME/state"; then fail 'recycled a recorded task copy'; fi
rm "$FM_HOME/state/owner.meta"
printf 'uncommitted\n' > "$slot/unsaved"
if bash "$recycle" "$repo" "$FM_HOME/state"; then fail 'recycled a dirty copy'; fi
rm "$slot/unsaved"
printf 'task=other\nhome=elsewhere\n' > "$(dirname "$slot")/.fm-slot-owner"
if bash "$recycle" "$repo" "$FM_HOME/state"; then fail 'recycled a claimed copy'; fi
rm "$(dirname "$slot")/.fm-slot-owner"
# A process that appears after selection must stop the return.
mkdir -p "$lab/bin"
FM_TEST_REAL_TREEHOUSE=$(command -v treehouse)
export FM_TEST_REAL_TREEHOUSE FM_TEST_COUNTER="$lab/status-count" FM_TEST_RETURNED="$lab/returned"
cat > "$lab/bin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "$*" = 'status --json' ]; then
  count=0
  [ ! -f "$FM_TEST_COUNTER" ] || count=$(cat "$FM_TEST_COUNTER")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_TEST_COUNTER"
  if [ "$count" -gt 1 ]; then
    "$FM_TEST_REAL_TREEHOUSE" status --json | python3 -c 'import json,sys; s=json.load(sys.stdin); s[0]["status"]="in-use"; s[0]["processes"]=[{"pid":1}]; json.dump(s,sys.stdout)'
    exit "$?"
  fi
elif [ "${1:-}" = return ]; then
  : > "$FM_TEST_RETURNED"
fi
exec "$FM_TEST_REAL_TREEHOUSE" "$@"
SH
chmod +x "$lab/bin/treehouse"
if PATH="$lab/bin:$PATH" bash "$recycle" "$repo" "$FM_HOME/state"; then
  fail 'recycled a copy after a process appeared'
fi
[ ! -e "$FM_TEST_RETURNED" ] || fail 'return ran after a process appeared'
bash "$recycle" "$repo" "$FM_HOME/state" || fail 'idle saved copy was not recycled'
[ "$(git -C "$repo" rev-parse saved)" = "$saved" ] || fail 'saved branch changed'
(cd "$repo" && SHELL=/bin/true treehouse get --no-fetch >/dev/null) || fail 'pool did not allocate the recycled copy'
pass 'idle saved work is preserved while a full pool recycles its unowned slot'
