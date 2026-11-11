#!/usr/bin/env bash
# Live guard for the Codex crewmate launch's native hook posture and read-only gate.
#
# This uses the installed Codex CLI to verify the actual launch flags remain
# accepted, while Firstmate leaves native hook layers enabled, preserves Codex's
# trust review, and blocks edits because this interactive adapter cannot report
# same-session native loading evidence. It spends no model tokens.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  printf 'approve-for-me\n' > "$home/config/codex-approval-mode"
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  flags=${flags%%\"\$(*}
  printf '%s' "$flags"
}

test_installed_codex_accepts_preserved_hook_posture_for_captured_crewmate_launch() {
  local launch flags listing
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")
  case " $flags " in
    *' --sandbox read-only '*) ;;
    *) fail "codex $CODEX_VERSION captured launch omitted the native-loader read-only gate" ;;
  esac
  case " $flags " in
    *' --approve-for-me '*|*' --dangerously-bypass-approvals-and-sandbox '*)
      fail "codex $CODEX_VERSION captured launch allowed edits despite unsupported native loading"
      ;;
  esac
  case " $flags " in
    *' --dangerously-bypass-approvals-and-sandbox '*)
      fail "codex $CODEX_VERSION captured launch retained the complete-bypass posture"
      ;;
  esac
  case " $flags " in
    *' --disable hooks '*) fail "codex $CODEX_VERSION launch disabled native hooks" ;;
  esac
  case " $flags " in
    *' --dangerously-bypass-hook-trust '*) fail "codex $CODEX_VERSION launch bypassed hook trust review" ;;
  esac

  listing=$(codex --sandbox read-only features list 2>&1) ||
    fail "codex $CODEX_VERSION rejected the read-only worker launch flags: $listing"
  [ -n "$listing" ] || fail "codex $CODEX_VERSION returned an empty feature list"
  printf 'ok - codex %s accepts the preserved-hook, unsupported-loader read-only launch\n' "$CODEX_VERSION"
}

test_installed_codex_accepts_preserved_hook_posture_for_captured_crewmate_launch

echo "# all fm-codex-hook-layer-live-e2e tests passed"
