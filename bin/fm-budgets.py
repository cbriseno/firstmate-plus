#!/usr/bin/env python3
"""Behavior budgets: compare whole-system behavior with fixed limits.

Usage: python3 bin/fm-budgets.py table    compute and print; writes nothing
       python3 bin/fm-budgets.py check    compute, publish, alarm (watcher tick)
       python3 bin/fm-budgets.py limits   print the effective limits as JSON

It implements a manual procedure, in order: read the records the system already
writes, compute each measure over its window, and compare it with its limit.
It only reads those records. `check` additionally writes STATE/budgets.json
(the current table, read by the Deck), appends one line per measure and hour to
STATE/budgets-history.jsonl (35 days kept), and for a measure over its limit
writes STATE/budget-<measure>.budget-alarm, a one-line reason that the watcher
queues as an actionable check for firstmate: at most one per measure per 24 h.
An alarm still exceeded 2 h later with no data/*/brief.md written since that
names the measure sends one fm-notify.py `budget-exceeded` notice per episode.
A measure with no samples is null ("unmeasured"), never within its limit.

Limits: the defaults below, overridden per installation by CONFIG/budgets.json
{"measures": {"<measure>": {"limit": N, "alarm": false}}}; tests read them
with `limits`, so tests and monitoring use the same numbers. A null limit means
the p90 of that measure's last 14 days of history, once 72 hourly points exist.
Skip: FM_BUDGETS=0 disables `check`; "alarm": false keeps a measure measured.
Delivery and test-slot observations are included in the current snapshot.
The watcher routes overdue work and slot pressure as operational work and
rechecks it even if an earlier wake was acknowledged.

Paths follow FM_HOME (default: this checkout), FM_STATE_OVERRIDE,
FM_CONFIG_OVERRIDE and FM_DATA_OVERRIDE. Diagnostic-log measures come from
bin/fm-diag.sh's per-user log and are machine-wide; the rest are this home's.
"""
import calendar
import glob
import json
import os
from collections import Counter
from pathlib import Path
import subprocess
import sys
import time

from fm_integration import DEADLINE, snapshot as delivery_snapshot
from fm_test_slots import sample as slot_snapshot
from fm_nudge import CATEGORIES, cause_of, rows as nudge_rows, unrooted

# key: family, unit, window seconds, default limit, scope, meaning
MEASURES = {
    'primary_quiet_wakes_per_h': ('rate', 'wakes', 3600, 4, 'home', 'heartbeat and informational-summary wakes delivered to the primary; limit_idle applies while no worker is working'),
    'obligations_overdue_per_day': ('rate', 'obligations', 86400, 0, 'machine', 'mechanical obligations still unresolved after their deadline'),
    'worker_messages_per_h_max': ('rate', 'messages', 3600, 6, 'home', 'inbox messages to the busiest single worker; the first notice of a wait it declared is its own requested wake, not counted'),
    'wake_attention_p95_s': ('latency', 's', 3600, 600, 'machine', 'p95 wait of acknowledged wake rows'),
    'hook_run_p95_ms': ('latency', 'ms', 3600, 2000, 'machine', 'p95 of blocking hook runs'),
    'work_snapshot_p95_ms': ('latency', 'ms', 3600, 10000, 'machine', 'p95 of work snapshots'),
    'worker_zombies_sustained_max': ('accumulation', 'zombies', 900, 2, 'machine', 'fewest unreaped zombies a worker kept across 15 min, worst worker'),
    'state_growth_mb_per_day': ('accumulation', 'MB', 86400, 1, 'home', 'net growth of the state directory'),
    'home_summary_age_s': ('freshness', 's', 0, 900, 'home', 'age of the home summary when last read'),
    'task_usd_per_h_max': ('spend', 'USD', 3600, None, 'home', 'list-price spend of the costliest task in the last hour'),
    'usd_per_day': ('spend', 'USD', 86400, None, 'home', 'list-price spend of all tasks in the last 24 h'),
}
for category in CATEGORIES:
    MEASURES[f'nudges_{category}_per_day'] = ('rate', 'nudges', 86400, 0 if CATEGORIES[category] else None, 'home', f'supervisor nudges today: {category}')
MEASURES['nudges_unclassified'] = ('accumulation', 'nudges', 0, 0, 'home', 'historical nudges needing category review')
MEASURES['supervisor_interventions_per_day'] = ('rate', 'nudges', 86400, 0, 'home', 'corrections recorded today at every level')
MEASURES['correction_causes_unrooted'] = ('accumulation', 'causes', 0, 0, 'home', 'correction causes without an open root task, or recurred after it closed')
DEFAULT_EXTRA = {'primary_quiet_wakes_per_h': {'limit_idle': 1},
                 'nudges_new-orders_per_day': {'alarm': False},
                 'supervisor_interventions_per_day': {'alarm': False}}
ALARM_EVERY = 86400
NOTIFY_AFTER = 7200
RELAPSE_WINDOW = 14 * 86400
HISTORY_DAYS = 35

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get('FM_HOME') or ROOT)
STATE = Path(os.environ.get('FM_STATE_OVERRIDE') or HOME / 'state')
CONFIG = Path(os.environ.get('FM_CONFIG_OVERRIDE') or HOME / 'config')
DATA = Path(os.environ.get('FM_DATA_OVERRIDE') or HOME / 'data')


def diag_dir():
    if os.environ.get('FM_DIAGNOSTICS_HOME'):
        return Path(os.environ['FM_DIAGNOSTICS_HOME']) / 'firstmate'
    if sys.platform == 'darwin':
        return Path.home() / 'Library/Logs/Firstmate/Diagnostics/firstmate'
    return Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local/state') / 'firstmate/diagnostics/firstmate'


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return default


def write_json(path, value):
    tmp = Path(f'{path}.tmp{os.getpid()}')
    tmp.write_text(json.dumps(value, indent=1, sort_keys=True) + '\n', encoding='utf-8')
    os.replace(tmp, path)


def limits():
    over = load_json(CONFIG / 'budgets.json', {}).get('measures', {})
    out = {}
    for key, (family, unit, window, limit, scope, meaning) in MEASURES.items():
        item = dict(limit=limit, alarm=True, unit=unit, window_s=window, family=family, scope=scope, meaning=meaning)
        item.update(DEFAULT_EXTRA.get(key, {}))
        if isinstance(over.get(key), dict):
            item.update({k: v for k, v in over[key].items() if k in ('limit', 'limit_idle', 'alarm')})
        if key == 'nudges_new-orders_per_day':
            item.update(limit=None, alarm=False)
        out[key] = item
    return out


def lines_newest_first(path, block=1 << 20):
    try:
        handle = open(path, 'rb')
    except OSError:
        return
    with handle:
        handle.seek(0, os.SEEK_END)
        end, rest = handle.tell(), b''
        while end > 0:
            start = max(0, end - block)
            handle.seek(start)
            chunk = handle.read(end - start) + rest
            parts = chunk.split(b'\n')
            rest = parts.pop(0) if start else b''
            for raw in reversed(parts):
                if raw:
                    yield raw
            end = start
        if rest:
            yield rest


def diag_events(since):
    """Diagnostic events newer than `since` (epoch), from the live and rotated log."""
    cutoff = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(since))
    out = []
    for name in ('events.jsonl', 'events.1.jsonl'):
        for raw in lines_newest_first(diag_dir() / name):
            try:
                event = json.loads(raw)
            except ValueError:
                continue
            if str(event.get('t', '')) < cutoff:
                return out
            out.append(event)
    return out


def p95(values):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    return values[max(0, -(-len(values) * 95 // 100) - 1)] if len(values) >= 5 else None


def fleet_working():
    for meta in STATE.glob('*.meta'):
        if meta.with_suffix('.parked').exists():
            continue
        try:
            last = meta.with_suffix('.status').read_text(encoding='utf-8', errors='replace').strip().splitlines()[-1]
        except (OSError, IndexError):
            continue
        if last.startswith('working'):
            return True
    return False


def quiet_wakes(since):
    ended = {}
    try:
        for row in (STATE / '.watch-cycle-exits.log').read_text(errors='replace').splitlines():
            fields = dict(part.split('=', 1) for part in row.split('\t') if '=' in part)
            ident = fields.get('lock_before', '').split('|identity:', 1)[-1]
            if fields.get('ended_at', '').isdigit():
                ended.setdefault(ident, int(fields['ended_at']))
    except OSError:
        return None, 'no watcher cycle log'
    count = matched = 0
    try:
        rows = (STATE / '.watch-deliveries.log').read_text(errors='replace').splitlines()
    except OSError:
        return None, 'no delivery log'
    for row in rows:
        parts = row.split('\t', 2)
        if len(parts) < 3 or ended.get(parts[1], 0) < since:
            continue
        matched += 1
        count += parts[2].startswith(('heartbeat', 'check: informational summary'))
    return count, f'{count} quiet of {matched} wakes delivered in the window'


# bin/fm-watch.sh paused_until_resume opens this notice (older installations
# wrote the second form) and ends it with "Pause: <the declared status line>".
WAIT_NOTICES = ('Your declared pause condition has been reached.', 'Your declared pause deadline has arrived.')


def worker_messages(since):
    """Count each worker's inbox records in the window.

    Every message that reached a worker is an inbox record, including Lavish
    results delivered to their owner (bin/fm-procevent.sh), so procevent-inbox
    results are not counted again. The first notice of a declared wait is the
    wake the worker asked for; a repeated notice of the same wait still counts.
    """
    counts, first, waits = {}, {}, {}
    for path in glob.glob(str(STATE / '*.inbox' / '*.msg')) + glob.glob(str(STATE / '*.inbox' / 'handled' / '*.msg')):
        task = Path(path.split('.inbox', 1)[0]).name
        try:
            head, _, body = Path(path).read_text(errors='replace').partition('\n--\n')
            at = next(line[3:] for line in head.splitlines() if line.startswith('at='))
            stamp = calendar.timegm(time.strptime(at, '%Y-%m-%dT%H:%M:%SZ'))
        except (OSError, StopIteration, ValueError):
            continue
        wait = body.startswith(WAIT_NOTICES) and body.partition('Pause: ')[2].strip()
        if wait and (stamp, path) < first.get((task, wait), (stamp + 1, '')):
            first[(task, wait)] = (stamp, path)
        if stamp >= since:
            counts.setdefault(task, []).append((path, wait))
    for task, records in counts.items():
        waits[task] = sum(1 for path, wait in records if wait and first[(task, wait)][1] == path)
        counts[task] = len(records) - waits[task]
    if not any(counts.values()):
        return 0, 'no messages in the window'
    task = max(counts, key=counts.get)
    return counts[task], f'busiest worker {task} ({waits[task]} requested wait notices not counted)'


def spend(cache, now):
    """Refresh per-task USD from data/*/usage.json; keep one hour of samples."""
    usd = cache.setdefault('usd', {})
    samples = cache.setdefault('samples', {})
    for path in DATA.glob('*/usage.json'):
        task = path.parent.name
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        if usd.get(task, [None])[0] != mtime:
            total = sum(item.get('usd') or 0 for item in load_json(path, {}).get('by', []) if isinstance(item, dict))
            usd[task] = [mtime, round(total, 4)]
        if mtime >= now - 2 * 3600:
            series = samples.setdefault(task, [])
            series.append([now, usd[task][1]])
    worst, worst_task = 0.0, None
    for task, series in list(samples.items()):
        older = [s for s in series if s[0] <= now - 3600]
        series[:] = older[-1:] + [s for s in series if s[0] > now - 3600]
        if len(series) < 2 and (not series or series[0][0] < now - 2 * 3600):
            del samples[task]
            continue
        delta = series[-1][1] - series[0][1]
        if delta > worst:
            worst, worst_task = delta, task
    total = round(sum(v[1] for v in usd.values()), 4)
    return round(worst, 2), (f'costliest task {worst_task}' if worst_task else 'no spend in the window'), total


def dir_bytes(path):
    total = 0
    for base, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(base, name)).st_size
            except OSError:
                pass
    return total


def history(path):
    rows = []
    try:
        for line in path.read_text(encoding='utf-8').splitlines():
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    except OSError:
        pass
    return rows


def day_ago(rows, key, now):
    old = [r['value'] for r in rows if r.get('key') == key and r.get('value') is not None and now - 90000 <= r.get('t', 0) <= now - 82800]
    return old[0] if old else None


def compute(now, cache, rows):
    lim = limits()
    events = diag_events(now - 3600)
    values = {}

    def by(name):
        return [e for e in events if e.get('e') == name]

    working = fleet_working()
    value, detail = quiet_wakes(now - 3600)
    values['primary_quiet_wakes_per_h'] = (value, detail + ('; fleet working' if working else '; fleet idle or paused'))
    # An open obligation is re-paged every period; count obligations, not pages.
    # Pages written before they carried an identity count one each.
    overdue = [e for e in diag_events(now - 86400) if e.get('e') == 'obligation.overdue']
    distinct = len({e.get('obligation') or i for i, e in enumerate(overdue)})
    diagnosed = any((diag_dir() / name).is_file() for name in ('events.jsonl', 'events.1.jsonl'))
    values['obligations_overdue_per_day'] = (distinct if diagnosed else None,
                                             f'{distinct} overdue obligations ({len(overdue)} pages)' if diagnosed else 'no diagnostic log')
    values['worker_messages_per_h_max'] = worker_messages(now - 3600)
    acks = [e.get('age_s') for e in by('wake.ack')]
    values['wake_attention_p95_s'] = (p95(acks), f'{len(acks)} acknowledged wakes')
    hooks = [e.get('ms') for e in by('hook.run')]
    values['hook_run_p95_ms'] = (p95(hooks), f'{len(hooks)} hook runs')
    snaps = [e.get('ms') for e in by('work.snapshot')]
    values['work_snapshot_p95_ms'] = (p95(snaps), f'{len(snaps)} snapshots')
    cutoff = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now - 900))
    per_task = {}
    for e in by('worker.procs'):
        if str(e.get('t', '')) >= cutoff and isinstance(e.get('zombies'), int):
            per_task.setdefault(e.get('task'), []).append(e['zombies'])
    sustained = {t: min(z) for t, z in per_task.items() if len(z) >= 2}
    values['worker_zombies_sustained_max'] = (max(sustained.values()) if sustained else None, f'{len(sustained)} workers sampled')
    state_bytes = dir_bytes(STATE)
    old = day_ago(rows, 'state_bytes', now)
    values['state_growth_mb_per_day'] = (None if old is None else round((state_bytes - old) / 1e6, 2), f'state is {state_bytes / 1e6:.1f} MB')
    read = load_json(STATE / '.home-summary-read.json', {})
    age = read.get('age_seconds') if isinstance(read, dict) else None
    values['home_summary_age_s'] = (age if isinstance(age, int) and not isinstance(age, bool) and age >= 0 else None,
                                    'age observed when the home summary was read')
    worst, detail, usd_total = spend(cache, now)
    values['task_usd_per_h_max'] = (worst, detail)
    old = day_ago(rows, 'usd_total', now)
    values['usd_per_day'] = (None if old is None else round(max(0.0, usd_total - old), 2), f'{usd_total:.0f} USD recorded in total')

    today = time.strftime('%Y-%m-%d', time.localtime(now))
    ledger = nudge_rows(STATE / 'nudges.jsonl')
    all_nudges = [r for r in ledger if r.get('time') and not r.get('link')]
    nudges = [r for r in all_nudges if str(r.get('time', '')).startswith(today)]
    gaps = Counter(str(cause_of(r) or 'historical unmapped') for r in nudges
                   if CATEGORIES.get(r.get('category'), True))
    values['supervisor_interventions_per_day'] = (
        sum(gaps.values()), ', '.join(f'{gap}: {count}' for gap, count in sorted(gaps.items()))
        or 'no mechanical interventions today')
    for category in (*CATEGORIES, 'unclassified'):
        matching = ([r for r in all_nudges if 'legacy_category' in r and r.get('category') not in CATEGORIES]
                    if category == 'unclassified' else [r for r in nudges if r.get('category') == category])
        details = [(('[' + ' '.join(str(r.get('legacy_category', '')).split()) + '] ')
                    if category == 'unclassified' else '') + ' '.join(str(r.get('text', '')).split()) +
                   (' (task: ' + ' '.join(str(r.get('task') or 'create a root-cause task').split()) + ')'
                    if category != 'new-orders' else '') for r in matching]
        detail = '; '.join(details) or 'no nudges today'
        if category == 'unclassified' and matching:
            detail = 'classify historical categories; ' + detail
        key = 'nudges_unclassified' if category == 'unclassified' else f'nudges_{category}_per_day'
        values[key] = (len(matching), detail)
    debt = unrooted(ledger)
    bare = [f"{name} ({item['count']})" for name, item in sorted(debt.items()) if not item['recurred']]
    back = [f"{name} ({item['count']}, after {item['root']} closed)" for name, item in sorted(debt.items()) if item['recurred']]
    values['correction_causes_unrooted'] = (len(debt), '; '.join(
        ([f"recurred: {', '.join(back)}"] if back else []) + ([f"no root task: {', '.join(bare)}"] if bare else []))
        + '; link each to an open root task with bin/fm-nudge.sh link' if debt
        else 'every cause has an open or verified root task')

    table = {}
    for key, item in lim.items():
        value, detail = values[key]
        limit = item['limit_idle'] if key == 'primary_quiet_wakes_per_h' and not working else item['limit']
        if limit is None and key != 'nudges_new-orders_per_day':
            past = sorted(r['value'] for r in rows if r.get('key') == key and isinstance(r.get('value'), (int, float)) and r.get('t', 0) >= now - RELAPSE_WINDOW)
            limit = past[len(past) * 9 // 10] if len(past) >= 72 else None
        exceeded = None if value is None or limit is None else value > limit
        table[key] = dict(item, value=value, limit=limit, exceeded=exceeded, detail=detail)
    return table, {'state_bytes': state_bytes, 'usd_total': usd_total}


def print_table(table):
    print(f'{"measure":30} {"value":>10} {"limit":>8}  verdict    detail')
    for key, row in table.items():
        verdict = 'unmeasured' if row['value'] is None else ('no limit' if row['limit'] is None else ('EXCEEDED' if row['exceeded'] else 'ok'))
        print(f'{key:30} {str(row["value"]):>10} {str(row["limit"]):>8}  {verdict:10} {row["detail"]}')


def print_operations(delivery, slots):
    if slots:
        print(f'Test runs: {slots["runs"]}, turns: {slots["slots"]}, in use: {slots["occupied"]}, '
              f'oldest wait (s): {slots["oldest_wait_s"]}, publication wait (s): {slots["priority_wait_s"]}')
    else:
        print('Test runs and turns: unmeasured')
    for project, data in delivery['projects'].items():
        scopes = {project: data, **{f'{project}/{key}': value for key, value in data['requests'].items()}}
        for name, clock in scopes.items():
            print(f'Integration {name}: age (s) {clock["since_s"]}, interval (s) {clock["between_s"]}')


def capture_operations(now):
    os.environ.setdefault('FM_HOME', str(HOME))
    delivery = delivery_snapshot(HOME, now)
    slots = slot_snapshot()
    return delivery, slots


def operational_alarm(now, cache, delivery, slots):
    overdue = delivery['overdue']
    alarm = STATE / 'budget-operational-progress.budget-alarm'
    identity, reasons = [], []
    if overdue:
        first = overdue[0]
        task = first['tasks'][0]
        identity.extend([first['project'], first['request'], first['since'], task])
        reasons.append(f'integration overdue ({DEADLINE // 3600} h) for request {first["request"]}, '
                       f'project {first["project"]}, next task {task}; owner primary: {first["next_step"]}, '
                       'take the next authorized step or record the blocker, owner and next opportunity before acknowledging.')
    if slots and slots['runs'] > slots['slots']:
        identity.append('test-slots')
        reasons.append(f'{slots["runs"]} test runs for {slots["slots"]} host test slots; '
                       'owner primary: use the existing test priority for the captain’s next delivery '
                       'and reuse its live run before starting more tests.')
    if not identity:
        cache.pop('operational', None)
        alarm.unlink(missing_ok=True)
        return
    prior = cache.get('operational', {})
    next_check = prior.get('next', now) if prior.get('identity') == identity else now
    if next_check > now:
        return
    recheck = now + 1800
    until = time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(recheck))
    tmp = alarm.with_suffix('.tmp')
    tmp.write_text('check: ' + ' '.join(reasons)
                   + f' Evidence: {STATE}/budgets.json. Recheck by {until}.\n', encoding='utf-8')
    os.replace(tmp, alarm)
    cache['operational'] = dict(identity=identity, next=recheck)


def recent_commits():
    try:
        out = subprocess.run(['git', '-C', str(ROOT), 'log', '--since=24.hours.ago', '--format=%h', '-n', '12', 'HEAD'],
                             capture_output=True, text=True, timeout=10).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        return 'unknown'
    return ' '.join(out) or 'none'


def delegated(key, since):
    for brief in DATA.glob('*/brief.md'):
        try:
            if brief.stat().st_mtime >= since and key in brief.read_text(errors='replace'):
                return True
        except OSError:
            pass
    return False


def check(now):
    cache = load_json(STATE / '.budgets-cache.json', {})
    hist_path = STATE / 'budgets-history.jsonl'
    rows = history(hist_path)
    table, counters = compute(now, cache, rows)
    if table['home_summary_age_s']['exceeded']:
        # Re-read through the normal collector after allowing its bounded
        # refresh to finish. Keep the old sample when no newer read succeeds.
        env = os.environ.copy()
        timeout = env.get('FM_HOME_SUMMARY_TIMEOUT', '60')
        timeout = int(timeout) if timeout.isdigit() and int(timeout) > 0 else 60
        env['FM_SNAPSHOT_BUDGET'] = str(timeout + 30)
        env['FM_SNAPSHOT_SECONDMATES'] = '0'
        env.setdefault('FM_SNAPSHOT_REGISTRY_TIMEOUT', '30')
        try:
            result = subprocess.run(
                ['bash', '-c', '. "$1"; shift; fm_run_timed "$@"', 'budget-recheck',
                 str(ROOT / 'bin/fm-timeout-lib.sh'), str(timeout * 2 + 60),
                 str(ROOT / 'bin/fm-fleet-snapshot.sh'), '--json'],
                env=env, capture_output=True, text=True)
            current = json.loads(result.stdout)['secondmate_current']
            records = current['records']
            if (result.returncode == 0 and current['registry']['complete'] and not current['truncated']
                    and records and all(r['provenance']['selected'] == 'structured-home'
                                        and r['provenance']['summary_source'] in ('local-ledger', 'remote-ledger')
                                        and isinstance(r['freshness']['age_seconds'], int) for r in records)):
                row = table['home_summary_age_s']
                row['value'] = max(r['freshness']['age_seconds'] for r in records)
                row['exceeded'] = row['value'] > row['limit']
        except (OSError, ValueError, KeyError, TypeError):
            pass
    delivery, slots = capture_operations(now)
    episodes = cache.setdefault('episodes', {})
    for key, row in table.items():
        ep = episodes.setdefault(key, {'alarms': []})
        ep['alarms'] = [a for a in ep.get('alarms', []) if a >= now - RELAPSE_WINDOW]
        if not row['exceeded']:
            ep.pop('since', None)
            ep.pop('notified', None)
            continue
        ep.setdefault('since', now)
        row['since'] = ep['since']
        if row['alarm'] and not (ep['alarms'] and ep['alarms'][-1] > now - ALARM_EVERY):
            relapse = (f'; relapse: {len(ep["alarms"])} earlier alarm(s) in 14 days - stop patching, have a fresh reviewer from the other'
                       ' provider read every producer of this measure and propose what to delete or merge') if ep['alarms'] else ''
            reason = (f'check: behavior budget exceeded: {key}={row["value"]} {row["unit"]} over limit {row["limit"]}'
                      f' since {time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(ep["since"]))} ({row["family"]}, {row["detail"]});'
                      f' commits in last 24h: {recent_commits()}{relapse}; review the listed task or create a root-cause task without asking the captain;'
                      f' name {key} in its brief; evidence {STATE}/budgets.json; skip: FM_BUDGETS=0, or "alarm": false for'
                      f' {key} in {CONFIG}/budgets.json')
            alarm = STATE / f'budget-{key}.budget-alarm'
            Path(f'{alarm}.tmp').write_text(reason + '\n', encoding='utf-8')
            os.replace(f'{alarm}.tmp', alarm)
            ep['alarms'].append(now)
        last = ep['alarms'][-1] if ep['alarms'] else None
        if last and not ep.get('notified') and now - last >= NOTIFY_AFTER and not delegated(key, last):
            text = f'Presupuesto excedido 2 h sin encargo: {key}={row["value"]} {row["unit"]} (límite {row["limit"]})'[:240]
            rc = subprocess.run([sys.executable, str(ROOT / 'bin/fm-notify.py'), '--home', str(HOME), '--event', 'budget-exceeded',
                                 '--text', text], capture_output=True, timeout=15).returncode
            ep['notified'] = [now, rc]
    hour = time.strftime('%Y-%m-%dT%HZ', time.gmtime(now))
    if cache.get('history_hour') != hour:
        keep = [r for r in rows if r.get('t', 0) >= now - HISTORY_DAYS * 86400]
        keep += [dict(hour=hour, t=now, key=k, value=r['value'], limit=r['limit']) for k, r in table.items()]
        keep += [dict(hour=hour, t=now, key=k, value=v, limit=None) for k, v in counters.items()]
        tmp = Path(f'{hist_path}.tmp{os.getpid()}')
        tmp.write_text(''.join(json.dumps(r, sort_keys=True) + '\n' for r in keep), encoding='utf-8')
        os.replace(tmp, hist_path)
        cache['history_hour'] = hour
    write_json(STATE / 'budgets.json', dict(schema='fm-budgets.v1', generated_epoch=now,
                                            generated=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now)),
                                            measures=table, integration=delivery, test_slots=slots))
    operational_alarm(now, cache, delivery, slots)
    write_json(STATE / '.budgets-cache.json', cache)
    return table


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ''
    now = int(time.time())
    if command == 'limits':
        print(json.dumps(limits(), indent=1, sort_keys=True))
    elif command == 'table':
        print_table(compute(now, load_json(STATE / '.budgets-cache.json', {}), history(STATE / 'budgets-history.jsonl'))[0])
        print_operations(*capture_operations(now))
    elif command == 'check':
        if os.environ.get('FM_BUDGETS', '1') == '0':
            return 0
        print_table(check(now))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
