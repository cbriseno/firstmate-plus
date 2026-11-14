# Control and recovery

Load this with the running or recorded tool reference for trust, skill invocation, interrupt, exit, resume, or recovery.

## Typed data and lifecycle control

The router owns lifecycle-only control and recorded-harness selection.
Conversation and harness-native skill invocation use `../../../bin/fm-send.sh`.
`../../../docs/agent-control.md` owns the data-plane split, and `../../../bin/fm-control-lib.sh` owns executable capabilities.
Tool-reference exit and interrupt values are empirical records, not keys to improvise; a new adapter remains uncontrollable until they land in that owner.
Let the control plane verify postconditions.

## Trust and skill submission

Inspect after spawn within the tool's readiness window.
A security permission requires the operator's explicit approval for the actual folder, hooks, imports, or connector, or a standing approval that covers that scope; supervisor approval alone does not grant it.
With that authority, select only the documented choice for the visible dialog from the active Firstmate home, binding `FM_HOME` unless already correct, then inspect again under the router-owned completion postcondition.
Backend arrow-key capability and the lifecycle control plane's supported verbs are separate; do not infer authority from either.
No observed dialog proves only that launch.

Each supported harness handles its folder-trust gate differently, and the tool reference owns the detail.
For Claude, load `references/harness/claude.md`; its workspace-trust section owns the dialog-specific limits and spawn-time pre-registration for every spawn kind.
Codex directory and hook trust sequences, including fresh host-task folders, belong to `references/harness/codex.md`.

Use the tool's exact skill form, or natural language only when no separate command is verified or the form remains uncertain.
A successful send or key return is not proof of submission; require the tool-specific postcondition.
Popup, queued-input, and readiness handling belongs to `../../../bin/fm-composer-lib.sh` and the selected backend.

## Interrupt and exit

Use the control plane so capabilities are checked first.
Interrupt preserves the agent and work; exit stops only the agent and preserves its endpoint, isolated copy, and uncommitted changes.
Cleanup and discard are not lifecycle verbs.
The tool reference records repeat, acknowledgement, and clearing behavior, while the executable owner sends or refuses the sequence.

## Resume and recovery

Native resume availability and form belong solely to the selected tool reference.
Use native resume only when both that reference and the recovery procedure call for it.
Deterministic relaunch instead trusts instructions on disk, not a private session, and never needs a session id printed at exit.
One relaunch-time exception is the runtime's own recorded session identity, used only to keep that runtime's status authority valid across the replacement - `../../../docs/agent-control.md` "Transactional relaunch" owns it.

## Manual context handoff

Use the installed `relay` skill for a primary handoff; its algorithm belongs to that extension.
For a worker, use the existing relaunch verb rather than opening another agent beside it.
This procedure does not enable an automatic threshold or change the dispatch profile.

1. Have the worker finish its current operation and stop starting new actions.
   It writes a progress note with the objective, completed work, worktree and branch, evidence, remaining work, exact steering inbox, and any external action already performed that must not be repeated.
   It reports the note's path through its existing task status route and waits for the replacement.
2. From the owning home, run `bin/fm-control.sh <task-id> relaunch --note-file <progress-note>`.
   Omit profile overrides to retain the recorded harness, model and effort.
   The control plane owns stopping the old process, preserving work and delivering the note; its header owns the flags and failure recovery.
3. Verify the successor reads the note and pending inbox messages, acknowledges handled messages, and completes one small remaining operation without repeating a completed action.
   A successful launch alone does not establish continuity.
   Refresh the task's progress checkpoint after the handoff, under the launch brief's progress contract.
4. Inspect the task and project session history through `bin/fm_task_sessions.py`'s list interface.
   Verify the prior launch is archived and the replacement is active with the intended profile and a new transcript, or report a missing binding with its recorded reason.
   Report the completed handoff through the existing status route so firstmate follows the active session.

If the replacement fails to start, report the handoff as incomplete with the preserved work and note paths and the control plane's concrete process verdict.
Inspect that verdict before retrying; never create an additional worker to compensate for an unconfirmed launch.

`../stuck-crewmate-recovery/SKILL.md` owns worker recovery and `../secondmate-provisioning/SKILL.md` owns secondmate recovery; both preserve recorded work.
The router's recovery scenarios select the additional common references for replacement profiles and secondmates.
