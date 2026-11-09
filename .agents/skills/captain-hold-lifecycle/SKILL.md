---
name: captain-hold-lifecycle
description: >-
  Load before holding any task for the captain, before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, on a `captain call opened for idle in-flight work` check wake, and on any RECORD DIVERGENCE line the wake drain prints.
user-invocable: false
metadata:
  internal: true
---

# Captain-hold lifecycle

A decision is not a separate thing: it is simply a task waiting on the captain.
The one primitive is an ordinary backlog task held for the captain through `bin/fm-captain-hold.sh hold`; its identity is the task id, and that wrapper owns the deterministic mechanics this policy relies on.
The originating worker performs the semantic inventory under `AGENTS.md` section 1 and returns the concise result; scripts must not infer captain calls from report prose, visual-review artifacts, terminal output, or chat.

## Policy

Every unresolved question that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must be carried by a captain-held task in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
For a Lavish board-backed handoff, the hosting worker passes its reply through the crew-hosted contract before appending status; `AGENTS.md` section 9 owns delegation and the adapter owns version-specific acceptance ordering.
Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
The originating investigation or review is never its own inventory entry, so hold a separate task for the call and pass `--origin <origin-id>` so `complete` can check it.
Prepare the decision under `AGENTS.md` section 9 before holding it; retain the analysis and plan in the linked result rather than expanding the card.
Keep the reason a short plain summary, and put the card the captain answers in the structured hold fields: `--context`, `--question`, one `--option` per choice, `--recommended`, and `--link` to the report.
`hold` refuses a call without `--question` and at least two `--option` choices, so think the choices through before holding rather than retrying around the refusal.
Pass `--no-options "<why>"` instead only when the question genuinely has no choices to click, including an answer in words or a legacy wait.
Use the owner's explicit action facet for a separate persistent instruction to act in chat; [`fm-captain-hold.sh`](../../../bin/fm-captain-hold.sh) owns its fields and authoritative completion contract.
Never write options into the reason or the question text: a board shows that prose only as text, so the captain gets no real choices.
Hold one task per independent captain decision, each with its own question and options, so every open captain question has a held task and its own one-click card.
When several decisions gate one work item, create one captain-held decision task per question and mark the work item blocked by each of them with `bin/fm-tasks-axi.sh block <work> --by <decision>` instead of holding the work item for one decision, so it stays undispatchable until every decision is answered.
Represent each held task with exactly one board card; never fan one task id into duplicate same-key cards.
Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
Pass the card fields again on every re-hold: a re-hold after a release starts a new hold, so `hold` refuses it without them; only a repeat of a still-active hold whose card already has choices may omit them.
After inventorying the whole report and review surface, run `bin/fm-captain-hold.sh complete` with every captain-held task id, or with `--none` only when the reviewed surface leaves nothing waiting on the captain.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; secondmate-owned work registers in that secondmate home's backlog, and a question already held anywhere is never re-registered as a second row.
Do not close a captain-held task merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
Holding the work item the question gates is safe for exactly that reason: cleanup keeps such a row open with the finished work's deliverable recorded and returns it to the queue, so it still reads as the captain's own call.
Only `answer` with the captain's words, an evidence-backed board-requested `reconcile close`, or the owner's verified moot-retirement path may resolve it.

An unanswered separate call, question or explicit action, may retire automatically when its origin and all transitively gated work are verifiably closed, or an explicit supersession attestation replaces the origin proof while all known gated work is closed.
Completion of the originating investigation alone, elapsed time, and read or acknowledgement receipts never prove mootness; without known gated work, automatic retirement leaves the call open.
The owner preserves existing answers and actual work, records retirement as a durable `reconciled` resolution rather than an answer or human action completion, and leaves uncertain or still-needed calls open.
[`fm-captain-hold.sh`](../../../bin/fm-captain-hold.sh) owns the exact eligibility, proof, retry and supersession mechanics; closure, teardown and same-home session reconciliation invoke its sweep without a captain validation step.

Never invent a captain answer: `bin/fm-captain-hold.sh answer` writes his exact words into the task and closes a question-shaped call, while `--release` frees a captain-gated work item to proceed.
Before asking again, reconcile the canonical recorded answer and the originating work's `recorded_answers` in `work snapshot`.
A settled question can still have a pending inbox application receipt; handle or relay that saved answer through the primary owner without reopening the question or bypassing policy review.
A merge approval uses that existing release path because approval permits the merge to proceed; cleanup closes the work only after it lands and records what shipped.
Closing a held row at merge approval instead records completion before landing, so the backlog claims completion before the work actually ships.
When the answer changes what a task must build, follow `AGENTS.md` section 7's mid-task ask rule to preserve the captain's words in the brief and steer the worker.
When the captain says "later", that is an answer too: re-hold with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` plus the card fields (`--question`, the `--option` choices, `--recommended`) so the item leaves the live Captain's Call and resurfaces on its date, instead of leaving a live-looking card or fabricating a closure.
"A keyed answer resolves its matching captain-held task" is one capability with one owner, `bin/fm-captain-hold.sh answers`, and every channel that carries a captain answer feeds it the same task id and answer; a channel never maps keys to tasks, records a decision, or resolves anything itself.
Chat already feeds it through `bin/fm-send.sh --resolve-key`, and a captured-answer source feeds it once bound with `bin/fm-captain-hold.sh bind <source-id>`; bind before arming the source, and key each structured question by the held task's id.
An unbound source and a key that names no captain-held task both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the direct command above.
One answer value is reserved and closes nothing: `reconcile` means "go re-check reality", never "the captain answered", so the shared intake refuses it from every channel and creates nothing.
A bound captured source uses a separate seam: its adapter omits reconcile from keyed answers and emits the selected task id through `reconciles`, the generic runner feeds that into `reconcile-requests`, and the intake verifies the source binding and the local captain-held task before filing the durable board request.
A remote-secondmate card whose task is absent from the main backlog therefore remains announced but cannot create a main-home request; owner-aware request and mutation routing to the authoritative secondmate home is a separate follow-up.
Delegate that board-created re-check to the hosting worker and apply or delegate its resulting disposition: `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` records the EVIDENCE and closes a moot call, while `reconcile note <id> --note-file <path>` annotates a genuinely active call and leaves it held.
Both outcomes refuse unless that task still has the pending request created by the captain's board selection, so neither is a standalone way to mutate a captain call.
A normal captain answer also retires any pending request because the call is settled, including close, release, and idempotent replay paths.
A retirement failure makes the command fail without reversing the already-durable answer, close, or note, and `reconcile list` keeps the surviving request visible for retry.
`reconcile list` names every request still outstanding.
Never use `answer` for an evidence-only moot call: `answer` records what the captain said, while `reconcile close` and verified moot retirement record evidence.
A captain-held task closed outside this owner leaves no durable answer, so the completion gate keeps failing until `answer` records the decision the captain actually gave.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

A captain call can be written down twice - as the keyed status decision the fold reads, and as the backlog task held for the captain - and those two records can disagree without either surface saying so.
`bin/fm-captain-hold.sh diverged` reports that contradiction and the wake drain prints it as `RECORD DIVERGENCE`; it closes nothing, because a captain call closed wrongly leaves review entirely, which is worse than the noise.
Read such a line as "these two records disagree", never as "the captain ruled and someone forgot to file it": a call can dissolve because its premise was false, or turn out to have been a question of fact rather than the captain's to answer.
Reconcile it with what actually happened - `answer` when the captain's own words exist to record, and a fresh `needs-decision` line re-opening the status decision when that resolution was not the captain's word.
The absence of a routed work item is not a divergence and the guard never requires one: when the decision IS the deliverable there is nothing to route.

## The call supervision opens itself

`bin/fm-inactive-reconcile.sh` holds one kind of call without you: work still in flight whose worker is gone and that waits on nothing due, carded with the choices `close`, `keep`, and `reopen` (its header owns the rule), then announced once by a `captain call opened for idle in-flight work` check wake.
That wake is never a wait to re-absorb: relay the call, and when the captain is not using English, re-hold the task with the same three option ids and the card rewritten as below.
Record a chat answer with `answer --release`, because applying it is what moves the task: `close` is ordinary cleanup under `ship-landing`, with `--residual` for anything still kept alive or left to check; `keep` leaves the work in flight, not asked about again until it appends a new event or is relaunched; `reopen` relaunches its worker under `stuck-crewmate-recovery`.

## Writing the card

Write every captain-facing field short, plain, and casual, in the language the captain is using (English or Spanish), so an intern and a principal engineer both get it in seconds.
Use one line of context, then the question, then a few short options with the recommended one marked through `--recommended`.
Option labels name the outcome in everyday words, and an option detail, when needed, is one short line.
Leave out internal terms such as task ids, hold, intake, reconcile, pipeline steps, or byte limits; the details belong in the linked report, not on the card.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Prepare decisions under the policy above, inventory only genuine unresolved choices that require the captain, and find the task each one gates.
3. Hold that task - or create one captain-held task per open decision the review raised - with a short reason plus the structured card fields written as described in "Writing the card".
4. Run `complete` with the full captain-held inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. Resolve calls through their owner: `answer` (or a channel feeding `answers`), board-requested `reconcile close` or `reconcile note`, verified moot retirement, action completion, or `--until` for a captain deferral.
7. Confirm Bearings reflects the outcome: answered or reconciled-moot calls leave Captain's Call, released work resumes, active reconciliations remain held, and deferred calls sit in Charted Next with their date.

`bin/fm-captain-hold.sh --help` owns command syntax, close modes, legacy-identity compatibility, completion attestation, retry behavior, and close ordering.
`docs/captain-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
