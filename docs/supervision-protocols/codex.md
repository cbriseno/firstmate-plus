Mode: Codex foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. First cycle: run one foreground watcher checkpoint with `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`.
   Set `yield_time_ms` to about 50000 when starting or resuming a checkpoint, and do not poll it or any other running supervision command in shorter steps, because each poll is a model request carrying the whole context.
4. Ordinary wake: if the command prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain queued wakes, handle that wake, then start the next checkpoint.
5. If the command prints `checkpoint:` or exits 124 with no wake, process any queued user message now visible to Codex, then start the next checkpoint; a quiet close needs no drain, because a new durable row or status line wakes a checkpoint by itself.
6. Never use shell `&` or Codex background tasks for firstmate watcher supervision.
7. Do not run `bin/fm-watch-arm.sh` as Codex's normal supervision command.
   If it is ever shelled anyway, a backgrounded, piped, or bundled anti-pattern is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.codex/hooks.json`.
8. Failure or missing cycle only: drain queued wakes, inspect the failure, then start a fresh foreground checkpoint.

Codex cannot reason while a foreground tool call is running.
The bounded checkpoint returns control regularly so user messages and queued wakes can be handled without relying on background-task wake semantics.
Keep the turn active and repeat the checkpoint/drain/handle/ack cycle while supervision is required; use progress messages for updates.
A checkpoint started before a final reply is not persistent supervision, and its quiet timeout is normal.
There is no verified post-final native wake adapter for this protocol.
Durable answer wakes survive until handled, but cannot start a new Codex turn by themselves.
The existing host's posture coverage and bounded park are documented in [Supervision host](../supervision-host.md#codex-checkpoint-bound).
If the session must end without a verified successor, report that supervision will stop and name the unresolved work and next action; never claim unattended continuation.
