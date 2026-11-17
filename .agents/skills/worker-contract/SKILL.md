---
name: worker-contract
description: Load when a Firstmate ship or scout brief instructs you to follow the worker contract.
user-invocable: false
metadata:
  internal: true
---

# Worker contract

Apply this contract using the task-specific paths, commands, delivery rules, and setup in the brief.
If a task-specific instruction conflicts with this contract, the brief takes precedence.

## Rules

1. Follow the task-specific delivery and branch rules in the brief.
2. Keep project edits inside this worktree; put labs, installations, copies, and other scratch output in the task tmpdir (the parent of `$GOTMPDIR`), which teardown deletes.
   Keep only reports, logs, and captures in the task data directory named in the brief; outside the worktree, also write the status, card, and steering-inbox records authorized there.
   A ship leaves the worktree clean before reporting done; a scout may leave laboratory changes for preservation at teardown.
3. Use the forge and browser tools named in the brief.
4. Report status by appending one line:
   Use the status command supplied in the task brief.
   States: working, needs-decision, blocked, paused, done, failed.
   Use the declared external-wait status in place of `paused` throughout this contract.
   Substitute `<epoch>` with the current Unix time in seconds - run `date +%s` and write the number it printed; a stamp that is not plain digits records no time at all.
   Decision, failure, and completion lines wake firstmate; routine `working` and `paused` lines are batched, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; firstmate
   copies that URL from your line rather than assembling one.
   A mid-task `working:` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined `done:` gate under Definition of done.
   With each status line, also refresh the card the captain's board shows for this task:
   Use the card command supplied in the task brief.
   Write `{what is happening now}` as one plain line of at most 120 characters that states a fact about the work rather than a message, in the language of the captain's own words under `## Captain's intent`, without repeating the card title and without ids, paths, hashes, or tool names.
   When you report done, add `--summary '{what this delivers, in one or two plain sentences}'` to the same command, in the same language.
   A card write that fails never blocks the task; the status line stays authoritative.
   Use `paused: {why}` - distinct from `blocked:` - when deliberately waiting for work or an external condition expected to clear on its own, including your own validation round.
   Before ending your turn with your own background shell or monitor still running, or before waiting on your own pipeline run or a long foreground command, append `paused [at=<epoch>]: {job and completion condition}` to the status file.
   Name what you are waiting for and what will let you resume; do not repeat the declaration on every poll.
   Do not declare active implementation or reasoning as a wait.
   Firstmate may still raise one first-sight alert; the declared wait then uses the existing long recheck cadence instead of repeated possible-wedge alarms.
   When you know when the wait clears, include `until <YYYY-MM-DDTHH:MMZ>` (UTC) for a recheck at that time; for your own background job or command with a timeout, that time is its start plus its timeout, rounded up to the minute.
   Follow the resolution rule below when the wait clears, then resume the task.
   Fix the root cause, not the symptom, and fix it at its most general level: before adding a case, list or exception, ask what general mechanism produced this failure and correct that. Be critical of the request, the plan and your own fix; a growing list of hardcoded scenarios means the general problem is still open.

5. Before escalating an obstacle or question, follow [Obstacles and escalation](#obstacles-and-escalation).
6. If a decision belongs above the implementation worker (product choices, destructive actions),
   prepare the decision evidence required by AGENTS.md section 9 for firstmate before stopping; stop before the action that needs that decision.
   append `needs-decision [at=<epoch>]: {summary of options}` and stop. Firstmate will reply with the decision.

   To request a separable front, instead append `needs-decision [key=dividir-<slug>] [at=<epoch>]: <front>; <source>; <acceptance>; <integrator>; <independent work continuing>`.
   Quote the original request in the acceptance criteria and continue work that does not depend on the split.
   Firstmate dispatches helpers and resolves the key; do not delegate directly.
   While at least one separate front is open, the original task owner is the Task Lead (Responsable de tarea).
   The Task Lead reviews and integrates helper results and owns the original task's board and replies; helpers do not operate that board.
   When no independent work remains, use the declared external-wait status and resume when Firstmate delivers the result through the inbox.
   When all separate fronts close, the owner returns to the ordinary worker role.

   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved [at=<epoch>]: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.
7. Never administer infrastructure that every lane shares. Two things are shared:
   - The `no-mistakes` daemon - one instance serving every lane/home, so stopping, restarting, or
     updating it kills other lanes' in-flight pipeline runs; only firstmate manages the daemon.
     Before you append `blocked:` about the pipeline, run `no-mistakes daemon status` and
     `no-mistakes axi status`. If the daemon socket refuses connections or is missing, append
     `blocked [at=<epoch>]: {the daemon error}` and stop even when the local run record still says running or
     fixing, because that record can be stale after the daemon exits. A run record failed with a
     daemon error is also a real block.
     Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep
     going. A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error:
     the daemon accepts `respond` immediately and runs the round in the background, so a killed or
     timed-out call was only waiting for a read while the run kept working.
   - The worktree pool your own worktree came from, and the repository every lane's worktree
     shares. Never create, remove, return, prune, move, or reassign a worktree or pool slot, and
     never write into a sibling slot's directory. Rule 2 does not cover this: removing a worktree
     is administration rather than an edit outside your directory, and it lands on lanes that are
     running right now. The act is the rule and commands are only examples of it - `treehouse`
     get/return/remove/prune, the equivalent operations on any other worktree provider or runtime
     backend, and `git worktree add|remove|move|prune`. A slot that looks unused is not evidence
     that it is free, and returning your own worktree is firstmate's job at cleanup, not yours.
   If you genuinely need a second checkout, another slot, or the daemon touched, append
   `blocked [at=<epoch>]: {what you need}` and stop; firstmate arranges it.
8. Never start a shell command with `cd`, and never run a search whose path depends on the current directory.
   Use absolute paths, `git -C <abs>`, or a `( cd <abs> && ... )` subshell.
   Quote every variable in `rm` and other destructive commands (`rm -rf -- "$dir"`) and prefer literal paths or a `mktemp -d` directory for scratch data: an unquoted expansion triggers the harness's safety prompt and stalls you.
   Write a variable glob as `rm -f -- "${dir:?}"/*`, and remove a `$(...)` result only by the literal paths it printed: Claude Code holds `$dir/*`, `"$dir"/*` and substitution targets on a permission dialog even in bypass mode and denies them after two minutes.
   Pass this rule to every sub-agent you launch.


## Obstacles and escalation

Apply this procedure before declaring `blocked`, including after command-specific recovery is exhausted.

1. Read the brief, applicable rules, steering replies, and existing evidence for the affected step.
   If they already answer the question or authorize the action, act on them and record the reason; do not request the same authority again.
   Interpret an external event by its documented session state and content; a connection or presence change with no new request or answer creates no new decision or blocker.
2. Identify the unmet prerequisite and the smallest action that would let the affected work proceed.
   Resolve reversible task-local setup and implementation problems yourself within the task's allowed paths and authority, including preparing an isolated test environment in task scratch.
   For a timeout, distinguish unfinished work under the observed scheduling/load from a failed assertion; adjust task-local waiting bounds to the observed cost without weakening assertions or changing required acceptance limits.
3. Apply the command's documented bounded recovery first; `bin/fm-tasks-axi.sh --help` owns work-lock contention recovery.
   If the same obstacle persists after two attempts, stop retrying that path and find another authorized way forward.
   A retry count, timeout, or temporary refusal alone does not establish a need for firstmate to act.
4. Continue independent authorized work that does not depend on that path; stop the whole task only when no such work remains.
   If the remaining prerequisite is expected to clear on its own, use the declared external-wait status with the condition that will let you resume, then follow the resolution rule when it clears.
   While a review interaction remains open, keep its existing listener active through the adapter's documented recovery until a terminal or explicit review signal; a transport event does not end the review.
5. Use `blocked` only when the affected work cannot proceed until an identified outside actor performs a necessary action you lack the authority or capability to perform.
   Append `blocked [key=<slug>] [at=<epoch>]: {failed path; evidence; affected work; next action needed from firstmate}`, naming that actor and action and why authorized local recovery cannot supply it.
   For an unanswered decision above your scope, use `needs-decision` with the full question, options, and recommendation, and stop before the action that needs the answer.

Do not turn a technical obstacle or firstmate's own choice into a new human approval request, or wait for another worker without naming the action firstmate must assign.
Quota and cost are reported, never a reason to wait.
This does not relax safety gates, required validation, shared-infrastructure boundaries, or the ban on reporting done with unresolved required work.


## Inbox and progress

Read and acknowledge messages in the task inbox in numeric order by moving each handled message to its `handled/` directory.
Check the inbox when notified and at natural checkpoints, except while waiting if the brief says not to poll.
Follow the progress contract provided at launch.
When firstmate requests a safe point, preserve work and record paused with its exact safe-point request key and numeric timestamp only after reaching it; resume only when explicitly instructed.

## Access and captured logs

Before a long run or freezing inputs, list the required services and data areas and make one small read from each using the documented access mode, including anonymous access when supported.
Report missing access before starting the full pass; renew an expired service login rather than repeatedly retrying it.
Before saving or sharing captured logs, pipe them through `python3 <firstmate-code-root>/bin/fm-redact-log.py`; never retain the raw token-bearing output or enable shell tracing around credentials.
The filter masks credential-bearing lines, not arbitrary unlabeled secrets; prefer selecting only the nonsecret fields needed for evidence.

For visual review boards, follow the [crew-hosted board contract](../../../docs/configuration.md#crew-hosted-lavish-review-boards), including creating or resuming without a browser launch and reusing the session.

## Reports

For a requested report, provide a self-contained `report.html` alongside any required machine-readable or Markdown record.
Copy and adapt the inline [report theme](report-theme.html), preserving offline use and system light and dark modes.
When publishing the HTML, declare `outcome.review=needed` in the task presentation, including for a partial result, and use the returned `outcome_occurrence` in the report's links.
Each new result must be declared as a new occurrence before its links are written; changing the review mark does not close the task or answer a decision.
When arming a Lavish review for that report, pass `--review-occurrence <outcome_occurrence>` so End and Send & End apply to the version opened; a browser disconnect never marks it reviewed.
Use the Deck address in the brief, if present, to build ordinary links to `/?task=<id>&view=delivery&item=<occurrence>&do=reviewed` and `do=lavish`, URL-encoding each value.
For approval or independent decisions, link each existing captain call as `/?task=<call>&view=call&option=<id>` for each offered option; the Deck confirms the action, and unanswered calls remain open.
Choose the actions from what the report asks: review and Lavish for an informational report; approve, request changes and Lavish for approval; options for each independent decision and Lavish for decisions.
When the Deck address or network is unavailable, offer to arrange review through firstmate; do not ask the reader to run commands.
For a list of independent choices, include every relevant item, identify unverified items as needing investigation, and offer a single submit control that preserves each chosen item as its own decision.
Start with the result, its significance, and the next action in plain, friendly language for the reader, never agent-to-agent prose.
Spell out names rather than presenting unexplained IDs or version labels.
When a report mentions a Deck task, write its name in words and link the task ID to its card.
Explain a flow with a step-by-step diagram and a concrete end-to-end example; present data in tables or charts instead of paragraphs.
Adapt the visuals to the subject, and put supporting data, methods, technical verification, and other technical detail in expandable sections or a separate record.
Keep the initially visible report to at most 300 words and one screen; put the remaining detail in closed expandable sections.
Before delivering it, open the report in a browser with those sections closed and run the adjacent [report check](report-check.js) as a browser expression (for example, `chrome-devtools-axi eval "$(cat /path/to/worker-contract/report-check.js)"`).
It counts rendered HTML and SVG text, including headings, table cells and closed-section summaries, and reports visible graphic candidates; inspect the page and count actual flow diagrams, including any made from HTML rather than graphics.
Record the visible word count and actual diagram count with the result, and do not deliver until the count is at most 300, at least one flow diagram is visible, and the opening screen includes a complete end-to-end example and data in tables.
Check the screen visually as well: a word count alone cannot prove it fits, and a graphic count cannot establish that a diagram explains the flow.
Show the generation date and time in the reader's local time, never UTC, plus relative age that refreshes locally when JavaScript is available; the absolute local time must remain visible without it.
Name the model and reasoning effort of the report author only; obtain them from this task's runtime metadata, and if either is absent say so rather than guessing.
Include the evidence needed to read the report offline without a CDN, external fonts, agent interface, or required service.
Give firstmate the full report link and a one- or two-sentence outcome.
Keep the existing result/review declaration current.
Opening a report must not start Lavish; on-demand integration is a separate capability.

## Project memory

A project's `AGENTS.md` or `CLAUDE.md` is loaded into every agent session in that project, so edit it only to correct information that is factually wrong - including information your own change made wrong - and never to add knowledge because it is missing.
A correction edits only the wrong text: do not run `fm-ensure-agents-md.sh`, create either file, or add sections, headings, or pointers alongside it.
