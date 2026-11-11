#!/usr/bin/env bash
# Spawn behavior for a forge=external project, whose review tool uploads its own
# snapshot so a worker never pushes a task branch (docs/external-review-forge.md).
# These drive the real spawn path with a fake terminal: every configured
# protection is validated before any endpoint exists, the per-task push guard
# is installed even when the home keeps AI trailers, and the task record carries
# what bin/fm-dod-lib.sh's ready-report gate reads.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-external-review)

# make_case <name> <id> [registry-tokens]: a home whose registry binds the
# project forge=external, a project with a bare origin, a pooled worktree, the
# review tool adapter, and a forge=external direct-PR brief. Sets CASE_DIR,
# HOME_DIR, PROJECT_DIR, POOL_DIR, ORIGIN_DIR, FAKEBIN_DIR.
make_case() {
  local name=$1 id=$2 tokens=${3:-direct-PR forge=external}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  ORIGIN_DIR="$CASE_DIR/origin.git"
  POOL_DIR="$CASE_DIR/pool"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$HOME_DIR/data/$id" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  # shellcheck disable=SC2016 # Backticks are literal adapter text.
  printf '%s\n' 'Run `review-tool upload --draft`.' > "$HOME_DIR/config/external-review.md"
  printf -- '- project [%s] - fixture (added 2026-01-01)\n' "$tokens" > "$HOME_DIR/data/projects.md"
  touch "$HOME_DIR/state/.last-watcher-beat"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" config user.name "Project Public"
  git -C "$PROJECT_DIR" config user.email public@example.invalid
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$PROJECT_DIR" "$ORIGIN_DIR"
  git -C "$PROJECT_DIR" remote add origin "file://$ORIGIN_DIR"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Ship a change through the review tool.

## Firstmate spec
Exercise the external review spawn path.

# Definition of done
Delivery contract: mode=direct-PR forge=external
Ship branch: fm/$id
EOF
}

run_spawn() {  # <id> <args...>
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

refused_before_launch() {  # <id> <label> <needle> <out> <status>
  [ "$5" -ne 0 ] || fail "$2 launched"$'\n'"$4"
  assert_contains "$4" "$3" "$2 was refused without its reason"
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "$2 still published a task record"
}

test_spawn_refusals_before_launch() {
  local id out status
  id=ext-yolo-r1
  make_case yolo "$id"
  out=$(run_spawn "$id" --mode direct-PR --yolo on); status=$?
  refused_before_launch "$id" "a --yolo on spawn on forge=external" "--yolo on is refused" "$out" "$status"

  id=ext-noadapter-r1
  make_case noadapter "$id"
  rm -f "$HOME_DIR/config/external-review.md"
  out=$(run_spawn "$id" --mode direct-PR --yolo off); status=$?
  refused_before_launch "$id" "a spawn with no review tool adapter" "external-review.md" "$out" "$status"

  id=ext-nobackup-r1
  make_case nobackup "$id"
  printf 'backup\n' > "$HOME_DIR/config/external-review-backup"
  out=$(run_spawn "$id" --mode direct-PR --yolo off); status=$?
  refused_before_launch "$id" "a spawn naming an absent backup remote" "does not have" "$out" "$status"

  id=ext-alias-r1
  make_case alias "$id"
  printf 'backup\n' > "$HOME_DIR/config/external-review-backup"
  git -C "$PROJECT_DIR" remote add backup "file://$ORIGIN_DIR/"
  out=$(run_spawn "$id" --mode direct-PR --yolo off); status=$?
  refused_before_launch "$id" "a backup remote aliasing origin" "points at the project's shared origin" "$out" "$status"

  id=ext-prefix-r1
  make_case prefix "$id"
  printf 'backup\nprefix=fm/copies/\n' > "$HOME_DIR/config/external-review-backup"
  git init --quiet --bare "$CASE_DIR/backup.git"
  git -C "$PROJECT_DIR" remote add backup "file://$CASE_DIR/backup.git"
  out=$(run_spawn "$id" --mode direct-PR --yolo off); status=$?
  refused_before_launch "$id" "a backup prefix inside the task prefix" "starts with the task branch prefix" "$out" "$status"

  id=ext-mismatch-r1
  make_case mismatch "$id"
  sed -i.bak 's/^Delivery contract: mode=direct-PR forge=external$/Delivery contract: mode=direct-PR/' "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode direct-PR --yolo off); status=$?
  refused_before_launch "$id" "a brief without forge=external" "forge mismatch" "$out" "$status"
  pass "forge=external spawn: yolo, a missing adapter, an absent or aliasing backup, an overlapping prefix, and a forge mismatch all refuse before launch"
}

test_spawn_keeps_the_normal_push_guard() {
  local id out status hooks
  id=ext-launch-r1
  make_case launch "$id"
  : > "$HOME_DIR/config/keep-ai-trailers"
  out=$(run_spawn "$id" --mode direct-PR --yolo off); status=$?
  expect_code 0 "$status" "configured external-review launch should succeed: $out"
  hooks="$HOME_DIR/state/$id.git-hooks"
  assert_present "$HOME_DIR/state/$id.meta" "launch did not publish its task record"
  out=$(printf 'refs/heads/main %040d refs/heads/main %040d\n' 1 0 | "$hooks/pre-push" origin "file://$ORIGIN_DIR" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "the retained origin push guard allowed a push"
  assert_contains "$out" 'nothing is ever pushed to origin' "the normal origin guard did not explain its refusal"
  pass "forge=external launch keeps the origin push guard when AI trailers are retained"
}

test_local_only_startup_with_disposable_terminal() {
  local id out status
  id=local-launch-r1
  make_case local-launch "$id" local-only
  sed -i.bak 's/Delivery contract: mode=direct-PR forge=external/Delivery contract: mode=local-only/' "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode local-only --yolo off); status=$?
  expect_code 0 "$status" "local-only startup should succeed: $out"
  assert_present "$HOME_DIR/state/$id.meta" "local-only startup did not publish its task record"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOME_DIR/state/$id.git-hooks" \
    git -C "$POOL_DIR" commit --quiet --allow-empty -m 'Exercise local task hooks' || fail "local-only commit could not run its installed hooks"
  assert_equals 'Project Public <public@example.invalid>|Project Public <public@example.invalid>' \
    "$(git -C "$POOL_DIR" show -s --format='%an <%ae>|%cn <%ce>')" "spawn pins author and committer"
  pass "local-only startup publishes task metadata and commits through the installed hooks without a provider call"
}

test_identity_fallback_and_stale_copy() {
  local id=identity-fallback-r1 out status
  make_case identity-fallback "$id" local-only
  git init --quiet "$HOME_DIR"
  git -C "$HOME_DIR" config user.name 'Home Public'
  git -C "$HOME_DIR" config user.email home@example.invalid
  git -C "$PROJECT_DIR" config --unset user.name
  git -C "$PROJECT_DIR" config --unset user.email
  git -C "$POOL_DIR" config extensions.worktreeConfig true
  git -C "$POOL_DIR" config --worktree user.name Codex
  git -C "$POOL_DIR" config --worktree user.email codex@openai.com
  sed -i.bak 's/Delivery contract: mode=direct-PR forge=external/Delivery contract: mode=local-only/' "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode local-only --yolo off); status=$?
  expect_code 0 "$status" "home identity fallback should launch: $out"
  git -C "$POOL_DIR" commit --quiet --allow-empty -m 'Home identity fallback' || fail 'fallback commit failed'
  assert_equals 'Home Public <home@example.invalid>|Home Public <home@example.invalid>' \
    "$(git -C "$POOL_DIR" show -s --format='%an <%ae>|%cn <%ce>')" 'home fallback replaces stale worktree identity'
  git -C "$HOME_DIR" config --unset user.name
  git -C "$HOME_DIR" config --unset user.email
  git -C "$PROJECT_DIR" config --unset user.name
  git -C "$PROJECT_DIR" config --unset user.email
  out=$(bash "$ROOT/bin/fm-git-identity.sh" "$POOL_DIR" "$PROJECT_DIR" "$HOME_DIR" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'missing public configuration was accepted'
  assert_contains "$out" 'configure public git' 'missing identity explains configuration needed'
  pass 'home fallback replaces a stale worktree identity and missing identity refuses'
}

test_identity_fallback_and_stale_copy
test_spawn_refusals_before_launch
test_spawn_keeps_the_normal_push_guard
test_local_only_startup_with_disposable_terminal

echo "# all fm-spawn-external-review tests passed"
