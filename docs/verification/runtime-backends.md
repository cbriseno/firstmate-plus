# Runtime backend verification

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

## Worker temporary processes

The ownership and platform contract lives in the header of `bin/fm-worker-processes.py`.
On 2026-11-06, Linux with Python 3.11.2, chrome-devtools-axi 0.1.44 and Chrome 148.0.7778.178 ran a private worker that opened a Python HTTP server and headless browser.
The wrapper captured 21 processes including the detached bridge, MCP, Chrome, telemetry and crashpad, then returned `exit 0 captured 21 survivors {}`.
The common spawn path was inspected for tmux, Herdr, Zellij, Orca, cmux, Paseo and Rex; it wraps ship, scout and host commands after environment filtering and leaves secondmate launches unchanged.
Harness command templates retain their existing bytes inside the wrapper; ownership uses kernel process relationships rather than vendor names or rendered output.
The portable regression entry point is `FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-control.test.sh tests/fm-control-relaunch.test.sh tests/fm-spawn-compact-adviser-disable.test.sh tests/fm-teardown.test.sh`.
It exercises automatic close, explicit exit, teardown, separate ownership scopes and both launch environment modes.
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

Historical machine-specific probe transcripts are not distributed.
Use the current affected regression tests to refresh this compatibility topic.

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
