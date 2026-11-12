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
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
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
   Use `blocked:` when you are stuck and need help.

5. Apply any command-specific bounded recovery first; bin/fm-tasks-axi.sh --help owns work-lock contention recovery.
   If the same obstacle persists after two attempts, stop retrying that path and find another authorized way forward.
   Continue independent authorized work that does not depend on that path; stop the whole task only when no such work remains.
   When no authorized way forward remains and firstmate must act, append `blocked [key=<slug>] [at=<epoch>]: {failed path; evidence; affected work; next action needed from firstmate}`.
   Do not turn a technical obstacle or firstmate's own choice into a new human approval request, or wait for another worker without naming the action firstmate must assign.
   This does not relax safety gates, required validation, shared-infrastructure boundaries, or the ban on reporting done with unresolved required work.
6. If a decision belongs above the implementation worker (product choices, destructive actions),
   prepare the decision evidence required by AGENTS.md section 9 for firstmate before stopping; stop before the action that needs that decision.
   append `needs-decision [at=<epoch>]: {summary of options}` and stop. Firstmate will reply with the decision.

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


## Inbox and progress

Read and acknowledge messages in the task inbox in numeric order by moving each handled message to its `handled/` directory.
Check the inbox when notified and at natural checkpoints, except while waiting if the brief says not to poll.
Follow the progress contract provided at launch.
When firstmate requests a safe point, preserve work and record paused with its exact safe-point request key and numeric timestamp only after reaching it; resume only when explicitly instructed.

## Project memory

A project's `AGENTS.md` or `CLAUDE.md` is loaded into every agent session in that project, so edit it only to correct information that is factually wrong - including information your own change made wrong - and never to add knowledge because it is missing.
A correction edits only the wrong text: do not run `fm-ensure-agents-md.sh`, create either file, or add sections, headings, or pointers alongside it.
