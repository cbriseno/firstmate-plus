#!/usr/bin/env python3
"""refresh TASK_DIR writes usage.json from sessions.jsonl; unchanged source sizes
reuse the cache. Watcher slow checks, Claude turn ends and teardown refresh; snapshots only aggregate
cached files. Claude's final cost-state supersedes message estimates (otherwise
estimated=true); Codex includes all rollouts sharing session_meta.session_id.
Missing sessions/prices stay unknown. USD is API list-price equivalent, not a bill.
Prices below: USD/million input, cached input, output, cache writes 5m/1h.
Verified 2026-11-09, standard short-context rates:
https://platform.claude.com/docs/en/about-claude/pricing
https://developers.openai.com/api/docs/pricing
"""
from collections import Counter
import json
import math
from pathlib import Path
import sys
import tempfile

PRICES = {
    'claude-fable-5-1': (10, .25, 50, 12.5, 20),
    'claude-opus-5-5': (4, .2, 20, 5, 8),
    'claude-sonnet-5-5': (2, .1, 10, 2.5, 4),
    'claude-haiku-5-5': (.1, .01, .5, .125, .2),
    'gpt-6.1-sol': (2, .1, 10), 'gpt-6.1-terra': (1, .05, 5),
    'gpt-6-luna': (.1, .01, .5), 'gpt-6-astra': (10, 1, 50),
}


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def read_usage(path):
    usage = read(path)
    if not isinstance(usage, dict):
        return {}
    values, unknown = usage.get('by', []), usage.get('unknown', [])
    if not isinstance(values, list) or not isinstance(unknown, list):
        return {}
    if any(not isinstance(reason, str) for reason in unknown):
        return {}
    for value in values:
        if not isinstance(value, dict):
            return {}
        if any(not isinstance(value.get(k), (str, type(None)))
               for k in ('harness', 'model', 'effort')):
            return {}
        if any(k not in value for k in ('harness', 'model', 'effort')):
            return {}
        if not isinstance(value.get('usd_known'), bool):
            return {}
        if any(type(value.get(k)) not in (int, float) or
               (isinstance(value[k], float) and not math.isfinite(value[k])) or value[k] < 0
               for k in ('usd', 'tokens', 'output_tokens', 'sessions')):
            return {}
    return usage


def records(path):
    with path.open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            try:
                yield json.loads(line)
            except ValueError:
                continue  # A running harness may have an unfinished last line.


def bucket(rows, harness, model, effort):
    key = (harness, model, effort)
    return rows.setdefault(key, dict(harness=harness, model=model, effort=effort,
        usd=0., tokens=0, output_tokens=0, sessions=0, usd_known=True))


def charge(row, amounts, multiplier=1):
    prices = PRICES.get(row['model'])
    row['tokens'] += sum(amounts)
    row['output_tokens'] += amounts[2]
    row['usd_known'] &= prices is not None
    row['usd'] += sum(a * p * multiplier for a, p in zip(amounts, prices or ())) / 1e6


def claude(paths, session):
    rows, seen, efforts, final = {}, set(), {}, None
    for path in paths:
        effort = session.get('effort')
        for event in records(path):
            if event.get('type') == 'api-request':
                params = event.get('params') or {}
                effort = (params.get('output_config') or {}).get('effort') or effort
            elif event.get('type') == 'cost-state' and path == paths[0]:
                final = event
            elif event.get('type') == 'assistant':
                message = event.get('message') or {}
                usage = message.get('usage')
                if not usage or not message.get('id') or message['id'] in seen:
                    continue
                seen.add(message['id'])
                if path == paths[0]:
                    final = None  # A resumed session has outgrown its closing total.
                model = message.get('model') or session.get('model')
                efforts[model] = effort
                creation = usage.get('cache_creation') or {}
                w1 = creation.get('ephemeral_1h_input_tokens', 0)
                amounts = [usage.get('input_tokens', 0), usage.get('cache_read_input_tokens', 0),
                    usage.get('output_tokens', 0), creation.get('ephemeral_5m_input_tokens', usage.get('cache_creation_input_tokens', 0) - w1), w1]
                charge(bucket(rows, 'claude', model, effort), amounts,
                       5 if model == 'claude-haiku-5-5' and sum(amounts) - amounts[2] > 100000 else 1)
    if final:
        for model, usage in final.get('modelUsage', {}).items():
            matches = [r for r in rows.values() if r['model'] == model]
            row = bucket(rows, 'claude', model, efforts.get(model, session.get('effort')))
            # Keep observed effort splits; assign closing/background differences
            # to the last observed effort for that model.
            row['usd'] += usage['costUSD'] - sum(r['usd'] for r in matches)
            row['output_tokens'] += usage['outputTokens'] - sum(r['output_tokens'] for r in matches)
            row['tokens'] += sum(usage.get(k, 0) for k in ('inputTokens', 'outputTokens', 'cacheReadInputTokens', 'cacheCreationInputTokens')) - sum(r['tokens'] for r in matches)
            for row in [r for r in rows.values() if r['model'] == model]:
                row['usd_known'] = True
    return list(rows.values()), final is None, bool(final and final.get('hasUnknownModelCost'))


def codex(paths, session):
    rows = {}
    for path in paths:
        model, effort = session.get('model'), session.get('effort')
        for event in records(path):
            payload = event.get('payload') or {}
            if event.get('type') == 'turn_context':
                model = payload.get('model') or model
                effort = payload.get('effort') or payload.get('reasoning_effort') or effort
            elif event.get('type') == 'token_usage_record':
                usage = payload.get('usage') or {}
                cached = usage.get('cached_input_tokens', 0)
                charge(bucket(rows, 'codex', model, effort),
                       [usage.get('input_tokens', 0) - cached, cached, usage.get('output_tokens', 0)])
    return list(rows.values()), False, False


def session_paths(session):
    path = Path(session['session'])
    if session['harness'] == 'claude':
        return [path] + sorted((path.parent / path.stem / 'subagents').glob('*.jsonl'))
    if session['harness'] == 'codex':
        sid = next(records(path), {}).get('payload', {}).get('session_id')
        root = next((p for p in path.parents if p.name == 'sessions'), path.parent)
        return sorted(set([path] + [p for p in root.rglob('rollout-*.jsonl')
            if sid and next(records(p), {}).get('payload', {}).get('session_id') == sid]))
    return []


def refresh(folder):
    folder = Path(folder)
    source = folder / 'sessions.jsonl'
    if not source.exists():
        return
    sessions = list(records(source))
    inputs, unknown, seen = [], [], set()
    for session in sessions:
        if not session.get('session'):
            unknown.append('no-session')
            continue
        if session['session'] in seen:
            continue
        try:
            paths = session_paths(session)
            if paths and all(str(p) in seen for p in paths):
                continue
            seen.update(str(p) for p in paths)
            inputs.append((session, paths))
            if not paths:
                unknown.append('unsupported-harness')
        except OSError:
            inputs.append((session, [Path(session['session'])]))
            unknown.append('missing-session')
    sizes = {str(p): p.stat().st_size if p.exists() else None
             for p in [source] + [p for _, paths in inputs for p in paths]}
    target = folder / 'usage.json'
    if read_usage(target).get('sizes') == sizes:
        return
    rows, estimated = {}, False
    for session, paths in inputs:
        if not paths or any(sizes[str(p)] is None for p in paths):
            if paths:
                unknown.append('missing-session')
            continue
        values, estimate, incomplete = (claude if session['harness'] == 'claude' else codex)(paths, session)
        estimated |= estimate
        if incomplete or not values:
            unknown.append('incomplete-usage')
        for value in values:
            row = bucket(rows, value['harness'], value['model'], value['effort'])
            for field in ('usd', 'tokens', 'output_tokens'):
                row[field] += value[field]
            row['sessions'] += 1
            row['usd_known'] &= value['usd_known']
    result = dict(by=list(rows.values()), unknown=unknown, estimated=estimated, sizes=sizes)
    with tempfile.NamedTemporaryFile(mode='w', dir=folder, delete=False) as stream:
        json.dump(result, stream)
    Path(stream.name).replace(target)
    from fm_delivery import fleet_event
    fleet_event(folder.parent.parent, 'task.usage', folder.name, result)


def aggregate(data, tasks, backlog, usages=None):
    rows, counts, unknown = {}, Counter(), []
    for task in tasks:
        task_id = task['key'][5:]
        usage = usages.get(task_id, {}) if usages is not None else read_usage(Path(data) / task_id / 'usage.json')
        values = usage.get('by', [])
        reason = next(iter(usage.get('unknown') or []), None)
        state = ('no_agent' if backlog[task_id].get('kind') == 'captain' else 'not_started'
                 if task['backlog_state'] == 'queued' else 'unknown') if not values else (
                 'running' if task['backlog_state'] == 'in_flight' else 'counted')
        counts[state] += 1
        if state not in ('no_agent', 'not_started') and (reason or state == 'unknown'):
            unknown.append(dict(task=task_id, title=task['title'], reason=reason or 'no-session'))
        for value in values:
            row = bucket(rows, value['harness'], value['model'], value['effort'])
            for field in ('usd', 'tokens', 'output_tokens', 'sessions'):
                row[field] += value[field]
            row['usd_known'] &= value['usd_known']
    values = sorted(rows.values(), key=lambda r: -r['usd'])
    result = dict(usd=round(sum(r['usd'] for r in values), 2), usd_basis='api-list-price',
        usd_complete=not unknown and all(r['usd_known'] for r in values),
        tokens=sum(r['tokens'] for r in values), output_tokens=sum(r['output_tokens'] for r in values),
        tasks=dict(counts), by=values, unknown=unknown, excludes=['coordinator'])
    for row in values:
        row['usd'] = round(row['usd'], 2)
    return result


if __name__ == '__main__':
    if sys.argv[1:] in (['--help'], ['-h']):
        print(__doc__)
        raise SystemExit(0)
    if len(sys.argv) != 3 or sys.argv[1] != 'refresh':
        raise SystemExit(__doc__)
    refresh(sys.argv[2])
