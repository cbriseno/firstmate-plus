# shellcheck shell=bash
# Optional flow contract for bearings rows and secondmate summaries.
# phase: active|human|dependency|integration|technical|unknown.
# state: executing|waiting|held|ready|unknown; ready distinguishes a queued
# dispatch from a worker's verified done state through next_action/source.
# Reasons and titles are full captured text. Dependencies are home-local backlog
# identities, with canonical state and provenance; absent records stay unknown.
# A declaration is historical evidence, never a substitute for current_state.
# presentation is optional owner-authored card text (card_title, card_status,
# group, summary, waiting_for, next_action; bin/fm-tasks-axi.sh owns their
# meaning and bounds), with separate historical presentation_evidence. Every
# key is always present; missing text stays null; no action is minted by phase.
# title stays the full backlog title, never replaced by card_title.
# The legacy human-hold next_action retains its canonical reason, never executed.
# execution is registered metadata only; native_activity never uses phase or
# endpoint presence as model liveness. run_step is a sampled validation source,
# expiring after its TTL, not a native model observation. A step sampled during
# collection, after the fixed reference time, has a negative age and stays fresh
# while it is less than one TTL ahead of that reference.
# This projection classifies structured fields only, never prose or vendor UI.
# shellcheck disable=SC2034,SC2016
FM_FLOW_JQ_DEFS='
  def flow_run_step($step; $now):
    if ($step | type) != "object" then null else
      (try ($step.observed_at | fromdateiso8601) catch null) as $at
      | (try ($now | fromdateiso8601) catch null) as $now_at
      | (if $at == null or $now_at == null then null else ($now_at - $at) end) as $age
      | ($step.ttl_seconds // 0) as $ttl
      | ($age != null and ($ttl | type) == "number" and $ttl > 0 and $age > (0 - $ttl) and $age < $ttl
         and $step.source == "no-mistakes.attributed-run"
         and ($step.phase == "validation" or $step.phase == "ci")) as $fresh
      | $step + {state:(if $fresh then ($step.declared_state // $step.state) else "unknown" end),
          declared_state:($step.declared_state // $step.state),
          freshness:(if $fresh then "fresh" else "stale" end),age_seconds:$age}
    end;
  def flow_registration($now):
    {execution:(.execution // null),run_step:flow_run_step(.run_step; $now),
     native_activity:(.native_activity // {state:"unknown",verified:false,observed_at:null,source:null,identity:null})};
  def flow_context($record; $current; $declaration; $owner; $records; $decisions):
    ($record.unresolved_blocker_ids // []) as $waiting
    | [($record.blocked_by_ids // $waiting)[] as $id
       | ([$records[] | select(.id == $id)][0]
          // [($record.dependency_records // [])[] | select(.id == $id)][0] // null) as $dep
       | {id:$id,title:($dep.title // $id),owner:$owner,state:($dep.state // "unknown"),
          unresolved:(($waiting | index($id)) != null),
          source:(if $dep == null then "backlog.record.unavailable" else ($dep.source // "backlog.record") end),
          reconciliation_required:($dep.state == "done" and (($waiting | index($id)) != null))}] as $deps
    | ($current.state // "unknown") as $state
    | (if $state == "working" then "active"
       elif ($waiting | length) > 0 then "dependency"
       elif $record.hold_kind == "captain" or any($decisions[]?; .verb == "needs-decision") then "human"
       elif $state == "done" then "integration"
       elif $state == "paused" or $state == "parked" or $state == "blocked" or $state == "failed" then "technical"
       else "unknown" end) as $phase
    | {phase:$phase,title:($record.title // null),
       state:(if $phase == "active" then "executing"
              elif $record.current_role == "held" then "held"
              elif $phase == "dependency" or $phase == "human" or $phase == "technical" then "waiting"
              elif $phase == "integration" or $record.state == "queued" then "ready"
              else "unknown" end),
       owner:$owner,
       reason:(if $record.hold_reason != null then $record.hold_reason
               elif $record.blocked_reason != null then $record.blocked_reason
               elif $state != "unknown" then ($current.detail // $state)
               else ($declaration.note // $current.detail // "Motivo no registrado") end),
       source:(if $record.hold_reason != null then "backlog.hold_reason"
               elif $record.blocked_reason != null then "backlog.blocked_reason"
               elif $state != "unknown" then ("current_state." + ($current.source // "unknown"))
               elif $declaration.note != null then "status.declaration (historical)"
               else "unknown" end),
       declared_state:($declaration.state // null),
       presentation:($record.presentation
         | {card_title, card_status, group, summary, waiting_for, next_action}),
       presentation_evidence:($record.presentation_evidence // null),
       waiting_for:($record.presentation.waiting_for //
         (if ($waiting | length) > 0 then ($deps | map(select(.unresolved) | .title) | join(", ")) else null end)),
       next_action:($record.presentation.next_action //
         (if $phase == "human" then $record.hold_reason else null end)),
       firstmate_action:null,
       dependencies:$deps};
'
