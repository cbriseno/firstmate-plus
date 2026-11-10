#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
# Adding without --repo warns once and remains valid for projectless host work.
# New add/create/public-followup tasks receive their own presentation.request
# from the backlog title and repo (or Proyecto sin registrar). Pass
# --request-from <task-id> to reuse that task's declared request for another
# step of the same request, including work in another repository.
# A dependency or a shared project alone never implies a shared request.
# bin/fm-teardown.sh --residual files its follow-up with --request-from the
# closed task when that task declares a request.
# Existing duplicate adds retain their presentation unchanged.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/fm-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/fm-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - `hold` with `--kind captain`, because a captain call opened here would
#     carry no card for the captain to answer: bin/fm-captain-hold.sh hold is
#     the one path that opens one, and it refuses a call without choices;
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
# New successful done/close transitions preserve an optional owner completion
# receipt through fm-backlog-transition-lib.sh; retries retain the old instant.
# start/reopen invalidate that receipt. Receipt failures warn without changing
# a successful backend result; unavailable proof retains date-only history.
#
# Home-owned presentation extension (not a tasks-axi backend mutation):
#   presentation <id> [--json]                         Read the saved declaration.
#   presentation <id> [--card-title TEXT] [--card-status TEXT] [--group TEXT]
#                     [--summary TEXT] [--waiting-for TEXT] [--next-action TEXT]
#   presentation <id> --presentation-file /path/to/object.json
#   presentation <id> --repair --presentation-file /path/to/object.json
#   presentation <id> --reconcile                     Retain verified gate facts.
#   presentation <id> --presentation-file FILE --replan REASON
#   progress-contract <id>                            Render current worker instructions.
#   progress-check                                   Read missed reporting obligations.
#   presentation <id> --clear
#   presentation --groups [--json]                     List the group labels in use.
# This is the card the captain's board renders. Every field is optional, null or
# one line of plain text, written for the captain: short, plain, in the
# captain's language, with no ids, paths, hashes, or tool names.
#   card_title  (1..80)   short card title; firstmate sets it when filing the task.
#   card_status (1..120)  what is happening now, without repeating the title; the
#                         worker refreshes it with each status line (bin/fm-brief.sh
#                         renders that command for it).
#   group       (1..40)   the one project or initiative the task belongs to; reuse
#                         the exact text of a label --groups lists.
#   summary     (1..2000) one or two sentences on what the task delivers; the
#                         worker sets it when it reports done, and firstmate
#                         checks it before cleanup.
#   waiting_for, next_action (1..2000) optional wait and next-step text.
# File input only (no flags): the captain's request this task belongs to,
#   request {id, label, project} (each 1..80 plain text, all three required), and
#   outcome {role: step|partial|final, review: needed|done}; either key may be null.
#   Omitted or null means unclassified. A new owner close of a delivery with no
#   outcome declares final/needed when data/<id>/report.md exists, else step.
# Reuse the same request on tasks derived from one request; group is not a fallback.
# work snapshot exposes request/outcome on tasks and requests [{id,label,project,
#   tasks: [task keys], updated_at: latest member activity or null,
#   project_key: displayed project most member tasks show under (a tie prefers
#   the declared project) or null}]. Request identity is id within this home.
#   requests[].usage sums cached task usage; bin/fm_task_usage.py owns pricing,
#   refresh mechanics and the usage format. Snapshot never refreshes these caches.
#   Delivery history retains these fields. Each project also lists
#   requests: [request keys whose project_key is it, in request order] and
#   derived_blocked_by: [{ref: other project, open: true, via: [{task, blocker}]}]
#   aggregated from open task dependencies across displayed projects; member
#   tasks never inherit them, unlike declared group dependencies in blocked_by.
# Firstmate may rewrite any text field at any time. Writes patch only supplied fields,
# empty text clears one field, --clear clears them all. File input is the same
# partial object; unknown keys, wrong types, and over-bound text are rejected.
# Input must be a separate file, never data/<id>/presentation.json (owner output).
# To repair an invalid declaration, --repair requires that separate file, retains
# the original bytes as .presentation-invalid.*.json beside the declaration, and
# resets unspecified fields to null. Normal writes still reject invalid data.
# Owner lock acquisition waits at most five seconds; longer contention refuses
# before the command runs. Only stderr starting with `work mutation busy:` or
# owner JSON state=rejected/code=busy identifies this pre-execution contention.
# Preserve the exact command and input, wait one second and retry once without
# reporting blocked or waiting for firstmate. On success, continue normally.
# If still busy, report both failures, affected work and the action needed from
# firstmate; continue independent authorized work. Do not apply this recovery
# to unsafe lock errors, other refusals or failures with possible partial effects.
# A successful presentation requires exit success, ok=true, state=published,
# evidence.available=true and lifecycle.evidence.current=true, not just exit 0.
# File input may include phase (investigation, implementation, rebase, validation,
# branch-ready, integration, activation, complete) together with progress.
# Each step may bind gate=branch-ready, integrated or pipeline-passed. Only the existing delivery
# ready-head validator, matching forge merge receipt, default-branch ancestry,
# and attributed passing pipeline outcome close those gates; arbitrary
# labels, status prose, phase text and elapsed time never do. Other steps remain
# explicit declarations, including local checks and installed activation.
# Completed labels cannot regress or disappear through replay; --replan REASON
# permits a deliberate semantic correction, while verified gate facts survive.
# A progress publication records its own reported_at, status-boundary fingerprint,
# task contract and code head. Card-only patches never refresh that checkpoint.
# A new status boundary, promotion or code head demands an explicit checkpoint,
# even when no step completed. There is no elapsed-work or periodic heartbeat TTL.
# work snapshot returns progress only for a current checkpoint, declared_progress
# for retained measurements, phase, verified_gates and progress_evidence separately.
# Existing watcher slow checks and wake-drain surface missing/stale obligations
# after FM_SIGNAL_GRACE (existing status coalescing grace, default 30 seconds).
# With no watcher, reads still expose the obligation; the next drain reconciles it.
# Authoritative own/inherited task or group holds defer actionable checkpoint
# obligations until legitimate resume. A paused status verb alone never defers
# them: ordinary validation/background waits still owe truthful checkpoints.
# Progress Git/delivery probes share a five-second budget per owner invocation
# and cache repeated Git observations within that read. Exhaustion exposes unknown
# evidence and withholds a current measurement; it never guesses gate completion.
# The existing backlog owner verifies the exact current or retained archived
# task before writing private data/<id>/presentation.json atomically. This is an authored declaration with
# its own source/time, never a status transition, liveness signal or refresh
# heartbeat. Reads never renew it; unknown fields remain null. No wake is sent.
# Work controls (explicit FM_HOME, local Markdown owner):
#   work bootstrap  Canonical activation base plus ledger cut; fm_work_projection.py owns replay semantics.
#   work capabilities | snapshot [--runtime] [--order recent|manual]  Fresh endpoint liveness; --runtime adds full crew evidence.
#   work preview | apply                 One bounded operation JSON on stdin.
#   work request-status --request-id ID   Durable receipt; retries never repeat effects.
#   work close --request-id ID            Close only workers at that pause's safe point.
#   work reconcile                        Advance safe closes and queued resumes in «Mi orden».
#   work pause.preview | pause.request | pause.cancel
#   work resume.preview | resume.request | resume.dequeue
# Signal verbs read JSON {scope, rev, request_id, actor?, reason?}; previews
# need no request_id. Scopes are task:<id>, project:<repo>, req:<request.id>.
# Request scopes select only explicit presentation.request membership.
#   work outcome.review                 Shared result review mark; JSON on stdin.
# Payload (all four fields required, no extras):
#   {"target":"task:<id>","occurrence":"<snapshot outcome_occurrence>",
#    "review":"done","expected_review":"needed"}
# target also accepts this home's persistent task alias. Both review fields
# accept needed|done. No request_id, task revision or lifecycle action is involved.
# Read outcome_occurrence from work snapshot.tasks[] or presentation <id>.
# It identifies the current authored result, independently of the review mark.
# Presentation changes to summary or outcome create a new occurrence; clearing
# outcome removes it. Identical publications and card/progress-only updates
# preserve it. Legacy declarations without an occurrence use legacy:<observed_at>;
# the next write preserves that identity unless the result changes.
# The owner locks, checks the exact task/occurrence and expected review, and
# atomically stores outcome.review and the declaration's observed_at.
# It persists the same occurrence, progress checkpoint and all other presentation
# fields. It never closes a task, answers a decision or controls a worker.
# Success: {ok:true,state:"applied",target,occurrence,outcome:{role?,review},
#   undo:{target,occurrence,review:<previous>,expected_review:<new>}}.
# Submit undo to the same verb to reverse the mark for that occurrence.
# Refusals: state=conflict with code=stale_occurrence|review_conflict; refresh
# before retrying. No receipt is created; a lost reply is resolved by reading.
# state=rejected with code=invalid_value (payload shape/values), unknown_target
# (missing/non-task target), no_outcome (no needed|done classification), busy
# (owner lock held), or owner_failed (invalid declaration/unsafe local paths).
# Refusal envelope: {request_id:null,state,code,message}.
# Failure envelope: {state:"failed",code:"owner_failed",message}.
# Refusals exit 0; malformed JSON and I/O errors exit 1 with state=failed,
# code=owner_failed. Always inspect state/code, not only process success.
# Capabilities revision 1.8 advertises outcome_controls:["outcome.review"]
# and feature outcome_review. Snapshot exposes the persisted mark to all clients.
# pause.request notifies workers, then closes only after their keyed safe point;
# FM_WORK_SAFE_POINT_TIMEOUT (seconds, 1..86400, default 300) exposes an
# unconfirmed pause without killing the worker. The main wake drain advances
# these controls; snapshot/request-status never send lifecycle commands.
# resume.request leaves its selected pause intact while queued, checks current
# capacity before clearing it and relaunching saved work, and preserves other
# pauses. resume.dequeue leaves queued work paused. pause.cancel is refused
# after a safe point. Signal receipts and snapshot pause_controls/events expose
# confirmation, refusal and queue progress; crew shows running agents and cap.
# Pause completion requires the exact safe-point acknowledgement or a fresh
# recovery-grade dead/missing endpoint verdict, never a status tail or metadata
# existence. Unknown liveness stays received with an explicit Spanish reason.
# snapshot automatically reconciles pending pause receipts under the owner lock;
# request-status --request-id ID is the explicit safe recheck after restoring
# endpoint access. Neither read sends lifecycle controls or repeats a pause.
# Snapshot tasks expose worker_liveness {state: alive|dead|unknown, verdict,
# source, observed_at}; pause.safe_point=no_worker distinguishes proven absence
# from reached. A held live/unconfirmed worker remains stopping without its
# acknowledgement. An unheld in-flight task with a proven dead worker is ready
# (subject to other conditions), never running; backlog state stays in_flight.
# clear_pause only removes the selected pause. Its note's resume_candidates
# contains confirmed live workers only; it never starts an absent worker.
#   work assign --task ID --subproject KEY|none   Firstmate-only membership maintenance.
#   work supervision --tasks ID...          Read-only bounded supervision predicate.
# Captures current source texts under the work lock, then parses and probes
# outside it; missing/invalid data needs supervision. No history or alias writes.
#   work dispatch-check --task ID         Nonzero if group pause/dependency prevents launch.
#   work normalize-plan --map FILE --additions FILE   Read-only current-source manifest.
#   work normalize-plan --metadata-only --map FILE   Only project visibility, zero task operations.
#   work normalize-plan --hierarchy-only --map FILE  Only declared owner display topology.
#   work normalize-plan --freeze-scope --map FILE    Dry-run explicit historical scope.
# Freeze map: {schema:"fm-work-freeze-scope.v1", tasks:[existing IDs],
# include_future:boolean, authority:"original instruction/reference or pending proposal"}.
# Named tasks are finite; include_future=true is only for an explicit future stop.
# Legacy freezes remain restricted until their owner approves this migration.
# Plan impact lists released/preserved controls; no worker receives continuation.
# Approve the exact list before normalize-apply; replan if current sources change.
# The normal backup/rollback path owns this structure-only atomic mutation.
# Hierarchy map: {schema: "fm-work-hierarchy.v1", groups: [{key, before, after}]}.
# Each before/after is {kind, parent, label}; kind=project requires parent=null,
# kind=subproject requires an existing group projected as a root project parent.
# Both require a plain label; fourth levels, cycles and unknown parents are refused.
# An existing subproject may become a logical root independently of its repository.
# Canonical keys and repository routing remain stable, including permanent aliases.
# The owner returns explicit kind/parent in projects/subprojects and tasks; tasks
# additionally expose repository_project as their original routing identity.
# In a logical layout every group selects and controls its displayed tasks;
# source repository cards no longer control tasks moved to another root.
# Promotion refuses any change to effective pauses or dependency conditions.
# This changes no stored membership, registry or repository.
# Dry-run fingerprints current sources; apply rejects any diff beyond the declared
# hierarchy and verifies exact backlog/registry/retained-task/control/alias invariants.
# Apply/rollback use the same durable normalization receipt and guarded recovery.
# Metadata map: {schema: "fm-work-project-metadata.v1", groups: [{key,
# visibility: public|private|unknown, expected: {present: boolean, value: previous|null}}]}.
# Optional visibility on project groups is explicit; absence retains the registry
# fallback (public for install links, unknown otherwise), without privacy inference.
# Metadata-only apply rejects any structure change outside the declared fields;
# normal normalize-apply/rollback own its backup, idempotency and conflict checks.
#   work normalize-apply --request-id ID              Manifest JSON on stdin; exact backup/receipt.
#   work normalize-rollback --request-id ID           Guarded field rollback; refuses later edits.
#   work aliases-init --map FILE --request-id ID       Explicit private alias activation.
# Seed: {schema: "fm-work-alias-seed.v1", home: absolute FM_HOME, entries:
# [{key: canonical_identity, alias: "T-XXX"|"P-XXX"|"S-XXX", primary: boolean}]}.
# Every seeded key needs exactly one primary assignment; alternate history aliases
# remain reserved reverse lookups. Existing assignments cannot be overwritten.
# data/work-alias-activations/<ID>.json saves before/after and the exact seed;
# prepared means incomplete and refuses automatic replay. Never seed private demo
# contents in tracked source. Use a home-specific seed before any allocation.
# data/work-aliases.json persists forward and reverse indexes atomically under the
# shared work lock. After activation, reads extend it for newly observed identities
# with random readable three-symbol suffixes and complete collision probing.
# Assignments and historical reservations never expire or recycle, even if a row
# disappears; exhaustion fails explicitly. Canonical IDs remain valid everywhere.
# A snapshot before activation has alias=null and aliases.state=uninitialized;
# after activation every projected node has alias and aliases.state=active.
# Do not enable alias-dependent presentation before explicit activation succeeds.
# Snapshot/preview/resolve serialize allocation under the owner lock; preview
# never changes work data. Read-only metadata operations do not seed a ledger.
#   work resolve --ref ALIAS|CANONICAL                 Home-scoped lookup for intake/tools.
# Returns canonical key, primary alias, task_id when applicable, and available.
# Missing retained rows still resolve through reserved aliases with available=false;
# controls reject absent work. preview/apply resolve target/on/before/after before
# the usual revision, cycle, completed-task and owner guards. No hash guessing.
# Roll back alias activation by rolling code/consumer presentation back while
# retaining the reservation ledger and receipt; never delete/recycle allocations.
# normalize-plan additions are {groups: [stable group declarations], membership:
# {task_id: subproject_key}, active: [explicit approved implementation task ids]}.
# The active list is descriptive; normalization never creates or broadens pauses.
# Partial migrations keep their backup/receipt and refuse automatic replay.
# Presentation file input also accepts progress: {steps: [{label: 1..80 chars,
# state: done|active|todo}]}, 1..30 authored steps; null clears the declaration.
# Data/control schema: fm-work-contract.v1; capabilities revision 1.3 adds
# stable_aliases, normalized_hierarchy, question_provenance, removal_consultation.
# question.origin contains key, alias, available, title, backlog_state, completed,
# source from the retained origin row. question.open belongs to the decision itself;
# Revision 1.4 adds progress_checkpoints, progress_phases and verified_progress_gates.
# Revision 1.6 adds worker_liveness and pause_reconciliation.
# completed/missing origins never answer, close or hide an outstanding decision.
# request_removal accepts note up to 2000 characters, excluding NUL. Its preview
# impact.consultation records canonical+short target, hierarchy initiative, real
# descendant states and dependency edges, with advice=null/deletion_authorized=false.
# Apply writes only request/inbox records; no work-structure write, task mutation,
# safety advice, or deletion. result.consultation exposes note_id/status/reply.
# received means recorded/pending review; applied means a real fm-inbox.sh reply
# exists, never deletion approval or execution. Ordinary request-status and retry
# preserve that same request and note. A saved note whose queue announcement
# failed stays received with an explicit repair reason; apply with the same
# request_id repairs the announcement, while request-status never announces.
# A written removal request interrupted before persisting its note receipt can
# recover the idempotent note on explicit retry using its originally saved scope.
# native_delivery distinguishes direct-input acceptance from unavailable or
# unproved delivery; only an actual inbox reply completes the consultation.
# question.answer exposes a settled canonical captain answer; recorded_answers
# joins it to its originating work. application pending/responded/unconfirmed
# describes the separate inbox handling receipt, never policy execution or an
# unanswered question. A re-held current call does not reuse an older answer.
# Original creation instants are mandatory for new cards. add/create,
# public-followup add and captain-call/internal-add owners use the same seam in
# fm_delivery.py, retaining native stdout/exit behavior. The existing work lock
# spans backend creation and publication of data/<id>/creation.json:
# {schema:"fm-task-creation.v1",id,source,created_at:<UTC ISO8601>}.
# source is fm-tasks-axi.add or fm-tasks-axi.public-followup.add.
# The instant is captured at that owner commit; a backend's original zoned
# instant remains the preferred read source. New group/project/subproject
# records use structure.created_at at normalize-apply, never preview time.
# Existing instants, dates and unknowns are immutable across ordinary edits.
# A legacy already=true/idempotent add never invents an older record's time.
# Creation reserves a fsynced .task-creation-*.json journal before mutation;
# success requires an exclusive durable receipt, not a best-effort update.
# A failed/unproved write returns failure and retains its original journal for
# explicit recovery. Reads never infer a creation time from an attempt,
# spawn/update/mtime or first observation.
# A completed creation journal is also joined by ID before receipt publication;
# an explicit same-add retry repairs that exact failed publication with the
# original instant. A legacy duplicate with no such journal stays date/unknown.
# New receipts never overwrite old ones.
# created={value,precision,source} projects a valid original instant or
# receipt, otherwise the unchanged backlog date/unknown. Group priority/pause
# metadata first materialized for an existing project is not a creation event.
# Request snapshots expose updated_at and default to recent activity; --order manual
# is the work order: placed requests keep structure.order, unplaced ones enter by
# priority, sigue follows it, and yields names the running task lowest in it that
# gives way to ready work of a request placed higher. move request:<id> saves the
# visible order with the move applied, never task priorities, and returns its ordinary Undo.
# data/work-structure.json has one writer here.
# A pause of active work requests a safe checkpoint through the primary inbox;
# it never controls a worker endpoint. Removal requests never delete anything.
# Pausing a task with an existing captain/external/dependency wait records a
# separate task_pauses entry; it never overwrites or releases the original hold.
# pause.condition exposes that retained hold, question.open remains independent,
# and clear_pause/Undo remove only the separate pause, preserving the condition
# and the existing freeze. Dispatch refuses the separate pause as well.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

# All writers of fields shared with work controls use the same inherited lock.
# The work owner can call this wrapper while retaining its transaction lock.
run_owner() {
  if [ -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ]; then
    FM_HOME="$FM_HOME" python3 "$SCRIPT_DIR/fm_work_lock.py" "$DATA" \
      python3 "$SCRIPT_DIR/fm_delivery.py" ledger-mutation "$DATA" -- "$@"
  elif [ -e "$DATA/.work.lock" ] || [ -L "$DATA/.work.lock" ]; then
    python3 "$SCRIPT_DIR/fm_work_lock.py" "$DATA" "$@"
  else
    "$@"
  fi
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

# Help is read-only: bypass the creation owner and its transaction lock.
case "${1:-}" in
  add|create)
    for arg in "${@:2}"; do
      case "$arg" in
        --) break ;;
        -h|--help) exec tasks-axi "$1" --help ;;
      esac
    done
    ;;
esac

case "${1:-}" in
  progress-contract)
    [ "$#" -eq 2 ] || fail 'progress-contract requires one exact task id'
    # The delivery reader resolves FM_HOME physically before checking containment.
    DATA=$(fm_backlog_data_absolute "$DATA") || fail 'cannot resolve progress contract data directory'
    export FM_HOME
    exec python3 "$SCRIPT_DIR/fm_delivery.py" progress-contract --task "$2" --data "$DATA"
    ;;
  progress-check)
    export FM_HOME
    exec python3 "$SCRIPT_DIR/fm_delivery.py" progress-check
    ;;
  work)
    shift
    export FM_HOME
    exec python3 "$SCRIPT_DIR/fm_work.py" "$@"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  presentation)
    shift
    case "${1:-}" in
      -h|--help) usage; exit 0 ;;
      --groups) export FM_HOME; exec python3 "$SCRIPT_DIR/fm_delivery.py" presentation --data "$DATA" "$@" ;;
      ''|-*) fail 'presentation requires a task id or --groups; use --help' ;;
    esac
    presentation_id=$1
    shift
    export FM_HOME
    if [ -e "$DATA/.work.lock" ] || [ -L "$DATA/.work.lock" ]; then
      python3 "$SCRIPT_DIR/fm_work_lock.py" --wait-seconds 5 "$DATA" \
        python3 "$SCRIPT_DIR/fm_delivery.py" presentation --task "$presentation_id" --data "$DATA" "$@"
    else
      python3 "$SCRIPT_DIR/fm_delivery.py" presentation --task "$presentation_id" --data "$DATA" "$@"
    fi
    exit $?
    ;;
esac

if [ "${1:-}" = hold ]; then
  previous_arg=''
  for arg in "$@"; do
    case "$previous_arg $arg" in
      '--kind captain'|*' --kind=captain')
        fail "a captain hold opens a captain call; use bin/fm-captain-hold.sh hold, which records the card the captain answers"
        ;;
    esac
    previous_arg=$arg
  done
fi

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi
case "${1:-}" in
  add|create) CREATION_DATA=$(fm_backlog_data_absolute "$DATA") || fail 'cannot resolve task creation data' ;;
  public-followup)
    if [ "${2:-}" = add ]; then
      CREATION_DATA=$(fm_backlog_data_absolute "$DATA") || fail 'cannot resolve task creation data'
    fi
    ;;
  done|close|unhold) ACTION_DATA=$(fm_backlog_data_absolute "$DATA") || fail 'cannot resolve the attention owner data directory' ;;
esac

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${1:-}" in
  done|close|unhold)
    for action_id in "$@"; do
      case "$action_id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      [ -e "$ACTION_DATA/$action_id/captain-call.json" ] || [ -L "$ACTION_DATA/$action_id/captain-call.json" ] || continue
      action_rc=0
      FM_DATA_OVERRIDE="$ACTION_DATA" bash "$SCRIPT_DIR/fm-captain-hold.sh" action-pending "$action_id" || action_rc=$?
      case "$action_rc" in
        0) fail 'an action attention card persists until complete-action records authoritative completion; a generic close/unhold is not completion' ;;
        1) ;;
        *) fail "cannot verify the action lifecycle for $action_id" ;;
      esac
    done
    ;;
esac
case "${1:-}" in
  add|create)
    repo_or_help=0
    for arg in "${ARGS[@]}"; do
      case "$arg" in --repo|--repo=*|-h|--help) repo_or_help=1 ;; esac
    done
    [ "$repo_or_help" = 1 ] || echo 'warning: no --repo supplied; task will have no project (valid for host work)' >&2
    python3 "$SCRIPT_DIR/fm_work_lock.py" "$CREATION_DATA" \
      python3 "$SCRIPT_DIR/fm_delivery.py" create-task "$CREATION_DATA" -- tasks-axi ${ARGS[@]+"${ARGS[@]}"}
    exit $?
    ;;
  public-followup)
    if [ "${2:-}" = add ]; then
      python3 "$SCRIPT_DIR/fm_work_lock.py" "$CREATION_DATA" \
        python3 "$SCRIPT_DIR/fm_delivery.py" create-task "$CREATION_DATA" -- tasks-axi ${ARGS[@]+"${ARGS[@]}"}
      exit $?
    fi
    ;;
  show|view|list)
    set -o pipefail
    tasks-axi ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
  done|close)
    case "${2:-}" in
      ''|-*) exec tasks-axi ${ARGS[@]+"${ARGS[@]}"} ;;
    esac
    previous_state=''
    previous_hold=''
    if fm_backlog_row_probe "$DATA" "$2"; then
      previous_state=${FM_BACKLOG_ROW_STATE%% *}
      previous_hold=$FM_BACKLOG_ROW_HOLD_KIND
    fi
    run_owner tasks-axi ${ARGS[@]+"${ARGS[@]}"}
    result=$?
    if [ "$result" -eq 0 ] && [ -n "$previous_state" ] && [ "$previous_state" != 'done' ] && [ "$previous_hold" != captain ]; then
      fm_backlog_record_completion "$DATA" "$2" ''
    fi
    if [ "$result" -eq 0 ] && ! fm_backlog_backend_manual "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; then
      FM_DATA_OVERRIDE="$DATA" bash "$SCRIPT_DIR/fm-captain-hold.sh" sweep-moot >&2 || {
        printf 'moot-retirement: closure succeeded; automatic retirement needs retry through sweep-moot\n' >&2
      }
    fi
    exit "$result"
    ;;
  start|reopen)
    run_owner tasks-axi ${ARGS[@]+"${ARGS[@]}"}
    result=$?
    [ "$result" -ne 0 ] || fm_backlog_invalidate_completion "$DATA" "${2:-}"
    exit "$result"
    ;;
esac
run_owner tasks-axi ${ARGS[@]+"${ARGS[@]}"}
exit $?
