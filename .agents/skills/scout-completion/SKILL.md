---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, is being considered for promotion to implementation, or the captain asks to review or continue a closed scout.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; relay its concise findings and decision summary, make sure the card's summary states them in one or two plain sentences in the captain's language (`bin/fm-tasks-axi.sh presentation <id> --summary`), record the report as the Done artifact, and re-evaluate the queue.
When the captain asks to review or continue a closed scout, have a worker restore its backup into a new copy using the recovery command printed by `bin/fm-teardown.sh`, then inspect or continue the preserved changes instead of repeating the investigation.
Route unresolved work from the report through `AGENTS.md` section 7, reusing the originating task when promotion fits.
A report supplies evidence and grants no new implementation authority.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
For every visual report or iterative discussion, retain the scout as host under `AGENTS.md` section 9 and the crew-hosted Lavish board contract in `docs/configuration.md`; it creates, hosts, and iterates the artifact and returns the resulting decision.
When existing or newly granted authority covers implementation, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
Pass its current implementation title with `--card-title`, then reconcile the new plan under the presentation owner's checkpoint contract (`bin/fm-tasks-axi.sh --help`).
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
