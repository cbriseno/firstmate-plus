#!/usr/bin/env python3
"""Progress reconciliation used by the existing presentation owner.

fm-tasks-axi.sh owns the public contract. No harness output, elapsed work,
status prose, or model calls establish a completed semantic step here.
"""
import copy
import datetime as dt
import hashlib
import functools
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path


# Installation language for fixed control copy; protocols and user data stay intact.
def tr(message):
    language = os.environ.get('FM_LANGUAGE')
    if language is None:
        home = Path(os.environ.get('FM_HOME', Path(__file__).resolve().parent.parent))
        try:
            language = (home / 'config/language').read_text(encoding='utf-8').strip()
        except OSError:
            language = 'en'
    if language != 'es':
        return message
    try:
        catalog = json.loads((Path(__file__).resolve().parent.parent / 'locales/es.json').read_text(encoding='utf-8'))
        return catalog.get(message, message)
    except (OSError, ValueError):
        return message

PHASES = ('investigation', 'implementation', 'rebase', 'validation',
          'branch-ready', 'integration', 'activation', 'complete')
GATES = ('branch-ready', 'integrated', 'pipeline-passed')
BIN = Path(__file__).resolve().parent
_deadline = None
_budget_exhausted = False


def read_timeout(limit):
    """One five-second probe budget per owner invocation, not per row.

    This bounds instrument cost under the existing work lock, not declaration
    freshness. Cached Git reads share that observation within the invocation.
    """
    global _deadline, _budget_exhausted
    if _deadline is None:
        _deadline = time.monotonic() + 5
    remaining = _deadline - time.monotonic()
    if remaining <= 0:
        _budget_exhausted = True
        raise subprocess.TimeoutExpired('progress evidence budget', 5)
    return min(limit, remaining)


def probe(argv, timeout, env=None):
    """Bound this read's private CLI group, including inherited pipe holders."""
    process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, start_new_session=True, env=env)
    try:
        out, err = process.communicate(timeout=timeout)
        return subprocess.CompletedProcess(argv, process.returncode, out, err)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=1)
        raise


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def validate_record(record):
    if not isinstance(record, dict) or set(record) - {
            'reported_at', 'status_token', 'context', 'head', 'gates', 'replan_reason'}:
        raise ValueError('invalid progress checkpoint')
    if (not isinstance(record.get('context'), dict)
            or (record.get('reported_at') is not None and not isinstance(record['reported_at'], str))
            or (record.get('status_token') is not None and not re.fullmatch(r'[0-9a-f]{64}', record['status_token']))
            or not isinstance(record.get('gates'), dict)):
        raise ValueError('invalid progress checkpoint')
    if record.get('reported_at') is not None:
        dt.datetime.strptime(record['reported_at'], '%Y-%m-%dT%H:%M:%SZ')
    for key, gate in record['gates'].items():
        if (key not in GATES or not isinstance(gate, dict)
                or not re.fullmatch(r'[0-9a-f]{40,64}', gate.get('head', ''))
                or not isinstance(gate.get('source'), str)):
            raise ValueError('invalid progress gate receipt')


def sources(home, task_id, read):
    def optional(path, limit):
        try:
            return read(home, path, limit)
        except FileNotFoundError:
            return ''
    meta = dict(line.split('=', 1) for line in optional('state/' + task_id + '.meta', 65536).splitlines()
                if '=' in line)
    status = optional('state/' + task_id + '.status', 1024 * 1024)
    # Only reporting boundaries, never keywords in their prose. Decisions and
    # notes do not demand that an unchanged semantic plan advance.
    events = [line for line in status.splitlines() if re.match(
        r'^(working|paused|done|failed|blocked|needs-decision)(?:\s+\[[^\]\n]+\])*:', line)]
    token = fingerprint(events)
    context = {key: meta.get(key) for key in ('kind', 'mode')}
    return meta, events, token, context


@functools.lru_cache(maxsize=512)
def git(path, *args):
    if not path:
        return None
    try:
        result = probe(['git', '-C', path, *args], read_timeout(3))
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def code_head(meta):
    return git(meta.get('worktree'), 'rev-parse', '--verify', 'HEAD')


def observed_run(view, runtime, head):
    """Consume the existing attributed observation; never initiate a poll."""
    step = (runtime or {}).get('run_step') or {}
    if step.get('source') != 'no-mistakes.attributed-run' or not head:
        return view
    try:
        stamp = dt.datetime.strptime(step['observed_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
        age = (dt.datetime.now(dt.timezone.utc) - stamp).total_seconds()
        if not 0 <= age < step['ttl_seconds']:
            return view
    except (KeyError, TypeError, ValueError):
        return view
    if runtime.get('state') in ('working', 'parked') and not view['evidence'].get('applicable_gates'):
        if view['phase'] != 'validation' and view['evidence']['current']:
            view['evidence'].update(current=False, freshness='stale')
            view['evidence']['reasons'].append('validation-checkpoint-required')
        view['phase'] = 'validation'
    if (runtime.get('state') == 'done' and step.get('outcome') in
            ('passed', 'passed-with-override', 'passed-with-skips', 'checks-passed')
            and isinstance(step.get('head'), str) and re.fullmatch(r'[0-9a-f]{40,64}', step['head'])):
        view['gates']['pipeline-passed'] = dict(head=step['head'], source=step['source'],
            run_id=step.get('run_id'), outcome=step['outcome'])
        if view['progress']:
            for item in view['progress']['steps']:
                if item.get('gate') == 'pipeline-passed' and step['head'] == head:
                    item['state'] = 'done'
    return view


def gate_facts(home, task_id, meta, events, previous):
    """Delegate ready proof to its existing owner; integration is Git ancestry.

    The ready receipt pins an accepted head, so later teardown/replay cannot
    erase that fact. New code invalidates applicability, not historical proof.
    """
    facts = copy.deepcopy(previous or {})
    if meta.get('kind') != 'ship':
        return facts
    head = code_head(meta)
    if (events and re.match(r'^done(?:\s|:)', events[-1]) and head
            and facts.get('branch-ready', {}).get('event') != fingerprint(events[-1])):
        script = r'''
. "$1/fm-dod-lib.sh"
fm_dod_should_gate_ship_done ship "$2" "$5" || exit 1
fm_dod_accept_ship_done ship "$2" "$3" "$4" "$5" "$6" "$7" "$8" || exit 1
if url=$(fm_dod_pr_url_from_done_note "$(status_line_note "$5")") &&
   fm_dod_recorded_pr_on_forge "$6" "$7" "$8" "$2" "$url"; then
  fm_dod_meta_value "$8" pr_head
else
  git -C "$3" rev-parse --verify HEAD
fi
'''
        try:
            result = probe(['bash', '-c', script, 'fm-progress', str(BIN), meta.get('mode', ''),
                meta.get('worktree', ''), meta.get('project', ''), events[-1], str(home / 'state'),
                task_id, str(home / 'state' / (task_id + '.meta'))],
                read_timeout(8))
            proven_head = result.stdout.strip()
            if result.returncode == 0 and re.fullmatch(r'[0-9a-f]{40,64}', proven_head):
                facts['branch-ready'] = dict(head=proven_head, source='delivery.accepted-ready-head', event=fingerprint(events[-1]))
        except (OSError, subprocess.SubprocessError):
            pass
    ready = facts.get('branch-ready')
    if ready and meta.get('mode') == 'local-only':
        project = meta.get('project')
        default = git(project, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
        default = default.removeprefix('origin/') if default else next(
            (b for b in ('main', 'master') if git(project, 'rev-parse', '--verify', 'refs/heads/' + b)), None)
        if default and git(project, 'merge-base', '--is-ancestor', ready['head'], 'refs/heads/' + default) is not None:
            facts['integrated'] = dict(head=ready['head'], source='git.default-contains-ready-head')
    elif ready and meta.get('pr'):
        script = r'''
. "$1/fm-pr-lib.sh"
fm_pr_url_parse "$4" || exit 1
fm_pr_poll_merge_already_notified "$2" "$3" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"
'''
        try:
            result = probe(['bash', '-c', script, 'fm-progress', str(BIN), str(home / 'state'),
                task_id, meta['pr']], read_timeout(3))
            if result.returncode == 0:
                facts['integrated'] = dict(head=ready['head'], source='delivery.merge-receipt', pr=meta['pr'])
        except (OSError, subprocess.SubprocessError):
            pass
    return facts


def reconcile(home, task_id, fields, record, read, verify=True):
    meta, events, token, context = sources(home, task_id, read)
    record = record or {}
    facts = gate_facts(home, task_id, meta, events, record.get('gates')) if verify else record.get('gates', {})
    head = code_head(meta) if meta.get('kind') == 'ship' else None
    phase = fields.get('phase') or {'scout': 'investigation', 'ship': 'implementation'}.get(meta.get('kind'))
    reasons = []
    if context != record.get('context') and record:
        reasons.append('task-contract-changed')
        phase = {'scout': 'investigation', 'ship': 'implementation'}.get(meta.get('kind'))
    if head and record.get('head') and head != record['head']:
        reasons.append('code-head-changed')
        phase = 'implementation'
    if fields.get('progress') is None:
        freshness = 'missing'
        reasons.append('initial-plan-required')
    elif not record.get('reported_at'):
        freshness = 'unknown'
        reasons.append('legacy-declaration-needs-checkpoint')
    else:
        if token != record.get('status_token'):
            reasons.append('status-checkpoint-required')
        freshness = 'stale' if reasons else 'current'
    applicable = {key: value for key, value in facts.items()
                  if value['head'] == head or (not head and not meta.get('kind'))}
    if _budget_exhausted or (meta.get('kind') == 'ship' and record.get('head') and not head):
        reasons.append('progress-evidence-budget-exhausted' if _budget_exhausted else 'code-identity-unavailable')
        if freshness == 'current':
            freshness = 'unknown'
    if meta.get('kind') == 'ship' and 'integrated' not in applicable and phase in ('integration', 'activation', 'complete'):
        reasons.append('integration-not-verified')
        if freshness == 'current':
            freshness = 'stale'
    if 'integrated' in applicable and phase not in ('activation', 'complete'):
        phase = 'integration'
    elif 'branch-ready' in applicable and phase not in ('activation', 'complete'):
        phase = 'branch-ready'
    steps = copy.deepcopy(fields.get('progress'))
    if steps:
        for step in steps['steps']:
            gate = step.get('gate')
            if gate:
                # An old plan cannot declare delivery ahead of the instrument.
                step['state'] = 'done' if gate in applicable else 'todo'
    return dict(progress=steps, phase=phase, gates=facts,
                evidence=dict(freshness=freshness, current=freshness == 'current', reasons=reasons,
                              reported_at=record.get('reported_at'), source='task.progress.checkpoint',
                              applicable_gates=sorted(applicable))), (meta, token, context, head)


def checkpoint(home, task_id, fields, old_fields, old_record, read, stamp, replan=None):
    progress = fields.get('progress')
    previous = old_fields.get('progress')
    if progress and previous and not replan:
        done = {s['label'] for s in previous['steps'] if s['state'] == 'done' and not s.get('gate')}
        labels = {s['label'] for s in progress['steps']}
        if done - labels:
            raise ValueError('completed steps cannot disappear; use --replan REASON for a deliberate correction')
        for step in progress['steps']:
            if step['label'] in done:
                step['state'] = 'done'
    view, (meta, token, context, head) = reconcile(home, task_id, fields, old_record, read)
    record = dict(reported_at=stamp, status_token=token, context=context, head=head, gates=view['gates'])
    if replan:
        record['replan_reason'] = replan
    return record


def contract(home, task_id, data=None):
    import shlex
    quote = shlex.quote
    input_path = str(Path(os.path.abspath(data or home / 'data')) / task_id / 'progress-input.json')
    command = ('FM_HOME=' + quote(str(home)) + ' bash ' + quote(str(BIN / 'fm-tasks-axi.sh'))
               + ' presentation ' + quote(task_id) + ' --presentation-file ' + quote(input_path))
    template = """At the start, write a short honest plan with phase and progress to {input_path}, then publish it with:
`{command}`
Example ship input: {"phase":"implementation","card_status":"Implementation in progress","progress":{"steps":[{"label":"Implementation","state":"active"},{"label":"Affected checks","state":"todo"},{"label":"Branch ready","state":"todo","gate":"branch-ready"},{"label":"Integration","state":"todo","gate":"integrated"}]}}.
For a scout use phase=investigation and only its actual research/report steps; add installed activation only when it is in scope.
The input file is task scratch; never write presentation.json, which is the owner's validated output.
Update and republish phase, card_status and steps together after each status report and verified milestone, before a validation wait, after promotion/rebase/resume/handoff, and before readiness; unchanged steps are honest when work continues without a completed milestone.
Keep the initial plan small but concrete for this task; the example is a shape, not evidence of completed work.
Use done for closed explicit steps and todo for remaining ones, never estimate a percentage or time.
Keep implementation, affected checks, branch readiness, merge and installed activation distinct; never declare delivery or activation from code completion alone.
Confirm exit success AND ok=true, state=published, evidence.available=true and lifecycle.evidence.current=true; busy/rejected JSON is not publication, even with exit0.
After a done status, publish the checkpoint before stopping; the owner verifies gate-bound readiness separately.
Start later inputs from the current owner declaration, never an old draft; a card-status-only write preserves old steps and never renews the checkpoint.
Put summary and card text in that JSON too; file input and individual field flags are mutually exclusive.
If publication fails, preserve the input and report the failure to firstmate; bin/fm-tasks-axi.sh --help owns bounded contention and explicit repair.
"""
    for label in ('Implementation in progress', 'Implementation', 'Affected checks', 'Branch ready', 'Integration'):
        template = template.replace(label, tr(label))
    return template.replace('{command}', command).replace('{input_path}', quote(input_path))
