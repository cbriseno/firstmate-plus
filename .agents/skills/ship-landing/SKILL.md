---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
In no-mistakes mode the earlier `done [at=<epoch>]: {summary}` is the pipeline handoff and is not gated.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
Before cleanup, check that the card's summary says in one or two plain sentences, in the captain's language, what changed for the captain, and rewrite it with `bin/fm-tasks-axi.sh presentation <id> --summary` when it does not.
Retain delivery gate facts with `presentation <id> --reconcile` and settle any progress reconciliation notice under that owner's checkpoint contract before retiring the live status/meta; installed acceptance remains separate.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
Use `--preserve` only for a ship or scout with an attached task branch; a host or detached scout uses ordinary teardown.
Complete the applicable verification and installation within the same task before closing it.
When something must stay alive to protect landed work, close with `bin/fm-teardown.sh <id> --residual "<what is left, in the captain's language>"`; add `--keep-running` only when cleanup itself would destroy what must be kept, because it leaves the task's endpoint and local copy untouched and names them in that item (the script header owns both flags).
Recheck a residual item whenever its condition can have changed, close it with `bin/fm-tasks-axi.sh done <id>-residual` once it is settled, and ask the captain before closing anything it kept running, since it was kept for them.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.
When a `cleanup-disposition:<fingerprint>` wake names that task, record `closed` after teardown succeeds, or record `retained` with its reason or `blocked` with the teardown refusal through `fm-inactive-reconcile.sh disposition`; the startup scan keeps an unresolved disposition visible after wake acknowledgement.
When the applicable delivery procedure requires installed verification, complete it within the same task before treating the request as finished.
When teardown prints `Install follow-up:`, run its named `bin/fm-install-followup.sh brief` command and dispatch that follow-up when the selected delivery procedure uses this capability.
Report a landed change as on its way until that verification is complete.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
