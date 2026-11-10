# Fleet activity ledger

The fleet activity ledger is an opt-in, append-only file that outside tools can read to follow what a firstmate home is doing: which tasks were dispatched, what their workers reported, when a PR became ready for review, when their work merged, and when they were cleaned up.
It is the stable, documented hook for firstmate status; this page is its contract.

## Turning it on and off

Create the presence flag `config/fleet-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
The flag is local, gitignored, per home, and not inherited by second mate homes, so each home that should publish a ledger needs its own flag.
While the flag is absent, each producer performs one file-existence test and nothing else: no process starts and nothing is written.

## The file

The ledger is `state/fleet-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, in the order they are written.

Every record carries these members:

| Member  | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| `v`     | Record format version, currently `1`                      |
| `ts`    | Unix time in seconds when the record was written          |
| `event` | One of the event names below                              |
| `task`  | The task id, or `primary`, `work` or `home` for home entities |
| `home` | Explicit owning home (older legacy records may omit it) |

Readers must ignore members and events they do not recognize, so later versions can add them without breaking existing readers.

## Events

| Event              | Extra members                                  | Written when |
| ------------------ | ---------------------------------------------- | ------------ |
| `task.dispatched`  | `kind`, `project`, `harness`, `model`          | A new worker or second mate is launched. A relaunch of an existing task is not recorded. |
| `task.status`      | `state`, `key`, `text`                         | A complete, nonblank line in the task's status log is captured. |
| `task.pr_ready`    | `pr`                                           | Firstmate records the task's PR as ready for review. |
| `task.merged`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The task's PR merge is recorded, or its local-only branch landed. |
| `task.cleaned_up`  | none                                           | The task's worker and local copy were removed. |
| `call.opened` | `home`, `value` | A structured captain hold is saved or updated. |
| `call.resolved` | `home`, `value` | The captain-hold owner settles the call and announces its resolution. |
| `task.presentation` | `home`, `value` | The presentation owner publishes its declaration under the presentation lock. |
| `task.changed` | `home`, `value.task` | A canonical backlog row changes; null means removed. |
| `task.completion` | `home`, `value.receipt` | A completion receipt is written or invalidated. |
| `task.usage` | `home`, `value` | The usage owner replaces its cached task totals. |
| `work.aliases` | `home`, `value` | The identity owner saves its resulting reservations. |
| `task.review` | `home`, `value` | The owner changes a result's review mark; value is its presentation read result. |
| `work.structure` | `home`, `value` | The structure owner saves the complete resulting structure. |
| `work.control` | `home`, `value` | The control owner saves its request, scope, state and events. |
| `call.application` | `home`, `value` | The inbox owner records handling of a settled answer; value contains call and answer. |
| `agent.activity` | `home`, `value` | The busy writer accepts an incarnation's state; value contains gen, seq, state, source and event. |
| `agent.retired` | `home`, `value` | The busy writer removes that incarnation; value retains its gen. |
| `agent.liveness` | `home`, `value` | The worker process wrapper observes child start or finishes scope cleanup; value contains state (`alive` or `dead`), source, verdict, spawn gen and observed_at. |
| `primary.final` | `home`, `value` | A verified primary final surface supplies complete text, harness, session and turn. |
| `home.configuration` | `home`, `value` | Explicit configuration publication records lane_capacity, project_capacity and projects text (null when absent). |

For entity events, `home` is the explicit owning home and `value` is the complete resulting entity, without status-text truncation.
`call.opened` and `call.resolved` values carry the canonical task row and `call` record, its existing lifecycle `identity` (`hold_set#prior-resolution-count`), `occurrence`, and the canonical `answer` when available, including its separate application state.
Presentation values carry the presentation owner's read result: declaration, outcome occurrence, checkpoint, lifecycle and evidence.
Replays replace the value for that identity; they do not increment counters.
Entity commands return failure if publication fails, preserving the already saved canonical change for explicit replay through its owner.
The primary Stop guard reports capture failure and continues its existing supervision check, so a broken ledger cannot disable supervision.
A crash between the canonical write and append can still omit an event; this is not a transactional journal or a complete board bootstrap.
Backlog mutations use the canonical Markdown parser under the existing work lock, publishing changed rows without a runtime/history snapshot.
Direct edits outside these owners still require explicit publication or canonical recovery.
After editing capacity or the registry, run `bash bin/fm-fleet-ledger.sh configuration` with the owning `FM_HOME`.
For a failed task append, replay the current value with `python3 bin/fm_delivery.py ledger-task --task ID`; for a saved inbox reply, use `ledger-application --task NOTE_ID`.
These repair commands publish existing facts and never repeat a human answer.

`task.dispatched` members: `kind` is `ship`, `scout`, or `secondmate`; `project` is the project directory name, or `null` for a remote second mate; `harness` names the agent tool; `model` is the requested model, or `null` for the tool's default.

`task.pr_ready` members: `pr` is the PR's full URL.
It is written each time firstmate records a PR for the task, so registering a replacement PR, or the same PR again, writes another record; recording the PR again as part of merging it writes none.

`task.status` members: `state` is the status line's leading word, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, or `resolved`, or `null` when the line has none.
`key` is the line's `[key=...]` decision key, or `null`.
`text` is the status line after its first colon, verbatim, capped at 2000 characters; if the line has no colon, it is the whole line.

Example:

```json
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1790132870,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1790133400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133410,"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133900,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133960,"event":"task.cleaned_up","task":"fix-login"}
```

## Limits

- A worker using the current status command in its instructions records its line immediately after appending it, while the ledger is enabled.
  The supervision monitor's regular poll is the backstop: it records any line the immediate write missed, and does not record again a line that write already recorded.
  Uninstrumented writes still trail the status log by up to one poll interval, or until the monitor next runs when none is running:
  - lines from workers whose instructions predate this, or that append without running the instruction's full command;
  - lines written while the immediate record fails, for example when the ledger file cannot be written.
  Recording `task.pr_ready`, `task.merged`, or `task.cleaned_up` first records that task's pending status lines.
- Captured status lines are delivered at least once unless a write fails or a crash loses unflushed records: an interrupted capture can repeat records, so a reader that must not double-count should tolerate duplicates.
- A status record can appear just before its task's `task.dispatched` record when the worker writes a status line in the moment between its launch and that record.
- When a home turns the ledger on, status lines already in a live task's log are recorded on that task's next capture (which may be a worker status command, PR registration, merge, cleanup, or monitor poll); tasks dispatched or cleaned up while the flag was absent have no record of that.
- There is no sequence number and no gap detection.
- Writes are plain appends with no forced flush to disk, so a machine crash can lose the newest records.
- The file is never rotated and grows until truncated.
  To truncate it, stop readers, then empty it with `: > state/fleet-ledger.jsonl`; restart readers from an explicit canonical base, never an earlier cursor or projection.
- The ledger copies status text verbatim from the home's `state/` directory and adds no scrubbing, so give its readers exactly the trust you give `state/`.
  Entity events also contain complete private call, answer, presentation and final-message text.

## Not included

These are possible follow-ups, deliberately left out of this version:

- session start, away-mode, and quiet-mode events;
- sequence numbers and gap detection;
- rotation and continuity across rotated files;
- backfill or replay of events from before the ledger was turned on;
- secret scrubbing beyond what status lines already contain, and privacy guarantees stronger than those of `state/`.

`bin/fm-fleet-ledger.sh`'s header owns the writer mechanics and lists every producer.

## Harness coverage

Claude's existing Stop guard captures the primary final before its supervision and loop allowances, only in the primary checkout with verified session-lock ownership.
Codex project hooks remain unverified and worker launches keep hooks disabled.
For a Codex primary, launch with `-c 'notify=["bash","/absolute/firstmate/bin/fm-primary-final.sh","codex"]'` to capture normal finals through its verified notify surface; combine this with an existing notify consumer if one is configured, rather than replacing it silently.
Codex workers publish normal completion through their existing notify command, bound to the busy generation; this does not enable hook trust or change the rollout classifier.
Other adapters' turn activity comes from their existing busy writer.
A final capture never identifies a free-form question semantically, opens a call, resolves an answer, closes a task or releases a lane.
Structured question interception and error/interrupt coverage beyond the existing verified adapters are unavailable, not inferred from documentation.
A chat answer still goes through `fm-captain-hold.sh answer` with the current expected identity; arrival of chat text does not settle a call.
Worker process liveness uses the common process wrapper rather than a harness hook; its scope and limits are owned by `bin/fm-worker-processes.py`.
It includes relaunches, changes occupied-agent counts without completing the task, and survives a killed harness while the wrapper remains alive.
Killing the wrapper itself with SIGKILL or losing the host can still omit the exit event; secondmate launches do not use this wrapper.
macOS Codex activity remains unknown outside its normal-completion notify signal.
Run `FM_FLEET_LEDGER_LIVE_E2E=1 bash tests/fm-fleet-ledger-live-e2e.test.sh` to refresh real primary-final evidence on either platform.
