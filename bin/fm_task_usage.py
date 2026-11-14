#!/usr/bin/env python3
"""refresh TASK_DIR writes usage.json from sessions.jsonl; unchanged source sizes
reuse the cache. Watcher slow checks, Claude turn ends and teardown refresh; snapshots only aggregate
cached files. Claude closing totals identify incomplete message data; Codex
includes all rollouts sharing session_meta.session_id.
Missing sessions/prices stay unknown. USD is API list-price equivalent, not a bill.
Pricing is a pinned API list-price estimate, not a bill. The versioned price file
is fm_task_prices.json; retain old snapshots in usage.json. FM_PRICE_MAX_AGE_DAYS
sets the stale warning threshold (default 30 days). Standard API pricing is
assumed; other service tiers and undisclosed cache retention are unknown.
"""
from collections import Counter
from datetime import date
import json
import math
import os
from pathlib import Path
import sys
import tempfile

PRICE_FILE = Path(__file__).with_name('fm_task_prices.json')
CATEGORIES = ('input', 'cache_read', 'output', 'cache_write_5m', 'cache_write_1h')


def pricing_warning(pricing):
    try:
        limit = max(0, int(os.environ.get('FM_PRICE_MAX_AGE_DAYS', '30')))
        return (date.today() - date.fromisoformat(pricing['verified'])).days > limit
    except (ValueError, KeyError, TypeError):
        return True


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
    if isinstance(usage.get('pricing'), dict):
        usage['pricing_stale'] = pricing_warning(usage['pricing'])
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
        usd=0., tokens=0, output_tokens=0, sessions=0, usd_known=True, breakdown=[], price_unknown=[]))


def charge(row, amounts, pricing, tier='standard', multipliers=None):
    rates = pricing.get('models', {}).get(row['model'])
    if not isinstance(rates, list) or len(rates) < len(amounts):
        rates = None
    row['tokens'] += sum(amounts)
    row['output_tokens'] += amounts[2]
    row['usd_known'] &= rates is not None
    if rates is None and 'missing-price' not in row['price_unknown']:
        row['price_unknown'].append('missing-price')
    factors = multipliers or [1] * len(amounts)
    if rates is not None:
        rates = [p * f for p, f in zip(rates, factors)]
    entry = next((x for x in row['breakdown'] if x['tier'] == tier), None)
    if entry is None:
        entry = dict(tier=tier, tokens=dict.fromkeys(CATEGORIES, 0), rates_per_million=dict(zip(CATEGORIES, rates or [])), usd=0.)
        row['breakdown'].append(entry)
    for name, amount in zip(CATEGORIES, amounts):
        entry['tokens'][name] += amount
    if rates is not None:
        cost = sum(a * p for a, p in zip(amounts, rates)) / 1e6
        row['usd'] += cost
        entry['usd'] += cost


def claude(paths, session, pricing):
    rows, seen, final = {}, set(), None
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
                creation = usage.get('cache_creation') or {}
                w1 = creation.get('ephemeral_1h_input_tokens', 0)
                amounts = [usage.get('input_tokens', 0), usage.get('cache_read_input_tokens', 0),
                    usage.get('output_tokens', 0), creation.get('ephemeral_5m_input_tokens', usage.get('cache_creation_input_tokens', 0) - w1), w1]
                long = model == 'claude-haiku-5-5' and sum(amounts) - amounts[2] > 100000
                charge(bucket(rows, 'claude', model, effort), amounts, pricing,
                       'prompt > 100000' if long else 'standard', [5] * 5 if long else None)
    # Closing summaries may contain usage without per-request tier or cache TTL.
    # Do not invent a reproducible allocation from their costUSD.
    incomplete = bool(final and final.get('hasUnknownModelCost'))
    if final:
        for model, usage in final.get('modelUsage', {}).items():
            matches = [r for r in rows.values() if r['model'] == model]
            recorded = sum(usage.get(k, 0) for k in ('inputTokens', 'outputTokens', 'cacheReadInputTokens', 'cacheCreationInputTokens'))
            if recorded != sum(r['tokens'] for r in matches):
                incomplete = True
    return list(rows.values()), True, incomplete


def codex(paths, session, pricing):
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
                writes = usage.get('cache_write_input_tokens', 0)
                inputs = usage.get('input_tokens', 0)
                row = bucket(rows, 'codex', model, effort)
                long = inputs > 272000
                charge(row, [inputs - cached, cached, usage.get('output_tokens', 0)], pricing,
                       'prompt > 272000' if long else 'standard', [2, 2, 1.5] if long else None)
                if writes:  # Retention and overlap with input are not identified.
                    row['usd_known'] = False
                    if 'cache-write-retention-unknown' not in row['price_unknown']:
                        row['price_unknown'].append('cache-write-retention-unknown')
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
    previous = read_usage(target)
    if (previous.get('sizes') == sizes and previous.get('pricing') and
            read(target, {}).get('pricing_stale') == pricing_warning(previous['pricing'])):
        return
    pricing = previous.get('pricing') or read(PRICE_FILE, {})
    rows, estimated = {}, False
    for session, paths in inputs:
        if not paths or any(sizes[str(p)] is None for p in paths):
            if paths:
                unknown.append('missing-session')
            continue
        values, estimate, incomplete = (claude if session['harness'] == 'claude' else codex)(paths, session, pricing)
        estimated |= estimate
        if incomplete or not values:
            unknown.append('incomplete-usage')
        for value in values:
            row = bucket(rows, value['harness'], value['model'], value['effort'])
            for field in ('usd', 'tokens', 'output_tokens'):
                row[field] += value[field]
            row['sessions'] += 1
            row['usd_known'] &= value['usd_known']
            row['price_unknown'].extend(x for x in value.get('price_unknown', []) if x not in row['price_unknown'])
            row['breakdown'].extend(value['breakdown'])
    result = dict(by=list(rows.values()), unknown=unknown, estimated=estimated, sizes=sizes,
                  pricing=pricing, pricing_stale=pricing_warning(pricing),
                  usd_basis='estimación a precio de lista')
    if previous and not previous.get('pricing'):
        result['previous_unversioned'] = {k: previous.get(k) for k in ('by', 'unknown', 'estimated')}
    elif previous.get('previous_unversioned'):
        result['previous_unversioned'] = previous['previous_unversioned']
    with tempfile.NamedTemporaryFile(mode='w', dir=folder, delete=False) as stream:
        json.dump(result, stream)
    Path(stream.name).replace(target)
    from fm_delivery import fleet_event
    fleet_event(folder.parent.parent, 'task.usage', folder.name, result)


def aggregate(data, tasks, backlog, usages=None):
    rows, counts, unknown, prices = {}, Counter(), [], []
    for task in tasks:
        task_id = task['key'][5:]
        usage = usages.get(task_id, {}) if usages is not None else read_usage(Path(data) / task_id / 'usage.json')
        values = usage.get('by', [])
        pricing = usage.get('pricing')
        if values:
            prices.append(dict(task=task_id, pricing=pricing, stale=pricing_warning(pricing) if pricing else None))
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
            row['price_unknown'].extend(x for x in value.get('price_unknown', []) if x not in row['price_unknown'])
            row['breakdown'].extend(dict(part, pricing_version=pricing.get('version') if pricing else None, task=task_id)
                                    for part in value.get('breakdown', []))
    values = sorted(rows.values(), key=lambda r: -r['usd'])
    result = dict(usd=round(sum(r['usd'] for r in values), 2), usd_basis='api-list-price',
        usd_complete=not unknown and all(r['usd_known'] for r in values),
        tokens=sum(r['tokens'] for r in values), output_tokens=sum(r['output_tokens'] for r in values),
        tasks=dict(counts), by=values, unknown=unknown, excludes=['coordinator'],
        pricing=prices, price_label='estimación a precio de lista')
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
