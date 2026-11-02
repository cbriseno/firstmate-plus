#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the primary write guard (docs/primary-write-guard.md).
#
# bin/fm-primary-write-policy.mjs owns the per-target decision,
# bin/fm-primary-write-pretool-check.sh owns scope, the allowed-path set, the
# escape hatch, and harness rendering, and bin/fm-primary-write-grant.sh owns
# captain-approval grants. This suite proves the refusals for every covered
# write shape, every documented carve-out, grant lifecycle, primary-home scope
# (inert in a task worktree and a non-firstmate repo, live in a secondmate
# home), the escape hatch, both stdin transports, fail-open transport, and the
# tracked Claude and Codex registrations executed the way each harness runs
# them. No harness is spawned; live evidence lives in the guard doc.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-primary-write-tests)
CHECK="$ROOT/bin/fm-primary-write-pretool-check.sh"
GRANT="$ROOT/bin/fm-primary-write-grant.sh"
POLICY="$ROOT/bin/fm-primary-write-policy.mjs"

# The fixture lives under the test temp root, so the real temp directories
# would allow every path in it. Each run instead names one dedicated temp dir.
REAL_HOME=$HOME
USERHOME="$TMP_ROOT/userhome"
SCRATCH="$TMP_ROOT/scratch-tmp"
PRIMARY="$TMP_ROOT/primary"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
mkdir -p "$USERHOME/.config" "$SCRATCH"

# make_home <dir> [<bin-link-target>]: a plain primary-shaped checkout, with
# bin/ as an empty directory or as a symlink to the given scripts directory.
make_home() {
  local dir=$1 bin_target=${2:-}
  mkdir -p "$dir"
  git init -q "$dir"
  printf '# fixture\n' > "$dir/AGENTS.md"
  git -C "$dir" add AGENTS.md
  git -C "$dir" commit -q -m init
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects/foo"
  if [ -n "$bin_target" ]; then
    ln -s "$bin_target" "$dir/bin"
  else
    mkdir -p "$dir/bin"
  fi
}
make_home "$PRIMARY"

guard_env() {
  env HOME="$USERHOME" FM_ROOT_OVERRIDE="$1" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" FM_PROJECTS_OVERRIDE="$1/projects" \
    FM_PRIMARY_WRITE_TEMP_DIRS="$SCRATCH" FM_ALLOW_PRIMARY_WRITE= "${@:2}"
}

# run_cli <home> <tool> <command-or-path> [extra env...]
run_cli() {
  local home=$1 tool=$2 value=$3 rc=0 flag=--command
  shift 3
  case "$tool" in Edit|MultiEdit|Write|NotebookEdit) flag=--path ;; esac
  : > "$OUT"; : > "$ERR"
  guard_env "$home" "$@" "$CHECK" --claude --tool "$tool" --cwd "$home" "$flag" "$value" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_deny() {
  local label=$1 code=$2 tool=$3 value=$4 rc=0
  shift 4
  run_cli "$PRIMARY" "$tool" "$value" "$@" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc: $value"
  [ ! -s "$OUT" ] || fail "$label --claude deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted the permission decision: $(cat "$ERR")"
  jq -e --arg code "[$code]" '.systemMessage | startswith($code)' "$ERR" >/dev/null 2>&1 \
    || fail "$label expected code [$code], got: $(jq -r '.systemMessage' "$ERR" 2>/dev/null)"
}

expect_allow() {
  local label=$1 tool=$2 value=$3 rc=0
  shift 3
  run_cli "$PRIMARY" "$tool" "$value" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $value: $(cat "$ERR")"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "$label allow wrote output: $(cat "$OUT" "$ERR")"
}

test_refuses_captain_environment_writes() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    expect_deny "environment write" primary-write Bash "$c"
  done <<'EOF'
echo "alias ll='ls -l'" >> ~/.bash_aliases
printf 'x\n' > $HOME/.config/plugin.json
echo x | tee -a ~/.bashrc
echo x | sudo tee /etc/hosts
sed -i 's/a/b/' ~/.profile
sed -i.bak -e 's/a/b/' ~/.profile
perl -pi -e 's/a/b/' ~/.gitconfig
ruby -pi -e 'gsub(/a/, "b")' ~/.gitconfig
cp data/x ~/.local/bin/tool
install -m 755 data/x ~/.local/bin/tool
mv data/notes ~/notes
ln -s /opt/tool ~/.local/bin/tool
mkdir -p ~/.config/newplugin
touch ~/.hushlogin
chmod +x ~/.local/bin/tool
rm -f ~/.cache/thing
truncate -s 0 ~/.bash_history
dd if=/dev/zero of=$HOME/blob bs=1 count=1
curl -fsSLo ~/.local/bin/tool https://example.invalid/tool
wget -O ~/tool https://example.invalid/tool
python3 -c "open('/etc/motd', 'a').write('x')"
python3 -c "import os; open(os.path.expanduser('~/.bash_aliases'), 'a').write('x')"
node -e "require('fs').writeFileSync(require('path').join(require('os').homedir(), '.npmrc'), 'x')"
node -e "require('fs').appendFileSync('/etc/motd', 'x')"
bash -c 'echo x >> ~/.zshrc'
sh -c "printf x > ~/.config/plugin.json"
eval 'echo x >> ~/.bashrc'
echo x > ~/.config/$UNSET_NAME_FOR_TEST
find ~/.cache -name '*.tmp' -delete
find data -name x -exec cp {} ~/.config/ \;
printf '%s\n' a | xargs -I{} cp {} ~/.config/
git -C ~/dotfiles commit -am tweak
EOF
  expect_deny "heredoc into a dotfile" primary-write Bash "$(printf 'cat > ~/.config/plugin.json <<%s\n{"a": 1}\n%s' "'JSON'" "JSON")"
  expect_deny "python heredoc pathlib write" primary-write Bash "$(printf 'python3 - <<%s\nfrom pathlib import Path\n(Path.home() / %s).write_text(%s)\nPY' "'PY'" "'.bash_aliases'" "'x'")"
  expect_deny "shell heredoc" primary-write Bash "$(printf 'bash <<EOF\necho x >> ~/.bashrc\nEOF')"
  expect_deny "Write tool to a dotfile" primary-write Write "$USERHOME/.bash_aliases"
  expect_deny "Edit tool to user config" primary-write Edit "$USERHOME/.config/plugin.json"
  expect_deny "MultiEdit tool to user config" primary-write MultiEdit "$USERHOME/.config/plugin.json"
  expect_deny "apply_patch add outside" primary-write apply_patch "$(printf '*** Begin Patch\n*** Add File: %s/.bash_aliases\n+x\n*** End Patch' "$USERHOME")"
  expect_deny "apply_patch move outside" primary-write apply_patch "$(printf '*** Begin Patch\n*** Update File: data/a\n*** Move to: %s/a\n*** End Patch' "$USERHOME")"
  pass "refuses direct writes to the captain's shell, dotfiles, user config, and system files across every covered shape"
}

test_refuses_project_and_shared_material_writes() {
  expect_deny "redirect into a project" primary-write-project Bash 'echo x > projects/foo/README.md'
  expect_deny "cp into a project" primary-write-project Bash 'cp data/x projects/foo/x'
  expect_deny "subshell cd into a project" primary-write-project Bash '(cd projects/foo && echo x > out.txt)'
  expect_deny "git commit in a project" primary-write-project Bash 'git -C projects/foo commit -am x'
  expect_deny "git checkout in a project" primary-write-project Bash 'git -C projects/foo checkout -b topic'
  expect_deny "git clone into projects" primary-write-project Bash 'git clone https://example.invalid/y.git projects/y'
  expect_deny "Write into a project" primary-write-project Write "$PRIMARY/projects/foo/x.txt"
  expect_deny "NotebookEdit in a project" primary-write-project NotebookEdit "$PRIMARY/projects/foo/n.ipynb"
  expect_deny "apply_patch into a project" primary-write-project apply_patch "$(printf '*** Begin Patch\n*** Update File: projects/foo/a\n*** End Patch')"
  expect_deny "Write tracked shared material" primary-write Write "$PRIMARY/AGENTS.md"
  expect_deny "redirect over tracked shared material" primary-write Bash 'echo x >> AGENTS.md'
  expect_deny "git commit on the home checkout" primary-write Bash 'git commit -am "edit shared material"'
  expect_deny "git apply on the home checkout" primary-write Bash 'git apply data/change.diff'
  expect_deny "forged grant record" primary-write-grant-record Bash 'echo path=/ > state/primary-write-grants/1.grant'
  expect_deny "Write a grant record" primary-write-grant-record Write "$PRIMARY/state/primary-write-grants/1.grant"
  pass "refuses project-clone writes, shared tracked material, home-checkout git writes, and forged grant records"
}

test_allows_operational_paths_and_read_only_work() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    expect_allow "operational command" Bash "$c"
  done <<'EOF'
echo "working [at=1]: x" >> state/task.status
bin/fm-brief.sh t1 repo --mode direct-PR > data/t1/brief.md 2>/dev/null
printf 'x\n' > config/ready-after-green
mkdir -p data/t1 && cp state/a data/t1/a
sed -i 's/old/new/' data/backlog.md
sed -ie 's/old/new/' data/backlog.md
echo x | tee data/report.md >/dev/null
rm -f state/x-inbox/1.json
echo x > .lavish/board.html
echo KEY=1 >> .env
mv data/t1/report.draft data/t1/report.md
echo x 2>&1 >/dev/null
echo x >&2
cat projects/foo/README.md
git -C projects/foo log --oneline -5
git -C projects/foo status --short
git fetch origin
git checkout main
git switch main
ls -la ~/.config
grep -r alias ~/.bashrc
tmp=$(mktemp) && echo x > "$tmp" && rm -f "$tmp"
echo x > "$SOME_UNSET_SCRATCH_PATH_FOR_TEST"
echo x > state/$ID.status
node -e "console.log(require('fs').readFileSync('/etc/hostname','utf8'))"
python3 -c "print(open('/etc/hostname').read())"
wget -qO- https://example.invalid/x
curl -fsSL https://example.invalid/x
find state -name '*.tmp' -exec rm {} \;
printf '%s\n' a | xargs -I{} rm -f {}
EOF
  expect_allow "scratch temp dir" Bash "echo x > $SCRATCH/out.txt"
  expect_allow "python scratch write" Bash "python3 -c \"open('$SCRATCH/x', 'w').write('x')\""
  expect_allow "Edit captain preferences" Edit "$PRIMARY/data/captain.md"
  expect_allow "Write a brief" Write "$PRIMARY/data/t1/brief.md"
  expect_allow "Write config" Write "$PRIMARY/config/backend"
  expect_allow "Write a lavish report" Write "$PRIMARY/.lavish/review.html"
  expect_allow "Write home scratchpad" Write "$PRIMARY/scratchpad-notes.md"
  expect_allow "apply_patch on state" apply_patch "$(printf '*** Begin Patch\n*** Add File: state/x\n+x\n*** End Patch')"
  expect_allow "Read tool is never classified" Read "$USERHOME/.bashrc"
  expect_allow "unguarded tool" WebFetch "https://example.invalid"
  pass "allows state, data, config, .lavish, .env, scratch, temp writes, read-only work, and tangle-restore git"
}

test_secondmate_carve_outs() {
  local mate="$TMP_ROOT/mate-home" parent="$TMP_ROOT/parent-home"
  make_home "$mate"
  make_home "$parent"
  printf -- '- mate-a - test mate (home: %s; scope: tests; projects: none; added 2026-01-01)\n' "$mate" > "$PRIMARY/data/secondmates.md"
  expect_allow "main home curates a registered mate's memory" Write "$mate/data/captain.md"
  expect_allow "main home trims a registered mate's backlog" Bash "echo x >> $mate/data/backlog.md"
  expect_deny "main home cannot write a registered mate's projects" primary-write Write "$mate/projects/foo/x"
  rm -f "$PRIMARY/data/secondmates.md"
  expect_deny "unregistered mate home stays outside" primary-write Write "$mate/data/captain.md"

  printf 'mate-a\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.fm-secondmate-parent"
  local rc=0
  : > "$OUT"; : > "$ERR"
  guard_env "$mate" "$CHECK" --claude --tool Bash --cwd "$mate" \
    --command "echo 'done [at=1]: x' >> $parent/state/mate-a.status" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a secondmate home must reach its parent channel, got $rc: $(cat "$ERR")"
  rc=0
  guard_env "$mate" "$CHECK" --claude --tool Bash --cwd "$mate" \
    --command "echo x >> $parent/state/other.status" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a secondmate home must not write other parent state, got $rc"
  rc=0
  guard_env "$mate" "$CHECK" --claude --tool Bash --cwd "$mate" --command "echo x >> ~/.bashrc" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a secondmate home is in scope and must refuse dotfile writes, got $rc"
  pass "registered local mate homes and a mate's own parent channel are carve-outs; a mate home is itself guarded"
}

test_grant_lifecycle() {
  local rc=0 out
  out=$(guard_env "$PRIMARY" "$GRANT" grant "$PRIMARY/projects/foo" --approval 'yes, delete the stale lock file in foo' 2>&1) \
    || fail "grant for a project clone must succeed: $out"
  expect_allow "granted project write" Bash 'rm -f projects/foo/.stale.lock'
  expect_allow "granted project Write" Write "$PRIMARY/projects/foo/x.txt"
  expect_deny "grant does not leak to a sibling project" primary-write-project Write "$PRIMARY/projects/bar/x.txt"
  guard_env "$PRIMARY" "$GRANT" list | grep -q 'yes, delete the stale lock file in foo' \
    || fail "grant list must show the recorded approval"
  guard_env "$PRIMARY" "$GRANT" revoke "$PRIMARY/projects/foo" >/dev/null || fail "revoke must succeed"
  expect_deny "revoked grant" primary-write-project Bash 'rm -f projects/foo/.stale.lock'

  guard_env "$PRIMARY" "$GRANT" grant "$PRIMARY/projects/new-clone" --approval 'add the new-clone project' >/dev/null \
    || fail "grant for a future clone path must succeed"
  expect_allow "granted clone intake" Bash 'git clone https://example.invalid/new-clone.git projects/new-clone'
  printf 'path=%s\ngranted=1\nexpires=2\napproval=old\n' "$PRIMARY/projects/new-clone" \
    > "$PRIMARY/state/primary-write-grants/$(printf '%s' "$PRIMARY/projects/new-clone" | cksum | awk '{print $1}').grant"
  expect_deny "expired grant" primary-write-project Bash 'git clone https://example.invalid/new-clone.git projects/new-clone'

  guard_env "$PRIMARY" "$GRANT" grant "$PRIMARY/.agents/skills/local-note" --approval 'migrate the pinned entry' >/dev/null \
    || fail "an untracked home path must be grantable"
  expect_allow "granted untracked local skill" Write "$PRIMARY/.agents/skills/local-note/SKILL.md"

  for target in "$USERHOME/.bash_aliases" "$PRIMARY/AGENTS.md" "$PRIMARY" "$PRIMARY/.git/config" "$PRIMARY/projects"; do
    rc=0
    guard_env "$PRIMARY" "$GRANT" grant "$target" --approval 'x' >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 1 ] || fail "grant must refuse $target, got $rc"
  done
  rc=0
  guard_env "$PRIMARY" "$GRANT" grant "$PRIMARY/projects/foo" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "grant without --approval must be a usage error, got $rc"
  rc=0
  guard_env "$PRIMARY" "$GRANT" grant "$PRIMARY/projects/foo" --approval x --minutes 999 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "grant beyond the maximum lifetime must be a usage error, got $rc"
  guard_env "$PRIMARY" "$GRANT" revoke --all >/dev/null
  pass "grants open exactly one approved project or untracked home path until revoked or expired, and refuse everything else"
}

test_scope_and_escape_hatch() {
  local wt="$TMP_ROOT/task-wt" base="$TMP_ROOT/task-base" plain="$TMP_ROOT/not-firstmate" rc value
  fm_git_worktree "$base" "$wt" fm/primary-write-test
  printf '# fixture\n' > "$wt/AGENTS.md"
  mkdir -p "$wt/bin" "$wt/state"
  rc=0
  run_cli "$wt" Bash 'echo x >> ~/.bashrc' || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$ERR" ] || fail "guard must be inert in a linked task worktree, got $rc: $(cat "$ERR")"
  rc=0
  run_cli "$wt" Write "$USERHOME/.bashrc" || rc=$?
  [ "$rc" -eq 0 ] || fail "file tools must be inert in a linked task worktree, got $rc"

  mkdir -p "$plain/bin" "$plain/state"
  git init -q "$plain"
  rc=0
  run_cli "$plain" Bash 'echo x >> ~/.bashrc' || rc=$?
  [ "$rc" -eq 0 ] || fail "guard must be inert outside a firstmate home, got $rc"

  expect_allow "escape hatch" Bash 'echo x >> ~/.bashrc' FM_ALLOW_PRIMARY_WRITE=1
  for value in 0 yes true; do
    expect_deny "escape hatch value $value" primary-write Bash 'echo x >> ~/.bashrc' FM_ALLOW_PRIMARY_WRITE="$value"
  done
  pass "inert in task worktrees and non-firstmate repos; FM_ALLOW_PRIMARY_WRITE=1 is the only escape"
}

test_stdin_transports() {
  local rc payload
  payload=$(jq -cn --arg cwd "$PRIMARY" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"echo x >> ~/.bashrc"}}')
  rc=0; : > "$OUT"; : > "$ERR"
  printf '%s' "$payload" | guard_env "$PRIMARY" "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Codex-shaped stdin deny must exit 2, got $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[primary-write]"))' "$OUT" >/dev/null || fail "default mode must emit the stdout decision object"
  jq -e '.systemMessage | startswith("[primary-write]")' "$ERR" >/dev/null || fail "default mode must emit the stderr deny object"

  payload=$(jq -cn --arg cwd "$PRIMARY" --arg p "$USERHOME/.bashrc" '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}')
  rc=0; : > "$OUT"; : > "$ERR"
  printf '%s' "$payload" | guard_env "$PRIMARY" "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$OUT" ] || fail "Claude-shaped Write deny must exit 2 with empty stdout, got $rc"

  payload=$(jq -cn --arg cwd "$PRIMARY" --arg p "$PRIMARY/projects/foo/n.ipynb" '{tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$p}}')
  rc=0
  printf '%s' "$payload" | guard_env "$PRIMARY" "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "NotebookEdit notebook_path must be classified, got $rc"

  payload=$(jq -cn --arg cwd "$PRIMARY" '{tool_name:"apply_patch",cwd:$cwd,tool_input:{command:"*** Begin Patch\n*** Add File: projects/foo/x\n+hi\n*** End Patch"}}')
  rc=0
  printf '%s' "$payload" | guard_env "$PRIMARY" "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Codex apply_patch payload must be classified, got $rc"

  payload=$(jq -cn --arg cwd "$PRIMARY" '{tool_name:"Bash",cwd:$cwd,cursor_version:"1",tool_input:{command:"echo x >> ~/.bashrc"}}')
  rc=0; : > "$OUT"; : > "$ERR"
  printf '%s' "$payload" | guard_env "$PRIMARY" "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$ERR" ] || fail "a Cursor-delivered duplicate of the Claude settings must stand down, got $rc"
  pass "Claude, Codex, and apply_patch stdin transports render the established deny shapes; Cursor duplicates stand down"
}

test_fail_open_transport() {
  local payload rc fakebin tool tool_path
  for payload in '' 'not json' '{}' '{"tool_name":"Bash"}' '{"tool_name":"Write","tool_input":{}}'; do
    rc=0; : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" | guard_env "$PRIMARY" "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] && [ ! -s "$OUT" ] || fail "malformed payload '$payload' must fail open, got $rc"
  done
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq env cksum awk head cut; do
    tool_path=$(command -v "$tool") || continue
    ln -sf "$tool_path" "$fakebin/$tool"
  done
  rc=0
  guard_env "$PRIMARY" PATH="$fakebin" "$CHECK" --claude --tool Bash --command 'echo x >> ~/.bashrc' > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$ERR" ] || fail "missing node must fail open, got $rc: $(cat "$ERR")"
  pass "malformed transport and a missing Node runtime fail open rather than blocking every tool call"
}

test_policy_cli_contract() {
  local out
  out=$(node "$POLICY" --tool Bash --cwd "$PRIMARY" --allow "$PRIMARY/state" --command 'echo x > state/a')
  [ "$out" = allow ] || fail "policy CLI allow line must be exactly 'allow', got: $out"
  out=$(HOME="$USERHOME" node "$POLICY" --tool Bash --cwd "$PRIMARY" --allow "$PRIMARY/state" --command 'echo x > ~/.bashrc')
  case "$out" in deny$'\t'primary-write$'\t'*) ;; *) fail "policy CLI deny line must be deny<TAB>code<TAB>reason, got: $out" ;; esac
  if node "$POLICY" --bogus x >/dev/null 2>&1; then fail "policy CLI must reject unknown arguments"; fi
  pass "policy CLI emits the allow and deny line contract and rejects unknown arguments"
}

# Run each tracked registration's command the way its harness does, against the
# fixture home, so the wiring itself is exercised rather than read as bytes.
test_tracked_claude_registration() {
  local tool cmd rc payload count=0
  for tool in Bash Edit MultiEdit Write NotebookEdit; do
    cmd=$(jq -r --arg t "$tool" '[.hooks.PreToolUse[] | select(.matcher as $m | $t | test($m)) | .hooks[].command
      | select(contains("fm-primary-write-pretool-check.sh"))] | first // empty' "$ROOT/.claude/settings.json")
    [ -n "$cmd" ] || fail "tracked Claude settings must route $tool to the primary write guard"
    case "$tool" in
      Bash) payload=$(jq -cn --arg cwd "$PRIMARY" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"echo x >> ~/.bashrc"}}') ;;
      NotebookEdit) payload=$(jq -cn --arg cwd "$PRIMARY" --arg p "$USERHOME/n.ipynb" '{tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$p}}') ;;
      *) payload=$(jq -cn --arg t "$tool" --arg cwd "$PRIMARY" --arg p "$USERHOME/.bashrc" '{tool_name:$t,cwd:$cwd,tool_input:{file_path:$p}}') ;;
    esac
    rc=0; : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" | guard_env "$PRIMARY" CLAUDE_PROJECT_DIR="$ROOT" sh -c "$cmd" > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 2 ] && [ ! -s "$OUT" ] || fail "tracked Claude $tool registration must deny with empty stdout, got $rc: $(cat "$OUT")"
    count=$((count + 1))
  done
  for tool in Read Grep Glob; do
    cmd=$(jq -r --arg t "$tool" '[.hooks.PreToolUse[] | select(.matcher as $m | $t | test($m)) | .hooks[].command
      | select(contains("fm-primary-write-pretool-check.sh"))] | first // empty' "$ROOT/.claude/settings.json")
    [ -z "$cmd" ] || fail "read-only Claude tool $tool must not reach the primary write guard"
  done
  [ "$count" -eq 5 ] || fail "expected five guarded Claude tools, got $count"
  pass "tracked Claude registration routes Bash, Edit, MultiEdit, Write, and NotebookEdit through the guard with a Claude-shaped deny"
}

test_tracked_codex_registration() {
  local tool cmd rc payload codex_home="$TMP_ROOT/codex-home"
  make_home "$codex_home" "$ROOT/bin"
  mkdir -p "$codex_home/.codex"
  cp "$ROOT/.codex/hooks.json" "$codex_home/.codex/hooks.json"
  for tool in Bash apply_patch; do
    cmd=$(jq -r --arg t "$tool" '[.hooks.PreToolUse[] | select(.matcher as $m | $t | test($m)) | .hooks[].command
      | select(contains("fm-primary-write-pretool-check.sh"))] | first // empty' "$ROOT/.codex/hooks.json")
    [ -n "$cmd" ] || fail "tracked Codex hooks must route $tool to the primary write guard"
    if [ "$tool" = Bash ]; then
      payload=$(jq -cn --arg cwd "$codex_home" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"echo x >> ~/.bashrc"}}')
    else
      payload=$(jq -cn --arg cwd "$codex_home" '{tool_name:"apply_patch",cwd:$cwd,tool_input:{command:"*** Begin Patch\n*** Add File: projects/foo/x\n+hi\n*** End Patch"}}')
    fi
    # The tracked command runs under `bash -lc`, whose login profile rebuilds
    # PATH from the real HOME; a fixture HOME would drop Node and fail open.
    # The hook only evaluates the payload, so nothing is written either way.
    rc=0; : > "$OUT"; : > "$ERR"
    (cd "$codex_home" && printf '%s' "$payload" | guard_env "$codex_home" HOME="$REAL_HOME" sh -c "$cmd") > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 2 ] || fail "tracked Codex $tool registration must deny with exit 2, got $rc: $(cat "$ERR")"
    jq -e '.systemMessage | startswith("[primary-write")' "$ERR" >/dev/null 2>&1 || fail "tracked Codex $tool deny must reach stderr"
  done
  pass "tracked Codex registration routes Bash and apply_patch through the guard and blocks on exit 2"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck unavailable; lint owned by bin/fm-lint.sh"; return 0; }
  shellcheck -x "$CHECK" "$GRANT" || fail "guard scripts must be shellcheck-clean"
  node --check "$POLICY" || fail "policy must parse"
  pass "guard scripts are shellcheck-clean and the policy parses"
}

test_refuses_captain_environment_writes
test_refuses_project_and_shared_material_writes
test_allows_operational_paths_and_read_only_work
test_secondmate_carve_outs
test_grant_lifecycle
test_scope_and_escape_hatch
test_stdin_transports
test_fail_open_transport
test_policy_cli_contract
test_tracked_claude_registration
test_tracked_codex_registration
test_scripts_are_shellcheck_clean
