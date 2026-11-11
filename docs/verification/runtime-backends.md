# Runtime backend verification

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Worker session bindings

The durable record format and one-off historical migration belong to the header of `bin/fm_task_sessions.py`.
On 2026-11-09, Linux with Python 3.11.2, codex-cli 0.166.0 and Claude Code 2.1.319 verified both capture paths against real harnesses in disposable task data.
`python3 bin/fm-codex-activity.py classify "$STATE" "$ID"` returned `busy codex-rollout` and completed the durable record from the validated native process's rollout; repeating it retained one record.
`claude -p 'Reply with exactly OK.' --model haiku --effort low --tools '' --setting-sources '' --strict-mcp-config --settings "$SETTINGS" --system-prompt 'Reply to the provided text without using tools.'` returned `OK`, with its UserPromptSubmit hook filling the transcript path.
Replaying the first 60 lines of real historical Claude and Codex transcripts through the migration recovered both sessions; a second invocation left the files unchanged.
Claude's historical brief can arrive in a tool result after an inbox doorbell, and its first transcript record can lack a timestamp.
The portable regression entry point is `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-busy-state.test.sh`.
The common spawn path records launches before backend delivery for tmux, Herdr, Zellij, Orca, cmux, Paseo and Rex, independent of the harness command; session capture currently uses only Claude's existing hook and Codex's existing pin.
Remote secondmate launch transport is outside worker capture.
macOS was inspected but not executed; the writer and migration use Python's standard library, while automatic Codex capture retains its existing native Linux capability limit.

## Worker temporary processes

The ownership and platform contract lives in the header of `bin/fm-worker-processes.py`.
On 2026-11-10, Linux with Python 3.11.2 ran `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-work-activity.test.sh` with real disposable worker processes.
It reported `ok - real worker kill and wrapper stop publish death; count, row, recovery, relaunch and incarnation isolation`.
The common wrapper now publishes process liveness independently of harness output for ship, scout and host launches across tmux, Herdr, Zellij, Orca, cmux, Paseo and Rex; secondmate launches remain outside this wrapper.
The regression exercises SIGKILL of the worker while its wrapper remains alive, wrapper TERM, recovery and relaunch through the canonical owner and projection.
Its common publication path uses Python subprocess and the existing Bash ledger writer on Linux and macOS; macOS execution of this new regression remains unverified.
On 2026-11-06, Linux with Python 3.11.2, chrome-devtools-axi 0.1.44 and Chrome 148.0.7778.178 ran a private worker that opened a Python HTTP server and headless browser.
The wrapper captured 21 processes including the detached bridge, MCP, Chrome, telemetry and crashpad, then returned `exit 0 captured 21 survivors {}`.
The common spawn path was inspected for tmux, Herdr, Zellij, Orca, cmux, Paseo and Rex; it wraps ship, scout and host commands after environment filtering and leaves secondmate launches unchanged.
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

## Polytoken worker lifecycle

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

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

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

## Claude workspace trust

Verified 2026-11-11 on Linux with Claude Code 2.1.322: a linked Firstmate task worktree reached its interactive prompt and edited a disposable file while the canonical project's external-import decision remained `Approved=false, WarningShown=true`.
Workspace trust and external-import approval are independent; the declined import decision does not require rejecting workspace registration.
Refresh with `FM_CLAUDE_TRUST_LIVE_E2E=1 bash bin/fm-test-run.sh tests/fm-claude-trust-live-e2e.test.sh` from an isolated linked task worktree; the exact success output is `ok - 2.1.322 (Claude Code): interactive worktree edit completed with external imports declined`.
The guard uses a private config copy, a private tmux server, and an external-import fixture without modifying the operator's real config.
The portable registration regression is `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-claude-trust.test.sh`; macOS interactive execution remains unverified.

### Secondmate homes

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Pi seeded-secondmate project trust

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

## Codex automatic approval review

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Composer classification matrix

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-10-14 opencode 1.19.0 de-emphasised mode/footer row in the left-bar composer

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Grok approval-titled bottom border

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

## Gemini

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Trust options are not equivalent

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Busy signal

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Hook lifecycle

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Autonomous end-to-end worker

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Identity markers

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Credential wedge and its blast radius

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Settings placement

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Not verified

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Herdr

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### fm-remote server birth and login-keychain access

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Client selection

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Submit confirmation

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

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

## Zellij

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Orca

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Orca environment source

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## cmux

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Claude composer confirmation

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Paseo

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Rex

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Push events

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Worker tools on Rex

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex App host tools

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Cursor Agent CLI

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Process identity

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Environment markers and detection ordering

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Composer

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

#### tmux composer verdict, corrected 2026-08-13

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

#### tmux composer verdict, fully dim placeholder 2026-10-21

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Busy state

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Rendered busy token, delivery only

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Launch, lifecycle, and skills

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### End-to-end

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### Herdr backend

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Pi supervision branch

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-08-28 Pi 0.84.4 SDK compatibility refresh

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-08-29 deterministic captain-outcome delivery

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-01 sequence-keyed captain-outcome processing

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-02 historical post-construction provider-error fallback

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-02 streaming-time watcher delivery

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-04 off-thread supervision outcome delivery

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-18 away posture parks main

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

### 2026-09-20 the away words execute

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Native Codex through Pi

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Oh My Pi (omp)

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

## OpenCode 2 launch and brief delivery

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## OpenCode 1 compatibility of the dual-export plugins

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex native Stop owner

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex direct inbox delivery

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Codex worker activity

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

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
