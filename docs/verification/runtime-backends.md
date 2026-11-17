# Runtime backend verification

## Large Treehouse acquisitions

The acquisition wait and isolation contract belongs to the header of `bin/fm-spawn.sh`.
Verified 2026-11-14 on Linux with Treehouse v3.1.5, Herdr 0.9.5 and tmux 3.3a in private disposable sessions.
`bash bin/fm-spawn.sh "$ID" "$LAB_REPO" --mode local-only --yolo on --backend "$BACKEND" 'sleep 120'` acquired fresh copies of a generated 250,000-file repository with a disposable 70-second Git post-checkout hook.
Herdr completed in 111 seconds and tmux in 134 seconds; both printed progress beyond 60 polls, then `spawned`, and the native terminal cwd matched the recorded isolated worktree.
The portable regression command is `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-spawn-worktree-settle.test.sh`.
It covers preparation beyond the initial window, the subshell handoff's confirming read, late acquisition failure, stale cwd reads and refusal of the primary checkout.
macOS was inspected but not executed; the tmux probe reuses its existing portable foreground-process reader and the Herdr probe uses `pane process-info`.


## Worker session bindings

The durable record format and one-off historical migration belong to the header of `bin/fm_task_sessions.py`.
On 2026-11-09, Linux with Python 3.11.2, codex-cli 0.166.0 and Claude Code 2.1.319 verified both capture paths against real harnesses in disposable task data.
`python3 bin/fm-codex-activity.py classify "$STATE" "$ID"` returned `busy codex-rollout` and completed the durable record from the validated native process's rollout; repeating it retained one record.
`claude -p 'Reply with exactly OK.' --model haiku --effort low --tools '' --setting-sources '' --strict-mcp-config --settings "$SETTINGS" --system-prompt 'Reply to the provided text without using tools.'` returned `OK`, with its UserPromptSubmit hook filling the transcript path.
Replaying the first 60 lines of real historical Claude and Codex transcripts through the migration recovered both sessions; a second invocation left the files unchanged.
Claude's historical brief can arrive in a tool result after an inbox doorbell, and its first transcript record can lack a timestamp.
The portable regression entry point is `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-busy-state.test.sh`.
The historical client recovery interface now defaults to a read-only review; its apply and exact restore procedure is owned by `python3 bin/fm_task_sessions.py --help`.
On 2026-11-14, Linux with Python 3.11.2 ran `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-usage-recovery.test.sh` and reported `ok - synthetic client dry/review/apply/re-read/restore; explicit, inferred, ambiguous, rejected, unknown; unique sessions`.
This is synthetic client proof, without Mac originals or execution on macOS; unknown model costs remain unknown and no historical client data was installed.
The common spawn path records launches before backend delivery for tmux and Herdr, independent of the harness command; session capture currently uses only Claude's existing hook and Codex's existing pin.
On 2026-11-14, Linux with Python 3.11.2 and codex-cli 0.169.0 verified project attribution, active launch state and a null binding reason on the real transcript through `FM_CODEX_SESSION_BIND_LIVE=1 bash bin/fm-heavy-run.sh bash tests/fm-codex-session-bind-live-e2e.test.sh`.
It reported `ok - codex-cli 0.169.0: real worker transcript bound; activity qualification unchanged`.
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-codex-session-bind.test.sh tests/fm-host-task.test.sh tests/fm-control-relaunch.test.sh` refreshes task/project queries, same-second launch history, host attribution, promotion preservation, relaunch archival and anonymized binding diagnostics.
The lifecycle record format and the distinction between an active chat and a running process belong to the session writer's header.
Remote secondmate launch transport is outside worker capture.
macOS was inspected but not executed; the writer and migration use Python's standard library, while automatic Codex capture retains its existing native Linux capability limit.

### Manual context handoff

The procedure belongs to the harness adapter's [control and recovery reference](../../.agents/skills/harness-adapters/references/common/control-and-recovery.md#manual-context-handoff).
On 2026-11-14, Linux with Herdr 0.9.5, codex-cli 0.169.0 and Claude Code 2.1.325 exercised `FM_HOME="$LAB_HOME" bash bin/fm-control.sh "$ID" relaunch --note-file "$NOTE"` in disposable named Herdr sessions.
Codex used `gpt-6.1-terra`/`low`; Claude used `haiku`/`low` in host scratch.
Both successors preserved a completed local action, consumed and acknowledged a message queued before relaunch, and retained their profiles with distinct archived/active bound transcripts.
The pilots reported `PASS codex pending inbox continued once; same profile; archived/active transcripts` and the corresponding `PASS claude` result.
The existing primary relay primitive also closed the old pane and loaded a prepared stow handoff in a new session of each harness; the Claude fixture needed a follow-up instruction to execute its preserved pending operation.
The Claude host pilot exposed a missing argument separator that joined the last directory grant to `--settings`; adding the separator restored hook delivery and transcript binding in the repeated live pilot.
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-host-task.test.sh tests/fm-control-relaunch.test.sh` refreshes executable argument delivery and transactional failure coverage without submitting model prompts.
macOS was not executed in these pilots; the fix changes only a Bash argument separator and adds no dependency or automatic relay trigger.

### Automatic worker context handoff

The adapter contract belongs to [fm-worker-relay.py](../../bin/fm-worker-relay.py).
Verified 2026-11-15 UTC on Linux with Python 3.11.2, Herdr 0.9.5, codex-cli 0.169.0 and Claude Code 2.1.325.
`FM_WORKER_RELAY_LIVE=1 FM_RELAY_CHECK="$CHECKER" bash bin/fm-heavy-run.sh bash tests/fm-worker-relay-live-e2e.test.sh` exercised both installed harnesses with the relay-lite checker and an artificial absolute threshold in an isolated home.
The completed-turn callback requested and received one handoff note; the owning watcher relaunched through the existing control plane and delivered the session-history wake.
Both sessions preserved the initial file's bytes and modification time, performed the pending action once, retained their profiles, and linked distinct archived/active transcripts.
The live guard also retains a stale note asking for another handoff request and requires continuation with an empty inbox after relaunch.
A wait for the current handoff or relaunch is satisfied when the replacement runs.
Other explicit task holds and unresolved decisions remain in force.

```text
PASS automatic relay relay-codex-1896968 new transcript; same profile; one acknowledged request; one continuation
PASS automatic relay relay-claude-1896968 new transcript; same profile; one acknowledged request; one continuation
```

The guard closed its private tmux server and named Herdr session and verified the default session unchanged.
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-host-task.test.sh` covers unknown checker results, replayed callbacks, retired generations, profile/note preservation, control failure, terminal tasks and teardown of relay signals.
macOS was inspected but not executed; the adapter passed Python 3.9 grammar parsing and uses only the standard library.
These pilots do not calibrate production thresholds or enable workers in an operator home.

On 2026-11-15 UTC, Claude Code 2.1.325 reported `context_window.context_window_size=1000000` through its native statusline for `claude-opus-5-5`, `claude-sonnet-5-5` and `claude-haiku-5-5` on Linux.
The per-launch capture and display-preservation contract belongs to [fm-claude-context.py](../../bin/fm-claude-context.py).
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-host-task.test.sh` refreshes native payload forwarding, display preservation and session replacement without model prompts.
Set `FM_WORKER_RELAY_LIVE_CLAUDE_MODELS="claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5"` on the live guard above to select those exact models.
The capture uses Python 3.9 standard-library file and subprocess interfaces shared by Linux and macOS; macOS live acceptance remains unverified.

## Worker temporary processes

The ownership and platform contract lives in the header of `bin/fm-worker-processes.py`.
On 2026-11-10, Linux with Python 3.11.2 ran `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-work-activity.test.sh` with real disposable worker processes.
It reported `ok - real worker kill and wrapper stop publish death; count, row, recovery, relaunch and incarnation isolation`.
The common wrapper now publishes process liveness independently of harness output for ship, scout and host launches across tmux and Herdr; secondmate launches remain outside this wrapper.
The regression exercises SIGKILL of the worker while its wrapper remains alive, wrapper TERM, recovery and relaunch through the canonical owner and projection.
Its common publication path uses Python subprocess and the existing Bash ledger writer on Linux and macOS; macOS execution of this new regression remains unverified.
On 2026-11-06, Linux with Python 3.11.2, chrome-devtools-axi 0.1.44 and Chrome 148.0.7778.178 ran a private worker that opened a Python HTTP server and headless browser.
The wrapper captured 21 processes including the detached bridge, MCP, Chrome, telemetry and crashpad, then returned `exit 0 captured 21 survivors {}`.
The common spawn path was inspected for tmux and Herdr; it wraps ship, scout and host commands after environment filtering and leaves secondmate launches unchanged.
Harness command templates retain their existing bytes inside the wrapper; ownership uses kernel process relationships rather than vendor names or rendered output.
The portable regression entry point is `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-control.test.sh tests/fm-control-relaunch.test.sh tests/fm-spawn-compact-adviser-disable.test.sh tests/fm-teardown.test.sh`.
It exercises automatic close, explicit exit, teardown, separate ownership scopes and both launch environment modes.
On 2026-11-09, Linux with D-Bus 1.14.10, gh 2.102.0 (token in the keyring), chrome-devtools-axi 0.1.44 and Chrome 148.0.7778.178 ran workers without `DBUS_SESSION_BUS_ADDRESS`.
Five `gh api user` calls left five autolaunched `dbus-daemon` and `gnome-keyring-daemon` pairs under the previous wrapper and one private bus plus one keyring under the current one, none surviving the worker.
Five `chrome-devtools-axi open` and `stop` cycles on the Deck started no `dbus-daemon` or `gnome-keyring-daemon`, because the bridge launches Chrome with `--password-store=basic`.
`bin/fm-dbus-orphans.py` lists and closes autolaunched buses left behind outside workers; its regression is `FM_LIVE=0 bash tests/fm-dbus-orphans.test.sh`.
macOS was inspected but not executed in that verification; its detached-child limitation is documented in the implementation header.
No Herdr lifecycle command was run for this verification.

## Unattended Lavish board supervision

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Outgoing primary lock release

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Harness detection precedence

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### A real Codex session holding a retained Claude marker

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Real harness process names behind the walk

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## tmux

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Agent liveness name sources

Verified 2026-11-13 on Linux with Claude Code 2.1.323 and codex-cli 0.166.0.
Run `FM_HARNESS_LIVENESS_DRIFT=1 FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh` to refresh this token-free guard in disposable tmux resources.
Both installed binaries classified alive and were identified at `comm` ancestry strength.
The guard reported `checked 2 installed harness(es)` and `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0`.

### 2026-09-06 default-on drift refresh, and the Cursor editor CLI collision

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Harness-adapter instruction routing

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Cleanup endpoint identity

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Endpoint close

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Claude native repository configuration

Verified 2026-11-11 on Linux with Claude Code 2.1.322, claude-sonnet-5-5 at medium effort, Python 3.11.2 and Bash 5.2.
`FM_CLAUDE_NATIVE_LIVE_E2E=1 FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-claude-native-live-e2e.test.sh --jobs 1` executes captured `fm-spawn.sh` ship and scout commands against real Claude processes in disposable repository copies.
Pane and worktree acquisition are stubbed; the same worker's native init event, Skill calls and edited file prove loading, without naming a skill or marker in its assignment.
The `claude` fixture covers CLAUDE.md importing AGENTS.md, separate `.claude/skills` and `.agents/skills`, a command, an agent, project hooks, local settings and a project stdio MCP server.
The `shared` fixture has only AGENTS.md and `.agents/skills`.
A successful four-case run prints `ok - 2.1.322 (Claude Code): <claude|shared> <scout|ship> native markers reached an actual worker edit`.
All four cases passed with the deployed-model default, `claude-sonnet-5-5` at medium effort.
The first native Skill activation carries a hidden AGENTS.md value before any configuration read, and a distinct hidden skill-body value reaches the edited file.
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-claude-native-skills.test.sh --jobs 1` checks the portable discovery wiring, native-directory preservation and retargeting after relaunch.
`bin/fm-claude-native-skills.sh` owns the task-local discovery bridge; `bin/fm-spawn.sh` owns native instruction selection.
This changes only Claude ship/scout launch arguments, shared by the supported runtime backends; other harnesses, secondmates and primaries keep their own native loaders.
macOS live execution remains unverified; the helper uses portable Bash and symlinks.

## Claude workspace trust

Verified 2026-11-11 on Linux with Claude Code 2.1.322: a linked Firstmate task worktree reached its interactive prompt and edited a disposable file while the canonical project's external-import decision remained `Approved=false, WarningShown=true`.
Workspace trust and external-import approval are independent; the declined import decision does not require rejecting workspace registration.
Refresh with `FM_CLAUDE_TRUST_LIVE_E2E=1 bash bin/fm-test-run.sh tests/fm-claude-trust-live-e2e.test.sh` from an isolated linked task worktree; the exact success output is `ok - 2.1.322 (Claude Code): interactive worktree edit completed with external imports declined`.
The guard uses a private config copy, a private tmux server, and an external-import fixture without modifying the operator's real config.
The portable registration regression is `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-claude-trust.test.sh`; macOS interactive execution remains unverified.

### Secondmate homes

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Launch-prompt backstop signatures

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Worker account pin sign-in check

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Secondmate busy contract

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex hook trust

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex worker editing and native repository skills

Verified 2026-11-11 on Linux with `codex-cli 0.166.0`.
`FM_LIVE=0 FM_CODEX_HOOK_LAYER_LIVE=1 bash bin/fm-test-run.sh tests/fm-codex-hook-layer-live-e2e.test.sh` captures the production `fm-spawn.sh` command and runs it in private tmux with a disposable Codex profile.
The repository contains only `CLAUDE.md` and `.claude/skills`, and the worker brief names neither the skill nor its required admission format version.
The guard checks the initial native skill catalog before the task, the repository instruction and skill format in an actual `README.md` edit, busy/idle classification, and the worker's completion notification.
The exact verdicts were `ok - codex-cli 0.166.0: native skill, repository instructions, edit and completion verified` and `ok - native catalog and CLAUDE.md loaded before the unnamed task`.
The launch retained `--approve-for-me`, native hooks, and hook trust review; the disposable profile and project contained no hooks requiring consent.
`bin/fm-codex-activity.py` owns native root registration, its qualified runtime, completion attribution, and the editable fallback when registration is unsupported.
On 2026-11-12, Linux with an isolated `codex-cli 0.167.0` verified native `skills/extraRoots/set`, a first direct read of the indexed worktree skill body, and delivery through the configured primary completion callback. Activity classification for that newer runtime remains `unknown codex-unverified`; registration and notification do not qualify its activity parser.
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-codex-session-bind.test.sh` checks newer native registration, editable fallback on unavailable API, primary completion, and rejection of guardian-thread and stale-generation callbacks.
The Codex case in `tests/fm-busy-state.test.sh` passed with `ok - Codex rollout source proves lifecycle, kernel/session binding and replacement; invalid evidence stays unknown`, including simultaneous automatic review and parent-only completion notification.
The live guard submits a prompt and is opt-in; `tests/fm-spawn-dispatch-profile.test.sh` also checks configured approval and the absence of forced read-only for ship and scout launches without model calls.
macOS and other runtime backends were not executed in this guard; all backends consume the same generated brief and Codex launch template.

## Codex automatic approval review

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Composer classification matrix

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-10-14 opencode 1.19.0 de-emphasised mode/footer row in the left-bar composer

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-20 claude 2.1.236 statusLine footer through Herdr

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-29 claude 2.1.284 named session through Herdr

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-15 codex-cli 0.154.0 idle starfield and status footer through Herdr

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-18 OpenCode 1.18.31 idle cwd:branch furniture through tmux

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-10-14 OpenCode 1.18.31 absolute cwd rail on a wide tmux pane

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Steering-inbox doorbell

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Waiting-worker command ceilings

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Herdr

### Replacement presentation

On 2026-11-16, Linux and Herdr 0.9.5 passed the isolated real-backend replacement regression: a destroyed endpoint regained a dedicated space, a correctly projected endpoint retained its exact address, and an already-flat task regained a dedicated space.
The fixture uses an inert harness; it proves endpoint placement without submitting a vendor prompt.
`FM_TEST_HERDR_PROJECTION_RELAUNCH=1 bash bin/fm-test-run.sh tests/fm-control-herdr-projection-e2e.test.sh` refreshes this proof through the guarded named-session lab and verifies the unchanged default-session tripwire at cleanup.

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### fm-remote server birth and login-keychain access

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Client selection

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Submit confirmation

On 2026-11-13, Linux with Codex CLI 0.166.0 and Herdr 0.9.5 submitted a buffered `/quit` and exited after delayed input consumption.
`FM_HERDR_CODEX_DELAYED_LIVE=1 bash bin/fm-heavy-run.sh bash tests/fm-herdr-codex-delayed-live-e2e.test.sh` refreshes that proof in an isolated Herdr session.
The original raw transport failed the same guard with `buffered /quit remained unsubmitted`.

### Claude exit behind the slash-command popup

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Claude background-task exit picker

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Prune and respawn

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Launcher workspace placement

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Per-home and presentation topology

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Workspace-removal focus safety

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Attached foreground viewer

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Presentation version floor

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Composer and operational input

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Native blocked event

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Agent lifecycle control

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Endpoint recovery classification

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Stale agent registration

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Pane status authority across a relaunch

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Away-mode transport

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex App host tools

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Native Codex through Pi

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Process identity and markers

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Composer

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Busy state and lifecycle

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### End-to-end

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Busy inbox escalation

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex native Stop owner

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex direct inbox delivery

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex worker activity

Verified 2026-11-14 on Linux with `codex-cli 0.169.0` in an isolated Herdr session.
`FM_CODEX_TITLE_NOTIFY_LIVE=1 bash bin/fm-heavy-run.sh bash tests/fm-codex-title-notify-live-e2e.test.sh` refreshes the credentialed title/worker notification proof.
The verdict is `ok - codex-cli 0.169.0: title ignored while worker busy; real completion wakes once`.
Codex emits an early `agent-turn-complete` for an ephemeral conversation-title thread while the worker's first turn remains open.
The ordinary CLI callback forwards a completion only for a persisted CLI thread in the launch workspace and current generation, preserving both the watcher marker and ledger event for the real worker completion.
The callback uses filesystem metadata on Linux and macOS, independently of the Linux activity classifier's version qualification; macOS live execution remains unverified here.
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-codex-session-bind.test.sh tests/fm-busy-state.test.sh` refreshes the portable callback and existing native-server ownership regressions.

Durable worker transcript binding was separately verified on 2026-11-14 on Linux with `codex-cli 0.169.0` in an isolated Herdr session.
`FM_CODEX_SESSION_BIND_LIVE=1 bash bin/fm-heavy-run.sh bash tests/fm-codex-session-bind-live-e2e.test.sh` refreshes that credentialed proof.
The verdict is `ok - codex-cli 0.169.0: real worker transcript bound; activity qualification unchanged`.
The portable binding regression includes a newer CLI rollout; the real guard also requires that recording it leaves the newer runtime's activity verdict `unknown codex-unverified`.

## Shared publication boundary

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Controlled coordinator pilot

Verified 2026-11-07 on Linux, Bash 5.2, Python 3.11 and Claude Code 2.1.319.
The native pilot used Haiku 5.5, low effort and auto mode: one scout produced the technical report, applied an inbox correction, and the coordinator returned identical report bytes after restart.
A direct scratch-directory operation also ran while the worker was active.
The coordinator is mechanical; there is no primary-model solution or rewrite channel.
Refresh the portable ownership, pending-outcome and transition-alarm proof with `env -u FM_TASK_ID FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-claude-coordinator.test.sh --jobs 1`.
The measured run printed `host failover seconds: 4.92` and `PASS: controlled routing, exact worker report, bounded operation, pending outcome, transition alarms, host recovery, unread continuation and cleanup`.
The counterfactual omitting only outcome presentation failed on the same interface with an empty attention list despite the stored obligation.
The native run required an explicit, directory-scoped approval of its external instruction import; the repository does not override client consent.
This proves the controlled application's Linux lifetime only; native free chat, macOS execution and recovery after application SIGKILL or machine shutdown remain unverified.

## Fleet ledger primary finals

Verified 2026-11-09 on Linux with Claude Code 2.1.321 and codex-cli 0.166.0.
`FM_FLEET_LEDGER_LIVE_E2E=1 bash bin/fm-test-run.sh tests/fm-fleet-ledger-live-e2e.test.sh` runs the real Claude Stop guard and a real Codex TUI notify callback in disposable homes.
The Codex proof disables hooks and uses a private tmux server and private Codex configuration, leaving user settings and conversations untouched.
The exact verdicts were `ok - claude 2.1.321 (Claude Code): primary.final captured from the real final surface` and `ok - codex codex-cli 0.166.0: primary.final captured from the real final surface`.
The runner reported `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=15130`.
This proves full normal-final capture with session ownership, not structured question interception, failure/interrupt hooks, activity starts in Codex, or macOS execution.
Codex exec can exit before its asynchronous notify callback proves primary ownership; the maintained guard deliberately uses the persistent TUI.
The event format and installation boundary belong to [the fleet ledger contract](../fleet-ledger.md#harness-coverage).

`FM_CODEX_ACTIVITY_LIVE=1 FM_CODEX_ACTIVITY_NOTIFY_ONLY=1 bash bin/fm-test-run.sh tests/fm-codex-activity-live-e2e.test.sh` also verified the captured production worker launch on 2026-11-09.
It reported `ok - real Codex launch publishes normal completion with its bound generation` and `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=39341`.
The unrestricted activity matrix reached normal completion, Escape and incarnation replacement, but its latest private HTTP-error setup produced no owner binding, so that failure route is not refreshed by this ledger verification.

## Waiting-worker parking

Verified 2026-11-14 on Linux with Codex CLI 0.169.0, Claude Code 2.1.325 and Herdr 0.9.5.
`FM_WORKER_PARKING_LIVE=1 bash bin/fm-heavy-run.sh bash tests/fm-worker-parking-live-e2e.test.sh` refreshes the credentialed, isolated proof for every installed verified harness.
The run printed `PILOT PASSED codex continuation and acknowledged response` and `PILOT PASSED claude continuation and acknowledged response` and exited zero after guarded lab teardown.
On the current base, both Codex and Claude reopened their exact transcript and acknowledged the response.
Before the rebase's host argument-spacing fix, the Claude fixture also exercised the explicit missing-session fallback and retained-note continuation.
Both cases stopped the old agent, closed its pane, launched in the same task location and acknowledged the response in the existing inbox.
The current semantic activity limits remain explicit: unknown activity or an unconfirmed launch seed requires Firstmate's verified safe point; an observed busy event refuses parking.
`FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-control.test.sh tests/fm-send-inbox.test.sh tests/fm-herdr-lab.test.sh` refreshes the portable wait kinds, preserved work, pending response, supervision lease and lab recovery checks.
The initial lab snapshot lost during a canceled fixture was not reconstructed; explicit helper recovery verified the current default unchanged across its subsequent teardown.
No macOS execution is claimed by these results.
