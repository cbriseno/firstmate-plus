#!/usr/bin/env python3
"""Firstmate's home-owned work projection and controls; fm-tasks-axi.sh owns CLI help."""
import argparse
from fm_progress import tr
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import fcntl

from fm_work_lock import acquire
from fm_work_aliases import Aliases, PATH as ALIAS_PATH
from fm_progress import observed_run, sources as progress_sources, code_head

from fm_delivery import (BIN, canonical_read, home_path, read_text,
                         read_presentation, read_captain_call, read_captain_answer, task_creation, completion_receipt, retained_history,
                         reconcile_progress)

VISIBILITIES = ('public', 'private', 'unknown')
OPS = ['set_priority', 'set_pause', 'clear_pause', 'add_dep', 'remove_dep', 'move', 'request_removal']
ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}')
REQUEST = re.compile(r'[A-Za-z0-9_-]{16,80}')


def now():
    return dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


class Refusal(Exception):
    def __init__(self, code, message, **details):
        super().__init__(message)
        self.code, self.details = code, details


def refuse(condition, code, message, **details):
    if condition:
        raise Refusal(code, message, **details)


def plain(value, bound):
    return isinstance(value, str) and 0 < len(value.strip()) <= bound and not any(ord(c) < 32 for c in value)


def priority(value):
    return {'own': value, 'label': 'NA' if value in (None, 4) else 'P' + str(value)}


def time_value(value=None, source=None):
    if isinstance(value, str):
        try:
            if re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
                dt.date.fromisoformat(value)
                return dict(value=value, precision='date', source=source)
            dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
            return dict(value=value, precision='instant', source=source)
        except ValueError:
            pass
    return dict(value=None, precision='unknown', source=None)


def latest(values):
    known = [v for v in values if v and v.get('value')]
    return max(known, key=lambda v: v['value']) if known else time_value()


class Owner:
    def __init__(self):
        self.home = home_path()
        # Alternate layouts are not silently interpreted as this home's data.
        for name, child in [('FM_DATA_OVERRIDE', 'data'), ('FM_STATE_OVERRIDE', 'state'), ('FM_CONFIG_OVERRIDE', 'config')]:
            refuse(bool(os.environ.get(name)) and Path(os.environ[name]) != self.home / child,
                   'not_local_home', tr("Controls require this installation's local paths."))
        self.env = dict(os.environ, FM_HOME=str(self.home))
        self.data = self.home / 'data'
        self._runtime = {}
        self._workers = {}
        self.include_runtime = False
        self.structure_path = 'data/work-structure.json'

    def read(self, path, default=None):
        try:
            return json.loads(read_text(self.home, path))
        except FileNotFoundError:
            return copy.deepcopy(default)

    def atomic(self, path, value):
        target = self.home / path
        folder = self.home
        for part in target.relative_to(self.home).parts[:-1]:
            folder /= part
            refuse(folder.is_symlink(), 'owner_failed', tr('Unsafe data path.'))
            folder.mkdir(exist_ok=True)
        refuse(target.is_symlink(), 'owner_failed', tr('Unsafe data path.'))
        fd, temporary = tempfile.mkstemp(prefix='.work-', dir=folder)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(value, stream, ensure_ascii=False, indent=2)
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def lock(self):
        refuse(self.data.is_symlink(), 'owner_failed', tr('Unsafe data path.'))
        self.data.mkdir(exist_ok=True)
        try:
            self.lock_fd = acquire(self.data)
        except BlockingIOError:
            raise Refusal('busy', tr('Another change is in progress. Try again.'))
        self.env['FM_WORK_OWNER_FD'] = str(self.lock_fd)
        return self.lock_fd

    def command(self, script, *args, body=None, accepted=(0,)):
        if script == '@unset_priority':
            task_id, expected = args
            cli = shutil.which('tasks-axi')
            refuse(not cli, 'owner_failed', tr('tasks-axi is missing.'))
            root = Path(cli).resolve().parent.parent / 'src'
            # The same canonical library already required by delivery reads.
            payload = dict(path=str(self.home / self.backlog_path), id=task_id, expected=int(expected))
            read_text(self.home, self.backlog_path)  # refuse symlink ancestors
            result = subprocess.run(['node', str(BIN / 'fm-work-unset-priority.mjs'), str(root)],
                                    input=json.dumps(payload), text=True, capture_output=True, timeout=15)
            refuse(result.returncode != 0, 'owner_failed', result.stderr.strip()[:500])
            return result.stdout
        result = subprocess.run(['bash', str(BIN / script), *args], input=body,
                                env=self.env, pass_fds=(self.lock_fd,) if hasattr(self, 'lock_fd') else (), text=True, capture_output=True, timeout=30)
        refuse(result.returncode not in accepted, 'owner_failed', result.stderr.strip()[:500] or tr('The owner rejected the change.'))
        return result.stdout

    def load(self, include_presentations=True):
        try:
            config = canonical_read({'config': read_text(self.home, '.tasks.toml', 65536)})
        except FileNotFoundError:
            config = {}
        refuse(os.environ.get('TASKS_AXI_BACKEND', config.get('backend', 'markdown')) != 'markdown', 'not_local_home', tr('This backend only supports read access in Deck.'))
        cfg = config.get('markdown') or {}
        self.backlog_path = cfg.get('path') or 'data/backlog.md'
        try:
            self.backlog_text = read_text(self.home, self.backlog_path)
        except FileNotFoundError:
            refuse(True, 'owner_failed', tr('Missing backlog {path}; create it with In flight, Queued and Done sections before opening the board.').format(path=self.backlog_path))
        rows = canonical_read({'text': self.backlog_text})
        self.rows = {r['id']: r for r in rows}
        self.current_ids = set(self.rows)
        refuse(len(self.rows) != len(rows), 'owner_failed', tr('The backlog contains duplicate identities.'))
        history = retained_history(self.home, include_non_deliveries=True)
        for row in history['records']:
            if row['id'] not in self.rows or self.rows[row['id']]['state'] == 'done':
                self.rows[row['id']] = row
        self.history_sources = history['sources']
        self.captain_answers = {i: answer for i, row in self.rows.items()
                                if (answer := read_captain_answer(self.home, row)) is not None}
        self.answers_by_origin = {}
        for answer in self.captain_answers.values():
            self.answers_by_origin.setdefault(answer['origin'], []).append(answer)
        try:
            self.registry_text = read_text(self.home, 'data/projects.md')
        except FileNotFoundError:
            self.registry_text = ''
        self.projects = {}
        for line in self.registry_text.splitlines():
            match = re.match(r'^- ([A-Za-z0-9_.-]+) \[([^\]]*)\]\s*-\s*(.*)', line)
            if match:
                repo, flags, description = match.groups()
                install = re.search(r'(?:^|\s)install=([A-Za-z0-9_.-]+)', flags)
                self.projects[repo] = dict(key='project:' + repo, label=repo,
                    visibility='public' if install else 'unknown',
                    installs='project:' + install[1] if install else None, description=description)
        self.presentations = {i: read_presentation(self.home, i, verify=include_presentations) for i in self.rows}
        self.requests = {r['id']: r for p in self.presentations.values() if (r := p['presentation'].get('request'))}
        self.structure = self.read(self.structure_path, dict(schema='fm-work-structure.v1', groups={}, membership={}, order=[], edge_meta={}))
        self.validate_structure()
        self.aliases = Aliases(self, refuse)
        if hasattr(self, 'lock_fd'):
            self.aliases.sync()
        for group in self.structure['groups'].values():
            if group['kind'] == 'project' and 'visibility' in group:
                self.projects[group['repo']]['visibility'] = group['visibility']
        self.status = {}
        for i in self.rows:
            try:
                self.status[i] = read_text(self.home, 'state/' + i + '.status', 1024 * 1024)
            except FileNotFoundError:
                self.status[i] = ''
        # Every dependency/order/membership change invalidates all revisions.
        self._requests = None
        self.rev = digest([self.registry_text, self.structure, {i:p['presentation'].get('request') for i,p in self.presentations.items()}, {i: {k:r.get(k) for k in ('repo', 'state', 'priority', 'hold', 'deps')} for i,r in self.rows.items()}])
        return self

    def validate_structure(self):
        s = self.structure
        refuse(not isinstance(s, dict) or s.get('schema') != 'fm-work-structure.v1', 'owner_failed', tr('Invalid structure.'))
        for field, typ in [('groups', dict), ('membership', dict), ('order', list), ('edge_meta', dict)]:
            refuse(not isinstance(s.get(field), typ), 'owner_failed', tr('Invalid structure: ') + field)
        freeze = s.get('freeze')
        refuse(freeze is not None and (not isinstance(freeze, dict) or not isinstance(freeze.get('except'), list)
               or not plain(freeze.get('reason'), 500) or not isinstance(freeze.get('resumed', {}), dict)
               or ('tasks' in freeze and (not isinstance(freeze['tasks'], list)
                   or any(not isinstance(i, str) or not ID.fullmatch(i) for i in freeze['tasks'])))
               or ('include_future' in freeze and type(freeze['include_future']) is not bool)), 'owner_failed', tr('Invalid freeze.'))
        for key, group in s['groups'].items():
            refuse(not isinstance(group, dict), 'owner_failed', tr('Invalid group.'))
            repo = group.get('repo')
            kind = group.get('kind')
            refuse((kind == 'request' and (not key.startswith('req:') or not plain(key[4:], 80) or repo is not None)) or
                   (kind != 'request' and (repo not in self.projects or kind not in ('project', 'subproject') or
                   (kind == 'project' and key != 'project:' + repo) or
                   (kind == 'subproject' and not re.fullmatch(r'subproject:' + re.escape(repo) + r'/[A-Za-z0-9_.-]+', key)))),
                   'owner_failed', tr('Invalid group identity: ') + key)
            refuse('visibility' in group and (kind != 'project' or group['visibility'] not in VISIBILITIES),
                   'invalid_value', tr('Explicit visibility requires a project and public, private, or unknown.'))
            refuse(not plain(group.get('label'), 120) or
                   (group.get('priority') is not None and (type(group['priority']) is not int or group['priority'] not in range(5))),
                   'owner_failed', tr('Invalid group value.'))
        for task_id, sub in s['membership'].items():
            refuse(sub not in s['groups'] or s['groups'][sub]['kind'] != 'subproject', 'owner_failed', tr('Invalid membership.'))
            if task_id in self.rows:
                refuse(s['groups'][sub]['repo'] != self.rows[task_id].get('repo'), 'owner_failed', tr('The task belongs to another project.'))
        refuse(len(set(s['order'])) != len(s['order']), 'owner_failed', tr('Duplicate order.'))
        task_pauses = s.get('task_pauses', {})
        refuse(not isinstance(task_pauses, dict), 'owner_failed', tr('Invalid task pauses.'))
        for task_id, pause in task_pauses.items():
            refuse(not ID.fullmatch(task_id) or not isinstance(pause, dict) or pause.get('kind') != 'parked'
                   or not plain(pause.get('reason'), 200), 'owner_failed', tr('Invalid task pause.'))
        hierarchy = s.get('hierarchy', {})
        refuse(not isinstance(hierarchy, dict), 'owner_failed', tr('Invalid hierarchy.'))
        for key, node in hierarchy.items():
            refuse(key not in self.keys() or key.startswith('task:') or not isinstance(node, dict)
                   or set(node) != {'kind', 'parent', 'label'} or node['kind'] not in ('project', 'subproject')
                   or not plain(node['label'], 120), 'owner_failed', tr('Invalid hierarchy node.'))
        # Validate the complete effective topology, including unpatched groups
        # whose former repository root may have just become a subproject.
        for key in self.keys() - set('task:' + i for i in self.rows) - set(k for k in self.keys() if k.startswith('req:')):
            node = self.hierarchy(key)
            if node['kind'] == 'project':
                refuse(node['parent'] is not None, 'owner_failed', tr('A root project has no parent.'))
            else:
                parent = node['parent']
                refuse(not isinstance(parent, str) or parent not in self.keys() or parent.startswith('task:')
                       or parent == key or self.hierarchy(parent)['kind'] != 'project'
                       or self.hierarchy(parent)['parent'] is not None,
                       'owner_failed', tr('The hierarchy requires a project and subproject without a fourth level.'))

    def hierarchy(self, key):
        node = self.structure.get('hierarchy', {}).get(key)
        if node:
            return node
        group = self.structure['groups'].get(key, {})
        repo = group.get('repo', key[8:] if key.startswith('project:') else None)
        kind = group.get('kind', 'project')
        return dict(kind=kind, parent='project:' + repo if kind == 'subproject' else None,
                    label=group.get('label', repo))

    def display_membership(self, task_id):
        repo = self.rows[task_id].get('repo')
        project = 'project:' + repo if repo else None
        sub = self.structure['membership'].get(task_id)
        if sub:
            node = self.hierarchy(sub)
            return (sub, None) if node['kind'] == 'project' else (node['parent'], sub)
        if project is None:
            return None, None
        node = self.hierarchy(project)
        return (node['parent'], project) if node['kind'] == 'subproject' else (project, None)

    def display_members(self, key):
        if key.startswith('req:'):
            return [i for i,p in self.presentations.items() if (p['presentation'].get('request') or {}).get('id') == key[4:]]
        result = []
        for task_id in self.rows:
            project, sub = self.display_membership(task_id)
            if key in ('task:' + task_id, project, sub):
                result.append(task_id)
        return result

    def keys(self):
        return set('req:' + i for i in self.requests) | set('project:' + i for i in self.projects) | set(self.structure['groups']) | set('task:' + i for i in self.rows)

    def request_keys(self):
        return {'request:' + r['id'] for p in self.presentations.values() if (r := p['presentation'].get('request')) is not None}

    def logical_layout(self):
        return any(key.startswith('subproject:') and node['kind'] == 'project'
                   for key, node in self.structure.get('hierarchy', {}).items())

    def members(self, key):
        if key.startswith('task:'):
            return [key[5:]] if key[5:] in self.rows else []
        # A logical layout has one selection/control scope, including the
        # source repository cards from which tasks have moved away.
        if key.startswith('req:') or self.logical_layout():
            return self.display_members(key)
        if key.startswith('project:'):
            return [i for i, r in self.rows.items() if r.get('repo') == key[8:]]
        return [i for i, group in self.structure['membership'].items() if group == key and i in self.rows]

    def ancestors(self, task_id):
        request = self.presentations.get(task_id, {}).get('presentation', {}).get('request')
        scope = ['req:' + request['id']] if request else []
        if self.logical_layout():
            project, sub = self.display_membership(task_id)
            return [key for key in (sub, project) if key] + scope
        repo = self.rows[task_id].get('repo')
        return [k for k in ['project:' + repo if repo else None, self.structure['membership'].get(task_id)] if k] + scope

    def edges(self):
        edges = []
        for i, row in self.rows.items():
            for dep in row.get('deps', []):
                if dep.get('type') != 'blocked-by':
                    continue
                dep = dep['id']
                edges.append(('task:' + i, 'task:' + dep, self.structure['edge_meta'].get(i + '<-' + dep, {}).get('by', 'firstmate')))
        for key, group in self.structure['groups'].items():
            for edge in group.get('blocked_by', []):
                edges.append((key, edge['ref'], edge.get('by', 'firstmate')))
        for edge in self.structure.get('mixed_edges', []):
            edges.append((edge['target'], edge['ref'], edge.get('by', 'firstmate')))
        return edges

    def graph(self):
        keys = self.keys()
        graph = {k: set() for k in keys}
        # A group also waits for its member groups/tasks: this catches cycles
        # through empty groups and an ancestor even before tasks are assigned.
        for key, group in self.structure['groups'].items():
            if not self.logical_layout() and group['kind'] == 'subproject':
                graph['project:' + group['repo']].add(key)
            parent = self.hierarchy(key)['parent']
            if self.logical_layout() and parent:
                graph[parent].add(key)
        for task_id in self.rows:
            for ancestor in self.ancestors(task_id):
                if ancestor in graph:
                    graph[ancestor].add('task:' + task_id)
        for target, blocker, _ in self.edges():
            refuse(target not in keys or blocker not in keys, 'unknown_target', tr('A dependency has no known identity.'))
            graph[target].add(blocker)
            # Expand each group to tasks on both sides, including self edges.
            for a in self.members(target):
                for b in self.members(blocker):
                    graph['task:' + a].add('task:' + b)
        return graph

    def cycle(self):
        graph, visited, active = self.graph(), set(), []
        def walk(key):
            if key in active:
                return active[active.index(key):] + [key]
            if key in visited:
                return None
            active.append(key)
            for dep in sorted(graph[key]):
                cycle = walk(dep)
                if cycle:
                    return cycle
            active.pop()
            visited.add(key)
            return None
        for key in sorted(graph):
            found = walk(key)
            if found:
                return found
        return None

    def blockers(self, task_id, edges=None):
        keys = self.ancestors(task_id) + ['task:' + task_id]
        return [dict(ref=b, by=actor, open=b not in self.keys() or any(self.rows[i]['state'] != 'done' for i in self.members(b)))
                for a, b, actor in (self.edges() if edges is None else edges) if a in keys]

    def inherited(self, task_id):
        for key in self.ancestors(task_id):
            pause = self.structure['groups'].get(key, {}).get('pause')
            if pause:
                return dict(from_=key, **pause) | {'from': key}
        freeze = self.structure.get('freeze')
        resumed = set((freeze or {}).get('resumed', {}))
        if freeze and ('tasks' not in freeze or freeze.get('include_future') or task_id in freeze['tasks']) and task_id not in freeze['except'] and not resumed.intersection(self.ancestors(task_id) + ['task:' + task_id]):
            return {'from': 'freeze', 'reason': freeze['reason']}
        return None

    def current_hold(self, task_id):
        hold = copy.deepcopy(self.rows[task_id].get('hold'))
        if hold and hold.get('until') and hold['until'] <= dt.date.today().isoformat():
            return None
        return hold

    def progress_reporting_held(self, task_id):
        return bool(self.current_hold(task_id) or self.inherited(task_id)
                    or task_id in self.structure.get('task_pauses', {}))

    def request_records(self):
        if self._requests is not None:
            return self._requests
        folder = self.data / 'work-requests'
        if not folder.exists():
            return []
        refuse(folder.is_symlink(), 'owner_failed', tr('Unsafe receipt path.'))
        self._requests = [self.read('data/work-requests/' + f.name) for f in sorted(folder.glob('*.json'))]
        return self._requests

    def worker_liveness(self, task_id):
        if task_id in self._workers:
            return self._workers[task_id]
        value = dict(state='unknown', source='none', observed_at=now(), verdict='no_metadata')
        try:
            meta = 'state/' + task_id + '.meta'
            text = read_text(self.home, meta, 65536)
            # Remote paths and absent/ambiguous metadata cannot prove local death.
            if any(line.startswith('remote_host=') and line[12:] for line in text.splitlines()):
                value['verdict'] = 'remote'
                self._workers[task_id] = value
                return value
            value.update(source='backend.agent_state', verdict='unreadable')
            result = subprocess.run(['bash', '-c',
                '. "$1/fm-backend.sh"; '
                'fm_backend_validate_task_endpoint "$2" "$3" >/dev/null 2>&1 || exit 1; '
                'fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET"',
                'fm-work', str(BIN), str(self.home / meta), task_id],
                env=self.env, text=True, capture_output=True, timeout=8)
            verdict = result.stdout.strip()
            if read_text(self.home, meta, 65536) != text:
                value['verdict'] = 'metadata_changed'
            elif result.returncode == 0 and verdict in ('alive', 'dead', 'missing', 'ambiguous', 'unreadable', 'unverified'):
                value.update(verdict=verdict, state='dead' if verdict in ('dead', 'missing') else 'alive' if verdict == 'alive' else 'unknown')
        except (OSError, subprocess.TimeoutExpired):
            pass
        self._workers[task_id] = value
        return value

    def safe_point(self, task_id, record=None):
        # Reached requires the exact request marker after the request's timestamp.
        records = [r for r in self.request_records() if task_id in r.get('safe_tasks', [])
                   and r['operation']['op'] == 'set_pause']
        records.sort(key=lambda r: (r.get('at_ns', 0), r['at']), reverse=True)
        if not records:
            return 'none', None
        r = record or records[0]
        request_id = r['operation']['request_id']
        if r.get('cancelled'):
            return 'none', None
        stamp = int(dt.datetime.fromisoformat(r['at'].replace('Z', '+00:00')).timestamp())
        text = self.status.get(task_id, '')
        for line in reversed(text.splitlines()):
            if re.match(r'^paused\b', line) and '[key=safe-point-' + request_id + ']' in line:
                match = re.search(r'\[at=(\d+)\]', line)
                if match and int(match[1]) >= stamp:
                    return 'reached', request_id
        worker = self.worker_liveness(task_id)
        if worker['state'] == 'dead':
            return 'no_worker', request_id
        if worker['state'] == 'unknown':
            return 'unknown', request_id
        last = text.splitlines()[-1] if text.splitlines() else ''
        if self.rows[task_id]['state'] == 'done' or re.match(r'^(failed|done|blocked)\b', last):
            return 'unconfirmed', request_id
        return 'pending', request_id

    def runtime(self, task_id):
        if task_id in self._runtime:
            return self._runtime[task_id]
        try:
            read_text(self.home, 'state/' + task_id + '.meta', 65536)
        except FileNotFoundError:
            return dict(state='unknown', source='none', detail=tr('No worker is registered; the column comes from the backlog.'))
        # Reuse reconciliation; never infer liveness from status log or process names.
        try:
            result = subprocess.run(['bash', str(BIN / 'fm-crew-state.sh'), task_id, '--json'],
                env=dict(self.env, FM_CREW_STATE_NO_FORGE='1'), pass_fds=(self.lock_fd,) if hasattr(self, 'lock_fd') else (), text=True, capture_output=True, timeout=8)
            value = json.loads(result.stdout)
            if result.returncode == 0 and isinstance(value, dict):
                self._runtime[task_id] = value
                return value
        except (subprocess.TimeoutExpired, ValueError):
            pass
        return dict(state='unknown', source='none', detail=tr('Current activity could not be confirmed.'))

    def snapshot(self):
        tasks = []
        edges = self.edges()
        reasons = dict(records=[dict(id=i, hold_reason=(r.get('hold') or {}).get('reason')) for i,r in self.rows.items()])
        decoded = subprocess.run(['bash', '-c', '. "$1/fm-hold-reason-lib.sh"; fm_hold_reason_decode_stream json', 'fm-work', str(BIN)],
                                 input=json.dumps(reasons), text=True, capture_output=True, timeout=10, check=True)
        display_reasons = {r['id']: r['hold_reason'] for r in json.loads(decoded.stdout)['records']}
        for task_id, row in self.rows.items():
            authored = self.presentations[task_id]
            p = authored['presentation']
            evidence = authored.get('evidence') or {}
            hold = self.current_hold(task_id)
            if hold:
                hold['reason'] = display_reasons[task_id]
            inherited = self.inherited(task_id)
            task_pause = self.structure.get('task_pauses', {}).get(task_id)
            safe, request_id = self.safe_point(task_id) if (hold or inherited or task_pause) else ('none', None)
            blocks = self.blockers(task_id, edges)
            running = row['state'] == 'in_flight'
            worker = self.worker_liveness(task_id) if running else None
            closing = any(r.get('signal') == 'pause.request' and not r.get('cancelled') and not r.get('resumed')
                          and task_id in r.get('safe_tasks', []) and task_id not in r.get('exited', [])
                          for r in self.request_records())
            if row['state'] == 'done':
                state = 'done'
            elif running and (task_pause or inherited or (hold and hold.get('kind') == 'parked')) and (safe != 'reached' or closing) and worker['state'] != 'dead':
                state = 'stopping'
            elif running and not hold and not inherited and not task_pause and worker['state'] != 'dead':
                state = 'running'
            elif task_pause:
                state = 'paused_own'
            elif hold and hold.get('kind') == 'captain':
                state = 'captain'
            elif hold and hold.get('kind') == 'parked':
                state = 'paused_own'
            elif inherited:
                state = 'paused_inherited'
            elif any(b['open'] for b in blocks):
                state = 'waiting_dep'
            elif hold:
                state = 'waiting_' + hold.get('kind', 'external')
            else:
                state = 'ready'
            control_keys = self.ancestors(task_id) + ['task:' + task_id]
            control_times = [time_value(r['at'], 'work.control') for r in self.request_records()
                             if r.get('phase') == 'verified' and r['operation']['target'] in control_keys
                             and r['operation']['op'] != 'request_removal']
            hold_stamp = re.search(r'^Captain hold set:\s*(\S+)\s*$', (row.get('body') or ''), re.M)
            hold_set = hold_stamp[1] if hold_stamp else None
            stamps = control_times + [time_value(evidence.get('observed_at'), 'presentation'), time_value(hold_set, 'captain_hold'), time_value(row.get('closed'), 'backlog.closed')]
            for stamp in re.findall(r'\[at=(\d+)\]', self.status[task_id]):
                try:
                    stamps.append(time_value(dt.datetime.fromtimestamp(int(stamp), dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'status'))
                except (ValueError, OverflowError, OSError):
                    pass
            lifecycle = authored['lifecycle']
            runtime = self.runtime(task_id) if running and self.include_runtime else None
            if runtime:
                meta, _, _, _ = progress_sources(self.home, task_id, read_text)
                observed_run(lifecycle, runtime, code_head(meta))
            progress = lifecycle['progress']
            if progress:
                progress = dict(progress, done=sum(s['state'] == 'done' for s in progress['steps']), total=len(progress['steps']), updated=time_value(lifecycle['evidence'].get('reported_at'), 'progress.checkpoint'))
            declared_progress = progress
            if not lifecycle['evidence']['current']:
                progress = None
            call_row = dict(row, structured=True, hold_kind=(hold or {}).get('kind'), hold_reason=(hold or {}).get('reason'), hold_set=hold_set)
            call = read_captain_call(call_row, str(self.data))
            origin = re.search(r'^Captain hold origin:\s*(\S+)\s*$', (row.get('body') or ''), re.M)
            receipt = completion_receipt(self.home, row)
            project, subproject = self.display_membership(task_id)
            tasks.append(dict(runtime=runtime, worker_liveness=worker, backlog_state=row['state'], key='task:' + task_id,
                alias=self.aliases.alias('task:' + task_id), kind='task', parent=subproject or project,
                project=project, subproject=subproject, repository_project='project:' + row['repo'] if row.get('repo') else None,
                title=p.get('card_title') or row['title'], reason=(task_pause or hold or inherited or {}).get('reason'), state=state,
                priority=priority(row.get('priority')), pause=dict(own=task_pause or hold, condition=hold if task_pause else None, inherited=inherited, safe_point=safe, request_id=request_id,
                    state='stopping' if state == 'stopping' else 'paused' if state in ('paused_own', 'paused_inherited') and running else 'set_aside' if state in ('paused_own', 'paused_inherited') else 'none',
                    paused_by='task:' + task_id if task_pause or (hold and hold.get('kind') == 'parked') else (inherited or {}).get('from')),
                blocked_by=blocks, frees=dict(direct=[], chain_count=0), root_blocker=next((b['ref'] for b in blocks if b['open']), None),
                question=dict(origin_task='task:' + origin[1] if origin else None, open=bool(hold and hold.get('kind') == 'captain' and row['state'] != 'done'), call=call, answer=self.captain_answers.get(task_id), asked=time_value(hold_set, 'captain_hold')),
                recorded_answers=self.answers_by_origin.get(task_id, []),
                progress=progress, declared_progress=declared_progress, progress_evidence=lifecycle['evidence'],
                phase=lifecycle['phase'], verified_gates=lifecycle['gates'],
                request=p.get('request'), outcome=p.get('outcome'), outcome_occurrence=authored.get('outcome_occurrence'),
                created=task_creation(self.data, row) or time_value(row.get('created'), 'backlog.created'), updated=latest(stamps),
                completed=time_value(receipt['value'], 'completion') if receipt else time_value(row.get('closed'), 'backlog.closed') if row['state'] == 'done' else None,
                rev=self.rev))
        requests = {}
        for task in tasks:
            request = task['request']
            if request is None:
                continue
            # Membership is explicit; legacy titles and groups never invent it.
            group = requests.setdefault(request['id'], dict(request, scope='req:' + request['id'], pause=self.structure['groups'].get('req:' + request['id'], {}).get('pause'), tasks=[], updated_at=None))
            group['tasks'].append(task['key'])
            updated = task['updated']['value']
            if updated and (group['updated_at'] is None or updated > group['updated_at']):
                group['updated_at'] = updated
        by_key = {t['key']: t for t in tasks}
        for task in tasks:
            origin = by_key.get(task['question']['origin_task'])
            task['question']['origin'] = dict(key=task['question']['origin_task'], available=origin is not None,
                alias=origin['alias'] if origin else None, title=origin['title'] if origin else None,
                backlog_state=origin['backlog_state'] if origin else None, completed=origin['completed'] if origin else None,
                source='owner.retained_row' if origin else None) if task['question']['origin_task'] else None
        def root_blocker(key, visited):
            if key in visited:
                return key  # existing invalid historical graphs remain visible
            visited = visited | {key}
            if key.startswith('task:'):
                node = by_key.get(key)
                if node:
                    opened = [b['ref'] for b in node['blocked_by'] if b['open']]
                    return root_blocker(opened[0], visited) if opened else key
                return key
            members = [i for i in self.members(key) if self.rows[i]['state'] != 'done']
            return root_blocker('task:' + sorted(members)[0], visited) if members else key
        for t in tasks:
            if t['root_blocker']:
                t['root_blocker'] = root_blocker(t['root_blocker'], {t['key']})
        reverse_deps = {}
        for task in tasks:
            for ref in dict.fromkeys(b['ref'] for b in task['blocked_by']):
                reverse_deps.setdefault(ref, []).append(task['key'])
        for t in tasks:
            direct = reverse_deps.get(t['key'], [])
            seen = set(direct)
            pending = list(direct)
            while pending:
                key = pending.pop()
                for child in reverse_deps.get(key, []):
                    if child not in seen:
                        seen.add(child)
                        pending.append(child)
            t['frees'] = dict(direct=direct, chain_count=len(seen))
        groups = []
        for key in sorted((set('project:' + r for r in self.projects) | set(self.structure['groups'])) - {k for k in self.structure['groups'] if k.startswith('req:')}):
            raw = self.structure['groups'].get(key, {})
            repo = raw.get('repo', key[8:] if key.startswith('project:') else None)
            kind = raw.get('kind', 'project')
            topology = self.hierarchy(key)
            members = [by_key['task:' + i] for i in self.display_members(key)]
            pause = copy.deepcopy(raw.get('pause'))
            opened = [t for t in members if t['state'] != 'done']
            if not pause and self.structure.get('freeze') and (opened and all(t['pause']['inherited'] and t['pause']['inherited']['from'] == 'freeze' for t in opened)):
                pause = dict(reason=self.structure['freeze']['reason'], by='captain', at=None, from_='freeze', inherited=True)
            if pause:
                pause['affected'] = self.affected([t['key'] for t in members], tasks)
            groups.append(dict(key=key, scope=key, alias=self.aliases.alias(key), kind=topology['kind'], parent=topology['parent'],
                **({k:v for k,v in self.projects.get(repo, {}).items() if k not in ('key', 'label')} if kind == 'project' else {}),
                project=topology['parent'] or key, repository_project='project:' + str(repo), label=topology['label'], note=raw.get('note'), aliases=raw.get('aliases', []), priority=priority(raw.get('priority')),
                pause=pause, blocked_by=[dict(ref=b, by=a, open=b not in self.keys() or any(self.rows[i]['state'] != 'done' for i in self.members(b))) for k,b,a in self.edges() if k == key],
                created=time_value(raw.get('created_at'), 'structure'), updated=latest([t['updated'] for t in members] + [time_value(raw.get('updated_at'), 'structure')]), rev=self.rev))
        def rank(v):
            return v if v is not None else 5
        def sort_key(t):
            own = t['priority']['own']
            root = t['project'] if self.logical_layout() else t['repository_project']
            project = self.structure['groups'].get(root, {}).get('priority')
            sub = self.structure['groups'].get(self.structure['membership'].get(t['key'][5:]), {}).get('priority')
            manual = self.structure['order']
            return (0, manual.index(t['key'][5:])) if t['key'][5:] in manual else (1, rank(project if project is not None else own), rank(sub if sub is not None else own), rank(own), t['key'])
        request_groups = [dict(r, key='request:' + r['id']) for r in requests.values()]
        order = self.structure['order']
        # «Mi orden» is the work order: placed requests keep the captain's
        # order; any request not yet placed enters by its priority rank.
        unit = {t['key']: 'request:' + t['request']['id'] if t['request'] else t['key'] for t in tasks}
        best = {}
        for t in tasks:
            if t['state'] != 'done':
                best[unit[t['key']]] = min(best.get(unit[t['key']], (9,)), sort_key(t))
        units = {g['key'] for g in request_groups} | set(unit.values())
        placed = [k for k in order if k in units]
        pending = sorted(units - set(placed), key=lambda k: (best.get(k, (9,)), k))
        work = []
        for k in placed:
            while pending and best.get(pending[0], (9,)) < best.get(k, (9,)):
                work.append(pending.pop(0))
            work.append(k)
        work += pending
        self.work_order = [k for k in work if k.startswith('request:')]
        position = {k: i for i, k in enumerate(work)}
        def unit_slot(k):
            # Placed requests rank in the captain's order; other work enters before
            # the first placed request it outranks, so with nothing placed all tie.
            if k in placed:
                return (placed.index(k), 1)
            return (next((i for i, p in enumerate(placed) if best.get(k, (9,)) < best.get(p, (9,))), len(placed)), 0)
        self.work_slot, self.work_unit, self.work_placed = unit_slot, unit, set(placed)
        if getattr(self, 'request_sort', 'recent') == 'manual':
            request_groups.sort(key=lambda g: position[g['key']])
        else:
            request_groups.sort(key=lambda g: g['key'])
            request_groups.sort(key=lambda g: g['updated_at'] or '', reverse=True)
        # Projects view: project_key is the displayed project (a logical root
        # included) most of a request's tasks show under, a tie preferring the
        # declared repository; the declared project text stays as authored.
        # Each project lists its requests in this order.
        listed = {}
        for g in request_groups:
            roots = [by_key[k]['project'] for k in g['tasks'] if by_key[k]['project']]
            g['project_key'] = max(dict.fromkeys(roots), key=lambda k: (roots.count(k), k == 'project:' + g['project'])) if roots else None
            listed.setdefault(g['project_key'], []).append(g['key'])
        # Relations between projects: open task-to-task dependencies whose ends
        # show under different projects, aggregated per pair. They describe the
        # project header only, so member tasks never inherit them the way they
        # inherit the declared group dependencies in blocked_by.
        derived = {}
        for a, b, _ in self.edges():
            source, blocker = by_key.get(a), by_key.get(b)
            if (source and blocker and source['state'] != 'done' and blocker['state'] != 'done'
                    and source['project'] and blocker['project'] and source['project'] != blocker['project']):
                via = derived.setdefault(source['project'], {}).setdefault(blocker['project'], [])
                if dict(task=a, blocker=b) not in via:
                    via.append(dict(task=a, blocker=b))
        for g in groups:
            if g['kind'] == 'project':
                g['requests'] = listed.get(g['key'], [])
                g['derived_blocked_by'] = [dict(ref=ref, open=True, via=via) for ref, via in sorted(derived.get(g['key'], {}).items())]
        def slot(t):
            # Placed requests keep their tasks together in the captain's order;
            # other work enters by its own priority, so an unplaced board is today's order.
            if unit[t['key']] in placed:
                return (placed.index(unit[t['key']]), 1)
            return (next((i for i, k in enumerate(placed) if sort_key(t) < best.get(k, (9,))), len(placed)), 0)
        sigue = [t['key'] for t in sorted(tasks, key=lambda t: (slot(t), sort_key(t))) if t['state'] == 'ready']
        # Who gives way when there is no room: the running work lowest in the
        # work order, only for ready work the captain placed above it.
        crew = self.capacity()
        running = sorted((t for t in tasks if t['state'] == 'running'), key=lambda t: position[unit[t['key']]])
        yields = None
        if sigue and running and unit[sigue[0]] in placed and position[unit[sigue[0]]] < position[unit[running[-1]['key']]]:
            yields = dict(pause=running[-1]['key'], request=unit[running[-1]['key']], for_task=sigue[0], for_request=unit[sigue[0]],
                          room=crew.get('reason') is None and (crew.get('agents_cap') is None or crew['agents_running'] < crew['agents_cap']))
        controls = [r for r in self.request_records() if r.get('signal') in ('pause.request', 'resume.request')]
        current = {}
        for record in sorted(controls, key=lambda r: r.get('at_ns', 0)):
            current[record['scope']] = record
        current = dict(sorted(current.items(), key=lambda pair: pair[1].get('at_ns', 0)))
        queue = sorted((r['scope'] for r in current.values() if r.get('pause_state') == 'queued' and not r.get('cancelled')), key=self.scope_position)
        pauses = [dict(scope=r['scope'], state=r.get('pause_state', 'none'), at=r['at'],
                       agents_total=len(r.get('safe_tasks') or r.get('candidates', [])),
                       agents_at_safe_point=sum(self.safe_point(i, r)[0] == 'reached' for i in r.get('safe_tasks', [])) if r['signal'] == 'pause.request' else len(r.get('candidates', [])),
                       agents_closed=len(r.get('exited', r.get('candidates', []))), requested_by=r['operation'].get('actor', 'captain'),
                       inherited_from=sorted({k for i in self.members(r['operation']['target']) for k in self.ancestors(i)
                                              if k != r['operation']['target'] and self.structure['groups'].get(k, {}).get('pause')}),
                       reason=r['result'].get('reason'), running=r['result'].get('running'), cap=r['result'].get('cap'),
                       queue_position=queue.index(r['scope']) + 1 if r['scope'] in queue else None)
                  for r in current.values()]
        return dict(schema='fm-work-snapshot.v1', generated_at=now(), home=str(self.home), projects=[g for g in groups if g['kind'] == 'project'],
                    subprojects=[g for g in groups if g['kind'] == 'subproject'], tasks=tasks, requests=request_groups, sigue=sigue, rev=self.rev, history_sources=self.history_sources,
                    pause_controls=pauses, events=[e for r in sorted(controls, key=lambda r: r.get('at_ns', 0)) for e in r.get('events', [])],
                    crew=crew, yields=yields,
                    aliases=dict(state='active' if self.aliases.value is not None else 'uninitialized'))

    def scope_position(self, scope):
        # A control scope ranks by its highest member in «Mi orden» (set by snapshot).
        ranks = [self.work_slot(self.work_unit[k]) for k in ('task:' + i for i in self.members(scope)) if k in self.work_unit]
        return min(ranks, default=(len(self.work_placed) + 1, 0))

    @staticmethod
    def affected(keys, tasks):
        return dict(running=[t['key'] for t in tasks if t['key'] in keys and t['state'] == 'running'],
                    stopping=[t['key'] for t in tasks if t['key'] in keys and t['state'] == 'stopping'],
                    queued=[t['key'] for t in tasks if t['key'] in keys and t['state'] not in ('running', 'stopping', 'done')],
                    waiting_behind=[t['key'] for t in tasks if any(b['ref'] in keys and b['open'] for b in t['blocked_by'])])

    def change(self, op):
        """Simulate only. Returns owner argv and exact structure changes."""
        name, target = op.get('op'), op.get('target')
        refuse(op.get('actor', 'captain') not in ('captain', 'firstmate'), 'invalid_value', tr('Invalid operation author.'))
        refuse(name not in OPS, 'unsupported_op', tr('Operation unavailable.'))
        refuse(not isinstance(target, str) or (target not in self.keys() and not (name == 'move' and target in self.request_keys())), 'unknown_target', tr('The item no longer exists.'))
        refuse(op.get('expected_rev') != self.rev, 'stale_revision', tr('The data changed; review it again.'))
        task_id = target[5:] if target.startswith('task:') else None
        row = self.rows.get(task_id)
        refuse(row is not None and row['state'] == 'done' and name != 'request_removal', 'task_done', tr('This task is already complete.'))
        if name == 'move' and target in self.request_keys():
            refuse(op.get('adopt_priority') is not None or op.get('restore_unset'), 'invalid_value', tr('Request moves change only the work order.'))
            peers = self.request_keys()
            before_key, after_key = op.get('before'), op.get('after')
            refuse(bool(before_key) and bool(after_key), 'invalid_value', tr('Choose before or after.'))
            anchor = before_key or after_key
            refuse(anchor == target or (anchor is not None and anchor not in peers), 'invalid_value', tr('Invalid order target.'))
            before = copy.deepcopy(self.structure['order'])
            if 'restore_order' in op:
                order = op['restore_order']
                refuse(not isinstance(order, list) or any(not isinstance(k, str) or k not in peers | set(self.rows) for k in order)
                       or len(set(order)) != len(order), 'invalid_value', tr('Invalid order.'))
            else:
                self.snapshot()
                order = [k for k in self.work_order if k != target]
                at = order.index(anchor) + (1 if after_key else 0) if anchor else len(order)
                order.insert(at, target)
                order = [k for k in before if k not in peers] + order
            self.structure['order'] = order
            # Request moves set the work order; they never rewrite task priorities.
            return [], before, dict(op='move', target=target, restore_order=before)
        group = None
        if target.startswith('req:'):
            refuse(name not in ('set_pause', 'clear_pause'), 'unsupported_op', tr('Request scopes support pause and resume.'))
            group = self.structure['groups'].setdefault(target, dict(kind='request', repo=None, label=self.requests.get(target[4:], {}).get('label', target[4:]), priority=None, pause=None))
        elif task_id is None and name != 'request_removal':
            repo = target[8:] if target.startswith('project:') else self.structure['groups'][target]['repo']
            group = self.structure['groups'].setdefault(target, dict(kind='project', repo=repo, label=repo, priority=None, pause=None, blocked_by=[], aliases=[], created_at=None))
        command, undo, before = [], None, None
        if name == 'set_priority':
            value = op.get('value')
            refuse(value not in ('NA', None) and (type(value) is not int or value not in range(5)), 'invalid_value', tr('Choose P0 through P4 or NA.'))
            before = row.get('priority') if row else group.get('priority')
            value = (4 if row else None) if value == 'NA' else value
            if row:
                row['priority'] = value
                command = ['@unset_priority', task_id, str(before)] if value is None and before is not None else [] if value is None else ['update', task_id, '--priority', str(value)]
            else:
                group['priority'] = value
            undo = dict(op='set_priority', target=target, value=before)
        elif name in ('set_pause', 'clear_pause'):
            task_pauses = self.structure.get('task_pauses', {})
            layered = row is not None and (task_id in task_pauses or (name == 'set_pause' and row.get('hold') and row['hold'].get('kind') != 'parked'))
            freeze = self.structure.get('freeze')
            if freeze and not layered:
                resumed = freeze.setdefault('resumed', {})
                if name == 'clear_pause':
                    resumed[target] = dict(by=op.get('actor', 'captain'), at=now())
                else:
                    resumed.pop(target, None)
            before = copy.deepcopy(task_pauses.get(task_id) if layered else row.get('hold') if row else group.get('pause'))
            refuse(not layered and row is not None and before and before.get('kind') != 'parked', 'invalid_value', tr('This wait belongs to another process; respond or resolve it through its channel.'))
            if name == 'set_pause':
                refuse(not plain(op.get('reason'), 200) or any(c in op['reason'] for c in '()'), 'invalid_value', tr('Write a brief reason without parentheses.'))
                if layered:
                    self.structure.setdefault('task_pauses', {})[task_id] = dict(kind='parked', reason=op['reason'], set=now(), by=op.get('actor', 'captain'))
                elif row:
                    row['hold'] = dict(kind='parked', reason=op['reason'], set=now())
                    command = ['hold', task_id, '--kind', 'parked', '--reason', op['reason']]
                else:
                    group['pause'] = dict(reason=op['reason'], by=op.get('actor', 'captain'), at=now())
                undo = dict(op='set_pause', target=target, reason=before['reason']) if before else dict(op='clear_pause', target=target)
            else:
                if layered:
                    self.structure['task_pauses'].pop(task_id, None)
                elif row:
                    row.pop('hold', None)
                    command = ['unhold', task_id] if before else []
                else:
                    group['pause'] = None
                if before:
                    undo = dict(op='set_pause', target=target, reason=before['reason'])
        elif name in ('add_dep', 'remove_dep'):
            blocker = op.get('on')
            refuse(not isinstance(blocker, str) or blocker not in self.keys(), 'unknown_target', tr('The dependency no longer exists.'))
            refuse(blocker == target, 'self_dependency', tr('An item cannot wait for itself.'))
            exists = any(a == target and b == blocker for a,b,_ in self.edges())
            before = exists
            if row and blocker.startswith('task:'):
                deps = row.setdefault('deps', [])
                if name == 'add_dep' and not exists:
                    deps.append(dict(type='blocked-by', id=blocker[5:]))
                    command = ['block', task_id, '--by', blocker[5:]]
                elif name == 'remove_dep' and exists:
                    deps[:] = [d for d in deps if not (d.get('type') == 'blocked-by' and d.get('id') == blocker[5:])]
                    command = ['unblock', task_id, '--by', blocker[5:]]
                meta_key = task_id + '<-' + blocker[5:]
                if name == 'add_dep':
                    self.structure['edge_meta'][meta_key] = dict(by=op.get('actor', 'captain'), at=now())
                else:
                    self.structure['edge_meta'].pop(meta_key, None)
            else:
                if group is not None:
                    edges = group.setdefault('blocked_by', [])
                else:
                    edges = self.structure.setdefault('mixed_edges', [])
                edges[:] = [e for e in edges if not (e['ref'] == blocker and (group is not None or e['target'] == target))]
                if name == 'add_dep':
                    edges.append(dict(target=target, ref=blocker, by=op.get('actor', 'captain'), at=now()))
            cycle = self.cycle()
            refuse(bool(cycle), 'cycle', tr('This dependency creates a cycle.'), cycle_path=cycle)
            if exists != (name == 'add_dep'):
                undo = dict(op='remove_dep' if name == 'add_dep' else 'add_dep', target=target, on=blocker)
        elif name == 'move':
            refuse(not row, 'invalid_value', tr('Only tasks and requests can be ordered.'))
            snap = self.snapshot()
            refuse(target not in snap['sigue'], 'invalid_value', tr('Only tasks in Next can be ordered.'))
            before_key, after_key = op.get('before'), op.get('after')
            refuse(bool(before_key) and bool(after_key), 'invalid_value', tr('Choose before or after.'))
            anchor = before_key or after_key
            refuse(anchor == target or (anchor is not None and anchor not in snap['sigue']), 'invalid_value', tr('Invalid order target.'))
            before = dict(order=copy.deepcopy(self.structure['order']), priority=row.get('priority'))
            # Internal undo records the complete order under the same revision check.
            if 'restore_order' in op:
                order = op['restore_order']
                refuse(not isinstance(order, list) or len(set(order)) != len(order) or any(not isinstance(i, str) or (i not in self.rows and i not in self.request_keys()) for i in order), 'invalid_value', tr('Invalid order.'))
            else:
                order = [k[5:] for k in snap['sigue'] if k != target]
                at = order.index(anchor[5:]) + (1 if after_key else 0) if anchor else len(order)
                order.insert(at, task_id)
            value = op.get('adopt_priority')
            if value is not None:
                refuse(type(value) is not int or value not in range(5), 'invalid_value', tr('Invalid priority.'))
                row['priority'] = value
                command = ['update', task_id, '--priority', str(value)]
            if op.get('restore_unset') is True:
                command = ['@unset_priority', task_id, str(row.get('priority'))] if row.get('priority') is not None else []
                row['priority'] = None
            self.structure['order'] = order if 'restore_order' in op else [k for k in self.structure['order'] if k.startswith('request:')] + order
            undo = dict(op='move', target=target, restore_order=before['order'], adopt_priority=before['priority'], restore_unset=before['priority'] is None)
        elif name == 'request_removal':
            refuse(not isinstance(op.get('note', ''), str) or len(op.get('note', '')) > 2000 or '\x00' in op.get('note', ''),
                   'invalid_value', tr('The note must contain at most 2000 characters and no NUL.'))
        if group is not None:
            group['updated_at'] = now()
        return command, before, undo

    def preview(self, op):
        before = self.snapshot()
        command, previous, undo = self.change(op)
        after = self.snapshot()
        affected = ['task:' + i for i in self.members(op['target']) if self.rows[i]['state'] != 'done']
        impact = dict(affected=self.affected(affected, before['tasks']), sigue_after=after['sigue'], moved_any=before['sigue'] != after['sigue'],
                      offer=None, still_paused=[t['key'] for t in after['tasks'] if t['key'] in affected and (t['pause']['own'] or t['pause']['inherited'])], cycle_path=None)
        if (op['op'] == 'set_priority' or (op['op'] == 'move' and op['target'].startswith('task:'))) and not impact['moved_any']:
            running = [t for t in before['tasks'] if t['state'] == 'running']
            if running:
                impact['offer'] = dict(op='set_pause', target=running[0]['key'], why=tr('Changing priority does not interrupt active work.'))
        if op['op'] == 'request_removal':
            impact['consultation'] = self.consultation(op, before)
        return command, previous, undo, impact

    def consultation(self, op, snapshot):
        nodes = {n['key']: n for field in ('projects', 'subprojects', 'tasks') for n in snapshot[field]}
        target = nodes[op['target']]
        members = set('task:' + i for i in self.display_members(op['target']))
        scope = members | {op['target']}
        scope.update(n['key'] for n in nodes.values() if n['kind'] == 'subproject' and n['parent'] == op['target'])
        # Canonical ancestors own controls even when presentation reparented a
        # public counterpart; include their conditions as consultation evidence.
        controls = set(k for key in members for k in self.ancestors(key[5:]))
        scope |= controls
        subproject = target.get('subproject') or (target['key'] if target['kind'] == 'subproject' else None)
        return dict(target=dict(key=target['key'], alias=target['alias'], kind=target['kind'], parent=target['parent']),
            note=op.get('note', ''), initiative=dict(project=target['project'], subproject=subproject),
            groups=[dict(key=key, alias=nodes[key]['alias'], parent=nodes[key]['parent'], kind=nodes[key]['kind'],
                         pause=nodes[key]['pause'], blocked_by=nodes[key]['blocked_by'])
                    for key in sorted(scope) if key in nodes and nodes[key]['kind'] != 'task'],
            tasks=[dict(key=t['key'], alias=t['alias'], state=t['state'], backlog_state=t['backlog_state'],
                        question_open=t['question']['open']) for t in snapshot['tasks'] if t['key'] in members],
            affected=self.affected(list(members), snapshot['tasks']),
            dependencies=[dict(target=a, on=b, by=by,
                               open=b not in self.keys() or any(self.rows[i]['state'] != 'done' for i in self.members(b)))
                          for a, b, by in self.edges() if a in scope or b in scope],
            source='owner.current_snapshot', advice=None, deletion_authorized=False)

    def note(self, op, safe_tasks, consultation=None):
        eligible = [t['key'][5:] for t in self.snapshot()['tasks'] if t['key'][5:] in self.members(op['target'])
                    and not t['pause']['own'] and not t['pause']['inherited'] and not any(b['open'] for b in t['blocked_by'])
                    and t['backlog_state'] == 'in_flight' and t['worker_liveness']['state'] == 'alive'] if op['op'] == 'clear_pause' else []
        body = json.dumps(dict(schema='fm-work-control-note.v1', operation=op, consultation=consultation, safe_tasks=safe_tasks, resume_candidates=eligible,
             instruction=(tr('Reach a safe point, save progress, and use fm-send from the primary. Each worker must record paused [key=safe-point-{request_id}] [at=<epoch>]. Do not interrupt or discard work.').format(request_id=op['request_id']) if safe_tasks else
                          tr('For clear_pause, review resume_candidates and recheck work snapshot before using fm-send to resume; never remove individual holds or the freeze. For request_removal, review without deleting or discarding work and respond through fm-inbox reply.'))),
                          ensure_ascii=False)
        flags = ['--wake-primary'] if op['op'] == 'request_removal' else []
        receipt = json.loads(self.command('fm-inbox.sh', 'note', '--request-id', op['request_id'], '--json', *flags, '-',
                                          body=body, accepted=(0, 3) if op['op'] == 'request_removal' else (0,)))
        refuse(receipt.get('saved') is not True or receipt.get('request_id') != op['request_id']
               or not isinstance(receipt.get('id'), str) or not re.fullmatch(r'[A-Za-z0-9._-]+', receipt['id']),
               'owner_failed', tr('The inquiry receipt was not confirmed.'))
        return receipt

    def apply(self, op):
        request_id = op.get('request_id')
        refuse(not isinstance(request_id, str) or not REQUEST.fullmatch(request_id), 'invalid_value', tr('Invalid request identity.'))
        path = 'data/work-requests/' + request_id + '.json'
        existing = self.read(path)
        if existing:
            refuse(existing['operation'] != op, 'request_mismatch', tr('This identity belongs to another request.'))
            return self.reconcile(existing, path, retry=True)
        self.load()
        command, previous, undo, impact = self.preview(op)
        desired_structure = copy.deepcopy(self.structure)
        safe_tasks = [i for i in self.members(op['target']) if self.rows[i]['state'] == 'in_flight'] if op['op'] == 'set_pause' else []
        pending_tasks = [i for i in safe_tasks if self.worker_liveness(i)['state'] != 'dead']
        record = dict(schema='fm-work-request.v1', at=now(), at_ns=time.time_ns(), operation=op, safe_tasks=safe_tasks,
                      phase='prepared', command=command, desired_structure=desired_structure,
                      result=dict(request_id=request_id, state='received', code=None, message=tr('Request received.'), impact=impact, before=previous, undo=undo, pending_reason=None))
        self.atomic(path, record)  # A crash never silently replays partially executed effects.
        try:
            if command:
                self.command('@unset_priority', *command[1:]) if command[0] == '@unset_priority' else self.command('fm-tasks-axi.sh', *command)
            if op['op'] != 'request_removal':
                self.atomic(self.structure_path, desired_structure)
            record['phase'] = 'written'
            self.atomic(path, record)
            if pending_tasks or op['op'] in ('request_removal', 'clear_pause'):
                record['note'] = self.note(op, pending_tasks, impact.get('consultation'))
                if op['op'] == 'request_removal':
                    record['result']['consultation'] = dict(note_id=record['note']['id'], status='pending', reply=None)
            self.load()
            self.verify(op)
            refuse(self.structure != desired_structure, 'owner_failed', tr('The structure was not confirmed.'))
            record['phase'] = 'verified'
            self.atomic(path, record)
            if undo:
                undo['expected_rev'] = self.rev
            self.atomic(path, record)
            return self.reconcile(record, path)
        except (Refusal, subprocess.TimeoutExpired) as exc:
            record['result'].update(state='failed', code='owner_failed', message=str(exc), pending_reason=tr('Partial effects may exist; review the receipt before retrying with another identity.'))
            self.atomic(path, record)
            return record['result']

    def verify(self, op):
        target, name = op['target'], op['op']
        row = self.rows.get(target[5:]) if target.startswith('task:') else None
        group = self.structure['groups'].get(target, {})
        if name == 'set_priority':
            expected = (4 if row else None) if op['value'] == 'NA' else op['value']
            actual = row.get('priority') if row else group.get('priority')
            refuse(actual != expected, 'owner_failed', tr('The priority was not confirmed.'))
        elif name == 'move':
            if op.get('restore_unset'):
                refuse(row.get('priority') is not None, 'owner_failed', tr('The unset priority was not restored.'))
            elif op.get('adopt_priority') is not None:
                refuse(row.get('priority') != op['adopt_priority'], 'owner_failed', tr('The move priority was not confirmed.'))
        elif name == 'set_pause':
            actual = self.structure.get('task_pauses', {}).get(target[5:]) or row.get('hold') if row else group.get('pause')
            refuse(not actual or actual.get('reason') != op['reason'], 'owner_failed', tr('The pause was not confirmed.'))
        elif name == 'clear_pause':
            actual = self.structure.get('task_pauses', {}).get(target[5:]) or (row.get('hold') if row and (row.get('hold') or {}).get('kind') == 'parked' else None) if row else group.get('pause')
            refuse(bool(actual), 'owner_failed', tr('The pause was not cleared.'))
        elif name in ('add_dep', 'remove_dep'):
            actual = any(a == target and b == op['on'] for a,b,_ in self.edges())
            refuse(actual != (name == 'add_dep'), 'owner_failed', tr('The dependency was not confirmed.'))

    def reconcile(self, record, path, retry=False):
        result = record['result']
        op = record['operation']
        # Only an explicit retry can repair delivery. Removal is advisory, so
        # replaying its idempotent note cannot repeat a work-control effect.
        # Recover old saved-but-unannounced failures and the written/note crash
        # window using the original scope, never a newly computed consultation.
        if retry and op['op'] == 'request_removal' and record['phase'] == 'written':
            record['note'] = self.note(op, [], result['impact']['consultation'])
            record['phase'] = 'verified'
            result.update(state='received', code=None)
            self.atomic(path, record)
            retry = False  # note() already attempted announcement for this call.
        if record['phase'] != 'verified':
            if result['state'] != 'failed':
                result.update(state='failed', code='owner_failed', message=tr('Request interrupted; review effects before retrying.'), pending_reason=tr('No effects were repeated.'))
            return result
        if result['state'] == 'applied':
            return result
        if record['safe_tasks']:
            self.load()
            self._workers.clear()  # A receipt check always takes fresh endpoint evidence.
            if op['target'].startswith('task:'):
                selected = [i for i in record['safe_tasks'] if i in self.rows and
                            (i in self.structure.get('task_pauses', {}) or (self.current_hold(i) or {}).get('kind') == 'parked')]
            else:
                selected = self.members(op['target']) if self.structure['groups'].get(op['target'], {}).get('pause') else []
            active = [i for i in record['safe_tasks'] if i in selected]
            states = [self.safe_point(i, record)[0] for i in active]
            record['worker_evidence'] = {i: self.worker_liveness(i) for i in active}
            if all(s in ('reached', 'no_worker') for s in states):
                result.update(state='applied', message=tr('Pause confirmed without an active worker.') if 'no_worker' in states else tr('Pause confirmed at a safe point.') if states else tr('The pause was already cleared; no worker was resumed.'), pending_reason=None)
                if not active:
                    record['cancelled'] = True
            else:
                result.update(state='received', pending_reason=tr('Worker liveness cannot be confirmed. Check its connection and query this request again to verify the pause.') if 'unknown' in states else tr('Safe point unconfirmed.') if 'unconfirmed' in states else tr('Reaching a safe point.'))
        elif op['op'] == 'request_removal':
            note = record.get('note', {})
            note_id = note.get('id')
            receipts = json.loads(self.command('fm-inbox.sh', 'receipts', '--all-pending', '--all-handled', '--all-replies'))
            replies = receipts.get('replies', [])
            if any(r.get('id') == note_id or r.get('note_id') == note_id for r in replies):
                result.update(state='applied', message=tr('Firstmate answered the request.'), pending_reason=None)
                result['consultation'] = dict(note_id=note_id, status='replied', reply=next(r for r in replies if r.get('id') == note_id or r.get('note_id') == note_id))
            else:
                if retry and note_id and not note.get('acknowledged'):
                    record['note'] = self.note(op, [], result['impact']['consultation'])
                result.update(state='received', message=tr('Inquiry recorded, awaiting Firstmate review.'), pending_reason=tr('Waiting for Firstmate review and response.'))
                result['consultation'] = dict(note_id=note_id, status='pending', reply=None)
                if record.get('note', {}).get('announced') is False and not record['note'].get('acknowledged'):
                    result.update(message=tr('Inquiry saved; its announcement to Firstmate was not confirmed.'),
                                  pending_reason=tr('Retry the same request to repair its announcement without duplicating it.'))
                elif record.get('note', {}).get('native_delivery', {}).get('state') not in (None, 'accepted', 'already-handled'):
                    result.update(message=tr('Inquiry saved; native Firstmate attention is unconfirmed.'),
                                  pending_reason=tr('The inquiry remains pending; check its delivery receipt before repeating it.'))
                result['consultation']['native_delivery'] = record.get('note', {}).get('native_delivery')
        else:
            result.update(state='applied', message=tr('Change recorded and confirmed.'), pending_reason=None)
        self.atomic(path, record)
        return result

    def reconcile_pauses(self):
        # Observation may settle existing pause receipts, never replay controls or notes.
        for record in list(self.request_records()):
            if not record.get('signal') and record.get('phase') == 'verified' and record['operation']['op'] == 'set_pause' and record['result']['state'] == 'received':
                self.reconcile(record, 'data/work-requests/' + record['operation']['request_id'] + '.json')

    def close_safe_point(self, request_id):
        # Exits only agents that reached their own safe point for this request; repeat calls exit nothing twice.
        path = 'data/work-requests/' + request_id + '.json'
        record = self.read(path)
        refuse(record is None, 'unknown_target', tr('Unknown request.'))
        refuse(record['operation']['op'] != 'set_pause' or record.get('phase') != 'verified' or record.get('cancelled'),
               'invalid_value', tr('Only a verified pause request can close agents.'))
        self.load()
        self._workers.clear()
        target = record['operation']['target']
        hold = self.current_hold(target[5:]) if target.startswith('task:') else None
        active = (self.structure.get('task_pauses', {}).get(target[5:]) or (hold if (hold or {}).get('kind') == 'parked' else None)) if target.startswith('task:') else self.structure['groups'].get(target, {}).get('pause')
        refuse(not active, 'invalid_value', tr('The pause was cleared; no agent was closed.'))
        refuse(any(r.get('at_ns', 0) > record.get('at_ns', 0) and r['operation']['target'] == target
                   and r['operation']['op'] in ('set_pause', 'clear_pause') for r in self.request_records()),
               'invalid_value', tr('This pause was superseded; no agent was closed.'))
        exited = record.setdefault('exited', [])
        pending, failed, unconfirmed, errors = [], [], [], {}
        for task_id in record['safe_tasks']:
            if task_id in exited:
                continue
            state = self.safe_point(task_id, record)[0]
            if record.get('signal') and state in ('pending', 'unknown') and time.time_ns() - record['at_ns'] > max(1, min(86400, int(os.environ.get('FM_WORK_SAFE_POINT_TIMEOUT', '300')))) * 10**9:
                state = 'unconfirmed'
            if state == 'reached':
                try:
                    stop = subprocess.run(['bash', str(BIN / 'fm-control.sh'), task_id, 'exit'], env=self.env, pass_fds=(self.lock_fd,) if hasattr(self, 'lock_fd') else (), text=True, capture_output=True, timeout=180)
                    ok = stop.returncode == 0
                    if not ok:
                        errors[task_id] = stop.stderr.strip()[-500:]
                except subprocess.TimeoutExpired:
                    ok = False
                    errors[task_id] = 'exit timed out; inspect the recorded endpoint'
                (exited if ok else failed).append(task_id)
            elif state == 'unconfirmed':
                unconfirmed.append(task_id)
            elif state != 'no_worker':
                pending.append(task_id)
        self.atomic(path, record)
        complete = not (pending or failed or unconfirmed)
        return dict(state='applied' if complete else 'received', request_id=request_id, exited=exited, pending=pending, failed=failed, unconfirmed=unconfirmed, errors=errors,
                    event='pause.confirmed' if complete else 'pause.unconfirmed' if unconfirmed else None)

    def review_outcome(self, payload):
        refuse(set(payload) != {'target', 'occurrence', 'review', 'expected_review'}
               or not isinstance(payload.get('target'), str)
               or not plain(payload.get('occurrence'), 128)
               or payload.get('review') not in ('needed', 'done')
               or payload.get('expected_review') not in ('needed', 'done'),
               'invalid_value', 'Review requires target, occurrence, review and expected_review.')
        target = self.aliases.resolve(payload['target'])
        refuse(not target.startswith('task:') or target[5:] not in self.rows,
               'unknown_target', 'Unknown task.')
        task_id = target[5:]
        authored = self.presentations[task_id]
        refuse((authored.get('evidence') or {}).get('available') is False, 'owner_failed', 'Invalid presentation declaration.')
        outcome = authored['presentation'].get('outcome')
        refuse(not outcome or outcome.get('review') not in ('needed', 'done'), 'no_outcome', 'No reviewable outcome.')
        refuse(payload['occurrence'] != authored.get('outcome_occurrence'), 'stale_occurrence', 'The result has changed. Refresh before reviewing.')
        refuse(payload['expected_review'] != outcome['review'], 'review_conflict', 'The review mark has changed. Refresh before reviewing.')
        path = authored['evidence']['path']
        value = self.read(path)
        value['presentation']['outcome']['review'] = payload['review']
        value['outcome_occurrence'] = authored['outcome_occurrence']
        value['observed_at'] = now()
        self.atomic(path, value)
        return dict(ok=True, state='applied', target=target, occurrence=authored['outcome_occurrence'],
                    outcome=value['presentation']['outcome'],
                    undo=dict(target=target, occurrence=authored['outcome_occurrence'],
                              review=outcome['review'], expected_review=payload['review']))

    def control_event(self, record, event, **fields):
        events = record.setdefault('events', [])
        if not any(e['event'] == event and e.get('task') == fields.get('task') and e.get('reason') == fields.get('reason') for e in events):
            events.append(dict(event=event, scope=record['scope'], request_id=record['operation']['request_id'], at=now(), **fields))

    def capacity(self):
        value = json.loads(self.command('fm-capacity.sh', '--json', accepted=(0, 1)))
        return dict(agents_running=value['lanes']['count'], agents_cap=value['cap']['target'],
                    reason='resources' if value['cap']['status'] == 'invalid' or (value['cap']['status'] == 'ok' and any(
                        not r.startswith('full:') for r in value['verdict']['reasons'])) else None)

    def resume_preview(self, op):
        _, _, _, impact = self.preview(dict(op, op='clear_pause'))
        closed = set()
        for record in sorted(self.request_records(), key=lambda r: r.get('at_ns', 0)):
            closed.update(record.get('exited', []))
            closed.difference_update(record.get('started', []))
        candidates = [i for i in self.members(op['target']) if i in closed and self.rows[i]['state'] == 'in_flight'
                      and not self.progress_reporting_held(i) and not any(b['open'] for b in self.blockers(i))
                      and self.worker_liveness(i)['state'] != 'alive']
        self.load()  # Preview simulated clearing only the selected pause.
        return dict(impact=impact, agents_needed=len(candidates), candidates=candidates, **self.capacity())

    def signal(self, verb, op):
        target = op['target']
        scope = op.get('scope', target)
        if verb.endswith('.preview'):
            refuse(op.get('expected_rev') != self.rev, 'stale_revision', tr('The data changed; review it again.'), snapshot=self.snapshot())
        if verb == 'resume.preview':
            return self.resume_preview(op)
        if verb == 'pause.preview':
            _, _, _, impact = self.preview(dict(op, op='set_pause', reason=op.get('reason', 'Pausa desde el Deck')))
            return dict(self.capacity(), impact=impact, can_pause=True, reason=None)
        request_id = op.get('request_id')
        refuse(not isinstance(request_id, str) or not REQUEST.fullmatch(request_id), 'invalid_value', tr('Invalid request identity.'))
        path = 'data/work-requests/' + request_id + '.json'
        existing = self.read(path)
        if existing:
            refuse(existing.get('signal_operation') != op or existing.get('signal') != verb, 'request_mismatch', tr('This identity belongs to another request.'))
            return existing['result']
        refuse(op.get('expected_rev') != self.rev, 'stale_revision', tr('The data changed; review it again.'), snapshot=self.snapshot())
        matching = [r for r in self.request_records() if r.get('scope') == scope and not r.get('cancelled') and not r.get('resumed')]
        if verb in ('pause.cancel', 'resume.dequeue'):
            selected = [r for r in matching if r.get('signal') == ('pause.request' if verb == 'pause.cancel' else 'resume.request')]
            refuse(not selected, 'invalid_value', tr('No pending request in this scope.'))
            selected = [max(selected, key=lambda r: r.get('at_ns', 0))]
            if verb == 'pause.cancel':
                refuse(any(r.get('pause_state') == 'paused' or r.get('exited') or any(self.safe_point(i, r)[0] == 'reached' for i in r['safe_tasks']) for r in selected),
                       'invalid_value', tr('The safe point was reached; use resume.'))
                result = self.apply(dict(op, op='clear_pause'))
                refuse(result['state'] != 'applied', 'owner_failed', result['message'])
            else:
                refuse(any(r['pause_state'] != 'queued' for r in selected), 'invalid_value', tr('The request is no longer queued.'))
                result = dict(state='applied', request_id=request_id)
            for r in selected:
                r.update(cancelled=True, pause_state='paused' if verb == 'resume.dequeue' else 'none')
                r['result'].update(state='applied', pause_state=r['pause_state'])
                self.atomic('data/work-requests/' + r['operation']['request_id'] + '.json', r)
                if verb == 'pause.cancel':
                    for task_id in r['safe_tasks']:
                        if self.progress_reporting_held(task_id) or any(b['open'] for b in self.blockers(task_id)) or self.worker_liveness(task_id)['state'] == 'dead':
                            continue
                        try:
                            self.command('fm-send.sh', task_id, 'The safe-point request safe-point-' + r['operation']['request_id'] +
                                         ' was cancelled. Continue the saved work; preserve every other hold and pause.')
                        except (Refusal, subprocess.TimeoutExpired) as exc:
                            result.setdefault('warnings', []).append(dict(task=task_id, reason=str(exc)[:500]))
            saved = self.read(path, dict(operation=dict(op, op='clear_pause'), safe_tasks=[], phase='verified', at=now(), at_ns=time.time_ns()))
            saved.update(signal=verb, signal_operation=op, scope=scope, result=result)
            self.atomic(path, saved)
            return result
        if verb == 'pause.request':
            refuse(any(r.get('pause_state') == 'queued' for r in matching), 'invalid_value', tr('Dequeue the pending resume first.'))
            refuse(any(r.get('signal') == verb and r.get('pause_state') in ('pending', 'unconfirmed', 'failed') for r in matching),
                   'invalid_value', tr('A pause is already pending; inspect or cancel its request.'))
            result = self.apply(dict(op, op='set_pause', reason=op.get('reason', 'Pausa desde el Deck')))
            refuse(result['state'] == 'failed', 'owner_failed', result['message'])
            record = self.read(path)
            record.update(signal=verb, signal_operation=op, scope=scope, pause_state='pending')
            self.atomic(path, record)
            for task_id in record['safe_tasks']:
                if self.safe_point(task_id, record)[0] in ('reached', 'no_worker'):
                    continue
                try:
                    self.command('fm-send.sh', task_id,
                        'Reach a safe point and preserve your work. Record paused [key=safe-point-' + request_id +
                        '] [at=<current Unix seconds>] only after saving. Do not resume until explicitly relaunched or steered.')
                except (Refusal, subprocess.TimeoutExpired) as exc:
                    self.control_event(record, 'pause.unconfirmed', task='task:' + task_id, reason='delivery_failed')
            self.atomic(path, record)
            return self.advance_pause(record)
        preview = self.resume_preview(op)
        refuse(any(r.get('signal') == 'resume.request' and r.get('pause_state') == 'queued' for r in matching), 'invalid_value', tr('This scope is already queued.'))
        # Never relaunch while an agent is still saving work in this scope.
        refuse(any(r.get('signal') == 'pause.request' and r.get('pause_state') != 'paused' for r in matching),
               'invalid_value', tr('Wait for pause confirmation before resuming.'))
        record = dict(schema='fm-work-request.v1', at=now(), at_ns=time.time_ns(), phase='verified',
                      operation=dict(op, op='clear_pause'), signal=verb, signal_operation=op, scope=scope, safe_tasks=[],
                      pause_state='queued', candidates=preview['candidates'], started=[], events=[],
                      result=dict(state='received', request_id=request_id))
        self.atomic(path, record)
        ahead = any(r.get('signal') == 'resume.request' and r.get('pause_state') == 'queued' and not r.get('cancelled')
                    for r in self.request_records() if r['operation']['request_id'] != request_id)
        return self.advance_resume(record, from_queue=ahead, defer=ahead)

    def advance_pause(self, record):
        closed = self.close_safe_point(record['operation']['request_id'])
        # close_safe_point writes its exit list; retain that same durable record.
        record = self.read('data/work-requests/' + record['operation']['request_id'] + '.json')
        record['pause_state'] = 'paused' if closed['state'] == 'applied' else 'failed' if closed['failed'] else 'unconfirmed' if closed['unconfirmed'] else 'pending'
        if closed['event']:
            if closed['event'] == 'pause.confirmed':
                self.control_event(record, closed['event'], agents_closed=len(closed['exited']))
            else:
                for task_id in closed['unconfirmed']:
                    self.control_event(record, closed['event'], task='task:' + task_id, reason='safe_point')
        for task_id in closed['failed']:
            self.control_event(record, 'pause.unconfirmed', task='task:' + task_id, reason='close_failed')
        record['result'].update(closed, pause_state=record['pause_state'], events=record.get('events', []))
        if closed['state'] == 'applied':
            record['result'].update(message=tr('Pause confirmed.'), pending_reason=None)
        self.atomic('data/work-requests/' + record['operation']['request_id'] + '.json', record)
        return record['result']

    def advance_resume(self, record, from_queue=False, defer=False):
        path = 'data/work-requests/' + record['operation']['request_id'] + '.json'
        op = record['operation']
        if any(r.get('at_ns', 0) > record['at_ns'] and r['operation']['target'] == op['target']
               and r['operation']['op'] == 'set_pause' for r in self.request_records()):
            record.update(cancelled=True, pause_state='paused')
            record['result'].update(state='rejected', code='superseded', pause_state='paused', reason='other')
            self.control_event(record, 'resume.refused', reason='other')
            record['result']['events'] = record['events']
            self.atomic(path, record)
            return record['result']
        preview = self.resume_preview(dict(op, expected_rev=self.rev))
        cap = preview['agents_cap']
        reason = (preview['reason'] if preview['agents_needed'] else None) or ('cap' if cap is not None and preview['agents_running'] + preview['agents_needed'] > cap else None)
        if reason or defer:
            record['pause_state'] = 'queued'
            record['result'].update(state='received', pause_state='queued', reason=reason or 'cap', running=preview['agents_running'], cap=cap)
            self.control_event(record, 'resume.refused', reason=reason or 'cap', running=preview['agents_running'], cap=cap)
        else:
            # The selected pause is removed only after admission, preserving all others.
            command, _, _ = self.change(dict(op, expected_rev=self.rev))
            if command:
                self.command('fm-tasks-axi.sh', *command)
            self.atomic(self.structure_path, self.structure)
            self.load()
            record['pause_state'] = 'resuming'
            self.atomic(path, record)
            errors = {}
            for task_id in preview['candidates']:
                if task_id in record['started'] or self.progress_reporting_held(task_id) or any(b['open'] for b in self.blockers(task_id)):
                    continue
                if self.worker_liveness(task_id)['state'] != 'dead':
                    errors[task_id] = 'worker liveness is unknown; no relaunch attempted'
                    break
                try:
                    run = subprocess.run(['bash', str(BIN / 'fm-control.sh'), task_id, 'relaunch', '--note',
                        'Resume the saved work after the confirmed safe pause. The selected scope has resumed; preserve other holds.'],
                        env=self.env, pass_fds=(self.lock_fd,), capture_output=True, text=True, timeout=300)
                    if run.returncode:
                        errors[task_id] = run.stderr.strip()[-500:]
                        break
                    record['started'].append(task_id)
                    self.atomic(path, record)
                except subprocess.TimeoutExpired:
                    errors[task_id] = 'relaunch timed out; inspect the recorded endpoint before retrying'
                    break
            record['pause_state'] = 'failed' if errors else 'none'
            if errors:
                for task_id in set(preview['candidates']) - set(record['started']):
                    self.structure.setdefault('task_pauses', {})[task_id] = dict(kind='parked', reason='Reanudación sin confirmar', set=now(), by='firstmate')
                self.atomic(self.structure_path, self.structure)
            record['result'].update(state='failed' if errors else 'applied', pause_state=record['pause_state'], reason='other' if errors else None,
                                    agents_started=len(record['started']), running=preview['agents_running'] + len(record['started']), cap=cap, errors=errors)
            if errors:
                self.control_event(record, 'resume.refused', reason='other', running=preview['agents_running'], cap=cap)
            if not errors:
                self.control_event(record, 'resume.confirmed', agents_started=len(record['started']))
                if from_queue:
                    self.control_event(record, 'resume.started_from_queue')
                for paused in self.request_records():
                    if paused.get('scope') == record['scope'] and paused.get('signal') == 'pause.request':
                        paused['resumed'] = True
                        self.atomic('data/work-requests/' + paused['operation']['request_id'] + '.json', paused)
        record['result']['events'] = record.get('events', [])
        self.atomic(path, record)
        self.load()
        return record['result']

    def reconcile_controls(self):
        results = []
        records = sorted(self.request_records(), key=lambda r: r.get('at_ns', 0))
        for record in records:
            if record.get('cancelled') or record.get('resumed'):
                continue
            if record.get('signal') == 'pause.request' and record.get('pause_state') in ('pending', 'unconfirmed'):
                try:
                    results.append(self.advance_pause(record))
                except Refusal as exc:
                    if exc.code != 'invalid_value':
                        raise
                    record.update(cancelled=True, pause_state='none')
                    record['result'].update(state='rejected', code=exc.code, message=str(exc), pause_state='none')
                    self.atomic('data/work-requests/' + record['operation']['request_id'] + '.json', record)
                    results.append(record['result'])
        queued = [r for r in records if r.get('signal') == 'resume.request' and r.get('pause_state') == 'queued' and not r.get('cancelled')]
        if queued:
            # Queued resumes leave in «Mi orden» (arrival order among equals) and
            # never ahead of ready work of a request the captain placed higher.
            sigue = self.snapshot()['sigue']
            ahead = self.work_slot(self.work_unit[sigue[0]]) if sigue and self.work_unit[sigue[0]] in self.work_placed else None
            queued = [(self.scope_position(r['scope']), r) for r in queued]
            for rank, record in sorted(queued, key=lambda pair: pair[0]):
                if ahead is not None and ahead < rank:
                    break
                results.append(self.advance_resume(record, from_queue=True))
                if results[-1].get('pause_state') == 'queued':
                    break  # A later scope cannot take the first scope's place.
        return dict(state='applied', results=results)

    def hierarchy_invariants(self):
        controls = copy.deepcopy(self.structure)
        controls.pop('hierarchy', None)
        return dict(backlog=digest(self.backlog_text), registry=digest(self.registry_text),
                    retained_tasks=digest(self.rows), controls=digest(controls),
                    aliases=digest(self.aliases.value))

    def protections(self):
        return {i: dict(hold=self.current_hold(i), inherited=self.inherited(i), blockers=self.blockers(i))
                for i in self.rows}

    def normalization_plan(self, source, additions, metadata_only=False, hierarchy_only=False, freeze_scope=False):
        """Dry run from current sources. A manifest is data, never shell text."""
        structure = copy.deepcopy(self.structure)
        operations, conflicts = [], []
        if freeze_scope:
            refuse(not isinstance(source, dict) or source.get('schema') != 'fm-work-freeze-scope.v1'
                   or set(source) != {'schema', 'tasks', 'include_future', 'authority'}
                   or not isinstance(source['tasks'], list) or type(source['include_future']) is not bool
                   or not plain(source['authority'], 2000)
                   or any(not isinstance(i, str) or i not in self.rows for i in source['tasks'])
                   or len(source['tasks']) != len(set(source['tasks'])), 'invalid_value', tr('Explicit freeze scope and original authority are required.'))
            freeze = structure.get('freeze')
            refuse(not freeze, 'invalid_value', tr('There is no historical freeze to interpret.'))
            before = {i: self.inherited(i) for i in self.current_ids}
            freeze.update(tasks=sorted(source['tasks']), include_future=source['include_future'])
            self.structure = structure
            released, preserved = [], []
            for i in sorted(self.current_ids):
                if not before[i] and not self.current_hold(i) and i not in structure.get('task_pauses', {}):
                    continue
                controls = dict(task=i, hold=self.current_hold(i), task_pause=structure.get('task_pauses', {}).get(i),
                                inherited=self.inherited(i), dependencies=self.blockers(i), safe_point=self.safe_point(i)[0])
                kept = controls['hold'] or controls['task_pause'] or controls['inherited'] or any(b['open'] for b in controls['dependencies'])
                (preserved if kept else released).append(controls)
            return dict(schema='fm-work-normalization-manifest.v1', kind='freeze-scope', home=str(self.home),
                        expected=self.normalization_fingerprint(), structure=structure, operations=[], conflicts=[],
                        freeze_source=source, impact=dict(released=released, preserved=preserved, resumes_workers=False),
                        unassigned=[], active=copy.deepcopy(freeze['except']))
        if hierarchy_only:
            protections = self.protections()
            refuse(not isinstance(source, dict) or source.get('schema') != 'fm-work-hierarchy.v1'
                   or not isinstance(source.get('groups'), list) or not 1 <= len(source['groups']) <= 128,
                   'invalid_value', tr('Invalid hierarchy map.'))
            seen = set()
            for patch in source['groups']:
                refuse(not isinstance(patch, dict) or set(patch) != {'key', 'before', 'after'}
                       or not isinstance(patch['key'], str) or patch['key'] not in self.keys()
                       or patch['key'].startswith('task:') or patch['key'] in seen,
                       'unknown_target', tr('Unknown or duplicate group.'))
                key = patch['key']
                seen.add(key)
                actual = self.hierarchy(key)
                if actual == patch['after']:
                    continue
                if actual != patch['before']:
                    conflicts.append(dict(key=key, reason='hierarchy_changed', actual=actual, expected=patch['before']))
                    continue
                structure.setdefault('hierarchy', {})[key] = copy.deepcopy(patch['after'])
            self.structure = structure
            self.validate_structure()
            refuse(self.protections() != protections, 'invalid_value',
                   tr('The hierarchy would change an effective pause or dependency; preserve its protections first.'))
            return dict(schema='fm-work-normalization-manifest.v1', kind='hierarchy', home=str(self.home),
                        expected=self.normalization_fingerprint(), structure=structure, operations=[],
                        hierarchy_source=source, invariants=self.hierarchy_invariants(), conflicts=conflicts,
                        unassigned=[], active=copy.deepcopy(structure.get('freeze', {}).get('except', [])))
        if metadata_only:
            refuse(source.get('schema') != 'fm-work-project-metadata.v1' or not isinstance(source.get('groups'), list)
                   or not 1 <= len(source['groups']) <= 128, 'invalid_value', tr('Invalid metadata map.'))
            changes, seen = [], set()
            for patch in source['groups']:
                refuse(not isinstance(patch, dict) or set(patch) != {'key', 'visibility', 'expected'},
                       'invalid_value', tr('The map can only change explicit visibility.'))
                key = patch['key']
                refuse(not isinstance(key, str) or key in seen or key not in structure['groups']
                       or structure['groups'][key]['kind'] != 'project', 'unknown_target', tr('Unknown or duplicate metadata project.'))
                seen.add(key)
                group = structure['groups'][key]
                desired = patch['visibility']
                refuse(desired not in VISIBILITIES, 'invalid_value', tr('Invalid visibility.'))
                expected = patch['expected']
                actual = dict(present='visibility' in group, value=group.get('visibility'))
                refuse(not isinstance(expected, dict) or set(expected) != {'present', 'value'}
                       or type(expected['present']) is not bool, 'invalid_value', tr('The exact previous value is required.'))
                if 'visibility' in group and group['visibility'] == desired:
                    continue  # a freshly regenerated plan converges without rewriting other fields
                if expected != actual:
                    conflicts.append(dict(key=key, reason='project_visibility_changed', expected=expected, actual=actual))
                    continue
                group['visibility'] = desired
                changes.append(dict(key=key, before=actual, after=desired))
            self.structure = structure
            self.validate_structure()
            return dict(schema='fm-work-normalization-manifest.v1', kind='project-metadata', home=str(self.home),
                        expected=self.normalization_fingerprint(), structure=structure, operations=[], metadata_changes=changes,
                        conflicts=conflicts, unassigned=[], active=copy.deepcopy(structure.get('freeze', {}).get('except', [])))
        for group in source['groups'] + additions.get('groups', []):
            key, repo, kind = group['key'], group['repo'], group['kind']
            refuse('visibility' in group and (kind != 'project' or group['visibility'] not in VISIBILITIES),
                   'invalid_value', tr('Invalid project visibility.'))
            if repo not in self.projects:
                conflicts.append(dict(key=key, reason='unregistered_project'))
                continue
            if key in structure['groups']:
                if 'visibility' in group:
                    existing = structure['groups'][key]
                    if 'visibility' in existing and existing['visibility'] != group['visibility']:
                        conflicts.append(dict(key=key, reason='project_visibility_changed'))
                    else:
                        existing['visibility'] = group['visibility']
                continue  # preserve every other existing owner field
            pause = group.get('pause')
            structure['groups'][key] = dict(kind=kind, repo=repo, label=group['label'], priority=group.get('priority'),
                pause=dict(reason=tr('Pause preserved from the approved review'), by='captain', at=source.get('captured_at')) if pause else None,
                blocked_by=[], created_at=None, aliases=group.get('aliases', []), note=group.get('note') or '\n'.join(group.get('captain_notes', [])) or None, captain_notes=group.get('captain_notes', []),
                review_ids=group.get('review_ids', []))
            if 'visibility' in group:
                structure['groups'][key]['visibility'] = group['visibility']
        mappings = {t['id']: t.get('subproject') for t in source['tasks'] if t.get('subproject')}
        mappings.update(additions.get('membership', {}))
        for task_id, sub in mappings.items():
            if task_id not in self.rows:
                conflicts.append(dict(key=task_id, reason='unknown_task'))
                continue
            if structure['membership'].get(task_id) not in (None, sub):
                conflicts.append(dict(key=task_id, reason='membership_changed'))
                continue
            structure['membership'][task_id] = sub
        for task in source['tasks']:
            row = self.rows.get(task['id'])
            if row is None or row['state'] == 'done':
                continue
            for op in task.get('operations', []):
                if op['op'] == 'set_priority':
                    current = row.get('priority')
                    if current == op['value']:
                        continue
                    if current != op.get('expected'):
                        conflicts.append(dict(key=task['id'], reason='priority_changed_or_unset', expected=op.get('expected'), actual=current))
                        continue
                    operations.append(dict(task=task['id'], field='priority', before=current, after=op['value']))
                elif op['op'] == 'set_card_title':
                    current = self.presentations[task['id']]['presentation']['card_title']
                    if current != op['value']:
                        operations.append(dict(task=task['id'], field='card_title', before=current, after=op['value']))
        active = additions.get('active', [])
        refuse(any(i not in self.current_ids for i in active), 'invalid_value', tr('Active tasks must exist.'))
        # Organizing metadata grants no pause authority and preserves existing pauses.
        # Preserve notes/flags as evidence, without turning a removal candidate into deletion.
        structure['review'] = dict(source_schema=source['schema'], captured_at=source.get('captured_at'),
            tasks=[dict(id=t['id'], note=t.get('captain_note'), flags=t.get('flags', [])) for t in source['tasks']],
            deferred=source.get('deferred_review_points', []), received_proposals=additions.get('received_proposals', []))
        self.structure = structure
        self.validate_structure()
        cycle = self.cycle()
        refuse(bool(cycle), 'cycle', tr('Normalization creates a cycle.'), cycle_path=cycle)
        residual = [i for i in self.current_ids if self.rows[i]['state'] != 'done' and i not in structure['membership']]
        return dict(schema='fm-work-normalization-manifest.v1', home=str(self.home), expected=self.normalization_fingerprint(),
            structure=structure, operations=operations, conflicts=conflicts, unassigned=sorted(residual), active=active)

    def normalization_fingerprint(self):
        # Exact relevant sources, including declarations whose titles may be patched.
        return digest(dict(backlog=self.backlog_text, registry=self.registry_text,
                           structure=self.read(self.structure_path), presentations=self.presentations))

    def normalization_apply(self, manifest, request_id):
        refuse(not REQUEST.fullmatch(request_id or ''), 'invalid_value', tr('Invalid migration identity.'))
        refuse(manifest.get('schema') != 'fm-work-normalization-manifest.v1' or manifest.get('home') != str(self.home), 'not_local_home', tr('The manifest belongs to another installation.'))
        path = 'data/work-normalizations/' + request_id + '.json'
        existing = self.read(path)
        if existing:
            refuse(existing.get('manifest') != manifest, 'request_mismatch', tr('The migration already has different content.'))
            return existing
        refuse(bool(manifest.get('conflicts')), 'stale_revision', tr('Resolve dry-run conflicts before applying.'))
        refuse(manifest['expected'] != self.normalization_fingerprint(), 'stale_revision', tr('A source changed since the dry run.'))
        if manifest.get('kind') == 'freeze-scope':
            before_structure = copy.deepcopy(self.structure)
            projected = self.normalization_plan(manifest['freeze_source'], {}, freeze_scope=True)
            self.structure = before_structure
            refuse(projected != manifest, 'invalid_value', tr('The manifest changes fields outside the explicit freeze scope.'))
        if manifest.get('kind') == 'hierarchy':
            before_structure = copy.deepcopy(self.structure)
            before_invariants = self.hierarchy_invariants()
            projected = self.normalization_plan(manifest['hierarchy_source'], {}, hierarchy_only=True)
            self.structure = before_structure
            refuse(projected != manifest or manifest['invariants'] != before_invariants,
                   'invalid_value', tr('The manifest changes fields outside the hierarchy or its invariants.'))
        if manifest.get('kind') == 'project-metadata':
            projected = copy.deepcopy(self.structure)
            refuse(bool(manifest['operations']), 'invalid_value', tr('A metadata improvement does not modify tasks.'))
            seen = set()
            for change in manifest.get('metadata_changes', []):
                key = change.get('key')
                refuse(not isinstance(key, str) or key in seen or key not in projected['groups']
                       or projected['groups'][key]['kind'] != 'project' or change.get('after') not in VISIBILITIES,
                       'invalid_value', tr('Invalid metadata change.'))
                seen.add(key)
                group = projected['groups'][key]
                refuse(change.get('before') != dict(present='visibility' in group, value=group.get('visibility')),
                       'stale_revision', tr('Visibility changed before applying.'))
                group['visibility'] = change['after']
            refuse(projected != manifest['structure'], 'invalid_value', tr('The manifest changes fields outside visibility.'))
        for operation in manifest['operations']:
            task_id, field = operation.get('task'), operation.get('field')
            refuse(task_id not in self.current_ids or field not in ('priority', 'card_title'), 'invalid_value', tr('Invalid normalization operation.'))
            current = self.rows[task_id].get('priority') if field == 'priority' else self.presentations[task_id]['presentation']['card_title']
            refuse(current != operation.get('before'), 'stale_revision', tr('The field changed since the dry run.'))
            refuse(field == 'priority' and (type(operation.get('after')) is not int or operation['after'] not in range(5)), 'invalid_value', tr('Invalid priority.'))
            refuse(field == 'card_title' and not plain(operation.get('after'), 80), 'invalid_value', tr('Invalid title.'))
        old_structure = self.read(self.structure_path)
        for key, previous in (old_structure or {}).get('groups', {}).items():
            desired = manifest['structure']['groups'].get(key)
            refuse(desired is not None and desired.get('created_at') != previous.get('created_at'),
                   'invalid_value', tr("The group's original creation time is immutable."))
        self.structure = manifest['structure']
        self.validate_structure()
        refuse(bool(self.cycle()), 'cycle', tr('The structure contains a cycle.'))
        # Backup is exact, durable, and precedes every mutation.
        # Preserve original declaration bytes as well as their field projection.
        raw_presentations = {}
        for operation in manifest['operations']:
            task_id = operation['task']
            try:
                raw_presentations[task_id] = read_text(self.home, 'data/' + task_id + '/presentation.json', 32768)
            except FileNotFoundError:
                raw_presentations[task_id] = None
        try:
            raw_structure = read_text(self.home, self.structure_path)
        except FileNotFoundError:
            raw_structure = None
        backup = dict(backlog=self.backlog_text, registry=self.registry_text, structure=old_structure, structure_text=raw_structure,
                      presentations=self.presentations, presentation_files=raw_presentations)
        record = dict(schema='fm-work-normalization-receipt.v1', at=now(), manifest=manifest,
                      before=backup, state='received', completed=[])
        self.atomic(path, record)
        for op in manifest['operations']:
            refuse(op['field'] not in ('priority', 'card_title'), 'invalid_value', tr('The field cannot be normalized.'))
            if op['field'] == 'priority':
                self.command('fm-tasks-axi.sh', 'update', op['task'], '--priority', str(op['after']))
            else:
                self.command('fm-tasks-axi.sh', 'presentation', op['task'], '--card-title', op['after'])
            record['completed'].append(op)
            self.atomic(path, record)
        committed_structure = copy.deepcopy(manifest['structure'])
        created_at = now()
        for key, group in committed_structure['groups'].items():
            previous = (old_structure or {}).get('groups', {}).get(key)
            if previous is None:
                group['created_at'] = created_at
        self.atomic(self.structure_path, committed_structure)
        self.load()
        for op in record['completed']:
            value = self.rows[op['task']].get('priority') if op['field'] == 'priority' else self.presentations[op['task']]['presentation']['card_title']
            refuse(value != op['after'], 'owner_failed', tr('Normalization was not confirmed.'))
        refuse(self.structure != committed_structure, 'owner_failed', tr('The structure was not confirmed.'))
        if manifest.get('kind') == 'hierarchy':
            refuse(self.hierarchy_invariants() != manifest['invariants'], 'owner_failed', tr('The hierarchy changed identities or controls.'))
        record.update(state='applied', after=dict(fingerprint=self.normalization_fingerprint(), structure=self.structure,
                      assigned=len(self.structure['membership']), unassigned=manifest['unassigned']), applied_at=now())
        self.atomic(path, record)
        return record

    def normalization_rollback(self, request_id):
        refuse(not REQUEST.fullmatch(request_id or ''), 'invalid_value', tr('Invalid identity.'))
        path = 'data/work-normalizations/' + request_id + '.json'
        record = self.read(path)
        refuse(not record, 'unknown_target', tr('Unknown migration.'))
        if record['state'] == 'rolled_back':
            return record
        refuse(record['state'] != 'applied', 'owner_failed', tr('Incomplete migration: review the receipt before recovery.'))
        refuse(self.structure != record['after']['structure'], 'stale_revision', tr('The structure changed afterwards; it will not be overwritten.'))
        for op in record['completed']:
            current = self.rows[op['task']].get('priority') if op['field'] == 'priority' else self.presentations[op['task']]['presentation']['card_title']
            refuse(current != op['after'], 'stale_revision', tr('The field changed afterwards; it will not be overwritten.'))
        record['state'] = 'rolling_back'
        self.atomic(path, record)
        for op in reversed(record['completed']):
            if op['field'] == 'priority':
                self.command('@unset_priority', op['task'], str(op['after'])) if op['before'] is None else self.command('fm-tasks-axi.sh', 'update', op['task'], '--priority', str(op['before']))
            else:
                self.command('fm-tasks-axi.sh', 'presentation', op['task'], '--card-title', op['before'] or '')
        original = record['before']['structure']
        # An empty structure is semantically identical to the originally absent file.
        self.atomic(self.structure_path, original or dict(schema='fm-work-structure.v1', groups={}, membership={}, order=[], edge_meta={}))
        self.load()
        record.update(state='rolled_back', rolled_back_at=now())
        self.atomic(path, record)
        return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('verb', choices=['capabilities', 'snapshot', 'preview', 'apply', 'request-status', 'close', 'reconcile',
        'pause.preview', 'pause.request', 'pause.cancel', 'resume.preview', 'resume.request', 'resume.dequeue', 'outcome.review',
        'assign', 'dispatch-check', 'normalize-plan', 'normalize-apply', 'normalize-rollback', 'aliases-init', 'resolve'])
    parser.add_argument('--order', choices=['recent', 'manual'], default='recent', help='Request display order: activity or persisted manual order.')
    parser.add_argument('--runtime', action='store_true', help='Include full bounded crew reconciliation in addition to fresh endpoint liveness.')
    parser.add_argument('--freeze-scope', action='store_true', help='Interpret a historical freeze with explicit authority; dry run only until normalize-apply.')
    parser.add_argument('--metadata-only', action='store_true', help='Plan only explicit project visibility; preserve all other structure and task fields.')
    parser.add_argument('--hierarchy-only', action='store_true', help='Plan only the owner display hierarchy; preserve canonical routing and every control field.')
    parser.add_argument('--ref', help='Canonical identity or persistent short alias within the explicit home.')
    parser.add_argument('--map')
    parser.add_argument('--additions')
    parser.add_argument('--request-id')
    parser.add_argument('--task')
    parser.add_argument('--subproject')
    args = parser.parse_args()
    lock = None
    try:
        owner = Owner()
        owner.include_runtime = args.runtime
        owner.request_sort = args.order
        if args.verb == 'capabilities':
            result = dict(schema='fm-work-capabilities.v1', contract_major=1, revision='1.8', ops=OPS,
                          outcome_controls=['outcome.review'],
                          signals=['pause.preview', 'pause.request', 'pause.cancel', 'resume.preview', 'resume.request', 'resume.dequeue'],
                          features=['progress', 'safe_point', 'group_dependencies', 'manual_order', 'priority_unset',
                                    'stable_aliases', 'normalized_hierarchy', 'logical_project_roots', 'question_provenance', 'removal_consultation',
                                    'progress_checkpoints', 'progress_phases', 'verified_progress_gates', 'worker_liveness', 'pause_reconciliation', 'outcome_review'])
        else:
            if args.verb in ('snapshot', 'apply', 'request-status', 'close', 'reconcile', 'assign', 'normalize-apply', 'normalize-rollback', 'aliases-init') or '.' in args.verb or (owner.home / ALIAS_PATH).exists() or owner.env.get('FM_WORK_OWNER_FD'):
                lock = owner.lock()
            if lock is None and args.verb in ('snapshot', 'preview', 'normalize-plan', 'dispatch-check', 'resolve') and (owner.data / '.work.lock').exists():
                lock = os.open(owner.data / '.work.lock', os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise Refusal('busy', tr('Another change is in progress. Try again.'))
            DIAG['lock_ms'] = round((time.monotonic() - DIAG['started']) * 1000)
            owner.load(include_presentations=args.verb != 'snapshot')
            if args.verb == 'aliases-init':
                refuse(not REQUEST.fullmatch(args.request_id or ''), 'invalid_value', tr('Invalid activation identity.'))
                with open(args.map, encoding='utf-8') as stream:
                    result = owner.aliases.seed(json.load(stream), args.request_id)
            elif args.verb == 'resolve':
                key = owner.aliases.resolve(args.ref)
                result = dict(home=str(owner.home), key=key, alias=owner.aliases.alias(key),
                              available=key in owner.keys(), task_id=key[5:] if key.startswith('task:') else None)
            elif args.verb == 'normalize-plan':
                refuse(sum((args.hierarchy_only, args.metadata_only, args.freeze_scope)) > 1, 'invalid_value', tr('Choose one normalization mode.'))
                with open(args.map, encoding='utf-8') as stream:
                    source = json.load(stream)
                additions = {}
                if not args.metadata_only and not args.hierarchy_only and not args.freeze_scope:
                    with open(args.additions, encoding='utf-8') as stream:
                        additions = json.load(stream)
                result = owner.normalization_plan(source, additions, metadata_only=args.metadata_only, hierarchy_only=args.hierarchy_only, freeze_scope=args.freeze_scope)
            elif args.verb == 'normalize-apply':
                result = owner.normalization_apply(json.load(sys.stdin), args.request_id)
            elif args.verb == 'normalize-rollback':
                result = owner.normalization_rollback(args.request_id)
            elif args.verb == 'snapshot':
                owner.reconcile_pauses()
                # Canonical rows, controls, aliases and declarations are captured.
                # Slow evidence/liveness probes must not hold up owner writes.
                os.close(lock)
                lock = None
                del owner.lock_fd
                owner.env.pop('FM_WORK_OWNER_FD', None)
                for task_id, authored in owner.presentations.items():
                    if (authored.get('evidence') or {}).get('available') is not False:
                        authored['lifecycle'], _ = reconcile_progress(owner.home, task_id,
                            authored['presentation'], authored['progress_record'], read_text)
                result = owner.snapshot()
                DIAG['tasks'] = len(result.get('tasks', []))
            elif args.verb == 'reconcile':
                result = owner.reconcile_controls()
            elif args.verb == 'dispatch-check':
                if args.task not in owner.rows:
                    args.task = owner.aliases.resolve(args.task).removeprefix('task:')
                refuse(args.task not in owner.rows, 'unknown_target', tr('Unknown task.'))
                refuse(bool(owner.inherited(args.task)) or args.task in owner.structure.get('task_pauses', {})
                       or any(b['open'] for b in owner.blockers(args.task)), 'invalid_value', tr('The task has an inherited or direct pause or dependency.'))
                result = dict(allowed=True)
            elif args.verb == 'assign':
                if args.task not in owner.rows:
                    args.task = owner.aliases.resolve(args.task).removeprefix('task:')
                refuse(args.task not in owner.rows, 'unknown_target', tr('Unknown task.'))
                sub = args.subproject
                if sub != 'none':
                    sub = owner.aliases.resolve(sub)
                if sub == 'none':
                    owner.structure['membership'].pop(args.task, None)
                else:
                    refuse(sub not in owner.structure['groups'] or not sub.startswith('subproject:'), 'unknown_target', tr('Unknown subproject.'))
                    owner.structure['membership'][args.task] = sub
                owner.validate_structure()
                cycle = owner.cycle()
                refuse(bool(cycle), 'cycle', tr('Membership creates a cycle.'), cycle_path=cycle)
                owner.atomic(owner.structure_path, owner.structure)
                result = dict(state='applied', task=args.task, subproject=sub)
            elif args.verb == 'request-status':
                refuse(not args.request_id or not REQUEST.fullmatch(args.request_id), 'invalid_value', tr('Invalid identity.'))
                path = 'data/work-requests/' + args.request_id + '.json'
                record = owner.read(path)
                refuse(record is None, 'unknown_target', tr('Unknown request.'))
                result = record['result'] if record.get('signal') else owner.reconcile(record, path)
            elif args.verb == 'close':
                refuse(not args.request_id or not REQUEST.fullmatch(args.request_id), 'invalid_value', tr('Invalid identity.'))
                record = owner.read('data/work-requests/' + args.request_id + '.json')
                result = owner.advance_pause(record) if record and record.get('signal') == 'pause.request' else owner.close_safe_point(args.request_id)
            else:
                payload = sys.stdin.read(65537)
                refuse(len(payload) > 65536, 'invalid_value', tr('Request too large.'))
                op = json.loads(payload)
                refuse(not isinstance(op, dict), 'invalid_value', tr('A JSON object is required.'))
                if '.' in args.verb and args.verb != 'outcome.review':
                    op['target'] = op.get('target', op.get('scope'))
                    op['expected_rev'] = op.get('expected_rev', op.get('rev'))
                for field in ('target', 'on', 'before', 'after'):
                    if args.verb == 'outcome.review':
                        break
                    if op.get(field) is not None:
                        if op.get('op') == 'move' and isinstance(op[field], str) and op[field] in owner.request_keys():
                            continue
                        op[field] = owner.aliases.resolve(op[field])
                if args.verb == 'outcome.review':
                    result = owner.review_outcome(op)
                elif '.' in args.verb:
                    op['scope'] = op['target']
                    result = owner.signal(args.verb, op)
                elif args.verb == 'preview':
                    _, before, undo, impact = owner.preview(op)
                    result = dict(impact=impact, before=before, undo=undo)
                else:
                    result = owner.apply(op)
        print(json.dumps(result, ensure_ascii=False))
        DIAG['result'] = 'ok'
        return 0
    except Refusal as exc:
        DIAG['result'] = exc.code if exc.code == 'busy' else 'rejected'
        print(json.dumps(dict(request_id=locals().get('op', {}).get('request_id', args.request_id), state='conflict' if exc.code in ('stale_revision', 'stale_occurrence', 'review_conflict') else 'rejected', code=exc.code, message=str(exc), **exc.details), ensure_ascii=False))
        return 1 if args.verb == 'dispatch-check' else 0
    except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as exc:
        print(json.dumps(dict(state='failed', code='owner_failed', message=str(exc)), ensure_ascii=False))
        return 1
    finally:
        if lock is not None:
            os.close(lock)


DIAG = dict(started=time.monotonic(), result='failed')


def diag_snapshot():
    """Append one work.snapshot event to the diagnostic log (bin/fm-diag.sh)."""
    caller = ''
    try:
        ppid = os.getppid()
        if Path(f'/proc/{ppid}/cmdline').exists():
            args = Path(f'/proc/{ppid}/cmdline').read_bytes().decode(errors='replace').split('\0')
        else:
            args = subprocess.run(['ps', '-o', 'args=', '-p', str(ppid)], capture_output=True, text=True, timeout=2).stdout.split()
        names = [a.rsplit('/', 1)[-1] for a in args if a]
        caller = next((n for n in names if n.endswith(('.sh', '.py', '.js', '.mjs', '.ts'))), names[0] if names else '')
        subprocess.run(['bash', str(BIN / 'fm-diag.sh'), 'emit', 'work.snapshot', 'caller=' + caller,
                        'ms=%d' % round((time.monotonic() - DIAG['started']) * 1000), 'lock_ms=%s' % DIAG.get('lock_ms', ''),
                        'result=' + DIAG['result'], 'tasks=%s' % DIAG.get('tasks', '')],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass


if __name__ == '__main__':
    code = main()
    if sys.argv[1:2] == ['snapshot']:
        diag_snapshot()
    sys.exit(code)
