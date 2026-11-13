# Shared supervision branch

This document owns the shared dispatch eligibility, prompt, outcome store, and per-task leases used by the supervision host.
[`supervision-host.md`](supervision-host.md) owns host runtime, dialog context, delivery, and posture behavior.

## Components and their owners

| Component | Owner |
| --- | --- |
| Wake eligibility and eligible-row grants | `bin/lib/fm-branch-dispatch.ts` |
| Asynchronous subprocess execution | `bin/lib/fm-async-exec.ts` |
| Stable branch prompt | `bin/fm-branch-prompt.sh` |
| Outcome rows, cursor, and coverage indexes | `bin/fm-branch-outcome.sh` |
| Per-task leases and authority partition | `bin/fm-lease-lib.sh` and `bin/fm-lease.sh` |

### Wake dispatch

`bin/lib/fm-branch-dispatch.ts` owns the offer handshake and row eligibility.
[`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor consume contract.

A successful row grant transfers ownership of exactly the currently branch-eligible rows to the branch.

What is never offered, or falls back to main:

- While attended, a check-kind triggering close is never offered, even when other rows are eligible.
  Check-kind closes are merge-confirmation polls, Relay mentions, credential/auth failures, and every other legitimately main-only class.
- When a triggering close has no acceptor (host absent or branch broken), it keeps today's wake-to-main path.
- Watcher-failure alarms always go to main, because only main can repair the watcher cycle.

Under the away-posture record, the check-kind and decision-owned exclusions lift and every actionable row is offered ("Postures" below).
The no-acceptor fallback and the alarms still reach main in that posture.

#### Decision-owned rows

A decision-owned event surfaced by `bin/fm-watch.sh`'s signal path gets the same treatment as a check-kind triggering close, even though it keeps the ordinary `signal` kind.
`signal_files_actionable` marks the queued payload `needs-decision:` for any of these:

- A newly surfaced `needs-decision`.
- A `captain-held` declaration surfaced through the no-verb fallback.
- A pending-reply second-mate escalation.

`scopeForUnreadWake` excludes every marked row from what the branch may claim, as well as second-mate signals classified by the span rule below.

A second mate's status log is one shared channel carrying many independently keyed decisions, so its signal row is judged by the lines presented since the last drain rather than by the whole log.
The row is excluded when one of those lines is a decision, blocked, or captain-held line, resolves a decision open just before it, or declares, in the status parser's key positions, the key of a decision still open in that log.
A resolution that closes nothing, key-less beside only keyed decisions or keyed for a key never open, stays routine.
A key-less line otherwise falls back to its verb; an unrelated open decision alone leaves a routine span eligible, while a mixed span goes wholly to main.
The status-presentation cursor bounds that span, and a missing or unmatched cursor falls back to the whole log.
Single-task crewmate signals keep their existing task payload and attended-host whole-log rules, except that the TypeScript decision fold now ignores bare transition words without a colon or complete key token, matching `bin/fm-classify-lib.sh` on both crewmate and second-mate logs.

For a stale row, `scopeForUnreadWake` folds the mapped task's status log.
It excludes the row when any `needs-decision` remains open or the current meaningful declaration is `captain-held`.
An unreadable or symlinked status log fails the scope closed rather than influencing routing.

Before cross-referencing them, the dispatcher resolves trigger keys and every currently unread excluded decision row to task identity.
If a task key or endpoint alias names more than one task, including a record with a missing or empty project, the metadata scan is corrupt and the entire wake stays on main rather than selecting an owner by record order.
Exact keys take precedence over the `fm-` prefix fallback, and project context comes only from the resolved task's own metadata.
A projectless owner cannot borrow another alias's project or grant routing authority.
The cross-reference then applies two rules:

- Any signal or stale trigger containing a decision-owned task goes wholly to main, including a batch that also contains routine rows.
- An unread decision for one task keeps every later signal or stale trigger for that same task on main until the decision row is read.
  This holds regardless of which key a row carries for that task: its status-file key, its `window=` alias.

Other tasks remain independently eligible.
The wake message itself retains its existing shape, so other harness-arm scripts remain unchanged.

#### Heartbeats during dispatch

Heartbeat handling remains independent.
A fleet-wide heartbeat keeps its own all-or-nothing rule (see "Heartbeat routing" below): it takes every branch-ownable unread row or none of them.
A co-present main-owned check row no longer defers that review to main.
That row is not fleet context the branch is missing, and main is woken for it on its own triggering close.

### Branch system prompt

The branch system prompt comes from `bin/fm-branch-prompt.sh`.
Its header owns the byte-stable-prefix contract (no timestamps, no fleet snapshot, no per-wake content).

### Outcome store

The outcome store is `bin/fm-branch-outcome.sh`.
Its header owns the append-only format, read cursor, and bounded per-task status-coverage indexes.

Outcomes are stored before the host presents them.
Locked session-start replay stops before the first captain row, so it cannot acknowledge that outcome through prose alone.
[`supervision-host.md`](supervision-host.md) owns host delivery and acknowledgement.

### Consistency

`bin/fm-lease-lib.sh` owns:

- The per-task lease contract.
- The posture-aware main-only role partition.
- The deliberate CONFUSED-AGENT-GRADE threat model these guards target.
  That threat model was captain-decided; adversarial-grade separation is out of scope and tracked as follow-up design work.

`bin/fm-lease.sh` is the command surface.

The guards are wired into these scripts:

| Scripts | Guard behavior |
| --- | --- |
| `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` | Overlap, lease-checked, with claim serialization retained through the mutation. |
| `fm-pr-merge.sh`, `fm-merge-local.sh`, `fm-spawn.sh`, `fm-send.sh --resolve-key` for a decision key, and `fm-teardown.sh` for a second mate | Main-owned while attended; branch refused. |

A relaunch through `fm-control` stays branch-legal recovery in both postures.
Under the away-posture record, the PR merge, a fresh spawn, and a decision answer relocate to the branch behind each script's own gate.
Local-only landing and second-mate retirement never do ("Postures" below).

#### Pre-drain recheck

The branch recomputes eligibility immediately before prompting the branch to drain.
It publishes the exact eligible row set to `state/.branch-eligible-rows` through `writeEligibleRowsSnapshot`.

After an independently eligible wake has already been offered, a newly-arrived main-owned row observed at that pre-drain recheck does not revoke the offer.
Instead, that row is excluded from the eligible set.
Whatever else is currently eligible still reaches the branch, and the main-owned row stays queued for main's own drain.
[`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the consume-side guarantee that neither actor can present or acknowledge the other's claim.

Heartbeat keeps its own all-or-nothing recheck over the rows it can claim: it takes every branch-ownable unread row or none of them.
An unresolvable task-local row still defers the whole review to main.

A producer can still append a row in the instant between that final check and drain startup.
This accepted residual follows the confused-agent-grade boundary above rather than claiming adversarial queue isolation.

A broken branch between its bounded recovery probes keeps today's wake-to-main behavior in both postures.

## Lost-wake outcome backstop

Every main-actor wake drain checks each task's newest non-blank status event against the latest supervision-branch outcome that causally covers that task's status log.
When that event is terminal or otherwise captain-facing and remains uncovered, the drain prints it once in `STATUS OUTCOME BACKSTOP`.
It does so even if the original queue row was already acknowledged.
Routine events stay silent, and valid open decisions remain owned by `OPEN DECISIONS`.

The one-shot backstop cursor is independent from signal annotation.
A delayed signal can therefore still present its status context without repeating the recovered event.

### Bounded cost

The drain reads one fixed-size per-task outcome index instead of scanning append-only outcome history.
It inspects at most the final 64 KiB of each status log.

### Ordering limits

Status provenance added to new outcome rows distinguishes covered and genuinely later events even within one timestamp second.
Legacy outcomes predate that causal position, so equal-second migration cannot prove order.
That migration deliberately favors surfacing a plausibly later event, which can rarely duplicate an already handled legacy event.

A pathological latest status line that crosses the 64 KiB window is unclassifiable.
It remains silent rather than risking presentation of routine content.
This is an accepted limit, not a status-line size contract.

### Index repair

A missing or invalid outcome-index ready marker is rebuilt from the authoritative outcome rows by `processed-init` under the outcome lock.
That rebuild runs on the next main drain, on every harness.
Only a genuine store fault keeps that backstop skipped.

## Heartbeat routing

The cheap bash-level heartbeat scan absorbs a genuinely no-op pass before it reaches the host.
Only a scan already flagged as possibly captain-relevant emits the bare `heartbeat` wake.
The branch accepts it without a project only when every branch-ownable row observed in the unread-queue eligibility check is one of these:

- Heartbeat-kind.
- A resolvable task-local signal or stale event.

### Co-present main-owned rows

A heartbeat is never vetoed or ridden into main by a co-present check row or decision-owned signal/stale row.
Those rows are main-owned while attended.
They are excluded from what the branch may claim and left queued for main.
Main is woken for each on its own watcher cycle, so nothing starves by being left behind.
Under the away-posture record the branch claims them too ("Postures" below).

Deferring the fleet review to main merely because some unrelated merge poll or Relay mention happened to be sitting unread put a routine review in the captain's chat for a reason that had nothing to do with the fleet.
That coupling is gone.

What all-or-nothing still guarantees is unchanged: the branch takes every branch-ownable unread row or none of them.
An unresolvable task-local row, an unknown row kind, or an unreadable queue still defers the whole review to main.

### Reporting the review

The branch runs its normal operating procedure for the wake (`bin/fm-branch-prompt.sh` "Handling a wake") and performs the deeper fleet review that main previously performed.

| Review result | Report |
| --- | --- |
| Found literally nothing worth reporting | Verdict `routine`, `task=fleet`, and `silent=true`, so it is stored without a rendered note. |
| A fleet-wide routine action | Omits `silent` and keeps its rendered sailboat note. |

Only a captain-worthy finding reports verdict `captain` and appends a visible captain outcome entry.

Every other fleet-wide or unresolvable wake keeps today's wake-to-main path in both postures.
That includes watcher-failure alarms, which are never offered to the branch.

## Postures

The host reads the live away contract when preparing a turn.
[`bin/fm-branch-prompt.sh`](../bin/fm-branch-prompt.sh)'s Postures section owns the branch execution instructions.

### Authority relocation

`fm_lease_forbid_branch` passes the branch actor only for the actions whose guarded script opts in.
It does so only while `bin/fm-afk-contract.sh validate` succeeds on a complete, readable, live away record (`mode` is not quiet).
An archived, incomplete, invalid, or quiet record restores the attended refusal byte for byte.

The captain's away words are the whole mandate:

- The branch reads them at the tail.
- It decides by its own judgment whether the event in front of it is the moment they name.
- It acts on them only through the guarded scripts, never by analogy.
- It holds with verdict captain on doubt.

`bin/fm-branch-prompt.sh` "Postures" owns those execution rules.
It requires every action taken under the words to open its outcome summary with "per your away instructions:".

Each relocated script keeps its own gate, enforcing exactly what a script can check without reading words:

| Script | Gate while away |
| --- | --- |
| `bin/fm-pr-merge.sh` | Merges any pull request green at its live head, synchronously, under the record lock, and refuses `--allow-red`, `--allow-missing`, and `--allow-no-pipeline` while away, so the green gate is absolute in this posture; which pull request the words meant is the branch's reading. |
| `bin/fm-spawn.sh` | Dispatches only queued work whose blockers cleared - already queued, or filed by the branch because the words explicitly call for it; refuses a fresh ordinary spawn for either actor once the home holds as many ordinary task records as the record's spend cap (relaunches and secondmates exempt). |
| `bin/fm-send.sh --resolve-key` | Answers a decision the words pre-answer, or one `ask-user-authority`'s judgment (carried verbatim in the branch prompt) lets firstmate decide. |
| `bin/fm-merge-local.sh` | Never relocated. |

The merge-authority record and the outcome row's summary are the audit trail.
The return brief renders the words verbatim beside that account.

### The authority invariant

Being away changes how the captain is informed and what happens at a captain-owned decision point, never firstmate's authority set.
`tests/fm-branch-supervision.test.sh`, `tests/fm-pr-merge.test.sh`, and `tests/fm-send-resolve-key.test.sh` pin this invariant.
It sets these limits:

- The never-set (credential entry, legal or financial acceptance, an attended prompt, an unnamed discard, a security-sensitive action) has no guarded entrypoint that accepts away authority for either actor.
- A forced teardown stays refused for the branch.
- A red merge is refused in this posture whatever the words say.
- No relocation survives the return, because an archived record validates as absent and the words die with it.

### Cleanup after task completion

Ordinary cleanup of landed ships and completed scouts needs no authority relocation; [`bin/fm-branch-prompt.sh`](../bin/fm-branch-prompt.sh) owns the branch's cleanup instructions in both postures, including lease acquisition and refusal reporting.
The generated prompt includes the [scout-completion](../.agents/skills/scout-completion/SKILL.md) and [captain-hold-lifecycle](../.agents/skills/captain-hold-lifecycle/SKILL.md) policies verbatim so their completion gate reaches hosts without automatic skill loading.

## Verification

`tests/fm-branch-supervision.test.sh` exercises the shared prompt, outcome store, leases, and dispatch scope.
`tests/fm-supervision-host.test.sh` and `tests/fm-supervision-host-drain.test.sh` exercise host routing and drain ownership.
`tests/fm-wake-drain-outcome-backstop.test.sh` exercises the bounded status-coverage backstop.
