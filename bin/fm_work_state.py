"""Explain work placement from typed owner facts, without interpreting prose."""
import datetime as dt
import re


SECTIONS = ('needs_you', 'running', 'ready', 'dependency', 'capacity', 'waiting', 'paused', 'finished')
ATTENTION = ('questions', 'actions', 'reports', 'approvals')


def age_seconds(stamp):
    try:
        return max(0, int((dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(stamp.replace('Z', '+00:00'))).total_seconds()))
    except (AttributeError, TypeError, ValueError):
        return None


def explain(snapshot, statuses):
    sections = {s: [] for s in SECTIONS}
    attention = {s: [] for s in ATTENTION}
    workers = {s: [] for s in ('alive', 'dead', 'unknown', 'not_registered')}
    crew = snapshot['crew']
    cap = crew.get('agents_cap')
    capacity = dict(unit='worker_slot', limit=cap, state='unknown' if cap is None else 'configured',
                    source='config/lane-capacity')
    queued = {p['scope']: p for p in snapshot['pause_controls'] if p['state'] == 'queued' and p.get('queue_position') is not None}
    for task in snapshot['tasks']:
        key, state = task['key'], task['state']
        worker = task.get('worker_liveness')
        presence = worker['state'] if worker else 'not_registered'
        workers[presence].append(key)
        if worker:
            worker = dict(worker, age_seconds=age_seconds(worker.get('observed_at')),
                          generation=worker.get('gen'))
            task['worker_liveness'] = worker
        last = (statuses.get(key[5:]) or '').splitlines()
        match = re.match(r'^(working|paused|blocked|needs-decision|done|failed)\b([^:]*):\s*(.*)$', last[-1]) if last else None
        stamp = re.search(r'\[at=(\d+)\]', match[2]) if match else None
        declared_at = None
        if stamp:
            try:
                declared_at = dt.datetime.fromtimestamp(int(stamp[1]), dt.timezone.utc).isoformat()
            except (ValueError, OverflowError, OSError):
                pass
        declared = dict(state=match[1] if match else None, reason=match[3] if match else None,
                        at=declared_at, age_seconds=age_seconds(declared_at), until=task.get('wait_until'))
        blocks = [b['ref'] for b in task['blocked_by'] if b['open']]
        question = task['question']
        kinds = []
        if question['open'] and not blocks:
            kinds.append({'action': 'actions', 'approval': 'approvals'}.get((question.get('call') or {}).get('kind'), 'questions'))
        outcome = task.get('outcome') or {}
        if outcome.get('review') == 'needed':
            kinds.append('reports')
        for kind in kinds:
            attention[kind].append(key)
        pause = task['pause']
        own = pause.get('own') or {}
        inherited = pause.get('inherited')
        control = queued.get(key)
        if control is None:
            control = next((p for s, p in queued.items() if s in (task.get('project'), task.get('subproject'))
                            or s == 'request:' + (task.get('request') or {}).get('id', '')), None)
        capacity_wait = bool(control and
            (control['reason'] == 'resources' or
             (control['reason'] == 'cap' and cap is not None and control.get('running') is not None and control['running'] >= cap)))
        dispatch = task.get('dispatch_wait')
        dispatch_limited = bool(dispatch and task['backlog_state'] == 'queued' and
                                (dispatch.get('project_limit') is not None or cap is not None))
        if kinds:
            section, code = 'needs_you', 'human_' + kinds[0]
        elif question.get('filing_required'):
            section, code = 'waiting', 'call_record_required'
        elif state == 'done':
            section, code = 'finished', 'task_done'
        elif state == 'stopping':
            section, code = 'paused', 'worker_stopping'
        elif capacity_wait:
            section, code = 'capacity', 'capacity_' + control['reason']
        elif state in ('paused_own', 'paused_inherited'):
            section, code = 'paused', 'parked' if own.get('kind') == 'parked' else 'inherited_pause'
        elif blocks:
            section, code = 'dependency', 'open_dependency'
        elif dispatch_limited:
            section, code = 'capacity', 'capacity_dispatch'
        elif state == 'running':
            section, code = ('waiting', 'declared_' + declared['state']) if declared['state'] in ('paused', 'blocked', 'needs-decision') else ('running', 'task_in_flight')
        elif state.startswith('waiting_'):
            section, code = 'waiting', state
        elif task['backlog_state'] == 'in_flight' and presence == 'dead':
            section, code = 'waiting', 'worker_missing'
        else:
            section, code = 'ready', 'not_started'
        sections[section].append(key)
        task['placement'] = dict(section=section, code=code, unit='task', attention=kinds,
            reason=control['reason'] if section == 'capacity' and capacity_wait else
                task.get('reason') or (declared['reason'] if section == 'waiting' else None) or code,
            inputs=dict(question_open=question['open'], filing_required=question.get('filing_required', False), backlog_state=task['backlog_state'], task_state=state, hold=pause.get('condition') or own or None, own_pause=own or None,
                inherited_pause=inherited, blockers=blocks, declared=declared, worker=worker,
                worker_presence=presence, activity=task.get('native_activity'),
                project=task.get('project'), repository_project=task.get('repository_project'),
                capacity_wait=control if capacity_wait else None, dispatch_wait=dispatch))
    def count(keys):
        keys = sorted(set(keys))
        return dict(unit='task', count=len(keys), keys=keys)
    snapshot['counts'] = dict(scope='snapshot.tasks', tasks=count([t['key'] for t in snapshot['tasks']]),
        sections={s: count(keys) for s, keys in sections.items()},
        needs_you=dict(count([k for keys in attention.values() for k in keys]),
                       by_kind={s: count(keys) for s, keys in attention.items()},
                       composition='union'),
        workers={s: dict(count(keys), unit='task' if s == 'not_registered' else 'worker', identity='task') for s, keys in workers.items()},
        capacity=capacity)
    return snapshot
