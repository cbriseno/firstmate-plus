"""Canonical bootstrap and memory-only application of fleet entity values.

The Deck calls bootstrap once at activation/recovery, then reuses Projection.
The ledger position is captured under the work mutation lock before owner.load;
replay the suffix before serving a base. Unpublished external edits and a crash
between canonical save and append still require explicit canonical recovery.
"""
import copy
import json
import re
import subprocess
from pathlib import Path
from types import SimpleNamespace

from fm_work import Owner, digest, time_value, read_text, work_observation, fresh_run_step
import datetime as dt
from fm_delivery import BIN, completion_receipt, read_presentation, delivery_row
from fm_task_usage import read_usage


def position(home):
    try:
        stat = (Path(home) / 'state/fleet-ledger.jsonl').stat()
        # A writer can be in the middle of its append. Bootstrap is the only
        # full read; the live reader starts at the last complete line.
        content = (Path(home) / 'state/fleet-ledger.jsonl').read_bytes()
        return [stat.st_dev, stat.st_ino, content.rfind(b'\n') + 1]
    except FileNotFoundError:
        return [None, None, 0]


def bootstrap(owner):
    try:
        crew = owner.capacity()
    except subprocess.TimeoutExpired:
        crew = dict(agents_running=None, agents_cap=None, reason='unconfirmed')
    launches, workers = {}, {}
    enabled = (owner.home / 'config/fleet-ledger').exists()
    if enabled and owner.ledger_start[2]:
        with (owner.home / 'state/fleet-ledger.jsonl').open('rb') as stream:
            for line in stream.read(owner.ledger_start[2]).splitlines():
                event = json.loads(line)
                if event.get('home', str(owner.home)) != str(owner.home):
                    continue
                task, name = event.get('task'), event.get('event')
                if name == 'task.dispatched':
                    launches.setdefault(task, True)
                elif name == 'task.cleaned_up':
                    launches[task] = False
                    workers[task] = dict(state='dead', source='events', verdict=name)
                elif name == 'agent.liveness':
                    workers[task] = event['value']
                    launches[task] = event['value']['state'] == 'alive'
    owner._workers.update(workers)
    crew = lifecycle_capacity(crew, launches, enabled)
    owner.capacity = lambda: crew
    owner.observation = work_observation(owner.home, owner.env)
    snapshot = owner.snapshot()
    selector = subprocess.run(['bash', '-c', '. "$1/fm-landed-lib.sh"; printf "%s" "$FM_LANDED_JQ_DEFS"', 'projection', str(BIN)], capture_output=True, text=True, check=True).stdout
    facts = dict(calls={t['key'][5:]: t['question']['call'] for t in snapshot['tasks']},
        receipts={i: completion_receipt(owner.home, r) for i,r in owner.rows.items()},
        created={t['key'][5:]: t['created'] for t in snapshot['tasks']},
        usage={i: read_usage(owner.data / i / 'usage.json') for i in owner.rows})
    activity = {}
    for task, row in owner.rows.items():
        if row['state'] != 'in_flight':
            continue
        try:
            record = read_text(owner.home, 'state/' + task + '.busy-state', 4096).strip()
            gen = read_text(owner.home, 'state/' + task + '.busy-gen', 4096).strip()
        except (OSError, ValueError, UnicodeError):
            continue
        match = re.fullmatch(r'v1 gen=(\S+) seq=(\d+) state=(busy|idle|unknown) source=(\S+) event=(\S+) ts=(\d+)', record)
        if match and match[1] == gen:
            activity[task] = dict(gen=gen, seq=int(match[2]), state=match[3], source=match[4], event=match[5])
    return dict(schema='fm-work-bootstrap.v1', home=str(owner.home),
        position=owner.ledger_start, enabled=(owner.home / 'config/fleet-ledger').exists(),
        rows=owner.rows, presentations=owner.presentations, projects=owner.projects,
        registry_text=owner.registry_text, structure=owner.structure, status=owner.status,
        captain_answers=owner.captain_answers, requests=owner.request_records(),
        aliases=owner.aliases.value, facts=facts, snapshot=snapshot, selector=selector,
        launches=launches, activity=activity, observation=owner.observation, empty_presentation=read_presentation(owner.home, 'deck-projection-new', verify=False))


def lifecycle_capacity(crew, launches, enabled):
    known = enabled and bool(launches)
    return dict(crew, agents_running=sum(launches.values()) if known else None,
                reason=None if known else 'unconfirmed', source='fleet-ledger')


class Projection(Owner):
    """Same work rules, with all source access replaced by captured facts."""
    def __init__(self, base):
        self.home = Path(base['home'])
        self.data = self.home / 'data'
        for name in ('rows', 'presentations', 'projects', 'registry_text', 'structure', 'status', 'captain_answers', 'facts'):
            setattr(self, name, copy.deepcopy(base[name]))
        self._requests = copy.deepcopy(base['requests'])
        aliases = copy.deepcopy(base['aliases'])
        self.aliases = SimpleNamespace(value=aliases)
        self.aliases.alias = lambda key: (self.aliases.value or {}).get('forward', {}).get(key)
        self.workers = {t['key'][5:]: t['worker_liveness'] for t in base['snapshot']['tasks'] if t['worker_liveness']}
        self.crew = base['snapshot']['crew']
        self.launches = copy.deepcopy(base.get('launches', {}))
        self.ledger_enabled = base['enabled']
        self.observation = copy.deepcopy(base.get('observation', dict(main_inventory=base['snapshot'].get('main_inventory'), tasks=[])))
        self.include_runtime = False
        self.request_sort = 'manual'
        self.value = base['snapshot']
        self.selector = base['selector']
        self.history = self.select_history(self.rows.values())
        self.history_sources = self.value['history_sources']
        self.empty_presentation = base['empty_presentation']
        self.messages, self.activity = [], copy.deepcopy(base.get('activity', {}))
        self.calls = {(t['key'][5:], t['question']['asked']['value']): dict(task=t['key'][5:],
            call=dict(call=t['question']['call'], hold_set=t['question']['asked']['value']), state='open')
            for t in base['snapshot']['tasks'] if t['question']['open'] and t['question']['call']}
        self.rev = base['snapshot']['rev']
        self.facts['changed'] = {}

    @property
    def value(self):
        for task in self._value['tasks']:
            task['run_step'] = fresh_run_step(task.get('run_step'))
        return self._value

    @value.setter
    def value(self, value):
        self._value = value

    def select_history(self, rows):
        selected = subprocess.run(['jq', self.selector + '\nmap(select(landed_record))'],
            input=json.dumps(list(rows)), capture_output=True, text=True, check=True)
        return {r['id'] for r in json.loads(selected.stdout)}

    def worker_liveness(self, task_id):
        return self.workers.get(task_id, dict(state='unknown', source='events', verdict='unconfirmed'))

    def request_records(self):
        return self._requests

    def capacity(self):
        return self.crew

    def apply(self, event):
        name, task, value = event.get('event'), event.get('task'), event.get('value') or {}
        affected = {task}
        observation = event.get('observation')
        if isinstance(observation, dict):
            self.observation = copy.deepcopy(observation)
            affected = set(self.rows)
        elif name in ('task.changed', 'task.dispatched', 'task.cleaned_up'):
            self.observation['main_inventory'] = None
        scopes = {'task:' + str(task)} | (set(self.ancestors(task)) if task in self.rows else set())
        if name == 'task.changed' or name in ('call.opened', 'call.resolved'):
            row = value.get('task')
            if row is None:
                self.rows.pop(task, None)
                self.presentations.pop(task, None)
                self.history.discard(task)
            else:
                row = delivery_row(row, self.home)
                self.rows[task] = row
                self.history.discard(task)
                self.history |= self.select_history([row])
                self.status.setdefault(task, '')
                # Missing publications are explicitly unknown, never inferred.
                self.presentations.setdefault(task, copy.deepcopy(self.empty_presentation))
        elif name in ('task.presentation', 'task.review'):
            self.presentations[task] = value
        elif name == 'task.usage':
            self.facts['usage'][task] = value
        elif name == 'work.aliases':
            self.aliases.value = value
            affected = set(self.rows)
        elif name == 'work.structure':
            self.structure = value
            self.project_visibilities()
            affected = set(self.rows)
        elif name == 'work.control':
            self._requests = [r for r in self._requests if r['operation']['request_id'] != value['operation']['request_id']] + [value]
            affected = set(self.members(value['operation']['target']))
        elif name == 'task.completion':
            receipt = value.get('receipt')
            self.facts['receipts'][task] = receipt if receipt and receipt.get('valid', True) else None
        elif name == 'task.status':
            if not observation:
                for observed in self.observation.get('tasks', []):
                    if observed.get('id') == task:
                        observed['wait_until'] = None
                        observed['run_step'] = None
            if task in self.presentations:
                self.presentations[task] = copy.deepcopy(self.presentations[task])
                evidence = self.presentations[task]['lifecycle']['evidence']
                evidence.update(current=False, freshness='unknown', reasons=['source-changed'])
            declared = event.get('declared_at')
            stamp = ' [at=' + str(declared) + ']' if type(declared) is int and 0 <= declared <= 999999999999 else ''
            self.status[task] = self.status.get(task, '') + '\n' + (event.get('state') or '') + stamp + ' [key=' + str(event.get('key') or '') + ']: ' + event.get('text', '')
        elif name == 'primary.final':
            self.messages.append(value)
        elif name in ('agent.activity', 'agent.retired', 'agent.liveness', 'task.dispatched', 'task.cleaned_up'):
            if name == 'agent.activity':
                prior = self.activity.get(task, {})
                if prior.get('gen') == value.get('gen') and prior.get('seq', 0) > value.get('seq', 0):
                    return False
                self.activity[task] = value
                if value.get('state') != 'idle':
                    for observed in self.observation.get('tasks', []):
                        if observed.get('id') == task:
                            observed['wait_until'] = None
            elif name == 'agent.retired':
                if self.activity.get(task, {}).get('gen') == value.get('gen'):
                    self.activity.pop(task, None)
            elif name == 'agent.liveness':
                self.workers[task] = value
                self.launches[task] = value['state'] == 'alive'
                if value['state'] == 'dead':
                    self.activity.pop(task, None)
            elif name == 'task.dispatched':
                # Spawn can append dispatch after the child already exited.
                self.launches.setdefault(task, True)
                if self.workers.get(task, {}).get('source') != 'worker.process':
                    self.workers[task] = dict(state='unknown', source='events', verdict=name)
            else:
                self.workers[task] = dict(state='dead', source='events', verdict=name)
                self.launches[task] = False
        elif name == 'home.configuration':
            # Configuration publishes limits, not observed occupied lanes.
            cap = str(value.get('lane_capacity') or '').strip()
            self.crew = dict(self.crew, agents_cap=int(cap) if cap.isdigit() else None)
            self.registry_text = value.get('projects') or ''
            self.load_projects()
            self.project_visibilities()
            affected = set(self.rows)
        elif name != 'call.application':
            return False
        if name in ('call.opened', 'call.resolved'):
            self.calls[(task, value['call']['hold_set'])] = dict(value, task=task, state='open' if name == 'call.opened' else 'resolved')
        if name in ('call.opened', 'call.resolved', 'call.application'):
            if name == 'call.application' and (task, value['call']['hold_set']) in self.calls:
                self.calls[(task, value['call']['hold_set'])]['answer'] = value.get('answer')
            self.facts['calls'][task] = (value.get('call') or {}).get('call')
            if value.get('answer'):
                self.captain_answers[task] = value['answer']
                affected.add(value['answer']['origin'])
        if task in self.rows and name != 'task.status':
            self.facts['changed'][task] = time_value(dt.datetime.fromtimestamp(event['ts'], dt.timezone.utc).isoformat(), 'fleet.entity')
        self.answers_by_origin = {}
        for answer in self.captain_answers.values():
            self.answers_by_origin.setdefault(answer['origin'], []).append(answer)
        self.requests = {r['id']: r for p in self.presentations.values() if (r := p['presentation'].get('request'))}
        # Reuse the owner's revision and dependency rules. Dependents and scopes
        # can change from a row update even when their own rows did not change.
        self.rev = digest([self.registry_text, self.structure, {i:p['presentation'].get('request') for i,p in self.presentations.items()}, {i: {k:r.get(k) for k in ('repo', 'state', 'priority', 'hold', 'deps')} for i,r in self.rows.items()}])
        if name in ('task.changed', 'call.opened', 'call.resolved'):
            scopes |= set(self.ancestors(task)) if task in self.rows else set()
            affected |= {i for i in self.rows if any(b['ref'] in scopes for b in self.blockers(i))}
        self.crew = lifecycle_capacity(self.crew, self.launches, self.ledger_enabled)
        previous = {t['key'][5:]: t for t in self.value['tasks']}
        self.value = self.snapshot(facts=self.facts, previous=previous, affected=affected)
        return True
