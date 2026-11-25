#!/usr/bin/env bash
# Opt-in Herdr transport guard for both startup dialogs, with private fake UI.
# The real Codex surface is covered separately by fm-launch-prompt-signals-live-e2e.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_HERDR_STARTUP_DIALOGS_LIVE herdr jq python3
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
SESSION=$("$HELPER" name startup-dialogs-live)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-startup.XXXXXX") || exit 1
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  fm_test_remove_tree "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/launch"
cat > "$TMP_ROOT/bin/herdr" <<EOT
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOT
chmod +x "$TMP_ROOT/bin/herdr"
cat > "$TMP_ROOT/agent.sh" <<'EOT'
#!/usr/bin/env bash
clear
printf 'Folder access\n%s\n\nNote: You are in a subdirectory of a Git project.\n\nTrust this folder?\n› 1. Trust and continue\n  2. Back\n' "$1"
IFS= read -r _
printf 'folder\n' >> "$2"
clear
printf 'Hooks need review\n6 hooks are new or changed\n› 1. Review hooks\n  2. Trust all and continue\n'
IFS= read -rsn1 first
IFS= read -rsn2 rest
[ "$first$rest" = $'\e[B' ] || exit 2
printf 'down\n' >> "$2"
clear
printf 'Hooks need review\n6 hooks are new or changed\n  1. Review hooks\n› 2. Trust all and continue\n'
IFS= read -r _
printf 'hooks\n' >> "$2"
clear
printf 'Working (esc to interrupt)\n'
sleep 10
EOT
chmod +x "$TMP_ROOT/agent.sh"
"$HELPER" provision "$SESSION" || fail 'Herdr lab provisioning or default-session tripwire failed'
workspace=$(lab workspace create --cwd "$TMP_ROOT/launch" --label startup-dialogs --no-focus) || fail 'workspace creation failed'
pane=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id') || fail 'workspace returned no pane'
launch=$(printf '%q ' bash "$TMP_ROOT/agent.sh" "$TMP_ROOT/launch" "$TMP_ROOT/keys")
lab pane run "$pane" "$launch" >/dev/null || fail 'fake dialog launch failed'
for ((i=0;i<60;i++)); do
  screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
  case "$screen" in *'Trust this folder?'*) break ;; esac
  sleep 0.2
done
case "$screen" in *'Trust this folder?'*) ;; *) fail 'folder dialog did not render' ;; esac
PATH="$TMP_ROOT/bin:$ORIGINAL_PATH" FM_STARTUP_DIALOGS_POLL=0.5 \
  bash "$ROOT/bin/fm-startup-dialogs.sh" herdr "$SESSION:$pane" codex "$TMP_ROOT/launch" 30
[ "$(cat "$TMP_ROOT/keys" 2>/dev/null)" = "$(printf 'folder\ndown\nhooks')" ] || fail "Herdr did not deliver both approved choices"
pass "Herdr delivered both startup dialog choices"
