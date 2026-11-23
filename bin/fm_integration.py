"""Local integration evidence and overdue work, shared by the watcher and budgets."""
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from fm_delivery import completion_receipt, home_path, read_presentation, read_text, task_creation
from fm_progress import git


MARKER = 'firstmate integrate '
DEADLINE = 7200
TASK_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}')


def epoch(stamp):
    try:
        value = dt.datetime.fromisoformat((stamp or '').replace('Z', '+00:00'))
        return int(value.timestamp()) if value.tzinfo else None
    except (TypeError, ValueError, OverflowError):
        return None


def marker(home, data, task):
    declaration = read_presentation(home, task, data, verify=False)['presentation']
    return MARKER + json.dumps([task, (declaration['request'] or {}).get('id')], ensure_ascii=True)


def ref_history(repo):
    """Return changes on the current continuous history, newest first."""
    branch = git(repo, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    branch = branch.removeprefix('origin/') if branch else next(
        (b for b in ('main', 'master') if git(repo, 'rev-parse', '--verify', 'refs/heads/' + b)), None)
    if not branch:
        return [], None
    ref = 'refs/heads/' + branch
    log = git(repo, 'reflog', 'show', '--max-count=64', '--date=unix', '--format=%H%x09%P%x09%gD%x09%gs', ref)
    entries = []
    for line in (log or '').splitlines():
        head, _, suffix = line.partition('\t')
        parents, _, suffix = suffix.partition('\t')
        selector, _, action = suffix.partition('\t')
        stamp = re.search(r'@\{(\d+)\}$', selector)
        if not stamp:
            return [], None
        entries.append((head, int(stamp[1]), action, parents.split()))
    moves, since = [], None
    for index, (head, stamp, action, parents) in enumerate(entries):
        if re.match(r'(reset|rebase|rewind|branch: Reset)\b', action, re.I):
            break
        if index + 1 == len(entries):
            since = stamp
            break
        before, before_time, _, _ = entries[index + 1]
        if stamp < before_time:
            break
        if before == head:
            continue
        if before not in parents and git(repo, 'merge-base', '--is-ancestor', before, head) is None:
            break
        moves.append((head, stamp, action))
        since = stamp
    return moves, since


def local_events(owner, repo, project):
    moves, since = ref_history(repo)
    historical = {}
    for task, row in owner.rows.items():
        if row.get('repo') != project or row['state'] != 'done':
            continue
        if row.get('local_note') != 'local main':
            continue
        receipt = completion_receipt(owner.home, row)
        if receipt is None:
            continue
        declaration = owner.presentations[task]
        gates = (declaration.get('progress_record') or {}).get('gates', {})
        head = gates.get('integrated', gates.get('branch-ready', {})).get('head')
        request = declaration['presentation']['request']
        historical[task] = (epoch(receipt['value']), head, (request or {}).get('id'))
    events = []
    for index, (head, at, action) in enumerate(moves):
        if action.startswith(MARKER):
            payload = action[len(MARKER):].removesuffix(': Fast-forward')
            try:
                task, request = json.loads(payload)
            except (ValueError, TypeError):
                continue
            events.append(dict(task=task, request=request, at=at, source='local-merge'))
            continue
        branch = re.fullmatch(r'merge fm/(.+): Fast-forward', action)
        closed_before = moves[index - 1][1] if index else float('inf')
        # Older overlay integrations had no reflog message. Pair an exact
        # ready head when retained, or an unambiguous owner close in this move's
        # interval. The branch message, where present, already names the task.
        matches = [(task, request) for task, (closed, ready, request) in historical.items()
                   if closed is not None and at <= closed <= closed_before
                   and (branch[1] == task if branch else not action and ready in (None, head))]
        if len(matches) == 1:
            task, request = matches[0]
            events.append(dict(task=task, request=request, at=at, source='owner-close-and-reflog'))
    return events, since


def project_path(owner, project):
    projects = Path(os.environ.get('FM_PROJECTS_OVERRIDE', owner.home / 'projects'))
    path = projects / project
    if (path / '.git').exists():
        return str(path)
    for path in re.findall(r'/[A-Za-z0-9._/-]+', owner.projects.get(project, {}).get('description', '')):
        if (Path(path) / '.git').exists():
            return path
    return None


def summary(events, now):
    clocks = [event['at'] for event in events[:2]]
    return dict(last_at=clocks[0] if clocks else None,
                since_s=now - clocks[0] if clocks else None,
                between_s=clocks[0] - clocks[1] if len(clocks) == 2 else None)


def captain_request(owner, request):
    # The work owner creates a request group for ordinary maintenance too.
    # Captain placement or the retained original brief can establish intent.
    if 'request:' + request in owner.structure['order']:
        return True
    if not TASK_ID.fullmatch(request):
        return False
    script = '. "$1"; fm_brief_task_heading_body - "## Captain\x27s intent"'
    try:
        brief = read_text(owner.home, f'data/{request}/brief.md', 65536)
        result = subprocess.run(['bash', '-c', script, 'fm-integration',
                                 str(Path(__file__).with_name('fm-brief-heading-lib.sh'))],
                                input=brief, capture_output=True, text=True, timeout=5, check=True)
        return result.stdout.strip() not in ('', '{TASK}')
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def snapshot(home, now):
    from fm_work import Owner, Refusal

    result = dict(projects={}, overdue=[])
    if not (home / 'data/backlog.md').is_file():
        return result
    try:
        owner = Owner().load(include_presentations=False)
        edges = owner.edges()
    except (OSError, ValueError, Refusal, subprocess.SubprocessError):
        return result

    candidates, covered_projects = {}, set()
    for task in sorted(owner.current_ids):
        row = owner.rows[task]
        if row.get('kind') != 'ship' or not row.get('repo'):
            continue
        project = row['repo']
        covered_projects.add(project)
        if row['state'] == 'done' or owner.progress_reporting_held(task):
            continue
        if any(block['open'] for block in owner.blockers(task, edges)):
            continue
        request = owner.presentations[task]['presentation']['request']
        if request and not owner.presentations[task]['presentation']['closure']:
            candidates.setdefault(project, {}).setdefault(request['id'], []).append(task)
    for project in sorted(covered_projects):
        requests = candidates.get(project, {})
        repo = project_path(owner, project)
        events, since = local_events(owner, repo, project) if repo else ([], None)
        project_view = result['projects'][project] = dict(summary(events, now), coverage_from=since, requests={})
        for request in sorted(set(requests) | {event['request'] for event in events if event['request']}):
            tasks = requests.get(request, [])
            own = [event for event in events if event['request'] == request]
            request_view = project_view['requests'][request] = summary(own, now)
            if not tasks:
                continue
            created = task_creation(owner.data, dict(id=request))
            started = epoch((created or {}).get('value'))
            latest = request_view['last_at']
            if latest is None and (started is None or since is None or started < since):
                continue
            clock = max(latest or 0, started or 0)
            if now - clock >= DEADLINE and captain_request(owner, request):
                result['overdue'].append(dict(project=project, request=request, since=clock, tasks=tasks))
    if result['overdue']:
        owner.request_sort = 'manual'
        ordered = owner.snapshot(controls_only=True)
        requests = {key[8:]: rank for rank, key in enumerate(owner.work_order)}
        result['overdue'].sort(key=lambda item: requests.get(item['request'], len(requests)))
        ready = {key[5:]: rank for rank, key in enumerate(ordered['sigue'])}
        def priority(task):
            gates = (owner.presentations[task].get('progress_record') or {}).get('gates', {})
            return ('branch-ready' not in gates, ready.get(task, len(ready)), task)
        for item in result['overdue']:
            item['tasks'].sort(key=priority)
            task = item['tasks'][0]
            if not priority(task)[0]:
                step = 'review branch for landing'
            elif task in ready and not (owner.data / task / 'brief.md').is_file():
                step = 'prepare dispatch brief'
            else:
                step = 'review task continuation'
            item.update(owner='primary', next_step=step)
    return result


if __name__ == '__main__':
    task, data = sys.argv[1:]
    print(marker(home_path(), data, task))
