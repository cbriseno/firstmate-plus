#!/usr/bin/env bash
# fm-captain-hold.sh - deterministic mechanics for tasks held for the captain.
#
# The semantic policy is owned once by
# .agents/skills/captain-hold-lifecycle/SKILL.md. This script never reads
# report, visual-review, chat, or terminal prose to guess whether the captain
# owes an answer. The invoking agent decides what is genuinely waiting on the
# captain; this script supplies guarded creation, a durable record of what the
# captain actually said, the investigation completion gate, and the one
# keyed-answer intake every channel feeds.
#
# There is no separate decision type. A captain call is an ordinary backlog
# task held for the captain through this script's mandatory `hold` subcommand,
# and its identity is simply the task id. Older installs created derived
# `<origin>-decision-<key>` identities through bin/fm-decision-hold.sh; those
# rows are already plain task ids, so they keep working here unchanged, and
# the legacy inputs noted below resolve them without a migration.
# All backlog reads and mutations address the active home's configured data
# directory the way bin/fm-backlog-transition-lib.sh does, which keeps main-home
# and secondmate-home ownership aligned with the work that discovered the call.
#
# Usage:
#   hold requires --category product-design|unbacked-destructive|money|credentials-security|captain-only-fact.
#   fm-captain-hold.sh hold <task-id> --reason <reason> \
#     [--title <title>] [--repo <repo>] [--origin <origin-id>] [--until YYYY-MM-DD] \
#     (--question <line> --option <id>=<label>[|<detail>] --option <id>=<label>[|<detail>]... \
#      [--recommended <id>] [--context <line>] [--link <report path or URL>]
#      | --no-options <why> [--question <line> [--context <line>] [--link <report path or URL>]]
#      | --call-kind action --instruction <line> --where chat [--context <line>] [--link <path or URL>])
#   fm-captain-hold.sh answer <task-id> --decision-file <path> [--attach <file>]... [--release | --release-in-flight] [--expected-identity <identity>]
#   fm-captain-hold.sh correct <task-id> --decision-file <path> [--attach <file>]... [--expected-identity <identity>]
#   fm-captain-hold.sh complete-action <task-id> --evidence-file <path> [--expected-identity <identity>]
#   fm-captain-hold.sh action-pending <task-id>   (0 pending action, 1 other/completed, 2 unknown)
#   fm-captain-hold.sh answers [<legacy-origin> | --any-origin] --source <provenance> [--expected-identity <identity>]   (keyed answers on stdin)
#   fm-captain-hold.sh reconcile-requests --source-id <source-id> --source <provenance> [--expected-identity <identity>]   (task ids on stdin)
#   fm-captain-hold.sh capabilities --json
#   fm-captain-hold.sh bind <source-id> [<legacy-origin> | --any-origin]
#   fm-captain-hold.sh unbind <source-id>
#   fm-captain-hold.sh binding <source-id>
#   fm-captain-hold.sh complete <origin-id> (--none | <task-id>...)
#   fm-captain-hold.sh verify <origin-id>
#   fm-captain-hold.sh open <task-id> [--identity] [--distinguish-absent]
#   fm-captain-hold.sh resolved <task-id> <occurrence>
#   fm-captain-hold.sh diverged
#   fm-captain-hold.sh reconcile list
#   fm-captain-hold.sh reconcile close <task-id> --evidence-file <path>
#   fm-captain-hold.sh reconcile note <task-id> --note-file <path>
#   fm-captain-hold.sh retire-moot <task-id> [--superseded-by <task-id> --evidence-file <path>]
#   fm-captain-hold.sh sweep-moot
#
# `hold` places an existing task under an active captain hold, or creates the
# task first when no work item exists to hold (--title required to create; the
# optional --origin records provenance in the new task's body and supplies the
# default repo from that origin's metadata). Prefer holding the work item the
# question gates over minting a new row. Creating a missing row uses
# `tasks-axi add --kind captain`: that kind is backlog metadata, and the Beads
# adapter maps it to native issue type `task`. Captain holds have no due
# semantics (`--until` is the optional hold deferral), so the create waives
# Beads `due.required` through `BD_DUE_REQUIRED` rather than inventing a due
# date or registering a `types.custom` captain issue type. The command records
# a UTC `Captain hold set:` timestamp in the task body: repeating an active
# hold preserves the existing timestamp, while re-holding released work starts
# a new lifecycle. A task already closed is refused rather than reopened.
# `--origin` also records the origin on a `Captain hold origin:` body line, which
# `complete` and `verify` check. The reason may hold parentheses and line breaks:
# tasks-axi refuses them, so `hold` escapes them where it writes the reason and
# readers decode them (bin/fm-hold-reason-lib.sh owns the encoding).
# `--until` records the captain's own deferral date through `tasks-axi hold
# --until`, so a "revisit later" answer is stored as a date instead of a live
# card.
#
# STRUCTURED CALL FIELDS. The default call kind is question, including legacy
# records without a kind and genuine freeform --no-options questions.
# `--question`, the repeatable `--option`,
# `--recommended`, `--context`, and `--link` record the captain-facing card
# beside the unchanged `--reason`, so a board can offer real choices instead of
# options buried in prose. They are REQUIRED: every hold that opens a captain
# call - a new task, a held task's first hold, a re-hold after a release, or a
# hold whose `--until` date lapsed - must pass `--question` and at least two
# `--option` values, with `--recommended` naming the recommended one when there
# is one. The only escape is `--no-options <why>` for a genuinely open question
# or a wait with no choices (a human action, a date); its one-line reason (160
# characters) is recorded in the call record's `no_options` field, `--question`
# stays optional beside it, and it cannot be combined with `--option` or
# `--recommended`. Anything else is refused before any mutation, with the
# expected call shape on stderr. A repeat of an active hold (a reason update or
# an `--until` deferral) may omit the fields only while the current lifecycle's
# record already carries two options or a `no_options` reason; it then keeps
# that record. Any of the card fields requires `--question`. Bounds, in
# characters: question 160, option label 40, option detail 120, context 200,
# link 500, at most 8 options. Option ids are slugs of at most 32 characters,
# unique per call, and never the reserved answer `reconcile`; `--recommended`
# must name one of them. Every field is one line without control characters,
# and a field over its bound is refused rather than truncated. Validation runs
# before any mutation. After the backend hold succeeds, the fields are written
# atomically to the private record data/<task-id>/captain-call.json (schema
# fm-captain-call.v1: `call` is the card object, null for a `--no-options` hold
# without a question, and `no_options` appears only with that escape), bound to
# this hold lifecycle by its hold-set stamp. An active hold's repeat without
# fields keeps its record, and a new lifecycle (new stamp) never matches an
# older record.
# bin/fm-fleet-snapshot.sh exports a matching record as each open captain
# hold's `call` object and omits it otherwise; nothing ever derives options
# from reason or body prose.
# Explicit --call-kind action instead records call.kind="action", instruction
# (one line, at most200 characters), where="chat", question=null, options=[],
# recommended=null and optional context/link with the same bounds above.
# It cannot carry question/options/recommended/no-options or --until. It uses
# a separate captain-kind row, preserving the actual work and its origin and
# dependency links. Repeats may keep the record but cannot convert a pending
# action to a question. Nothing infers action kind from no_options or prose.
# Only the owning primary's complete-action, after the requested human action
# actually occurs, records its nonempty authoritative evidence (max8192 bytes)
# as Resolution mode: action-completed / Action completion evidence and closes
# that attention row. It reuses answer's lock, identity guard, durable record,
# interrupted-close recovery and digest-idempotent replay. Normal answer,
# board reconciliation and generic backlog close/unhold refuse outstanding actions;
# reading/opening, inbox ACK/reply or dismissal does not complete one.
# action-pending is the read-only predicate used by the ordinary writer; it
# returns2 on an unreadable record rather than allowing a close. This is a
# completion attestation by the primary, never automatic execution or consent
# to a separate policy decision.
# `retire-moot` is a distinct evidence-backed retirement, never completion of
# the human action. It applies to separate, queued captain-kind calls only.
# It verifies the origin is Done (including a verifiable archived origin), and
# every transitively gated task is Done, using all canonical dependency edges,
# including edges on closed rows. At least one gated task must be known: an
# investigation ending alone cannot erase a standalone question. Alternatively,
# --superseded-by plus nonempty --evidence-file explicitly attests supersession
# by an existing different task; all known gated work must still be Done.
# Without explicit supersession, missing origins fail closed; active work,
# invalid graphs and recorded answers always do. No age, report prose, read
# receipt or ACK is evidence of mootness.
# Retirement records Resolution mode: reconciled with the canonical origin,
# gated tasks/states and supersession evidence, preserves the call/body/answers,
# and retires a pending board request if present without requiring one.
# It shares the task control lock and work mutation lock, rechecks reality at
# mutation time, and safely retries an interrupted retirement. `sweep-moot`
# tries eligible calls, leaving unverifiable/active calls untouched; closure,
# teardown and session reconciliation invoke it in the owning home. A retired
# call is Done and no longer actionable; generic reopen and a fresh hold can
# restore it without deleting history.
#
# `answer` records the captain's exact words and resolves the call in the same
# act. It requires a non-empty captain decision file of at most 8192 bytes and
# writes a resolution block while preserving the leading hold-set stamp until
# the close succeeds (the previous body is preserved and archived through
# tasks-axi --archive-body). It closes a question with `tasks-axi done` - or,
# with `--release`, lifts the hold with `tasks-axi unhold` so a captain-gated
# WORK item resumes without closing - and restores resolution-first body
# ordering. `--release-in-flight` is the close a caller with no declared mode
# asks for: it releases when the task's backlog lifecycle state is in flight -
# dispatched work whose completion belongs to landing and cleanup - and closes
# anything else, read under the same task control lock as the transition. Kind,
# title, and metadata never decide it, because a question-only row can carry
# any kind and a dispatched row can outlive its worker. An exact retry also completes unfinished ordering normalization and
# is idempotent only when its requested close mode
# matches the newest record; a changed decision or a mode mismatch is rejected.
# A re-held task may record a new answer on top. On a task already closed outside this script,
# `answer` records the missing resolution block (the old `repair` path) only
# when the task still carries the captain-hold provenance tasks-axi preserves
# through a close, so an ordinary finished task cannot be dressed up as an
# answered captain call. A hold that expired by date (`--until` in the past) is
# still answerable: the surviving hold annotations, not tasks-axi's live
# `held:` bit, prove the captain owned it.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer resolves its matching captain-held task" is a single
# capability, owned here and nowhere else. `answers` reads
# `<task-id>\t<answer>\t<label>[\t<mode>]` lines on stdin and resolves each named
# task through the very same `answer` path above, so every guard applies
# identically no matter which channel the answer arrived on. The key IS the
# task id - no identity arithmetic. The optional fourth field selects the close:
# `done` completes the task, `release` lifts the hold so held work resumes, and
# an empty field - no close declared - takes `answer --release-in-flight`, so
# an answer never completes work that is still in flight; anything else is
# skipped. A key that names no task, a task that is
# not held for the captain, or a task already closed is reported as `skipped:`
# and feeds nothing. A replayed delivery whose answer digest and requested
# close mode both match the newest record is reported `closed:` and is a no-op;
# a mode mismatch is skipped. The command exits nonzero when any key was
# skipped. `--source` is provenance text recorded in the
# durable decision, never a behavior switch: this command has no per-channel
# branch and no knowledge of chat, review decks, or any transport.
# Legacy input: an optional positional origin (or a stored concrete-origin
# binding) makes a key that names no task fall back to the old
# `<origin>-decision-<key>` identity, so an in-flight pre-collapse channel
# keeps closing its rows; `--any-origin` and the stored `(any)` marker mean
# what an absent origin means and are accepted for the same reason.
#
# OPTIONAL ATOMIC LIFECYCLE GUARD.
# `--expected-identity` on answer, answers, and reconcile-requests requires the
# exact identity printed by `open <task-id> --identity`. The canonical backlog
# must still carry that open captain hold while the existing task control lock
# protects both comparison and transition. No report or caller-supplied record
# is authority. Conflict exits 3 and writes one stderr JSON object:
# {"error":"identity-conflict","reason":"mismatch"}, with reason `not-open`
# for a closed/unheld task or `absent` for an unknown task. It changes no body,
# hold, resolution, reconcile request, parent channel, notification, or wake.
# Backend errors remain failures (exit 2), and read timeouts remain exit 124.
# A guarded retry after a successful close/release is a conflict, including an
# exact answer retry; unguarded legacy replay behavior is unchanged.
# `correct` compares the same identity on an already answered closed/released
# row; it appends a correction without releasing or reopening work.
# With the flag, answers and reconcile-requests accept exactly one nonempty
# input row, read the whole input before acting, and reject empty, malformed,
# or multiple rows with exit 2 and stderr {"error":"invalid-guarded-input"}.
# Guarded answers require an exact task-id key and no concrete legacy-origin;
# their answer must be nonempty, with at most the documented four TSV fields.
# Guarded reconcile rows have a task id and at most one optional note field.
# No row of an invalid batch is applied. The source binding is still required
# for reconcile, which never answers or closes a call.
# `capabilities --json` is read-only, needs no configured home or tasks-axi,
# and returns {"schema":"fm-captain-hold.capabilities.v1",
# "expected_identity":["answer","answers","reconcile-requests","complete-action","correct"],
# "attachments":true,"correction":true,
# "guarded_input":"single-row","call_kinds":["question","action"],
# "action":{"where":["chat"],"completion":"complete-action","persistent":true}}.
# Clients can require this before guarded intake.
#
# RECONCILE IS RESERVED AT THIS INTAKE, NOT FILTERED IN A CHANNEL.
# The exact answer value `reconcile` means "go re-check reality", never "the
# captain answered". `answers` matches it before it reads the close mode,
# visibly refuses it, and never passes it to `answer`, so no channel and no
# card-declared mode can turn it into a close, release, or request. A separate
# `reconcile-requests` intake verifies a captured source's binding before it
# records a durable request under `state/reconcile-requests/`, then wakes its
# owning home through the durable queue. Pending retries share one wake; the
# original request timestamp and provenance survive retries, including changed
# notes. After acknowledgement a retry may notify again. A queue failure keeps
# the request and fails visibly so the same selection can retry. No hold is
# released and no resolution is recorded. Like answer wakes, this requires an
# active supervision cycle and cannot start a native turn after a final reply.
#
# `reconcile` is the verify-then-decide half. Both outcomes require the pending
# request created by the captain's board selection. `close` is the moot outcome:
# it requires the evidence that made the call moot, writes a `reconciled` resolution record
# under a `Reconciliation evidence:` label so it can never read as the
# captain's words, and closes the task. `note` is the still-active outcome: it
# appends one dated `Captain hold reconciled:` note and leaves the hold in
# place. A normal answer also retires the request because the call is settled.
# `list` is the read-only enumeration.
# docs/captain-hold-lifecycle.md owns the semantics.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines
# and pipe them here. It must never map keys to tasks, build decision records,
# choose a close mode beyond what its card declared, or close anything itself.
#
# `bind`, `unbind`, and `binding` record that a captured-answer SOURCE feeds
# this intake, for any channel whose answers arrive detached from their origin
# (a process-event source id, for example). The binding is a private record
# under `state/decision-bindings/`; a source with no binding feeds nothing, so
# this whole path is opt-in per source and an unbound source behaves as if it
# did not exist. `bind` deliberately does not require the source to exist yet,
# so a channel can be bound BEFORE it is armed. The optional second argument
# exists only for legacy pre-collapse records and callers: a concrete origin is
# stored verbatim and used as the composition fallback above, and
# `--any-origin` stores the same `(any)` marker a plain `bind <source-id>`
# stores. `binding` prints the stored value verbatim and `answers` accepts it,
# so the process-event runner's feed seam is unchanged.
#
# `complete` is the shared investigation and visual-review completion gate.
# It attests, in the origin task's metadata, the reviewed inventory of
# captain-held tasks that carry the origin's unresolved captain calls.
# `--none` is an explicit semantic attestation that the just-reviewed surface
# has no unresolved captain call, and is refused while the origin still has an
# open keyed status decision. With a non-empty inventory, every listed task is
# verified durable (captain-held, or carrying a recorded resolution),
# is never the origin itself, and, when `hold --origin` recorded one, was held
# for this origin; a hold with no recorded origin is accepted on durability
# alone and named in the output,
# the inventory is unioned idempotently into the metadata, and every still-open
# keyed status decision is transferred to its durable owner with a
# `captain-held [key=...]` status close naming the inventory. Later review
# passes may add ids. A post-teardown visual review can complete against the
# surviving report and tasks without recreating task state.
# `verify` is read-only and is called by scout teardown, so teardown cannot
# erase a source before this gate has succeeded: every recorded inventory
# entry must still satisfy the same durability and origin checks as `complete`,
# and no keyed status decision may be open.
# `complete` and `verify` also read an entry that markdown Done retention moved
# into the configured Done archive, where it counts only through a recorded
# resolution. Moot retirement also reads archived work as closure evidence.
# Metadata compatibility: the attestation keeps the historical
# `decisions_reviewed=1` and `decision_keys=` keys, and an inventory entry that
# names no existing task resolves through the legacy `<origin>-decision-<entry>`
# identity, so pre-collapse metadata written by fm-decision-hold.sh verifies
# unchanged. An entry that exists as a task id is always that task. On the
# Beads backend an attested legacy markdown id that resolves to no task is
# accepted through the migrated row fm-hold-migration produced, found by the
# authoritative evidence first: a row whose notes carry the marker line
# "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>". Only when no row carries that line is the legacy id tried under
# the configured beads prefix, and that name-only guess is accepted solely for
# a single row still held for the captain; two such rows refuse rather than
# attest, and `complete` names each prefix-resolved row beside its attested
# legacy id so the guess stays auditable.
#
# `open` is the read-only predicate a mechanical closer asks before it may
# retire a task's row: is this task still an open captain call? Exit 0 means it
# is (not Done, hold kind captain), 1 means it is not, and 2 means the answer
# could not be established, so a caller that must never close a live call can
# treat "cannot tell" as its own case instead of as a no. With
# `--distinguish-absent`, an absent local task returns 3 instead of 1; a home
# with no backlog file counts as absent, because it records no captain calls.
# It prints nothing on these predicate results and mutates nothing, unless
# `--identity` asks it to print this call's
# LIFECYCLE identity, which it does on an exit 0 only. That identity - the
# hold-set stamp and the count of recorded answers - is what distinguishes two
# successive calls on one task id: re-holding released work starts a new
# lifecycle without necessarily touching the task's status log, so a consumer
# that bounds repeated work per call cannot use the task id alone.
# bin/fm-teardown.sh asks it before its automatic
# backlog close and, on 0, returns the row to Queued with its deliverable
# recorded instead (bin/fm-backlog-transition-lib.sh owns that transition), so
# holding the very work item a question gates is safe. Resolution follows the
# lifecycle policy; cleanup never substitutes for an answer or moot proof.
# bin/fm-watch.sh asks it when an ordinary
# crew task reaches a due stale alarm - its open backlog hold need not appear in
# the task's last status line - and on a 0 bounds repeated alarms from new pane
# hashes for the decision.
#
# `diverged` is the read-only guard over the seam between the two records of
# one captain call. See "record divergence" beside command_diverged below.
# `resolved` is a read-only notification cancellation predicate: exit 0 only
# for the exact newest resolution count after its canonical close/release has
# settled, 1 otherwise. It does not accept a merely written, unfinished answer.
#
# Resolution records: the block written into the body names this script, the
# decision digest, and a `Resolution mode:` of answered, released, repaired,
# reconciled, or action-completed. Records written by the retired fm-decision-hold.sh (routed,
# declined, answered, repaired) are recognized everywhere a record is read, so
# nothing already closed needs rewriting.
#
# Parent channel: inside a secondmate home a task held for the captain, and its
# answer, are captain-facing facts the moment they are recorded, so `hold`
# publishes `needs-decision [key=captain-hold-<task>-<n>]` and `answer` (and
# `answers`) the matching `resolved` line on the parent channel through
# bin/fm-parent-channel-lib.sh, whether or not the mate model appends anything.
# <n> is the count of resolution records the body already carries plus one, so
# a released and re-held task opens and closes a distinct parent decision with
# no new persisted state, and an exact retry republishes the same line, which
# the channel deduplicates. A main home has no channel and publishes nothing.
# The hold or answer is already durable in the backlog, so a channel that
# cannot be written is reported as `actionable:` on stderr rather than undoing
# the record; bin/fm-inactive-reconcile.sh's diagnostics name a broken binding.
# After an answer, wake_answer_owner queues a check for this home's supervisor,
# including in a main home with no parent channel. The queue carries only the
# task and resolution occurrence, never the answer text. Pending retries are
# deduplicated under the queue lock; a retry after acknowledgement may notify
# again. A failed append leaves the answer intact and fails visibly so the same
# answer can be retried. This is durable delivery to an active supervision
# cycle, not a native callback capable of starting a turn after a final reply.
# A settled resolution also gets one idempotent inbox application note, keyed
# by captain-answer:<sha256("captain-answer:<id>:<occurrence>")>. Its metadata
# records the original task/origin/mode/digest; the answer stays canonical in
# the backlog. The note requests qualified native delivery through fm-inbox.
# A pending note means primary handling/application is unconfirmed, not that
# the captain owes another answer. An actual note reply means responded,
# never automatic policy execution. Exact answer replays reuse that note.
set -eu

# Capability discovery must remain cheap and read-only even without a home;
# loading the wake library below would initialize its state directory.
if [ "${1:-}" = capabilities ]; then
  [ "$#" -eq 2 ] && [ "$2" = --json ] \
    || { printf 'usage: fm-captain-hold.sh capabilities --json\n' >&2; exit 2; }
  printf '%s\n' '{"schema":"fm-captain-hold.capabilities.v1","expected_identity":["answer","answers","reconcile-requests","complete-action","correct"],"attachments":true,"correction":true,"guarded_input":"single-row","call_kinds":["question","action"],"action":{"where":["chat"],"completion":"complete-action","persistent":true}}'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

PARENT_HOLD_PUBLISHED=0
publish_parent_hold() {  # <task-id> <occurrence> <verb> <note>
  local id=$1 occurrence=$2 verb=$3 note=$4 rc=0
  PARENT_HOLD_PUBLISHED=0
  fm_parent_channel_report "$FM_HOME" "$STATE" \
    "$verb [key=captain-hold-$id-$occurrence]: captain hold $id: $(fm_parent_channel_clean_note "$note")" || rc=$?
  case "$rc" in
    0|1) PARENT_HOLD_PUBLISHED=1 ;;
    *) printf 'actionable: task %s is held for the captain in this home but that did not reach the parent channel (rc=%s)\n' "$id" "$rc" >&2 ;;
  esac

}

CAPTAIN_META_LOCK=
CAPTAIN_META_LOCK_HELD=0
CAPTAIN_CONTROL_LOCK=
CAPTAIN_CONTROL_LOCK_HELD=0
captain_hold_cleanup() {
  if [ "$CAPTAIN_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_META_LOCK" || true
    CAPTAIN_META_LOCK_HELD=0
  fi
  if [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_CONTROL_LOCK" || true
    CAPTAIN_CONTROL_LOCK_HELD=0
  fi
}
trap captain_hold_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

identity_conflict() {  # <mismatch|not-open|absent>
  printf '{"error":"identity-conflict","reason":"%s"}\n' "$1" >&2
  exit 3
}

invalid_guarded_input() {
  printf '{"error":"invalid-guarded-input"}\n' >&2
  exit 2
}

# Consume the entire guarded batch before any row can cause a mutation.
GUARDED_ROW=''
read_guarded_row() {
  local row count=0
  while IFS= read -r row || [ -n "$row" ]; do
    [ -n "$row" ] || invalid_guarded_input
    count=$((count + 1))
    [ "$count" -eq 1 ] || invalid_guarded_input
    GUARDED_ROW=$row
  done
  [ "$count" -eq 1 ] || invalid_guarded_input
}

acquire_task_control_lock() {  # <task-id>
  CAPTAIN_CONTROL_LOCK="$STATE/.control-$1.lock"
  fm_lock_acquire_wait "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=1
}

release_task_control_lock() {
  [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=0
  CAPTAIN_CONTROL_LOCK=
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

# The legacy derived identity older installs minted for a captain call.
# Kept only to resolve pre-collapse rows, metadata entries, and channel keys.
legacy_hold_id() {  # <origin-id> <key>
  printf '%s-decision-%s' "$1" "$2"
}

# The legacy any-origin binding marker. Slug validation rejects parentheses, so
# no real origin id or task id can collide with it.
BINDING_ANY='(any)'

DECISION_TEXT=''
DECISION_DIGEST=''
ANSWER_ATTACHMENTS='[]'

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || [ "${ALLOW_EMPTY_DECISION:-0}" -gt 0 ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

attach_answer_files() {  # <task-id> [file...]; saves each file and appends its saved path to the decision
  local id=$1 n=0 file name saved dir base existing
  shift
  [ "$#" -gt 0 ] || return 0
  base="$DATA/$id/answer-attachments"
  for file in "$@"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "attachment is not a regular file: $file"
    name=$(basename -- "$file")
    case $name in *$'\n'*|*$'\r'*) fail "attachment name has a line break: $file" ;; esac
  done
  [ ! -L "$DATA/$id" ] && [ ! -L "$base" ] || fail "unsafe attachment directory for $id"
  mkdir -p -- "$base" || fail "cannot create the attachment folder for $id"
  dir=$(umask 077; mktemp -d "$base/files.XXXXXX") || fail "cannot save attachments for $id"
  for file in "$@"; do
    n=$((n + 1))
    name=$(basename -- "$file")
    saved=''
    for existing in "$base"/*/"$n-$name"; do
      if [ -f "$existing" ] && [ ! -L "$existing" ] && cmp -s -- "$file" "$existing"; then
        saved=$existing
        break
      fi
    done
    if [ -z "$saved" ]; then
      saved="$dir/$n-$name"
      (umask 077; cp -- "$file" "$saved") || fail "cannot save attachment: $file"
    fi
    ANSWER_ATTACHMENTS=$(printf '%s' "$ANSWER_ATTACHMENTS" | jq -c --arg path "$saved" '. + [$path]')
    DECISION_TEXT=$(printf '%s\nAdjunto: %s' "$DECISION_TEXT" "$saved")
  done
  [ "$(printf '%s' "$DECISION_TEXT" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision with attachments exceeds 8192 bytes"
  DECISION_DIGEST=$(sha256_text "$DECISION_TEXT")
}

# Mutations address the configured data directory's backlog from its root, the
# way bin/fm-backlog-transition-lib.sh addresses every transition, so a home
# with a relocated data directory keeps one backlog. The explicit --file file
# belongs to the markdown backend only; a non-markdown backend is addressed by
# the root's own tasks-axi configuration, exactly like the transition library's
# mutate path.
tasks_axi() {
  local data file root backend
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  root=$(fm_backlog_root "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
  case "${1:-}" in
    add|create)
      FM_DATA_OVERRIDE="$data" bash "$SCRIPT_DIR/fm-tasks-axi.sh" "$@"
      return $?
      ;;
  esac
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
    (cd "$root" && tasks-axi "$@" --file "$file")
  else
    (cd "$root" && tasks-axi "$@")
  fi
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

# Read one row into TASK_SHOW_OUTPUT; a non-zero return means the row is
# absent. A read that could not finish inside its bound is NOT absence, and
# every caller below would otherwise spend it as one - minting a duplicate task,
# skipping a keyed answer, or reporting a task that exists as missing. So the
# bound's own status stops the command instead, loudly and by name, and it
# leaves 124 intact rather than collapsing to fail's 1 so a caller running this
# inside a command substitution can still tell a wedged backend from a
# genuinely unknown id.
TASK_SHOW_OUTPUT=
task_show() {  # <id>; sets TASK_SHOW_OUTPUT
  local data status=0 reason
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  TASK_SHOW_OUTPUT=$(fm_backlog_row_show "$data" "$1" --full 2>/dev/null) || status=$?
  if [ "$status" -eq 124 ]; then
    reason=${TASK_SHOW_OUTPUT%%$'\n'*}
    printf 'fm-captain-hold: %s\n' \
      "${reason:-tasks-axi show $1 exceeded its backlog read bound}" >&2
    exit 124
  fi
  return "$status"
}

# Read one row into `show`, failing with <absence-message> only when the read
# genuinely failed; a read-bound hit (124) stops the command by name instead.
# task_show must be called in THIS shell, not inside a command substitution:
# it carries the row in TASK_SHOW_OUTPUT, which a subshell cannot hand back.
task_show_or_fail() {  # <id> <absence-message>; sets show
  task_show "$1" || {
    [ "$?" -ne 124 ] || fail "the backlog backend exceeded its read bound reading $1"
    fail "$2"
  }
  show=$TASK_SHOW_OUTPUT
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

# A shown scalar field arrives as a JSON-encoded bare string, which decode_json
# accepts only where the installed JSON::PP defaults allow_nonref on. Older
# libraries default it off and reject the whole value as "must be object or
# array", so ask for it explicitly rather than inheriting the local default.
decode_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Decode show-encoded scalar fields and normalize the empty marker.
show_field_value() {  # <show-output> <field>
  local value
  value=$(decode_shown_value "$(show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

origin_exists_here() {  # <origin-id>
  [ -f "$STATE/$1.meta" ] && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1"
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# A resolution record written by this script or by the retired
# fm-decision-hold.sh. Both carry the same leader-then-captain-decision shape.
body_has_resolution_record() {  # <task-body>
  case "$1" in
    *"Resolution recorded by fm-captain-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-decision-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"Reconciliation evidence:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"Action completion evidence:"*) return 0 ;;
  esac
  return 1
}

# The recorded decision digest of either record format, from the show-escaped
# body (multi-line bodies print as one quoted line with \n escapes). Records
# are prepended, so the first match is the newest record.
recorded_decision_digest() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Decision digest: "*) rest=${rest#*"Decision digest: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

# How many resolution records the shown body carries, in either record format.
resolution_record_count() {  # <task-body>
  local body
  body=$(decode_shown_value "$1") || return 1
  printf '%s\n' "$body" \
    | grep -Ec '^Resolution recorded by fm-(captain|decision)-hold\.$' || true
}

# The newest record's `Resolution mode:` value; empty for a record predating it.
recorded_resolution_mode() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Resolution mode: "*) rest=${rest#*"Resolution mode: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

closed_answer_replay_mode_compatible() {  # <mode> <task-body>
  case "$1" in
    answered|repaired|routed) return 0 ;;
  esac
  return 1
}

# The record's label is what keeps an evidence-backed reconciliation from
# reading as the captain's own words. `reconciled` closes a call that went moot
# and carries verified evidence; every other mode carries what the captain said.
resolution_block() {  # <mode>
  local label='Captain decision:'
  [ "$1" != reconciled ] || label='Reconciliation evidence:'
  [ "$1" != action-completed ] || label='Action completion evidence:'
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: %s\nDecision bytes: %s\nDecision attachments: %s\n\n%s\n%s\n' \
    "$DECISION_DIGEST" "$1" "$(printf '%s' "$DECISION_TEXT" | LC_ALL=C wc -c | tr -d ' ')" "$ANSWER_ATTACHMENTS" "$label" "$DECISION_TEXT"
}

# Durable state of one captain call: an active captain hold (annotations
# surviving even when a date gate has expired) or a recorded captain answer.
verify_hold_durable() {  # <task-id>
  local id=$1 show state hold_kind body archived_status
  task_show "$id" || {
    [ "$?" -ne 124 ] || fail "the backlog backend exceeded its read bound reading $id"
    task_show_archived "$id" || {
      archived_status=$?
      [ "$archived_status" -ne 124 ] || exit 124
      fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
    }
  }
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if body_has_resolution_record "$body"; then
    return 0
  fi
  if [ "$state" != "done" ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  fail "captain-held task $id is neither held for the captain nor closed with a recorded captain answer"
}

# --- migrated legacy-id resolution on the Beads backend ---------------------
#
# A home that moved its backlog from markdown to Beads no longer carries the
# legacy hold ids a scout report attested: the migration rehomed every held
# row under a prefixed fm- id and recorded its markdown identity in the row's
# notes as "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>" (fm-hold-migration wrote the dated form on 2026-09-04). When an
# attested legacy id resolves to no task, the beads backend accepts the row the
# migration produced, found by scanning the configured graph's notes for either
# form of that marker line, and only when no row carries the marker by
# prepending the configured prefix to the legacy id - a name-only guess, so it
# is accepted solely for a row still held for the captain and only when it is
# the single such row. A markdown home keeps its legacy rows verbatim, so its
# exact-id resolution is unchanged.

CAPTAIN_MIGRATION_SCAN_LOADED=0
CAPTAIN_MIGRATION_SCAN_JSON=
NL_SEP=$'\n'

# Section-aware extraction from a .tasks.toml: only the named keys inside the
# named section, comments stripped. Prints "<key> <value>" lines.
captain_toml_section_entries() {  # <toml-file> <section> <key-alternation>
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v section="[$2]" -v keys="^($3)[[:space:]]*=" '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    BEGIN { insection = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { insection = (line == section); next }
      if (!insection) next
      if (line ~ keys) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "%s %s\n", key, line
      }
    }
  ' "$1"
}

captain_beads_toml_entries() {  # <toml-file>
  captain_toml_section_entries "$1" beads 'prefix|path|binary'
}

captain_beads_setting() {  # <entries-output> <setting>
  printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1
}

# Read the configured beads graph's row listing for a migration-note scan.
# The listing is deliberately re-read per unresolvable key: the cache below
# lives and dies with the command-substitution subshell every resolve_entry
# call site runs in, so it cannot persist across keys - bounded by a scout
# report's handful of attested ids. Returns 0 when the listing loads, and 2
# with the reason on stderr when the graph cannot be read.
captain_migration_scan_load() {  # <resolved-data-dir>
  local data=$1 root entries bd_bin bd_path backend
  [ "$CAPTAIN_MIGRATION_SCAN_LOADED" = 1 ] && return 0
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the configured data directory cannot be resolved for a migration scan: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" != beads ]; then
    CAPTAIN_MIGRATION_SCAN_LOADED=1
    return 0
  fi
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  bd_bin=$(captain_beads_setting "$entries" binary)
  bd_path=$(captain_beads_setting "$entries" path)
  bd_bin=${bd_bin:-bd}
  if [ -z "$bd_path" ]; then
    printf 'fm-captain-hold: the beads backend carries no graph path in %s, so a migrated hold cannot be found\n' "$root/.tasks.toml" >&2
    return 2
  fi
  # A relative [beads] path resolves against the backlog root, the same rule
  # every other .tasks.toml path consumer uses, never against the process CWD.
  case "$bd_path" in
    /*) ;;
    *) bd_path="$root/$bd_path" ;;
  esac
  command -v "$bd_bin" >/dev/null 2>&1 || {
    printf 'fm-captain-hold: the beads binary %s is not on PATH, so a migrated hold cannot be found\n' "$bd_bin" >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-captain-hold: jq is required to scan the beads graph for a migrated hold\n' >&2
    return 2
  }
  local bd_err
  bd_err=$(mktemp "${TMPDIR:-/tmp}/fm-captain-hold-bd.XXXXXX") || {
    printf 'fm-captain-hold: cannot stage the beads graph read diagnostics\n' >&2
    return 2
  }
  if ! CAPTAIN_MIGRATION_SCAN_JSON=$(BEADS_DIR="$bd_path" "$bd_bin" list --all --json 2>"$bd_err"); then
    printf 'fm-captain-hold: reading the beads graph at %s failed (%s), so a migrated hold cannot be found\n' \
      "$bd_path" "$(sanitize_field "$(head -c 200 "$bd_err" | tr '\n' ' ')")" >&2
    rm -f "$bd_err"
    return 2
  fi
  rm -f "$bd_err"
  CAPTAIN_MIGRATION_SCAN_LOADED=1
  return 0
}

# Resolve one attested legacy id to the migrated row that carries it on the
# beads backend. Prints "<row id> <how>" and returns 0 when exactly one
# migration matches, returns 1 when none does, and returns 2 with the reason on
# stderr when the scan itself cannot run or is ambiguous. The marker note is the
# authoritative evidence and is scanned first; the bare configured prefix is a
# guess, so it only runs when no marker line matches any identity and it accepts
# a row solely when that row is itself still held for the captain.
resolve_migrated_entry() {  # <origin-or-empty> <entry>
  local origin=$1 entry=$2 data root entries prefix derived show backend
  local candidate candidate_matches prefixed matches count prefixed_matches prefixed_count
  data=$(fm_backlog_data_absolute "$DATA") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  [ "$backend" = beads ] || return 1
  # Every identity this entry could have been migrated under: the raw entry,
  # and - for a pre-collapse channel key - the derived legacy identity its
  # origin would have minted, because fm-hold-migration recorded the DERIVED
  # id in each migrated row's marker note.
  CAPTAIN_MIGRATION_IDENTITIES=$entry
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    derived=$(legacy_hold_id "$origin" "$entry")
    if [ "$derived" != "$entry" ]; then
      CAPTAIN_MIGRATION_IDENTITIES="$CAPTAIN_MIGRATION_IDENTITIES $derived"
    fi
  fi
  captain_migration_scan_load "$data" || return 2
  matches=
  if [ -n "$CAPTAIN_MIGRATION_SCAN_JSON" ]; then
    for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
      candidate_matches=$(printf '%s\n' "$CAPTAIN_MIGRATION_SCAN_JSON" | jq -r \
        --arg exact "migrated from data/backlog.md id $candidate" \
        --arg dated "migrated from data/backlog.md id $candidate on " \
        '.[] | select(((.notes // "") | split("\n")) | any(. == $exact or startswith($dated))) | .id' 2>/dev/null) || {
        printf 'fm-captain-hold: the beads graph scan for the migrated hold of %s could not be parsed\n' "$candidate" >&2
        return 2
      }
      matches="${matches}${matches:+$NL_SEP}${candidate_matches}"
    done
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$count" in
      0) : ;;
      1) printf '%s migrated-note' "$(printf '%s\n' "$matches" | sed '/^$/d' | sed -n 1p)"; return 0 ;;
      *)
        printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s rows carry its marker line (identities tried: %s)\n' \
          "$entry" "$count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
        return 2
        ;;
    esac
  fi
  # No marker line anywhere: a mechanical migration keeps the legacy id under
  # the configured prefix, but that name alone is evidence of nothing, so only
  # a row still held for the captain - and only one of them - is accepted.
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  prefix=$(captain_beads_setting "$entries" prefix)
  [ -n "$prefix" ] || return 1
  prefixed_matches=
  for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
    case "$prefix" in
      *-) prefixed="$prefix$candidate" ;;
      *) prefixed="$prefix-$candidate" ;;
    esac
    # Same shell rule as task_show_or_fail: the row is read out of
    # TASK_SHOW_OUTPUT, so the read cannot sit inside a command substitution.
    task_show "$prefixed" 2>/dev/null || {
      [ "$?" -ne 124 ] || return 124
      continue
    }
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
    prefixed_matches="${prefixed_matches}${prefixed_matches:+$NL_SEP}$prefixed"
  done
  prefixed_count=$(printf '%s\n' "$prefixed_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$prefixed_count" in
    0) return 1 ;;
    1) printf '%s migrated-prefix' "$prefixed_matches"; return 0 ;;
  esac
  printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s captain-held rows carry the configured prefix (identities tried: %s)\n' \
    "$entry" "$prefixed_count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
  return 2
}

# Resolve one inventory entry or channel key to the task that carries it: the
# exact task id when it exists, else the legacy derived identity, else - on the
# beads backend - the migrated row the markdown-to-beads hold migration wrote.
# Prints "<resolved id> <how>", where <how> is exact, legacy, migrated-note or
# migrated-prefix, so a caller can record which evidence carried the attestation.
resolve_entry() {  # <origin-or-empty> <entry>; prints "<id> <how>" or fails
  local origin=$1 entry=$2 legacy migrated rc
  if task_show "$entry"; then
    printf '%s exact' "$entry"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if task_show "$legacy"; then
      printf '%s legacy' "$legacy"
      return 0
    fi
  fi
  rc=0
  migrated=$(resolve_migrated_entry "$origin" "$entry") || rc=$?
  case "$rc" in
    0) printf '%s' "$migrated"; return 0 ;;
    2) return 2 ;;
    124) return 124 ;;
  esac
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA); the nearest legacy identity $legacy also resolves to nothing"
  fi
  fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA)"
}

body_hold_set_timestamp() {  # <decoded-task-body>
  printf '%s\n' "$1" \
    | sed -n \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\)$/\1/p' \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | head -1
}

hold_lifecycle_identity() {  # <shown-task-body>
  printf '%s#%s\n' \
    "$(body_hold_set_timestamp "$(decode_shown_value "$1")")" \
    "$(resolution_record_count "$1")"
}

# Called only with this task's control lock held; leave the same canonical row
# in TASK_SHOW_OUTPUT for the transition, without a second unlocked precheck.
guard_expected_identity() {  # <task-id> <expected-identity> [correction-0-or-1]
  local id=$1 expected=$2 correcting=${3:-0} status=0 show state
  [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ] && [ "$CAPTAIN_CONTROL_LOCK" = "$STATE/.control-$id.lock" ] \
    || fail "identity comparison requires task control for $id"
  task_show "$id" || status=$?
  if [ "$status" -ne 0 ]; then
    if printf '%s\n' "$TASK_SHOW_OUTPUT" | grep -q '^code: NOT_FOUND$'; then
      identity_conflict absent
    fi
    printf 'fm-captain-hold: cannot read the canonical captain call %s\n' "$id" >&2
    exit 2
  fi
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  [ -n "$state" ] || { printf 'fm-captain-hold: canonical task %s has no state\n' "$id" >&2; exit 2; }
  if [ "$correcting" != 1 ]; then
    [ "$state" != "done" ] && [ "$(show_field_value "$show" hold_kind)" = captain ] \
      || identity_conflict not-open
  fi
  [ "$(hold_lifecycle_identity "$(show_field "$show" body)")" = "$expected" ] \
    || identity_conflict mismatch
}

write_hold_set_stamp() {  # <task-id> <shown-body> <timestamp> <preserve-existing-0-or-1>
  local id=$1 body=$2 hold_set=$3 preserve=$4 existing new_body tmp
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  existing=$(body_hold_set_timestamp "$body")
  if [ "$preserve" = 1 ] && [ -n "$existing" ]; then
    return 0
  fi
  if [ -n "$existing" ]; then
    body=${body#"Captain hold set: $existing"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
  fi
  new_body=$(printf 'Captain hold set: %s' "$hold_set")
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-stamp.XXXXXX") \
    || fail "cannot stage the hold-set stamp"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold-set stamp for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the hold-set stamp on $id"
  fi
  rm -f -- "$tmp"
}

# The origin a hold was recorded for lives in the held task's own body, on a
# line of its own, so `complete` can tell a call held for this origin from one
# held for another. Omitting --origin leaves any existing association intact.
body_hold_origin() {  # <decoded-task-body>
  printf '%s\n' "$1" | sed -n 's/^Captain hold origin: \(.*\)$/\1/p' | head -1
}

task_identity() {
  local id=$1
  if task_show "$id"; then
    id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
    validate_slug backend-task-id "$id"
  elif ! printf '%s\n' "$TASK_SHOW_OUTPUT" | grep -q '^code: NOT_FOUND$'; then
    fail "could not resolve the backend identity of $id"
  fi
  printf '%s' "$id"
}

write_hold_origin() {  # <task-id> <shown-body> <origin-or-empty>
  local id=$1 body=$2 origin=$3 stamp rest new_body tmp
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  stamp=$(printf '%s\n' "$body" | sed -n 1p)
  [ -n "$(body_hold_set_timestamp "$body")" ] \
    || fail "task $id lost its hold-set stamp before its origin was recorded"
  rest=$(printf '%s\n' "$body" | sed 1d | awk '!/^Captain hold origin: /' \
    | awk 'NF || started { started = 1; print }')
  new_body=$stamp
  if [ -n "$origin" ]; then
    new_body=$(printf '%s\nCaptain hold origin: %s' "$stamp" "$origin")
  fi
  if [ -n "$rest" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$rest")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-origin.XXXXXX") \
    || fail "cannot stage the hold origin"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold origin for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the hold origin on $id"
  fi
  rm -f -- "$tmp"
}

# --- structured call fields (STRUCTURED CALL FIELDS in the header) ----------

CALL_SCHEMA=fm-captain-call.v1
CALL_JSON=''
ACTION_COMPLETION=0

publish_call_event() {  # <event> <task-id> <occurrence>; task control lock held
  local event=$1 id=$2 occurrence=$3
  [ -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || return 0
  task_show_or_fail "$id" "cannot read $id for its ledger event"
  jq -cn --arg event "$event" --arg id "$id" --argjson occurrence "$occurrence" \
    --arg state "$(show_field_value "$show" state)" --arg body "$(show_field_value "$show" body)" \
    '{event:$event, occurrence:$occurrence, task:{id:$id,state:$state,body:$body}}' \
    | python3 "$SCRIPT_DIR/fm_delivery.py" ledger-call --task "$id" --data "$DATA" \
    || fail "canonical call $id saved but ledger publication failed; republish through the canonical owner"
}

captain_call_path() {  # <task-id>
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  printf '%s/%s/captain-call.json\n' "$data" "$1"
}

# The explicit type belongs to the existing call record; missing type is a
# legacy question, never an inference from absent options.
call_record_kind() {  # <task-id>
  local path
  path=$(captain_call_path "$1") || return 2
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then printf 'question'; return 0; fi
  [ -f "$path" ] && [ ! -L "$path" ] || return 2
  jq -er --arg id "$1" '
    select(.schema == "fm-captain-call.v1" and .id == $id)
    | (.call.kind // "question") | select(. == "question" or . == "action")
  ' "$path" 2>/dev/null || return 2
}

# Refuse a new captain call that carries no real choices, naming the expected
# call shape so the caller can retry at once.
refuse_without_choices() {  # <task-id> <why>
  local id=$1
  printf 'fm-captain-hold: %s\n' "$2" >&2
  cat >&2 <<EOF
A captain call needs real choices the captain can click. Hold it as:
  fm-captain-hold.sh hold $id --reason "<short summary>" --category <category> \\
    --question "<the question>" --option <id>="<choice>" --option <id>="<choice>" \\
    [--recommended <id>] [--context "<one line>"] [--link <report path or URL>]
Only for a genuinely open question or a wait with no choices (a human action, a date):
  fm-captain-hold.sh hold $id --reason "<short summary>" --category <category> \\
    --no-options "<why there are no choices>" [--question "<the question>"]
EOF
  exit 1
}

refuse_category() {
  printf 'fm-captain-hold: %s\n' "$1" >&2
  printf '%s\n' 'Allowed --category values: product-design, unbacked-destructive, money, credentials-security, captain-only-fact.' >&2
  printf '%s\n' 'Solo pregunta al capitán por producto/diseño, acciones destructivas o irreversibles sin respaldo, dinero, credenciales/seguridad, o un dato que solo el capitán tiene. Para cualquier otra cosa, hazlo y repórtalo.' >&2
  exit 1
}

# True when the private call record already gives the current hold lifecycle
# real choices or a recorded --no-options reason, so a repeat may keep it.
call_record_satisfies() {  # <task-id> <hold-set>
  local path
  [ -n "$2" ] || return 1
  path=$(captain_call_path "$1") || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  jq -e --arg schema "$CALL_SCHEMA" --arg id "$1" --arg hold_set "$2" '
    .schema == $schema and .id == $id and .hold_set == $hold_set
    and ((.call.kind == "action" and (.call.instruction | type) == "string" and .call.where == "chat")
         or ((.no_options // null) | type) == "string"
         or (((.call // {}).options // []) | length) >= 2)
  ' "$path" >/dev/null 2>&1
}

# Normalize the structured flags into one record payload in CALL_JSON, or fail
# before any mutation. jq measures the bounds, so they count characters rather
# than bytes in either language.
build_call_json() {  # <id> <question> <recommended> <context> <link> <no-options> <kind> <instruction> <where> [options...]
  local id=$1 question=$2 recommended=$3 context=$4 link=$5 no_options=$6 kind=$7 instruction=$8 where=$9 out
  shift 9
  case "$kind" in question|action) ;; *) fail '--call-kind must be question or action' ;; esac
  if [ "$kind" = action ]; then
    [ -n "$instruction" ] && [ "$where" = chat ] || fail 'an action needs --instruction and --where chat'
    [ "$#" -eq 0 ] && [ -z "$question$recommended$no_options" ] \
      || fail 'an action cannot carry question, options, recommended or no-options fields'
  elif [ -n "$instruction$where" ]; then
    fail '--instruction and --where require --call-kind action'
  elif [ -n "$no_options" ]; then
    [ "$#" -eq 0 ] && [ -z "$recommended" ] \
      || fail "--no-options cannot be combined with --option or --recommended"
    [ -n "$question" ] || { [ -z "$context" ] && [ -z "$link" ]; } \
      || fail "--question is required with --context or --link"
  else
    [ -n "$question" ] || refuse_without_choices "$id" "--question is required with --option, --recommended, --context, or --link"
    [ "$#" -ge 2 ] || refuse_without_choices "$id" "a captain call needs at least two --option choices"
  fi
  out=$(jq -cn --arg question "$question" --arg recommended "$recommended" \
    --arg context "$context" --arg link "$link" --arg no_options "$no_options" \
    --arg kind "$kind" --arg instruction "$instruction" --arg where "$where" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def field($label; $max):
      if test("[[:cntrl:]]") then error("\($label) must be one line without control characters")
      elif (trim | length) == 0 then error("\($label) must not be empty")
      elif (trim | length) > $max then error("\($label) has \(trim | length) characters; keep it within \($max)")
      else trim end;
    def optional($label; $max): if . == "" then null else field($label; $max) end;
    ($ARGS.positional) as $specs
    | if ($specs | length) > 8 then error("at most 8 --option values") else . end
    | [ $specs[]
        | (capture("^(?<id>[^=]*)=(?<label>[^|]*)(?:\\|(?<detail>.*))?$"; "s")
           // error("--option must be <id>=<label>[|<detail>]: \(.)")) as $m
        | {id:($m.id // "" | trim),
           label:($m.label // "" | field("option label"; 40)),
           detail:($m.detail // "" | optional("option detail"; 120))}
        | if (.id | test("^[A-Za-z0-9._-]{1,32}$") | not) then
            error("option id must be a slug of at most 32 characters: \(.id)")
          elif .id == "reconcile" then error("option id reconcile is reserved")
          else . end ] as $options
    | if ($options | map(.id) | unique | length) != ($options | length) then
        error("option ids must be unique") else . end
    | if $recommended != "" and ([$options[].id] | index($recommended)) == null then
        error("--recommended must name an --option id: \($recommended)") else . end
    | {call:(if $kind == "action" then
        {kind:"action",instruction:($instruction | field("instruction"; 200)),where:$where,
         question:null,options:[],recommended:null,
         context:($context | optional("context"; 200)),
         link:($link | optional("link"; 500)
               | if . != null and test("[[:space:]]") then error("link must not contain spaces") else . end)}
        elif $question == "" then null else
        {question:($question | field("question"; 160)),
         options:$options,
         recommended:(if $recommended == "" then null else $recommended end),
         context:($context | optional("context"; 200)),
         link:($link | optional("link"; 500)
               | if . != null and test("[[:space:]]") then error("link must not contain spaces") else . end)}
        end)}
      + (if $no_options == "" then {} else {no_options:($no_options | field("no-options reason"; 160))} end)
  ' --args "$@" 2>&1) || fail "${out#jq: error (at <unknown>): }"
  CALL_JSON=$out
}

write_captain_call() {  # <task-id> <hold-set>
  local id=$1 hold_set=$2 path dir tmp
  path=$(captain_call_path "$id") || fail "data directory cannot be resolved: $DATA"
  dir=${path%/*}
  [ ! -L "$dir" ] || fail "refusing the symlinked task data directory $dir"
  mkdir -p -- "$dir" && [ -d "$dir" ] && [ ! -L "$dir" ] \
    || fail "cannot prepare the task data directory $dir"
  tmp=$(umask 077; mktemp "$dir/.captain-call.XXXXXX") || fail "cannot stage the captain call for $id"
  if ! printf '%s' "$CALL_JSON" | jq -c --arg schema "$CALL_SCHEMA" --arg id "$id" \
      --arg hold_set "$hold_set" '{schema:$schema,id:$id,hold_set:$hold_set} + .' > "$tmp" \
    || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    fail "task $id is held for the captain but its structured call was not recorded; retry the same hold"
  fi
}

refuse_self_inventory() {
  local origin=$1 entry=$2 meta="$STATE/$1.meta"
  if list_has_key "$(meta_value "$meta" decision_keys)" "$entry"; then
    fail "origin $origin cannot be its own captain-call inventory entry; historical decision_keys in $meta still contains $entry; hold a separate captain task with --origin $origin, replace only $entry in the final decision_keys= line with that task id while preserving all other entries, then re-run complete $origin <task-id>"
  fi
  fail "origin $origin cannot be its own captain-call inventory entry; hold a separate captain task for the call and list that task"
}

# --- Done-archive reads on the markdown backend -----------------------------
#
# Done retention moves closed markdown rows into the configured archive, which
# tasks-axi show never reads, so an answered call a scout attested would read as
# absent once retention ran. The completion gate and moot-retirement proof
# consult the archive; mutation still addresses only current backlog rows.

# The [markdown] archive key tasks-axi would honour, resolved with tasks-axi's
# own source precedence: the backlog root's .tasks.toml first, then the
# user-level $HOME/.tasks-axi/config.toml. Empty when neither sets it; a relative
# value resolves against the backlog root wherever it was configured, the way
# tasks-axi resolves it.
captain_markdown_archive_setting() {  # <backlog-root>
  local root=$1 archive
  archive=$(captain_toml_section_entries "$root/.tasks.toml" markdown archive | sed -n 's/^archive //p' | head -1)
  if [ -z "$archive" ] && [ -n "${HOME:-}" ]; then
    archive=$(captain_toml_section_entries "$HOME/.tasks-axi/config.toml" markdown archive | sed -n 's/^archive //p' | head -1)
  fi
  printf '%s\n' "$archive"
}

# The archive tasks-axi writes: the [markdown] archive key resolved against the
# backlog root, else done-archive.md beside the addressed backlog file. Returns
# 1 when the configured backend keeps no markdown archive.
captain_markdown_archive_path() {
  local data root backend archive file
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  root=$(fm_backlog_root "$data") || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 1
  [ "$backend" = markdown ] || return 1
  archive=$(captain_markdown_archive_setting "$root")
  case "$archive" in
    '')
      file=$(fm_backlog_file "$data") || return 1
      archive="${file%/*}/done-archive.md"
      ;;
    /*) ;;
    *) archive="$root/$archive" ;;
  esac
  printf '%s\n' "$archive"
}

# Read an archived row (or --list for the dependency proof) into TASK_SHOW_OUTPUT
# exactly as tasks-axi shows live rows, replaying the newest archived blocks. A
# reused id can be archived more than once, and retention appends, so the last
# block is the newest. Returns 1 when the row is not archived.
task_show_archived() {  # <id>; sets TASK_SHOW_OUTPUT
  local id=$1 archive dir status=0 operation=show secs=${FM_BACKLOG_ROW_TIMEOUT_SECS:-10}
  local -a archive_args=("$id" --full)
  TASK_SHOW_OUTPUT=
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  archive=$(captain_markdown_archive_path) || return 1
  [ ! -L "$archive" ] || return 2
  [ -f "$archive" ] || return 1
  [ -r "$archive" ] || return 2
  if [ "$id" = --list ]; then
    operation=list
    archive_args=(--fields 'deps,hold_kind')
  fi
  dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-captain-hold-archive.XXXXXX") \
    || fail "cannot stage the Done archive read for $id"
  printf 'backend = "markdown"\n' > "$dir/.tasks.toml"
  {
    printf '## Done\n'
    LC_ALL=C awk -v id="$id" '
      /^- \[.\] / {
        rest = substr($0, 7)
        split(rest, fields, /[[:space:]]/)
        key = fields[1]
        inrow = (id == "--list" || key == id)
        if (inrow) blocks[key] = $0 "\n"
        next
      }
      inrow && ($0 == "" || $0 ~ /^[[:space:]]/) { blocks[key] = blocks[key] $0 "\n"; next }
      { inrow = 0 }
      END {
        if (id == "--list") { for (key in blocks) printf "%s", blocks[key] }
        else printf "%s", blocks[id]
      }
    ' "$archive"
  } > "$dir/backlog.md" || status=1
  if [ "$status" -eq 0 ]; then
    # The replayed archive read gets the same bound as a live backlog read, so a
    # wedged tasks-axi cannot hang verify, or complete while it holds the origin
    # metadata lock. A bound hit is not absence, so it stops loudly with 124.
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
    TASK_SHOW_OUTPUT=$(fm_run_timed "$secs" bash -c \
      'cd "$1" 2>/dev/null || exit 1; shift; exec tasks-axi "$@"' \
      _ "$dir" "$operation" "${archive_args[@]}" --file "$dir/backlog.md" 2>/dev/null)
    status=$?
    if [ "$status" -eq 124 ]; then
      printf 'fm-captain-hold: tasks-axi show %s exceeded its %ss Done-archive read bound\n' "$id" "$secs" >&2
    elif [ "$status" -ne 0 ]; then
      status=1
    fi
  fi
  rm -f -- "$dir/backlog.md" "$dir/.tasks.toml"
  rmdir -- "$dir" 2>/dev/null || true
  return "$status"
}

# The archived row an entry names, under its exact id or its legacy identity.
# A read that hit its bound is not absence: it returns 124 so the caller stops
# loudly instead of reading the row as unarchived.
archived_entry() {  # <origin-or-empty> <entry>; prints the archived id
  local origin=$1 entry=$2 legacy status=0
  task_show_archived "$entry" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s' "$entry"
    return 0
  fi
  [ "$status" -ne 124 ] || return 124
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    status=0
    task_show_archived "$legacy" || status=$?
    if [ "$status" -eq 0 ]; then
      printf '%s' "$legacy"
      return 0
    fi
    [ "$status" -ne 124 ] || return 124
  fi
  return 1
}

# Resolve one entry and verify the row it names is durably captain-held. A
# resolution failure that is not the read bound keeps resolve_entry's own
# status - its stderr already named the entry; 124 means the backend never
# answered, which is not the same as an unknown entry and must not be spent
# as absence. The result carries the attestation evidence and whether an
# origin was recorded, so completion can disclose the legacy fallback.
verify_entry_durable() {  # <origin-or-empty> <entry>; prints "<id> <how> <origin-state>"
  local origin=$1 entry=$2 resolved resolve_status=0 id how stored origin_state=unrecorded origin_id stored_id resolve_err archived archived_status
  # The origin task is never its own captain-call inventory: it is the work the
  # calls were found in, so accepting it would let a refused hold look recorded.
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ] && [ "$entry" = "$origin" ]; then
    refuse_self_inventory "$origin" "$entry"
  fi
  resolve_err=$(mktemp "${TMPDIR:-/tmp}/fm-captain-hold-resolve.XXXXXX") \
    || fail "cannot stage the resolution diagnostics for $entry"
  resolved=$(resolve_entry "$origin" "$entry" 2>"$resolve_err") || resolve_status=$?
  if [ "$resolve_status" -eq 1 ]; then
    archived_status=0
    archived=$(archived_entry "$origin" "$entry") || archived_status=$?
    if [ "$archived_status" -eq 0 ]; then
      resolved="$archived archived"
      resolve_status=0
    elif [ "$archived_status" -eq 124 ]; then
      rm -f -- "$resolve_err"
      exit 124
    else
      cat "$resolve_err" >&2
    fi
  else
    cat "$resolve_err" >&2
  fi
  rm -f -- "$resolve_err"
  if [ "$resolve_status" -ne 0 ]; then
    [ "$resolve_status" -ne 124 ] \
      || fail "the backlog backend exceeded its read bound resolving $entry"
    exit "$resolve_status"
  fi
  id=${resolved%% *}
  how=${resolved##* }
  verify_hold_durable "$id"
  id=$(show_field_value "$TASK_SHOW_OUTPUT" id)
  validate_slug backend-task-id "$id"
  stored=$(body_hold_origin "$(decode_shown_value "$(show_field "$TASK_SHOW_OUTPUT" body)")")
  origin_id=$origin
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    origin_id=$(task_identity "$origin") || exit $?
    [ "$id" != "$origin_id" ] || refuse_self_inventory "$origin" "$entry"
  fi
  if [ -n "$stored" ]; then
    if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
      stored_id=$(task_identity "$stored") || exit $?
      if [ "$stored_id" != "$origin_id" ]; then
        fail "captain-held task $id was held for origin $stored, not $origin; hold a task for $origin or list the right one"
      fi
    fi
    origin_state=recorded
  fi
  printf '%s %s %s\n' "$id" "$how" "$origin_state"
}

command_hold() {
  local id=${1:-} title='' reason='' repo='' origin='' until='' show state existing_title body='' hold_kind hold_set occurrence
  local existing_hold_kind='' existing_held='' preserve_hold_set=0 stored_reason previous_origin='' hold_status=0
  local question='' recommended='' context='' link='' no_options='' category='' call_given=0 call_kind=question instruction='' where='' existing_call_kind
  local -a call_options=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --origin) shift; origin=${1:-} ;;
      --until) shift; until=${1:-} ;;
      --category) shift; category=${1:-} ;;
      --question) shift; question=${1:-}; call_given=1 ;;
      --call-kind) shift; call_kind=${1:-}; call_given=1 ;;
      --instruction) shift; instruction=${1:-}; call_given=1 ;;
      --where) shift; where=${1:-}; call_given=1 ;;
      --option) shift; call_options+=("${1:-}"); call_given=1 ;;
      --recommended) shift; recommended=${1:-}; call_given=1 ;;
      --context) shift; context=${1:-}; call_given=1 ;;
      --link) shift; link=${1:-}; call_given=1 ;;
      --no-options)
        shift; no_options=${1:-}; call_given=1
        [ -n "$no_options" ] || fail "--no-options needs a short reason why the call has no choices"
        ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$reason" ] || fail "reason must not be empty"
  case "$category" in
    product-design|unbacked-destructive|money|credentials-security|captain-only-fact) ;;
    '') refuse_category '--category is required' ;;
    *) refuse_category "unsupported --category: $category" ;;
  esac
  if [ "$call_given" = 1 ]; then
    build_call_json "$id" "$question" "$recommended" "$context" "$link" "$no_options" "$call_kind" "$instruction" "$where" \
      "${call_options[@]+"${call_options[@]}"}"
  fi
  [ "$call_kind" != action ] || [ -z "$until" ] || fail 'an action persists until completion; --until is not allowed'
  # bin/fm-hold-reason-lib.sh owns the storage constraint and reversible encoding.
  stored_reason=$(fm_hold_reason_encode "$reason") || fail "could not encode the hold reason"
  if [ -n "$origin" ]; then
    validate_slug origin-id "$origin"
  fi
  if [ -n "$until" ]; then
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) fail "--until must be a YYYY-MM-DD date: $until" ;;
    esac
  fi
  hold_set=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$hold_set" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "FM_CAPTAIN_HOLD_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  acquire_task_control_lock "$id"
  require_tasks_axi
  if task_show "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    [ "$state" != "done" ] \
      || fail "task $id is already closed; a new captain call needs its own task"
    existing_call_kind=$(call_record_kind "$id") || fail "cannot read the call type for $id"
    if [ "$existing_call_kind" = action ]; then
      [ "$call_given" = 0 ] || [ "$call_kind" = action ] \
        || fail 'an outstanding action cannot become a question; complete the requested action first'
      call_kind=action
    fi
    if [ "$call_kind" = action ]; then
      [ "$(show_field_value "$show" kind)" = captain ] \
        || fail 'an action attention card must be separate from actual work; create a captain call with --origin'
      [ -z "$(show_field_value "$show" hold_until)" ] \
        || fail 'an action cannot inherit a dated question hold; create a separate action call'
    fi
    existing_hold_kind=$(show_field_value "$show" hold_kind)
    existing_held=$(show_field_value "$show" held)
    if [ "$existing_hold_kind" = captain ] && [ "$existing_held" = yes ]; then
      preserve_hold_set=1
    fi
    # Only a repeat of an active hold whose card already has choices may omit
    # the call fields; anything else would open a call with nothing to click.
    if [ "$call_given" = 0 ]; then
      { [ "$preserve_hold_set" = 1 ] \
          && call_record_satisfies "$id" "$(body_hold_set_timestamp "$(show_field_value "$show" body)")"; } \
        || refuse_without_choices "$id" "task $id has no captain call fields"
    fi
    if [ -n "$title" ]; then
      existing_title=$(show_field_value "$show" title)
      [ "$existing_title" = "$title" ] || fail "existing task $id has a different title"
    fi
  else
    [ "$call_given" = 1 ] || refuse_without_choices "$id" "task $id has no captain call fields"
    [ -n "$title" ] || fail "--title is required to create task $id"
    validate_one_line title "$title"
    if [ -z "$repo" ] && [ -n "$origin" ] && [ -f "$STATE/$origin.meta" ]; then
      repo=$(meta_value "$STATE/$origin.meta" project)
      repo=${repo%/}
      repo=${repo##*/}
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    [ -z "$origin" ] || body=$(printf 'Origin: %s' "$origin")
    # tasks-axi add never passes --due. Beads due.required would refuse this
    # create, and captain holds have no due semantics, so waive it for this
    # call only. --kind captain stays metadata; Beads native type is task.
    if [ -n "$body" ]; then
      BD_DUE_REQUIRED=false tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
        || fail "could not create task $id"
    else
      BD_DUE_REQUIRED=false tasks_axi add "$id" "$title" --kind captain --repo "$repo" >/dev/null \
        || fail "could not create task $id"
    fi
  fi
  [ "$call_kind" != action ] || [ -z "$until" ] || fail 'an action persists until completion; --until is not allowed'
  # Publish the timestamp before the captain-hold annotation. A concurrent
  # snapshot may see the harmless stamp by itself, but can never see a newly
  # held task without the timestamp that defines this hold lifecycle's age.
  task_show_or_fail "$id" "task $id disappeared before recording its hold-set stamp"
  write_hold_set_stamp "$id" "$(show_field "$show" body)" "$hold_set" "$preserve_hold_set"
  task_show_or_fail "$id" "task $id disappeared while recording its hold-set stamp"
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id did not retain its hold-set stamp"
  if [ -n "$origin" ]; then
    origin=$(task_identity "$origin") || exit $?
    previous_origin=$(body_hold_origin "$(show_field_value "$show" body)")
    write_hold_origin "$id" "$(show_field "$show" body)" "$origin" || exit $?
  fi
  if [ -n "$until" ]; then
    tasks_axi hold "$id" --reason "$stored_reason" --kind captain --until "$until" >/dev/null \
      || hold_status=$?
  else
    tasks_axi hold "$id" --reason "$stored_reason" --kind captain >/dev/null \
      || hold_status=$?
  fi
  if [ "$hold_status" -ne 0 ]; then
    # A refused re-hold must not associate the previous hold or answer with a
    # new origin. Restore the old line verbatim, without resolving it again.
    if [ -n "$origin" ]; then
      write_hold_origin "$id" "$(show_field "$show" body)" "$previous_origin" || exit $?
    fi
    fail "could not hold task $id for the captain"
  fi
  task_show "$id" || fail "task $id disappeared while holding it"
  show=$TASK_SHOW_OUTPUT
  hold_kind=$(show_field_value "$show" hold_kind)
  [ "$hold_kind" = captain ] || fail "task $id did not retain its captain hold"
  occurrence=$(( $(resolution_record_count "$(show_field "$show" body)") + 1 ))
  hold_set=$(body_hold_set_timestamp "$(show_field_value "$show" body)")
  [ -n "$hold_set" ] || fail "task $id lost its hold-set stamp while being held"
  [ "$call_given" = 0 ] || write_captain_call "$id" "$hold_set"
  publish_parent_hold "$id" "$occurrence" needs-decision "$reason"
  publish_call_event call.opened "$id" "$occurrence"
  printf '%s\n' "$id"
}

# Record a resolution block beneath any leading active hold-set stamp,
# preserving the previous body below it and archiving the pristine original.
# Successful closure removes the stamp to restore resolution-first ordering.
write_resolution_record() {  # <task-id> <mode> <shown-body>
  local id=$1 mode=$2 body=$3 new_body tmp hold_set
  new_body=$(resolution_block "$mode")
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  hold_set=$(body_hold_set_timestamp "$body")
  if [ -n "$hold_set" ]; then
    body=${body#"Captain hold set: $hold_set"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
    new_body=$(printf 'Captain hold set: %s\n\n%s' "$hold_set" "$new_body")
  fi
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-body.XXXXXX") \
    || fail "cannot stage the resolution record"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the resolution record for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the captain decision on $id"
  fi
  rm -f -- "$tmp"
}

report_retained_artifact_failure() {  # <task-id> <marker-path>
  printf 'fm-captain-hold: cannot apply the artifact recorded for %s in %s: %s\n' \
    "$1" "$2" "${FM_BACKLOG_TRANSITION_ERROR:-no reason reported}" >&2
}

apply_pending_retained_artifact() {  # <task-id>
  local id=$1 marker label
  local -a args=()
  RETAINED_CLOSE_ARGS=()
  marker=$(fm_backlog_close_marker_path "$STATE" "$id") || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  fm_backlog_close_marker_validate "$marker" "$DATA" "$id" "$STATE" \
    || { report_retained_artifact_failure "$id" "$marker"; return 1; }
  [ "$FM_BACKLOG_CLOSE_VALIDATED_MODE" = retain ] || return 0
  args=("${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]+"${FM_BACKLOG_CLOSE_VALIDATED_ARGS[@]}"}")
  case "${args[0]-}" in
    --pr|--report)
      if [ "${args[0]}" = --pr ] && label=$(fm_backlog_pr_note_label "${args[1]-}"); then
        RETAINED_CLOSE_ARGS=(--note "$label ${args[1]}")
        return 0
      fi
      fm_backlog_row_artifact_supported "$id" "${args[@]}" || return 0
      fm_backlog_mutate "$DATA" update "$id" "${args[@]}" \
        || { report_retained_artifact_failure "$id" "$marker"; return 1; }
      ;;
  esac
}

close_answered() {  # <task-id> <release-0-or-1>
  if [ "$2" = 1 ]; then
    tasks_axi unhold "$1" >/dev/null
  else
    apply_pending_retained_artifact "$1" || return 1
    tasks_axi "done" "$1" "${RETAINED_CLOSE_ARGS[@]+"${RETAINED_CLOSE_ARGS[@]}"}" >/dev/null
  fi
}

remove_interrupted_answer_stamp() {  # <task-id>
  local id=$1 show body existing tmp
  task_show_or_fail "$id" "task $id disappeared after closing"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the closed body for $id"
  existing=$(body_hold_set_timestamp "$body")
  [ -n "$existing" ] || return 0
  body=${body#"Captain hold set: $existing"}
  case "$body" in
    $'\n\n'*) body=${body#$'\n\n'} ;;
    $'\n'*) body=${body#$'\n'} ;;
  esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-normalize.XXXXXX") \
    || fail "cannot stage the closed body for $id"
  if ! printf '%s\n' "$body" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not restore the resolution record ordering for $id"
  fi
  rm -f -- "$tmp"
}

command_answer() {
  local id=${1:-} decision_file='' release=0 release_in_flight=0 show state hold_kind body outcome recorded_mode occurrence
  local expected='' call_kind completing=${ACTION_COMPLETION:-0} correcting=${ANSWER_CORRECTION:-0}
  local -a attach_files=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --attach) shift; attach_files+=("${1:-}") ;;
      --release) release=1 ;;
      --release-in-flight) release_in_flight=1 ;;
      --expected-identity) shift; expected=${1:-}; validate_one_line expected-identity "$expected" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ "$release" = 0 ] || [ "$release_in_flight" = 0 ] \
    || fail "--release and --release-in-flight are alternatives; pass one"
  validate_slug task-id "$id"
  ALLOW_EMPTY_DECISION=${#attach_files[@]} load_decision "$decision_file"
  acquire_task_control_lock "$id"
  require_tasks_axi
  if [ -n "$expected" ]; then
    guard_expected_identity "$id" "$expected" "$correcting"
  else
    task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  fi
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  call_kind=$(call_record_kind "$id") || fail "cannot read the call type for $id"
  if [ "$call_kind" = action ]; then
    [ "$completing" = 1 ] || fail 'an action needs authoritative completion evidence through complete-action; answering or dismissing is not completion'
    [ "$release$release_in_flight" = 00 ] || fail 'complete-action closes the separate attention card, never actual work'
  else
    [ "$completing" = 0 ] || fail 'complete-action requires an explicit action call'
  fi
  if [ "$correcting" = 1 ]; then
    [ "$release$release_in_flight" = 00 ] || fail 'a correction does not release or reopen work'
    body_has_resolution_record "$body" || fail "task $id has no answer to correct"
    recorded_mode=$(recorded_resolution_mode "$body")
    case "$recorded_mode" in answered|released|repaired|routed|declined) ;; *) fail 'this resolution is not an answer' ;; esac
    [ "$state" = "done" ] || { [ "$recorded_mode" = released ] && [ "$hold_kind" != captain ]; } \
      || fail 'answer the current open question before correcting a previous answer'
    attach_answer_files "$id" "${attach_files[@]+"${attach_files[@]}"}"
    DECISION_TEXT=$(printf 'Corrección de respuesta (no deshace lo ya aplicado):\n%s' "$DECISION_TEXT")
    DECISION_DIGEST=$(sha256_text "$DECISION_TEXT")
    if [ "$(recorded_decision_digest "$body")" = "$DECISION_DIGEST" ]; then
      wake_answer_owner "$id" "$(resolution_record_count "$body")"
      printf 'corrected: %s\n' "$id"
      return 0
    fi
    occurrence=$(( $(resolution_record_count "$body") + 1 ))
    write_resolution_record "$id" "$recorded_mode" "$body"
    wake_answer_owner "$id" "$occurrence"
    printf 'corrected: %s\n' "$id"
    return 0
  fi
  attach_answer_files "$id" "${attach_files[@]+"${attach_files[@]}"}"
  # Read under the control lock with the row the transition acts on.
  if [ "$release_in_flight" = 1 ] && [ "$state" = in_flight ]; then release=1; fi
  if [ "$release" = 1 ]; then outcome=released; else outcome=answered; fi
  [ "$completing" = 0 ] || outcome='action-completed'
  # The occurrence the parent line names: the record about to be written is
  # one past those already in the body, and a retry names the newest one.
  occurrence=$(( $(resolution_record_count "$body") + 1 ))

  if [ "$state" = "done" ]; then
    if body_has_resolution_record "$body"; then
      # An exact compatible retry is an idempotent no-op; drift is rejected.
      [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
        || fail "captain-held task $id records a different captain decision"
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      if [ "$completing" = 1 ]; then
        [ "$recorded_mode" = action-completed ] || fail 'this action has no matching completion record'
      else
        closed_answer_replay_mode_compatible "$recorded_mode" "$body" \
          || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay"
      fi
      [ "$release" = 0 ] \
        || fail "task $id records this answer with mode ${recorded_mode:-unknown}; --release cannot reopen a closed task"
      remove_interrupted_answer_stamp "$id"
      if [ "$completing" = 1 ]; then
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) action-completed
      elif [ "$recorded_mode" = repaired ]; then
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "answered (repaired)"
      else
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) answered
      fi
      printf '%s: %s\n' "$outcome" "$id"
      return 0
    fi
    [ "$release" = 0 ] || fail "task $id is already closed; --release cannot reopen it"
    # Closed outside this script: record the captain's answer retroactively.
    # tasks-axi keeps hold_kind through a close, so it is the surviving proof
    # this really was the captain's item rather than ordinary finished work.
    [ "$hold_kind" = captain ] \
      || fail "task $id was never held for the captain; nothing to record an answer on"
    if [ "$completing" = 1 ]; then recorded_mode='action-completed'; else recorded_mode=repaired; fi
    write_resolution_record "$id" "$recorded_mode" "$body"
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared while recording the answer"
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field "$show" state)" = "done" ] || fail "recording the answer reopened closed task $id"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    if [ "$completing" = 1 ]; then
      publish_parent_resolution_then_retire "$id" "$occurrence" action-completed
      printf 'action-completed: %s\n' "$id"
    else
      publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)"
      printf 'repaired: %s\n' "$id"
    fi
    return 0
  fi

  if [ "$hold_kind" = captain ]; then
    # Actively the captain's item (a date-expired hold keeps its annotations
    # and stays answerable). A matching record means an interrupted close to
    # finish; a different digest is a NEW answer on a re-held task and gets
    # its own record on top. Either way the close mode is the caller's flag
    # (or what --release-in-flight resolved it to above), checked against an interrupted close's recorded mode so a retry cannot
    # silently flip a release into a close.
    if body_has_resolution_record "$body" \
      && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      case "$recorded_mode" in
        action-completed) [ "$completing" = 1 ] || fail 'action completion must replay through complete-action' ;;
        released) [ "$release" = 1 ] || fail "task $id records this answer as a release; retry with --release" ;;
        answered|routed) [ "$release" = 0 ] || fail "task $id records this answer as a close; retry without --release" ;;
        *) fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay" ;;
      esac
      if ! close_answered "$id" "$release"; then
        fail "could not close answered captain-held task $id"
      fi
      remove_interrupted_answer_stamp "$id"
      publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "$outcome"
      printf '%s: %s\n' "$outcome" "$id"
      return 0
    fi
    write_resolution_record "$id" "$outcome" "$body"
    if ! close_answered "$id" "$release"; then
      fail "could not close answered captain-held task $id"
    fi
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared after closing"
    show=$TASK_SHOW_OUTPUT
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "$outcome"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi

  # Not held and not closed: only an already-recorded release replays cleanly.
  if body_has_resolution_record "$body"; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different captain decision with mode ${recorded_mode:-unknown}"
    [ "$recorded_mode" = released ] && [ "$release" = 1 ] \
      || fail "task $id records this answer with mode ${recorded_mode:-unknown}; replay requires matching --release"
    remove_interrupted_answer_stamp "$id"
    publish_parent_resolution_then_retire "$id" $((occurrence - 1)) released
    printf 'released: %s\n' "$id"
    return 0
  fi
  fail "task $id is not held for the captain; hold it first or name the right task"
}

command_complete_action() {
  local id=${1:-} evidence='' expected=''
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence-file) shift; evidence=${1:-} ;;
      --expected-identity) shift; expected=${1:-}; validate_one_line expected-identity "$expected" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$evidence" ] || fail 'complete-action requires --evidence-file recording authoritative completion of the requested human action'
  if [ -n "$expected" ]; then
    ACTION_COMPLETION=1 command_answer "$id" --decision-file "$evidence" --expected-identity "$expected"
  else
    ACTION_COMPLETION=1 command_answer "$id" --decision-file "$evidence"
  fi
}

# Predicate for the ordinary backlog writer: a generic close/unhold must not
# dismiss an explicit action. Unknown records fail closed; no inbox/read ACK
# or private call read changes the requested action's lifecycle.
command_action_pending() {  # <task-id>: 0 pending action, 1 other/completed, 2 unknown
  [ "$#" -eq 1 ] || return 2
  local id=$1 kind body
  validate_slug task-id "$id"
  kind=$(call_record_kind "$id") || return 2
  [ "$kind" = action ] || return 1
  require_tasks_axi
  task_show "$id" || return 2
  body=$(show_field "$TASK_SHOW_OUTPUT" body)
  if [ "$(show_field "$TASK_SHOW_OUTPUT" state)" = 'done' ] \
    && { [ "$(recorded_resolution_mode "$body" || true)" = action-completed ] \
      || [ "$(recorded_resolution_mode "$body" || true)" = reconciled ]; }; then return 1; fi
  return 0
}

# Read a complete, backend-neutral dependency graph, never truncated titles or
# the unresolved-only blocked_by view (which loses edges through Done rows).
moot_graph() {
  local data listing graph archived root backend archive secs=${FM_BACKLOG_ROW_TIMEOUT_SECS:-10}
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  listing=$(fm_run_timed "$secs" env FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
    bash "$SCRIPT_DIR/fm-tasks-axi.sh" list --fields deps,hold_kind) || return 1
  graph=$(printf '%s\n' "$listing" | parse_moot_graph) || return 1
  root=$(fm_backlog_root "$data") || return 1
  backend=$(fm_tasks_axi_backend "$root") || return 1
  if [ "$backend" = markdown ]; then
    archive=$(captain_markdown_archive_path) || return 1
    if [ -e "$archive" ] || [ -L "$archive" ]; then
      task_show_archived --list || return 1
      archived=$(printf '%s\n' "$TASK_SHOW_OUTPUT" | parse_moot_graph) || return 1
      # A current row always wins over its older archived incarnations.
      graph=$(printf '%s\n%s\n' "$archived" "$graph" | jq -cs add) || return 1
    fi
  fi
  printf '%s\n' "$graph"
}

parse_moot_graph() {
  python3 -c '
import csv, json, re, sys
lines = sys.stdin.read().splitlines()
header = next((i for i, line in enumerate(lines) if re.fullmatch(r"tasks\[\d+\]\{id,state,kind,repo,title,deps,hold_kind\}:", line)), None)
if header is None:
    raise ValueError("missing canonical dependency listing")
count = int(re.search(r"\[(\d+)\]", lines[header])[1])
rows = {}
slug = re.compile(r"[A-Za-z0-9._-]+")
for line in lines[header + 1:header + 1 + count]:
    if not line.startswith("  "):
        raise ValueError("incomplete canonical dependency listing")
    fields = next(csv.reader([line[2:]], escapechar="\\", strict=True))
    if len(fields) != 7:
        raise ValueError("invalid canonical dependency row")
    task, state, kind, _, _, deps, hold = fields
    if not slug.fullmatch(task) or task in rows or state not in ("queued", "in_flight", "done"):
        raise ValueError("invalid canonical task identity/state")
    blockers = []
    for edge in ([] if deps == "none" else deps.split(",")):
        if edge.startswith("blocked-by:"):
            blocker = edge[len("blocked-by:"):]
            if not slug.fullmatch(blocker):
                raise ValueError("invalid canonical dependency")
            blockers.append(blocker)
    rows[task] = dict(state=state, kind=kind, hold_kind=hold, blockers=blockers)
if len(rows) != count:
    raise ValueError("incomplete canonical dependency listing")
print(json.dumps(rows, sort_keys=True))
'
}

moot_ineligible() {
  printf 'kept: %s (%s)\n' "$1" "$2" >&2
  return 3
}

command_retire_moot() {
  local id=${1:-} superseded='' evidence_file='' supplied='' graph show body origin gated occurrence mode saved hold_set
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --superseded-by) shift; superseded=${1:-}; validate_slug superseding-task "$superseded" ;;
      --evidence-file) shift; evidence_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  if [ -n "$superseded" ] || [ -n "$evidence_file" ]; then
    [ -n "$superseded" ] && [ -n "$evidence_file" ] \
      || fail 'explicit supersession requires --superseded-by and --evidence-file together'
    [ "$superseded" != "$id" ] || fail 'a call cannot supersede itself'
    load_decision "$evidence_file"
    supplied=$DECISION_TEXT
  fi
  acquire_task_control_lock "$id"
  require_tasks_axi
  task_show_or_fail "$id" "captain call $id is absent"
  body=$(show_field "$show" body)
  mode=$(recorded_resolution_mode "$body" || true)
  hold_set=$(body_hold_set_timestamp "$(show_field_value "$show" body)")
  # A saved retirement is retryable even if a later lifecycle changed the graph;
  # any other saved answer always belongs to its existing owner, never this sweep.
  if body_has_resolution_record "$body"; then
    saved=$(show_field_value "$show" body | awk '/^Resolution recorded by fm-(captain|decision)-hold\.$/ { n++; if (n > 1) exit } { print }')
    if [ "$mode" != reconciled ] || ! [[ "$saved" == *'Moot retirement evidence (fm-captain-hold.v1)'* ]]; then
      moot_ineligible "$id" 'a recorded answer/resolution must be preserved'; return 3
    fi
    occurrence=$(resolution_record_count "$body")
    if [ "$(show_field "$show" state)" != 'done' ]; then
      # Re-verify before completing a saved but interrupted close.
      [ "$(show_field_value "$show" hold_kind)" = captain ] || { moot_ineligible "$id" 'no active captain hold'; return 3; }
      [ -n "$hold_set" ] && [ "$(printf '%s\n' "$saved" | sed -n 's/^Moot hold set: //p' | head -1)" = "$hold_set" ] \
        || { moot_ineligible "$id" 'the saved retirement belongs to an earlier hold'; return 3; }
      if [ -z "$superseded" ]; then
        superseded=$(printf '%s\n' "$saved" | sed -n 's/^Explicitly superseded by: //p' | head -1)
      fi
    else
      remove_interrupted_answer_stamp "$id"
      publish_parent_hold "$id" "$occurrence" resolved reconciled
      [ "$PARENT_HOLD_PUBLISHED" = 1 ] || fail "cannot publish retirement of $id"
      reconcile_request_retire "$id"
      printf 'retired-moot: %s\n' "$id"
      return 0
    fi
  fi
  [ "$(show_field "$show" state)" = queued ] \
    && [ "$(show_field_value "$show" kind)" = captain ] \
    && [ "$(show_field_value "$show" hold_kind)" = captain ] \
    || { moot_ineligible "$id" 'not a separate queued captain call'; return 3; }
  # Validate the record even though both supported call kinds retire alike.
  call_record_kind "$id" >/dev/null || fail "cannot verify call kind for $id"
  origin=$(body_hold_origin "$(show_field_value "$show" body)")
  [ -n "$origin" ] && [ "$origin" != "$id" ] \
    || { moot_ineligible "$id" 'no separate verifiable origin'; return 3; }
  graph=$(moot_graph) || fail 'cannot verify the complete canonical work graph'
  gated=$(printf '%s' "$graph" | jq -cer --arg id "$id" '
    . as $g | def descendants($seen):
      [$g | to_entries[] | select(any(.value.blockers[]; . as $b | $seen | index($b))) | .key] as $next
      | ($seen + $next | unique) as $all
      | if $all == $seen then $all else descendants($all) end;
    def cyclic($node; $path; $scope):
      if ($path | index($node)) != null then true
      else any($g[$node].blockers[]; . as $b
        | if ($scope | index($b)) != null then cyclic($b; $path + [$node]; $scope) else false end)
      end;
    (descendants([$id]) - [$id]) as $work
    | {tasks: $work, all_done: all($work[]; $g[.].state == "done"),
       circular: any(($work + [$id])[]; cyclic(.; []; $work + [$id]))}
  ') || fail 'cannot verify gated work'
  [ "$(printf '%s' "$gated" | jq -r .circular)" = false ] \
    || { moot_ineligible "$id" 'the gated graph contains a cycle'; return 3; }
  [ "$(printf '%s' "$gated" | jq -r .all_done)" = true ] \
    || { moot_ineligible "$id" 'gated work remains open'; return 3; }
  if [ -n "$superseded" ]; then
    task_show "$superseded" || { moot_ineligible "$id" 'superseding task is unavailable'; return 3; }
  else
    [ "$(printf '%s' "$gated" | jq '.tasks | length')" -gt 0 ] \
      || { moot_ineligible "$id" 'no gated work proves this standalone call moot'; return 3; }
    # The graph already merges canonical current and archived rows with current
    # state winning. Never replace a failed current read with an older Done row.
    [ "$(printf '%s' "$graph" | jq -r --arg origin "$origin" '.[$origin].state // "unknown"')" = 'done' ] \
      || { moot_ineligible "$id" 'origin work remains open or unavailable'; return 3; }
  fi
  # Refresh the call after dependency reads. The task and work locks cover the
  # proof and the close, while a direct backend mutation remains unsupported.
  task_show_or_fail "$id" "captain call $id disappeared"
  body=$(show_field "$show" body)
  if ! body_has_resolution_record "$body"; then
    DECISION_TEXT=$(printf 'Moot retirement evidence (fm-captain-hold.v1)\nMoot hold set: %s\nVerified at: %s\nOrigin: %s\nOrigin state: %s\nGated work (all Done): %s' \
      "$hold_set" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$origin" "$(if [ -n "$superseded" ]; then printf superseded; else printf 'done'; fi)" \
      "$(printf '%s' "$gated" | jq -r '.tasks | join(", ")')")
    if [ -n "$superseded" ]; then
      DECISION_TEXT=$(printf '%s\nExplicitly superseded by: %s\nSupersession evidence:\n%s' "$DECISION_TEXT" "$superseded" "$supplied")
    fi
    DECISION_DIGEST=$(sha256_text "$DECISION_TEXT")
    write_resolution_record "$id" reconciled "$body"
  fi
  # write_resolution_record does not refresh TASK_SHOW_OUTPUT.
  task_show_or_fail "$id" "captain call $id disappeared after recording evidence"
  occurrence=$(resolution_record_count "$(show_field "$show" body)")
  close_answered "$id" 0 || fail "could not close moot captain call $id; retry retire-moot"
  remove_interrupted_answer_stamp "$id"
  task_show_or_fail "$id" "captain call $id disappeared after retirement"
  if [ "$(show_field "$show" state)" != 'done' ] || ! body_has_resolution_record "$(show_field "$show" body)"; then
    fail "retirement of $id was not retained"
  fi
  publish_parent_hold "$id" "$occurrence" resolved reconciled
  [ "$PARENT_HOLD_PUBLISHED" = 1 ] || fail "cannot publish retirement of $id"
  reconcile_request_retire "$id"
  printf 'retired-moot: %s\n' "$id"
}

command_sweep_moot() {
  local graph ids id output rc failed=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_tasks_axi
  graph=$(moot_graph) || fail 'cannot read canonical calls for moot retirement'
  ids=$(printf '%s' "$graph" | jq -r 'to_entries[] | select(.value.state == "queued" and .value.kind == "captain" and .value.hold_kind == "captain") | .key')
  for id in $ids; do
    rc=0
    output=$(bash "$0" retire-moot "$id" 2>&1) || rc=$?
    case "$rc" in
      0) printf '%s\n' "$output" ;;
      3) : ;;
      *) printf 'moot-retirement failed for %s: %s\n' "$id" "$output" >&2; failed=1 ;;
    esac
  done
  return "$failed"
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The stored binding value, or empty when the source is unbound. An unreadable
# or wrong-schema record is a hard error rather than a silent "unbound":
# feeding nothing is the safe direction only when it is a deliberate choice,
# never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  if [ "$origin" != "$BINDING_ANY" ]; then
    case "$origin" in
      ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
    esac
  fi
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  if [ -z "$origin" ] || [ "$origin" = --any-origin ]; then
    origin=$BINDING_ANY
  else
    validate_slug legacy-origin "$origin"
  fi
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <task-id> <answer> <label>
  printf 'Captain answered this call through %s.\n' "$1"
  printf 'Task: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

legacy_keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

sanitize_reconcile_provenance() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-1024
}

# New guarded callers never enter the legacy replay shortcut, which can publish
# a wake without calling answer. The existing transition owns the only lock.
command_guarded_answers() {  # <origin> <source> <expected-identity>
  local origin=$1 source=$2 expected=$3 row rest key answer label mode='' tmp rc=0 tab=$'\t' release_flag=''
  [ -z "$origin" ] || [ "$origin" = "$BINDING_ANY" ] || invalid_guarded_input
  read_guarded_row
  row=$GUARDED_ROW
  key=${row%%"$tab"*}
  case "$key" in ''|*[!A-Za-z0-9._-]*) invalid_guarded_input ;; esac
  [ "${#key}" -le 128 ] || invalid_guarded_input
  case "$row" in *"$tab"*) rest=${row#*"$tab"} ;; *) invalid_guarded_input ;; esac
  answer=${rest%%"$tab"*}
  case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) invalid_guarded_input ;; esac
  label=${rest%%"$tab"*}
  case "$rest" in *"$tab"*) mode=${rest#*"$tab"} ;; esac
  case "$mode" in *"$tab"*) invalid_guarded_input ;; esac
  answer=$(sanitize_field "$answer")
  label=$(sanitize_field "$label")
  [ -n "$answer" ] && [ "$answer" != "$RECONCILE_VALUE" ] || invalid_guarded_input
  case "$mode" in
    '') release_flag=--release-in-flight ;;
    done) ;;
    release) release_flag=--release ;;
    *) invalid_guarded_input ;;
  esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  keyed_decision_text "$source" "$key" "$answer" "$label" > "$tmp" \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision for $key"; }
  # shellcheck disable=SC2086  # Empty or one literal flag, including on Bash 3.2.
  bash "$0" answer "$key" --decision-file "$tmp" $release_flag \
    --expected-identity "$expected" </dev/null >/dev/null || rc=$?
  rm -f -- "$tmp"
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'closed: %s\nanswers: closed=1 skipped=0\n' "$key"
}

command_answers() {
  local origin='' source='' row rest key answer label mode id show state hold_kind body digest legacy_digest legacy_key
  local recorded_digest recorded_mode occurrence tmp err closed=0 skipped=0 reason release_flag tab=$'\t'
  local resolve_rc expected='' answer_flag
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      --expected-identity) shift; expected=${1:-}; validate_one_line expected-identity "$expected" ;;
      --any-origin) origin=$BINDING_ANY ;;
      --*) usage >&2; exit 2 ;;
      *)
        [ -z "$origin" ] || { usage >&2; exit 2; }
        origin=$1
        ;;
    esac
    shift
  done
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    validate_slug legacy-origin "$origin"
  fi
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  if [ -n "$expected" ]; then
    command_guarded_answers "$origin" "$source" "$expected"
    return $?
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS= read -r row; do
    key=${row%%"$tab"*}
    rest=''
    case "$row" in *"$tab"*) rest=${row#*"$tab"} ;; esac
    answer=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    label=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) mode=${rest#*"$tab"} ;; *) mode='' ;; esac
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 128 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    if [ "$answer" = "$RECONCILE_VALUE" ]; then
      printf 'refused: %s (reconcile requests require a bound captured source)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    release_flag=''
    answer_flag=''
    case "${mode:-}" in
      '') answer_flag=--release-in-flight ;;
      done) : ;;
      release) release_flag=--release ;;
      *)
        printf 'skipped: %s (unknown close mode %s)\n' "$key" "$(sanitize_field "$mode")"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    resolve_rc=0
    id=$(resolve_entry "$origin" "$key" 2>"$err") || resolve_rc=$?
    id=${id%% *}
    if [ "$resolve_rc" = 2 ]; then
      reason=$(tr -d '\n' < "$err")
      printf 'skipped: %s (migrated-hold scan refused%s)\n' "$key" "${reason:+: $reason}"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$resolve_rc" -ne 0 ]; then
      # resolve_entry runs in a command substitution, so task_show's exit
      # cannot stop this loop; only its status crosses back. 124 means the
      # backend never answered, which is not the same as an unknown key and
      # must not be spent as a skip.
      [ "$resolve_rc" -ne 124 ] \
        || fail "the backlog backend exceeded its read bound resolving $key"
      printf 'skipped: %s (no captain-held task with that id)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    keyed_decision_text "$source" "$id" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $id"
    digest=$(sha256_text "$(cat "$tmp")")
    legacy_digest=''
    if [ "$id" != "$key" ]; then
      legacy_key=$key
    elif { [ -z "$origin" ] || [ "$origin" = "$BINDING_ANY" ]; } \
      && [ "${id#*-decision-}" != "$id" ]; then
      legacy_key=${id#*-decision-}
    else
      legacy_key=''
    fi
    if [ -n "$legacy_key" ]; then
      legacy_digest=$(sha256_text "$(legacy_keyed_decision_text "$source" "$legacy_key" "$answer" "$label")")
    fi
    task_show "$id" || { printf 'skipped: %s (absent)\n' "$id"; skipped=$((skipped + 1)); continue; }
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    hold_kind=$(show_field_value "$show" hold_kind)
    body=$(show_field "$show" body)
    recorded_digest=$(recorded_decision_digest "$body" || true)
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    # An undeclared close replays as the close `answer` resolves it to.
    if [ "$answer_flag" = --release-in-flight ] && [ "$state" = in_flight ]; then
      release_flag=--release
    fi
    [ -n "$answer_flag" ] || answer_flag=$release_flag
    if body_has_resolution_record "$body" \
      && { [ "$recorded_digest" = "$digest" ] \
        || { case "$body" in *"Resolution recorded by fm-decision-hold."*) true ;; *) false ;; esac \
          && [ -n "$legacy_digest" ] && [ "$recorded_digest" = "$legacy_digest" ]; }; }; then
      if { [ -z "$release_flag" ] && [ "$state" = "done" ] \
          && closed_answer_replay_mode_compatible "$recorded_mode" "$body"; } \
        || { [ "$release_flag" = --release ] && [ "$state" != "done" ] \
          && [ "$hold_kind" != captain ] && [ "$recorded_mode" = released ]; }; then
        occurrence=$(resolution_record_count "$body")
        case "$recorded_mode" in
          repaired) publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)" ;;
          released) publish_parent_resolution_then_retire "$id" "$occurrence" released ;;
          *) publish_parent_resolution_then_retire "$id" "$occurrence" answered ;;
        esac
        printf 'closed: %s\n' "$id"
        closed=$((closed + 1))
        continue
      fi
    fi
    if [ "$state" = "done" ]; then
      printf 'skipped: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$hold_kind" != captain ]; then
      printf 'skipped: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    # shellcheck disable=SC2086  # answer_flag is empty or a single literal flag.
    if "$0" answer "$id" --decision-file "$tmp" $answer_flag </dev/null >/dev/null 2>"$err"; then
      # A parent-channel delivery problem is reported on stderr by the answer
      # path even when the close succeeded; keep it visible.
      [ ! -s "$err" ] || cat "$err" >&2
      printf 'closed: %s\n' "$id"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-captain-hold: //')
      printf 'skipped: %s (%s)\n' "$id" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s skipped=%s\n' "$closed" "$skipped"
  [ "$skipped" -eq 0 ]
}

# --- reconcile: verify latest state, then close with evidence or annotate ----
#
# The semantics are owned by docs/captain-hold-lifecycle.md; this section owns
# the durable record and the two terminal operations that retire it. Nothing
# here closes a captain call on the strength of a reconcile alone: `close`
# demands the evidence that made the call moot, and `note` leaves it open.

RECONCILE_DIR="$STATE/reconcile-requests"
RECONCILE_SCHEMA=fm-reconcile-request.v1
RECONCILE_VALUE=reconcile

reconcile_request_path() { printf '%s/%s.request\n' "$RECONCILE_DIR" "$1"; }

# Idempotent per task: a repeated reconcile keeps the one request and its
# original timestamp, so a re-delivered board answer never resets the clock on
# an obligation that is already open.
reconcile_request_record() {  # <task-id> <provenance>
  local id=$1 source=$2 path tmp
  path=$(reconcile_request_path "$id")
  [ ! -e "$path" ] || return 0
  (umask 077; mkdir -p "$RECONCILE_DIR") || return 1
  [ -d "$RECONCILE_DIR" ] && [ ! -L "$RECONCILE_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$RECONCILE_DIR/.request.XXXXXX") || return 1
  if {
    printf 'schema=%s\n' "$RECONCILE_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'requested=%s\n' "${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf 'source=%s\n' "$(sanitize_reconcile_provenance "$source")"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

reconcile_request_read() {  # <task-id>; sets RECONCILE_REQUESTED/RECONCILE_SOURCE
  local id=$1 path schema task
  path=$(reconcile_request_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$RECONCILE_SCHEMA" ] || fail "reconcile request has an incompatible schema: $path"
  task=$(sed -n 's/^task=//p' "$path" | head -1)
  [ "$task" = "$id" ] || fail "reconcile request names a different task: $path"
  RECONCILE_REQUESTED=$(sed -n 's/^requested=//p' "$path" | head -1)
  RECONCILE_SOURCE=$(sed -n 's/^source=//p' "$path" | head -1)
}

reconcile_request_retire() {  # <task-id>
  rm -f -- "$(reconcile_request_path "$1")" \
    || fail "could not retire the pending reconcile request for $1"
}

publish_parent_resolution_then_retire() {  # <task-id> <occurrence> <note>
  local id=$1 occurrence=$2 note=$3 request
  request=$(reconcile_request_path "$id")
  publish_parent_hold "$id" "$occurrence" resolved "$note"
  if [ -e "$request" ] && [ "$PARENT_HOLD_PUBLISHED" != 1 ]; then
    fail "could not publish the answered captain-held task $id to its parent"
  fi
  reconcile_request_retire "$id"
  wake_answer_owner "$id" "$occurrence"
  publish_call_event call.resolved "$id" "$occurrence"
}

wake_answer_owner() {  # <task-id> <resolution-occurrence>
  local id=$1 occurrence=$2 key rc=0 body origin mode digest request note receipt
  key="captain-answer:$id:$occurrence"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || fail "answer recorded for $id but owner wake lock failed; retry this answer"
  if ! fm_wake_queued_carries_locked check "$key" 'check: captain-answer '; then
    fm_wake_append_locked check "$key" \
      "check: captain-answer task=$id occurrence=$occurrence; owner=firstmate; read the durable resolution with bin/fm-tasks-axi.sh show $id --full, act or relay through fm-send --resolve-key, then acknowledge this wake" || rc=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || rc=1
  [ "$rc" -eq 0 ] || fail "answer recorded for $id but owner wake failed; retry this answer"
  # The question is settled; a separate ordinary inbox receipt tracks the
  # primary's remaining application/review without asking the captain again.
  task_show "$id" || fail "answer recorded for $id but its application receipt could not read the resolution"
  body=$(show_field "$TASK_SHOW_OUTPUT" body)
  origin=$(body_hold_origin "$(show_field_value "$TASK_SHOW_OUTPUT" body)")
  mode=$(recorded_resolution_mode "$body") || fail "answer recorded for $id but its resolution mode is unreadable"
  digest=$(recorded_decision_digest "$body") || fail "answer recorded for $id but its digest is unreadable"
  request="captain-answer:$(sha256_text "$key")"
  note=$(jq -cn --arg id "$id" --arg origin "$origin" --arg mode "$mode" --arg digest "$digest" \
    --argjson occurrence "$occurrence" \
    '{schema:"fm-captain-answer-note.v1",task_id:$id,origin:$origin,occurrence:$occurrence,mode:$mode,digest:$digest,
      instruction:"The durable resolution is already recorded. Read it before asking again. A correction is a new message, never an undo of applied work; relay it through the active task chat. Review or apply it to the originating work through the primary owner, preserve policy review, and reply to this note with the actual handling outcome. Pending application is not an unanswered question."}') \
    || fail "answer recorded for $id but its application receipt could not be staged"
  receipt=$(printf '%s' "$note" | bash "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$request" --json --wake-primary -) \
    || fail "answer recorded for $id but its application note was not announced; retry the same answer"
  [ "$(printf '%s' "$receipt" | jq -r '.saved')" = true ] \
    || fail "answer recorded for $id but its application note receipt was not confirmed"
}

wake_reconcile_owner() {  # <task-id>
  local id=$1 key rc=0
  key="captain-reconcile:$id"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || fail "reconcile request recorded for $id but owner wake lock failed; retry this request"
  if ! fm_wake_queued_carries_locked check "$key" 'check: captain-reconcile '; then
    fm_wake_append_locked check "$key" \
      "check: captain-reconcile task=$id; owner=firstmate; read bin/fm-captain-hold.sh reconcile list, verify the premise, then use reconcile close --evidence-file or reconcile note --note-file; preserve the hold pending verification, never treat Reconcile as an answer; acknowledge after handling" || rc=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || rc=1
  [ "$rc" -eq 0 ] || fail "reconcile request recorded for $id but owner wake failed; retry this request"
}

command_reconcile_requests() {
  local source_id='' source='' origin row id note provenance show show_status=0 created=0 skipped=0 tab=$'\t'
  local expected=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) shift; source_id=${1:-} ;;
      --source) shift; source=${1:-} ;;
      --expected-identity) shift; expected=${1:-}; validate_one_line expected-identity "$expected" ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_source_id "$source_id"
  [ -n "$source" ] || fail "--source provenance is required"
  origin=$(read_binding "$source_id") || fail "cannot verify the binding for source $source_id"
  [ -n "$origin" ] || fail "source $source_id is not bound; no reconcile requests were created"
  require_tasks_axi
  if [ -n "$expected" ]; then
    read_guarded_row
    row=$GUARDED_ROW
    id=${row%%"$tab"*}
    note=''
    case "$row" in *"$tab"*) note=${row#*"$tab"} ;; esac
    case "$id" in ''|*[!A-Za-z0-9._-]*) invalid_guarded_input ;; esac
    [ "${#id}" -le 128 ] || invalid_guarded_input
    case "$note" in *"$tab"*) invalid_guarded_input ;; esac
    acquire_task_control_lock "$id"
    guard_expected_identity "$id" "$expected"
    provenance=$source
    [ -z "$note" ] || provenance="$source; captain note: $(sanitize_field "$note")"
    reconcile_request_record "$id" "$provenance" || fail "cannot record the reconcile request for $id"
    wake_reconcile_owner "$id"
    printf 'reconcile: %s\nreconcile-requests: created=1 skipped=0\n' "$id"
    return 0
  fi
  while IFS= read -r row; do
    id=${row%%"$tab"*}
    note=''
    case "$row" in *"$tab"*) note=${row#*"$tab"} ;; esac
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*) printf 'refused: %s (invalid task id)\n' "$id"; skipped=$((skipped + 1)); continue ;;
    esac
    [ "${#id}" -le 128 ] \
      || { printf 'refused: %s (task id is too long)\n' "$id"; skipped=$((skipped + 1)); continue; }
    acquire_task_control_lock "$id"
    show_status=0
    show=''
    task_show "$id" || show_status=$?
    [ "$show_status" -ne 0 ] || show=$TASK_SHOW_OUTPUT
    if [ "$show_status" -eq 124 ]; then
      fail "the backlog backend exceeded its read bound reading $id"
    fi
    if [ -z "$show" ]; then
      printf 'refused: %s (absent)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field "$show" state)" = "done" ]; then
      printf 'refused: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field_value "$show" hold_kind)" != captain ]; then
      printf 'refused: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
    else
      provenance=$source
      [ -z "$note" ] || provenance="$source; captain note: $(sanitize_field "$note")"
      if reconcile_request_record "$id" "$provenance"; then
        wake_reconcile_owner "$id"
        printf 'reconcile: %s\n' "$id"
        created=$((created + 1))
      else
        printf 'refused: %s (cannot record the reconcile request)\n' "$id"
        skipped=$((skipped + 1))
      fi
    fi
    release_task_control_lock || fail "cannot release task control for $id"
  done
  printf 'reconcile-requests: created=%s skipped=%s\n' "$created" "$skipped"
  [ "$skipped" -eq 0 ]
}

command_reconcile() {
  local action=${1:-}
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$action" in
    list)    reconcile_list "$@" ;;
    close)   reconcile_close "$@" ;;
    note)    reconcile_note "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

reconcile_list() {
  local path id count=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$RECONCILE_DIR" ] || { printf 'reconcile-requests: 0\n'; return 0; }
  for path in "$RECONCILE_DIR"/*.request; do
    [ -e "$path" ] || continue
    id=${path##*/}; id=${id%.request}
    RECONCILE_REQUESTED=''
    RECONCILE_SOURCE=''
    reconcile_request_read "$id" || continue
    printf '%s\trequested=%s\tsource=%s\n' "$id" "$RECONCILE_REQUESTED" "$RECONCILE_SOURCE"
    count=$((count + 1))
  done
  printf 'reconcile-requests: %s\n' "$count"
}

# The moot outcome. The evidence is what closes the call, and the `reconciled`
# resolution mode is what keeps the record from claiming the captain answered.
reconcile_close() {
  local id=${1:-} evidence_file='' show state hold_kind body occurrence recorded_mode
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence-file) shift; evidence_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$evidence_file" ] || fail "--evidence-file is required; a moot call closes on evidence, never on assertion"
  load_decision "$evidence_file"
  acquire_task_control_lock "$id"
  [ "$(call_record_kind "$id")" != action ] || fail 'an action must complete through complete-action, not reconciliation or dismissal'
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  occurrence=$(( $(resolution_record_count "$body") + 1 ))
  if [ "$state" = "done" ]; then
    # An exact retry finishes an interrupted close and stays idempotent; a
    # different evidence text on an already closed call is refused.
    body_has_resolution_record "$body" \
      || fail "task $id is already closed with no resolution record; use answer to record what closed it"
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different resolution; it cannot be reconciled again"
    [ "$(recorded_resolution_mode "$body" || true)" = reconciled ] \
      || fail "task $id was not closed by reconciliation"
    occurrence=$(resolution_record_count "$body")
    remove_interrupted_answer_stamp "$id"
    publish_parent_hold "$id" "$occurrence" resolved reconciled
    [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
      || fail "could not publish the reconciled captain-held task $id to its parent"
    reconcile_request_retire "$id"
    printf 'reconciled: %s\n' "$id"
    return 0
  fi
  [ "$hold_kind" = captain ] \
    || fail "task $id is not held for the captain; there is no captain call to reconcile"
  if body_has_resolution_record "$body" \
    && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$recorded_mode" = reconciled ] \
      || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a reconciliation retry"
    occurrence=$(resolution_record_count "$body")
  else
    write_resolution_record "$id" reconciled "$body"
  fi
  close_answered "$id" 0 || fail "could not close reconciled captain-held task $id"
  remove_interrupted_answer_stamp "$id"
  task_show_or_fail "$id" "task $id disappeared after closing"
  body_has_resolution_record "$(show_field "$show" body)" \
    || fail "captain-held task $id did not retain its durable resolution record"
  publish_parent_hold "$id" "$occurrence" resolved reconciled
  [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
    || fail "could not publish the reconciled captain-held task $id to its parent"
  reconcile_request_retire "$id"
  printf 'reconciled: %s\n' "$id"
}

# The still-active outcome. The hold survives, so the call stays the captain's
# and stays on Captain's Call, now carrying what the re-check found.
reconcile_note() {
  local id=${1:-} note_file='' note show body stamp tmp note_digest marker
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-file) shift; note_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$note_file" ] || fail "--note-file is required; leaving a call open records what the re-check found"
  [ -f "$note_file" ] || fail "note file does not exist: $note_file"
  note=$(cat "$note_file")
  [ -n "$note" ] || fail "note file must not be empty"
  [ "$(printf '%s' "$note" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "note file exceeds 8192 bytes"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  command_open "$id" \
    || fail "task $id is not an open captain call; a note cannot keep a closed call open"
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  note_digest=$(sha256_text "$note")
  marker="Reconcile request: $RECONCILE_REQUESTED | $RECONCILE_SOURCE | note digest: $note_digest"
  case "$body" in
    *"$marker"*)
      reconcile_request_retire "$id" \
        || fail "could not retire the applied reconcile request for $id"
      command_open "$id" || fail "recording the reconcile note released captain-held task $id"
      printf 'still-open: %s\n' "$id"
      return 0
      ;;
  esac
  stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-note.XXXXXX") \
    || fail "cannot stage the reconcile note"
  if ! printf '%s\n\nCaptain hold reconciled: %s\n%s\n%s\n' "$body" "$stamp" "$marker" "$note" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the reconcile note for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the reconcile note on $id"
  fi
  rm -f -- "$tmp"
  reconcile_request_retire "$id" \
    || fail "could not retire the applied reconcile request for $id"
  command_open "$id" || fail "recording the reconcile note released captain-held task $id"
  printf 'still-open: %s\n' "$id"
}

command_complete() {
  local origin=${1:-} meta previous='' supplied='' keys='' entry key status_file open has_meta=0 transfer_rc transfers=() resolved
  local resolved_how attested_by_prefix='' origin_state unrecorded_origin=''
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] && has_meta=1
  if [ "$has_meta" = 1 ]; then
    CAPTAIN_META_LOCK=$(fm_meta_lock_path "$meta") || fail "could not resolve task metadata lock"
    fm_lock_acquire_wait "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=1
    [ -f "$meta" ] || fail "task metadata disappeared while recording completion"
  fi
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with task ids"
      validate_slug task-id "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  if [ "$has_meta" = 1 ]; then
    previous=$(meta_value "$meta" decision_keys)
  fi
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      resolved=$(verify_entry_durable "$origin" "$entry") || exit $?
      origin_state=${resolved##* }
      resolved=${resolved% *}
      resolved_how=${resolved##* }
      resolved=${resolved%% *}
      if [ "$origin_state" = unrecorded ]; then
        unrecorded_origin="${unrecorded_origin}${unrecorded_origin:+ }$resolved"
      fi
      if [ "$resolved_how" = migrated-prefix ]; then
        attested_by_prefix="${attested_by_prefix}${attested_by_prefix:+ }$entry=$resolved"
      fi
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  open=$(status_open_decisions "$status_file")
  if [ -n "$open" ] && [ -z "$keys" ]; then
    fail "origin $origin still has open captain decisions in its status stream; hold a captain task for what remains, or answer them, before attesting --none"
  fi

  if [ "$has_meta" = 1 ]; then
    if [ "$(meta_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$meta"
    fi
    fm_lock_release "$CAPTAIN_META_LOCK"
    CAPTAIN_META_LOCK_HELD=0

    # Transfer every still-open status decision to the durable captain-held
    # inventory so the live status fold does not duplicate the same Captain's
    # Call item. The transfer lines are this home's own bookkeeping closes,
    # written by the turn that just reviewed the inventory, so they go through
    # ONE guarded self-announced append (bin/fm-wake-lib.sh) and do not wake
    # this same session; an append failure still fails this command loudly.
    if [ -n "$keys" ]; then
      while IFS=$'\t' read -r key _verb _summary; do
        [ -n "$key" ] || continue
        transfers+=("captain-held [key=$key]: tracked by $keys")
      done <<EOF
$open
EOF
      if [ "${#transfers[@]}" -gt 0 ]; then
        transfer_rc=0
        fm_wake_status_append_self_announced "$STATE" "$status_file" "${transfers[@]}" || transfer_rc=$?
        [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin"
      fi
    fi
  fi
  printf 'complete: %s captain-call inventory reviewed%s%s%s\n' "$origin" "${keys:+ ($keys)}" \
    "${attested_by_prefix:+ [attested through the configured prefix: $attested_by_prefix]}" \
    "${unrecorded_origin:+ [no recorded origin on: $unrecorded_origin; not checked against $origin]}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys entry key open resolved
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  meta="$STATE/$origin.meta"
  [ -f "$meta" ] || fail "origin metadata is absent: $meta"
  require_tasks_axi
  reviewed=$(meta_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed captain-call inventory"
  keys=$(meta_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      verify_entry_durable "$origin" "$entry" >/dev/null
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(status_open_decisions "$STATE/$origin.status")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    fail "open captain decision $origin/$key is not transferred to the captain-held inventory; re-run complete"
  done <<EOF
$open
EOF
  printf 'verified: %s captain-call inventory\n' "$origin"
}

# --- record divergence ------------------------------------------------------
#
# A captain call can be written down twice, and until now nothing said when
# those two records disagreed. A `resolved [key=...]` line closes the status-log
# fold outright; the structured captain-held task is closed by a SEPARATE act
# (`answer` above). Closing only on the status side therefore looks complete
# there while the durable record still says the captain owes an answer and
# keeps resurfacing it. The defect was never the separation; it was the silence.
#
# `diverged` is a read-only report of that contradiction and nothing else. It
# closes NOTHING. A captain call closed wrongly disappears without review, which
# is strictly worse than the noise this prints, so reconciling a divergence stays
# a human-owned act - and it runs in either direction: record what the captain
# actually said with `answer`, or re-open the status decision when that
# resolution was not the captain's word.
#
# What it flags, and only this: a task that is still open and still carries the
# captain-hold annotations, whose key was closed on the status side by the
# RESOLVE verb. The other closing verb is not a divergence: a `captain-held`
# close is the VERIFIED transfer to that very task, written by command_complete
# only after verifying it, so the structured row staying open behind it is the
# correct state. Neither is a still-open status decision - the OPEN DECISIONS
# fold already owns that one.
#
# Routed work is deliberately irrelevant. When the decision IS the deliverable
# there is nothing to route, so the test is only whether the status side already
# declared this task's key resolved.
# Nor does the report interpret why that resolution exists. A call can turn out
# not to be a captain arbitration at all - a premise can dissolve, or a question
# of fact can prove its first reading wrong - so the report says only that the
# two records disagree and names both reconciliation directions above.
#
# Cost stays flat on a healthy home: one `tasks-axi list`, one key scan per
# status log, and the precise per-key fold only for a key that already names a
# still-open task. If tasks-axi is unavailable or its listing cannot be parsed,
# the guard cannot read the structured record and prints nothing.
#
# Output: one `<task-id>\t<origin>\t<key>\t<title>` line per divergence, in
# status-log then key order; nothing when the two records agree.

# Every still-open task id in this home's backlog, one per line. Only the first
# two comma-separated listing fields are read - both are slugs that precede any
# quoted title - so a title containing commas or quotes cannot shift them.
open_task_ids() {
  local data
  data=$(fm_backlog_data_absolute "$DATA") || return 1
  fm_backlog_row_list "$data" 2>/dev/null | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      if ($2 != "done") print id
    }
  '
}

# Every key token stated anywhere in a status log. A cheap candidate scan: it
# over-includes tokens that are only prose, and status_key_closing_verb below is
# what actually decides what the stream says about a key.
status_log_key_tokens() {  # <status-file>
  grep -o '\[key=[A-Za-z0-9._-]*\]' "$1" 2>/dev/null |
    sed 's/^\[key=//; s/\]$//' | LC_ALL=C sort -u
}

list_has_line() {  # <newline-separated-list> <value>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

command_diverged() {
  local ids resolve f origin tokens id keys key show title
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # Both records must belong to the SAME home or the comparison is meaningless:
  # tasks-axi reads $FM_HOME's backlog, so a state dir pointed somewhere else
  # would report one home's status logs against another home's tasks. Every
  # production caller pairs the two; a mismatch stays silent rather than
  # inventing a cross-home divergence.
  [ "$STATE" = "$FM_HOME/state" ] || return 0
  # A read-only listing on a per-wake path, so it skips the mutation-oriented
  # compatibility floor and its extra probes: a listing this parser cannot read
  # simply yields no candidates and the report stays silent.
  command -v tasks-axi >/dev/null 2>&1 || return 0
  ids=$(open_task_ids) || return 0
  [ -n "$ids" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    origin=$(basename "$f"); origin=${origin%.status}
    tokens=$(status_log_key_tokens "$f")
    [ -n "$tokens" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # The keys that could name this task in THIS log: the collapsed identity
      # (the key IS the task id) and, for a pre-collapse row, the legacy derived
      # one this origin would have minted.
      keys=$id
      case "$id" in
        "$origin-decision-"?*) keys="$keys"$'\n'"${id#"$origin-decision-"}" ;;
      esac
      while IFS= read -r key; do
        list_has_line "$tokens" "$key" || continue
        [ "$(status_key_closing_verb "$f" "$key")" = "$resolve" ] || continue
        task_show "$id" || continue
        show=$TASK_SHOW_OUTPUT
        [ "$(show_field "$show" state)" != "done" ] || continue
        [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
        # The title is the only free-text field here, and the report is
        # TAB-separated, so it goes through the same sanitizer every other
        # emitted field uses rather than being trusted to stay one clean line.
        title=$(sanitize_field "$(show_field_value "$show" title)")
        printf '%s\t%s\t%s\t%s\n' "$id" "$origin" "$key" "$title"
        break
      done <<INNER
$keys
INNER
    done <<EOF
$ids
EOF
  done
}

# Still an open captain call? Exit 0 yes, 1 no, 2 cannot tell (see the header).
# A row this home does not carry is 3 when the caller requests the distinction,
# and so is a home with no backlog file at all, because a backlog that does not
# exist holds nothing. Every read failure over a record that DOES exist is a 2,
# printed to stderr, because a mechanical closer must never read "cannot tell"
# as permission to close.
command_open() {  # <task-id> [--identity] [--distinguish-absent]
  local id='' identity=0 distinguish_absent=0 data state root file backend show shown_body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity=1 ;;
      --distinguish-absent) distinguish_absent=1 ;;
      -*) usage >&2; exit 2 ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 2; }
        id=$1
        ;;
    esac
    shift
  done
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      printf 'fm-captain-hold: task id must be a non-empty privacy-safe slug: %s\n' "$id" >&2
      exit 2
      ;;
  esac
  data=$(fm_backlog_data_absolute "$DATA") \
    || { printf 'fm-captain-hold: data directory cannot be resolved: %s\n' "$DATA" >&2; exit 2; }
  root=$(fm_backlog_root "$data") \
    || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
  if ! backend=$(fm_tasks_axi_backend_resolve "$root"); then
    exit 2
  fi
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") \
      || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      # No backlog file at all: this home records no captain calls, so the task
      # is absent from it rather than held. A record that EXISTS but cannot be
      # read is a different state and still leaves by the exit 2 paths below,
      # because that one may hide a live hold.
      [ "$distinguish_absent" = 0 ] || return 3
      return 1
    fi
  fi
  fm_tasks_axi_compatible || { printf 'fm-captain-hold: compatible tasks-axi is required\n' >&2; exit 2; }
  if fm_backlog_row_probe "$data" "$id"; then
    state=${FM_BACKLOG_ROW_STATE%% *}
    if [ "$state" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      if [ "$identity" -eq 1 ]; then
        task_show "$id" || {
          printf 'fm-captain-hold: captain call %s is open but its record could not be read\n' "$id" >&2
          exit 2
        }
        show=$TASK_SHOW_OUTPUT
        shown_body=$(show_field "$show" body)
        hold_lifecycle_identity "$shown_body"
      fi
      return 0
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    [ "$distinguish_absent" = 0 ] || return 3
    return 1
  fi
  printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_ROW_ERROR" >&2
  exit 2
}

command_resolved() {  # <task-id> <occurrence>
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  local id=$1 occurrence=$2 show body state mode
  validate_slug task-id "$id"
  case "$occurrence" in ''|*[!0-9]*) return 1 ;; esac
  [ "$occurrence" -gt 0 ] || return 1
  require_tasks_axi
  task_show "$id" || return 1
  show=$TASK_SHOW_OUTPUT
  body=$(show_field "$show" body)
  body_has_resolution_record "$body" || return 1
  [ "$(resolution_record_count "$body")" -eq "$occurrence" ] || return 1
  mode=$(recorded_resolution_mode "$body") || return 1
  case "$mode" in answered|released|repaired|reconciled|routed|declined|action-completed) ;; *) return 1 ;; esac
  state=$(show_field "$show" state)
  [ "$state" != 'done' ] || return 0
  [ "$mode" = released ] && [ "$(show_field_value "$show" hold_kind)" != captain ]
}

case "${1:-}" in
  retire-moot)
    if [ "${FM_CAPTAIN_MOOT_LOCKED:-0}" != 1 ]; then
      export FM_CAPTAIN_MOOT_LOCKED=1
      exec python3 "$SCRIPT_DIR/fm_work_lock.py" --wait-seconds 5 "$DATA" bash "$0" "$@"
    fi
    shift; command_retire_moot "$@" ;;
  sweep-moot) shift; command_sweep_moot "$@" ;;
  hold) shift; command_hold "$@" ;;
  answer) shift; command_answer "$@" ;;
  correct) shift; ANSWER_CORRECTION=1 command_answer "$@" ;;
  complete-action) shift; command_complete_action "$@" ;;
  action-pending) shift; command_action_pending "$@" ;;
  answers) shift; command_answers "$@" ;;
  reconcile-requests) shift; command_reconcile_requests "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  open) shift; command_open "$@" ;;
  resolved) shift; command_resolved "$@" ;;
  diverged) shift; command_diverged "$@" ;;
  reconcile) shift; command_reconcile "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
