#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables,
# and ONE named exception to that purity - fm_control_endpoint_absence_verdict,
# the single owner of the per-backend endpoint-absence proof, which does run
# backend reads. Everything else has no side effects, runs no backend command,
# and reads no state, so sourcing this file is still free and the tables can be
# read by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb: it is not deterministic across the
# verified adapters (docs/agent-control.md owns the per-adapter resume facts).
# `relaunch` uses the brief on disk rather than a harness-private session as
# its durable instruction. The relaunch-time exception is
# fm_control_relaunch_resume_flag below: a reference the endpoint's runtime
# bound as its status authority is returned to a replacement with that adapter.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harnesses() {
  printf '%s\n' claude codex opencode pi pi-signed grok kimi cursor omp
}

fm_control_harness_supported() {  # <harness>
  local harness found=1
  while read -r harness; do
    [ "$harness" = "${1-}" ] && found=0
  done < <(fm_control_harnesses)
  return "$found"
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# `omp` is exact because an `omp*` prefix would claim unrelated commands.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    *) return 1 ;;
  esac
}

# All remaining verified adapters support both task kinds.
fm_control_harness_supports_kind() {  # <harness> <kind>
  fm_control_harness_supported "${1-}"
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor) printf '1' ;;
    *) return 1 ;;
  esac
}

# The rendered proof required between presses, empty for current adapters.
fm_control_interrupt_arm_signal() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor) ;;
    *) return 1 ;;
  esac
}

# The settle interval after an interrupt press.
fm_control_interrupt_press_gap() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor) printf '0.2' ;;
    *) return 1 ;;
  esac
}

# A rendered surface that a mistimed interrupt press can open.
fm_control_interrupt_hazard_signal() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor) ;;
    *) return 1 ;;
  esac
}

# The key that must follow an interrupt to clear its composer, when needed.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor) ;;
    *) return 1 ;;
  esac
}

# The command or key that exits the agent from its own composer. OpenCode is
# version-sensitive: 2.x exits on raw keys, where bin/fm-control.sh sends Ctrl-U
# to clear the composer, then Ctrl-C, and one more Ctrl-C if the agent is still
# alive (verified on 2.0.11, 2.0.21, and 2.0.22), while 1.x exits on the typed
# /exit command. The detected major is recorded at spawn (bin/fm-spawn.sh) and
# passed as $2; when it is absent or 1 the version-agnostic /exit is used, which
# exits both lines.
fm_control_exit_command() {  # <harness> [opencode-major]
  case "${1-}" in
    opencode)
      case "${2-}" in
        ''|1) printf '/exit' ;;
        *) printf 'C-c' ;;
      esac
      ;;
    claude|grok|kimi|cursor) printf '/exit' ;;
    codex|pi|pi-signed|omp) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# The launch argument that makes a RELAUNCH of <harness> RESUME an exact agent
# session instead of starting a fresh one, printed only when <registered-agent>
# is the label that session reference belongs to; nothing otherwise.
#
# This exists for one runtime failure, not as a general resume feature. Herdr
# gives a pane one status authority, and for Pi with its installed integration
# that authority is the lifecycle hooks, which also suppress Herdr's screen
# detection for the pane. That registration outlives its agent process in the
# crew shape - a nested worktree shell under the pane's top shell - and Herdr
# then applies only reports carrying the session identity it bound. A
# replacement agent started fresh in that same pane reports a NEW session, so
# its state reports are ignored and the pane stays frozen at whatever the
# previous agent last reported: a working crewmate reads idle until its task
# ends (reproduced and fixed live 2026-09-21, herdr 0.9.1; the read that
# supplies the reference is
# bin/backends/herdr.sh's fm_backend_herdr_pane_agent_session_ref).
#
# So the reference is not chosen from what looks recent - it is the exact
# identity the endpoint's own runtime recorded, which is why a matched
# registered-agent label is required: resuming a reference reported by a
# DIFFERENT agent would inject another agent's conversation into this launch.
# `pi` is the label Pi and pi-signed both report, so one entry covers both.
# Every other harness returns nothing and keeps today's fresh-session
# relaunch, which is what the adapter tables above (and the absence of a
# verified resume form for those harnesses) require.
#
# Prints the flag name only; the caller quotes and appends the reference, since
# shell quoting belongs to the owner of the launch line (bin/fm-spawn.sh).
fm_control_relaunch_resume_flag() {  # <harness> <registered-agent>
  case "${1-}" in
    pi|pi-signed)
      [ "${2-}" = pi ] && printf -- '--session'
      ;;
  esac
  return 0
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear.
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux,
# and herdr implement fm_backend_agent_state; unknown backends report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# Whether a raw fm_backend_agent_state reading on <backend> goes through
# fm_control_endpoint_absence_verdict before a recovery verb (exit, relaunch)
# acts or refuses. `missing` always does. Passive readers keep the raw state.
fm_control_absence_recheck_applies() {  # <backend> <raw-state>
  case "${2-}" in
    missing) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_control_endpoint_absence_verdict: the ONE owner of the per-backend proof
# that an endpoint reading `missing` is actually GONE rather than merely
# unreachable from this seat. Call it only for a raw state that
# fm_control_absence_recheck_applies accepts.
#
# Prints "<verdict>\t<reason>" - always exactly one TAB, so a caller splits
# unambiguously with ${raw%%$'\t'*} and ${raw#*$'\t'}. The reason is empty
# except on `unproven`, where it is the concrete sentence the caller's refusal
# message embeds. It is returned on stdout rather than set in a variable
# because every caller reads this through a command substitution, where an
# assignment made here could never reach them.
#
# The verdicts:
#   gone     - absence is PROVEN. There is no endpoint and therefore no agent.
#   dead     - the endpoint is there after all and holds no agent.
#   alive    - the endpoint is there and an agent is running in it.
#   unproven - neither could be established; the caller must refuse.
#
# fm_backend_agent_state's `missing` conflates "the endpoint was DESTROYED"
# with "the endpoint is UNREACHABLE from here right now". An unreachable
# endpoint can still hold a live agent on the task's worktree, so every caller
# that would act on absence - `exit` claiming the agent stopped, `relaunch`
# re-creating the endpoint - must come through here rather than trusting the
# raw verdict.
#
# Whether absence is provable AT ALL is a property of the backend, not of the
# reading:
#   herdr CAN prove it. Every read goes through fm_backend_herdr_cli, which
#     passes `--session <session>`, so the recheck starts and reads the session
#     the RECORD names, through that session's own socket. The answer is about
#     the task's endpoint and nothing else.
#   tmux CANNOT. `list-windows -a` describes only the server the CURRENT
#     process addresses (its TMUX_TMPDIR/socket), and a task's record does not
#     carry the endpoint's socket identity - so a different but running server
#     would answer "not anywhere" about a window it was never able to see.
#     There is no read available here that closes that gap, so tmux always
#     returns `unproven` and both verbs refuse. tmux is left exactly as
#     deadlocked as it was before this change - no worse - but deliberately.
#
# Both control-plane callers share this one implementation so the proof cannot
# drift into two answers for the same endpoint.
fm_control_endpoint_absence_verdict() {  # <backend> <target> [meta]
  local backend=${1-} target=${2-}
  fm_backend_source "$backend" \
    || { printf 'unproven\tbackend %s could not be loaded to prove anything about that endpoint' "'$backend'"; return 0; }
  case "$backend" in
    tmux)
      printf 'unproven\ttmux absence cannot be proven from a task record: the record does not carry the endpoint'"'"'s socket identity, and a server-wide window inventory only describes the tmux server this process addresses, so a window absent from it may still be alive on another'
      ;;
    herdr)
      # Start the RECORDED session's server (only the server - nothing is
      # created) and re-read the recorded pane. A pane that comes back with the
      # server was never destroyed.
      case "$(fm_backend_herdr_endpoint_absence_recheck "$target")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing) printf 'gone\t' ;;
        *) printf 'unproven\tthe recorded herdr session'"'"'s server could not be started, or its pane could not be classified once it was running' ;;
      esac
      ;;
    *)
      printf 'unproven\tbackend %s has no recovery-grade classifier, so absence cannot be proven on it at all' "'$backend'"
      ;;
  esac
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Teardown's worktree return also reads this
# table for Polytoken; both consumers preserve git-tracked Polytoken layers.
# Prints zero or more absolute paths, one per line: worktree-resident
# hook files and firstmate-owned state tokens only, never a harness's own
# managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id> [kind]
  local harness=${1-} wt=${2-} state=${3-} id=${4-} kind=${5-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    # Every task's hooks live in the firstmate-owned settings file passed to
    # --settings. Repository settings.local.json is native project state.
    claude)
      printf '%s\n' "$state/$id.claude-settings.json"
      if [ "$kind" = secondmate ]; then
        printf '%s\n' "$wt/.fm-busy-stop"
      fi
      ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # polytoken's per-task wiring spans the worktree's project hook and facet
    # layers (the only hook and facet discovery a task controls, so a relaunch
    # must retire them rather than leave a stale hook pointing at a retired
    # busy generation), the generated no-argv busy writer the hooks reference,
    # and the per-task config and sessions roots, which are DIRECTORIES and
    # therefore ride fm_control_harness_wiring_dirs below rather than this
    # file table. The worktree layers are the project's own discovery paths,
    # so each is named only while it carries this task's generated content
    # (the hooks reference this task's busy writer, the facet this task's
    # inbox); a project's own hook layer or facet is never firstmate's to
    # retire.
    polytoken)
      if grep -qsF "/$id.polytoken-busy.sh" "$wt/.polytoken/hooks.json"; then
        printf '%s\n' "$wt/.polytoken/hooks.json"
      fi
      if grep -qsF "/$id.inbox" "$wt/.polytoken/facets/firstmate-worker.md"; then
        printf '%s\n' "$wt/.polytoken/facets/firstmate-worker.md"
      fi
      printf '%s\n' "$state/$id.polytoken-busy.sh"
      ;;
  esac
}

# The firstmate-owned per-task DIRECTORIES a harness mints, one per line:
# the same retirement contract as fm_control_harness_wiring_paths for
# artifacts that are directory trees rather than single files. Consumers
# remove these recursively; nothing here is ever a harness's own managed
# config. polytoken's config dir holds the mirrored worker config (the
# one launch-time autonomy surface, so a replacement must regenerate it
# from the current operator config), and the sessions root holds the
# versioned `<root>-v1` session tree the launch writes beside it, so both
# the root and its versioned sibling are named.
fm_control_harness_wiring_dirs() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    polytoken)
      printf '%s\n' "$state/$id.polytoken-config"
      printf '%s\n' "$state/$id.polytoken-sessions"
      printf '%s\n' "$state/$id.polytoken-sessions-v1"
      ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
