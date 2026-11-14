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

When a task worker declares ready-for-merge, needs-decision, captain-held, or a pause with an until date, Firstmate parks it as soon as the current operation has finished.
An active test or validation is still an operation, even after a wait status was written; wait for its completion before parking.
Use the control plane's park action immediately at that safe point, without an idle timer.
Its executable owner refuses known busy activity and reports unknown activity explicitly; Firstmate must verify the operation-complete safe point in that case.
It saves the launch, session reference, work location, progress and wait before closing the agent and pane.
A failed stop or close is incomplete parking; retry park after resolving the named failure.
A message sent through the existing inbox resumes a parked task before delivery; a failed resume retains that response pending and must not be resent.
Before an automatic resume, compare the saved harness with the current usage policy.
A different harness opens the existing captain hold with original-worker and current-harness takeover options, recommending the current policy; no agent launches and the inbox response stays pending.
If dispatch profiles contain several harnesses, resolve the applicable rule and quota choice yourself; never substitute the static crew setting. If that choice differs from the saved harness, open the same two-option captain hold before resuming explicitly.
Record the captain's actual answer through the hold owner, releasing the work in flight; then call resume with the explicitly chosen --harness, --model and --effort profile.
Choosing the original harness reopens its saved chat when possible; choosing another starts fresh with the saved progress note. Never resend the pending message.
The existing dated-pause watcher recheck also uses this route.
[Agent lifecycle control](../../../../../docs/agent-control.md) describes the lifecycle boundary; the command header owns exact mechanics.
Relaunch starts a fresh chat with a progress note; resume reopens the parked chat when its native identity is available, otherwise reports the reason for a fresh-chat fallback.

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
