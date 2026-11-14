#!/usr/bin/env python3
"""Durable launch records: harness, model, effort, started_at, session (transcript path).

resume-id STATE ID resolves a parked launch to its native UUID or explains absence.
start STATE ID appends metadata with session=null; bind STATE ID GEN reads a
Claude UserPromptSubmit payload on stdin and fills its transcript_path.
Codex calls bind() with its already validated rollout path. Unknown harnesses
keep null. sessions_file in task metadata selects data/<id>/sessions.jsonl,
which teardown leaves intact. Repeated callbacks do not add duplicate sessions.
New launch rows also carry project (the recorded path, null for host), launch
(spawn generation), status (active or archived), and reason (null when bound).
start archives earlier active launches of this task; exit alone does not archive
its resumable chat. Historical rows are retained unchanged, never guessed active.
list HOME [--task ID | --project PATH] [--status active|archived|unknown] reads
sessions.jsonl directly, including concurrent tasks in one project. Legacy rows
read as project=null/status=unknown and an absent path as legacy-unrecorded.
Binding attempts emit anonymized session.link events through fm-diag.sh.
backfill HOME [CLAUDE_PROJECTS CODEX_SESSIONS] prints a read-only local review.
It reads the first 60 transcript records, task session starts, state/*.meta and
creation receipts. Exact home inbox or recorded cwd/task-id matches are explicit;
a start within 300 seconds is only inferred (multiple candidates are ambiguous).
No timestamp-only attribution is applied automatically. Missing fields stay null.

Manual recovery (Python 3.9/stdlib, Linux/macOS, no services or new dependencies):
  1. backfill HOME [roots] > review.json             # no task writes
  2. Edit each candidate decision to accept/reject. For inferred/ambiguous joins,
     add corroboration naming independent evidence checked in local originals
     (worktree, dispatch/brief, task content); time proximity alone is not enough.
  3. backfill HOME [roots] --apply review.json --backup before.json
     Applies only accepted candidates still found in originals, saves the exact
     previous sessions/usage bytes (including absence), refreshes usage and rereads.
     Repeating unchanged accepted rows is a no-op. Stop active task writers first.
  4. backfill HOME --restore before.json            # restores both old files
Use --tasks ID [ID ...] to restrict the diagnostic to the affected task ids.
Review/output contains local paths and model/effort, never transcript text.
Keep review and backup local; return only task counts and missing-reason counts.
Cost is an estimate at list price, not billing. Unique sessions differ from
per-model session counters; missing usage/price is unknown, never zero spend.
"""

import argparse
import base64
import datetime as dt
import json
import subprocess
from pathlib import Path
import re
import sys
import uuid


def metadata(state, task):
    return dict(line.split("=", 1) for line in
                (Path(state) / (task + ".meta")).read_text().splitlines() if "=" in line)


def save(path, row, start=False):
    path = Path(path)
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    if not start:
        for old in reversed(rows):
            if old == dict(row, session=None):
                old["session"] = row["session"]
                break
        else:
            if any(old["session"] == row["session"] for old in rows):
                return
            rows.append(row)
    else:
        rows.append(row)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(old) + "\n" for old in rows))


def diagnostic(task, harness, result, reason):
    try:
        subprocess.run(["bash", str(Path(__file__).with_name("fm-diag.sh")), "emit",
                        "session.link", "task=" + task, "harness=" + harness,
                        "result=" + result, "reason=" + reason],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def record(state, task, session=None, gen=None, reason=None):
    meta = metadata(state, task)
    if "sessions_file" not in meta:
        diagnostic(task, meta.get("harness", "unknown"), "unavailable", "no-sessions-file")
        return
    if gen is not None and meta.get("busy_gen") != gen:
        diagnostic(task, meta.get("harness", "unknown"), "ignored", "stale-generation")
        return
    path = Path(meta["sessions_file"])
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    launch = meta.get("spawn_gen") or meta.get("busy_gen")
    identity = dict(harness=meta["harness"], model=meta["model"], effort=meta["effort"],
                    started_at=meta["spawned_at"])
    current = next((row for row in reversed(rows)
                    if all(row.get(k) == v for k, v in identity.items())
                    and row.get("launch", launch) == launch), None)
    starting = gen is None and reason is None and session is None
    if starting:
        for row in rows:
            if row.get("status") == "active":
                row["status"] = "archived"
        current = None
    if current is None:
        current = dict(identity, session=None, project=None if meta.get("kind") == "host" else meta.get("project") or None,
                       status="active", launch=launch, reason="awaiting-transcript")
        rows.append(current)
    if session:
        if current.get("session") == session:
            return
        current.update(session=session, reason=None)
    elif reason:
        if current.get("session") or current.get("reason") == reason:
            return
        current["reason"] = reason
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    diagnostic(task, meta["harness"], "bound" if session else "pending", current["reason"] or "transcript-linked")


def bind(state, task, gen, session):
    record(state, task, session, gen, None if session else "missing-transcript-path")


def unbound(state, task, gen, reason):
    record(state, task, gen=gen, reason=reason)


def list_sessions(home, task=None, project=None, status=None):
    paths = [Path(home) / "data" / task / "sessions.jsonl"] if task else sorted((Path(home) / "data").glob("*/sessions.jsonl"))
    for path in paths:
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            row = json.loads(line)
            row.setdefault("project", None)
            row.setdefault("status", "unknown")
            row.setdefault("reason", None if row.get("session") else "legacy-unrecorded")
            if (project is None or row["project"] == project) and (status is None or row["status"] == status):
                print(json.dumps(dict(row, task=path.parent.name)))


def resume_id(state, task):
    """Resolve only the saved launch's native identity, never the cwd's last chat."""
    parked = Path(state) / (task + ".parked")
    meta = dict(line.split("=", 1) for line in parked.read_text().splitlines() if "=" in line)
    try:
        rows = [json.loads(line) for line in Path(meta["sessions_file"]).read_text().splitlines()]
        row = next(row for row in reversed(rows) if row.get("launch") == meta.get("spawn_gen")
                   and row.get("harness") == meta["harness"] and row.get("session"))
        path = Path(row["session"])
        with path.open() as transcript:
            for _, line in zip(range(60), transcript):
                entry = json.loads(line)
                identity = (entry.get("payload", {}).get("id") if entry.get("type") == "session_meta"
                            else entry.get("sessionId") if meta["harness"] == "claude" else None)
                if identity:
                    print(str(uuid.UUID(identity)))
                    return
    except (OSError, KeyError, ValueError, StopIteration):
        pass
    raise SystemExit("saved launch has no readable native session identity")


def instant(value):
    try:
        if isinstance(value, (float, int)) or str(value).isdigit():
            return float(value)
        stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return stamp.timestamp() if stamp.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


def task_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value):
        raise ValueError("invalid task id")
    return value


def session_rows(folder):
    path = folder / "sessions.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []
    if any(not isinstance(r, dict) or r.get("harness") not in ("codex", "claude")
           or not isinstance(r.get("session"), (str, type(None))) for r in rows):
        raise ValueError("invalid session records")
    return rows


def diagnose(home, claude, codex, selected=None):
    from fm_delivery import task_creation
    from fm_task_usage import calculate
    contract = re.compile(r"Your steering inbox is `([^`]+)/state/([A-Za-z0-9._-]+)\.inbox`; this exact path belongs to your current task")
    tasks = set(selected or [p.name for p in (home / "data").glob("*") if p.is_dir() and not p.is_symlink()])
    tasks.update([] if selected else [p.stem for p in (home / "state").glob("*.meta")])
    info, transcripts, errors = {}, [], []
    for task in sorted(tasks):
        task_id(task)
        folder = home / "data" / task
        try:
            starts = session_rows(folder)
            meta = metadata(home / "state", task) if (home / "state" / (task + ".meta")).exists() else {}
            creation = task_creation(home / "data", dict(id=task))
            anchors = [("session-start", s.get("started_at")) for s in starts]
            anchors += [("recorded-start", meta.get("spawned_at")), ("creation-receipt", (creation or {}).get("value"))]
            info[task] = dict(starts=starts, meta=meta, anchors=[(k, instant(v)) for k, v in anchors if instant(v) is not None])
        except (OSError, ValueError, TypeError, AttributeError) as exc:
            errors.append(dict(task=task, reason="unreadable-task-record", error=type(exc).__name__))
    for harness, root, paths in (("claude", Path(claude), Path(claude).glob("*/*.jsonl")),
                                  ("codex", Path(codex), Path(codex).rglob("rollout-*.jsonl"))):
        if not root.is_dir():
            errors.append(dict(harness=harness, reason="missing-transcript-root"))
        for path in sorted(paths):
            try:
                with path.open(encoding="utf-8", errors="replace") as handle:
                    rows = []
                    for _, line in zip(range(60), handle):
                        try:
                            row = json.loads(line)
                            if isinstance(row, dict):
                                rows.append(row)
                        except ValueError:
                            continue
            except OSError:
                errors.append(dict(harness=harness, reason="unreadable-transcript", session=str(path)))
                continue
            matches = set(contract.findall("".join(json.dumps(r, ensure_ascii=False) for r in rows)))
            own = {t for h, t in matches if h == str(home)}
            # A contract for another task/home contradicts a temporal guess.
            if matches and (len(matches) != 1 or not own):
                continue
            cwd = next((r.get("cwd") or (r.get("payload") or {}).get("cwd") for r in rows
                        if r.get("cwd") or (r.get("payload") or {}).get("cwd")), None)
            explicit = own or {t for t, v in info.items() if cwd and
                (cwd == v["meta"].get("worktree") or t in Path(cwd).parts)}
            if own and not selected:
                for task in own:
                    info.setdefault(task, dict(starts=[], meta={}, anchors=[]))
            model = effort = None
            for row in rows:
                params = (row.get("params") if harness == "claude" else row.get("payload")) or {}
                if row.get("type") in ("api-request", "turn_context"):
                    model = model or params.get("model")
                    effort = effort or params.get("effort") or params.get("reasoning_effort") or (params.get("output_config") or {}).get("effort")
                if row.get("type") == "assistant":
                    model = model or (row.get("message") or {}).get("model")
            session = dict(harness=harness, model=model, effort=effort,
                started_at=next((r["timestamp"] for r in rows if r.get("timestamp")), None), session=str(path.resolve()))
            transcripts.append((session, explicit, "worker-contract" if own else "cwd-task-id"))
    results = []
    for task, value in info.items():
        candidates = []
        for session, explicit, method in transcripts:
            evidence = []
            if explicit:
                if task not in explicit or len(explicit) != 1:
                    continue
                confidence = "explicit"
                evidence = [method]
            else:
                stamp = instant(session["started_at"])
                evidence = [k for k, v in value["anchors"] if stamp is not None and abs(v - stamp) <= 300]
                if not evidence:
                    continue
                confidence = "inferred"
            candidates.append(dict(session=session, confidence=confidence, evidence=evidence,
                                   decision="pending", corroboration="",
                missing_fields=[k for k in ("model", "effort", "started_at") if session[k] is None],
                proposed_usage=calculate(home / "data" / task, [session])))
        inferred = [c for c in candidates if c["confidence"] == "inferred"]
        if len(inferred) > 1:
            for candidate in inferred:
                candidate["confidence"] = "ambiguous"
        reason = None if candidates else "no-nearby-transcript" if value["anchors"] else "no-recorded-anchor-or-explicit-link"
        # Preview is local and read-only. Unaccepted candidates are not charged.
        usage = calculate(home / "data" / task, value["starts"])
        results.append(dict(task_id=task, confidence="explicit" if any(c["confidence"] == "explicit" for c in candidates)
            else "ambiguous" if len(inferred) > 1 else "inferred" if inferred else "unknown",
            missing_reason=reason, candidates=candidates, current_usage=usage))
    return dict(home=str(home), basis="estimate at list price, not a bill", tasks=results, errors=errors)


def recover(home, review, backup, live):
    from fm_task_usage import refresh, read_usage
    if review.get("home") != str(home):
        raise ValueError("review belongs to another home")
    current = {t["task_id"]: t for t in live["tasks"]}
    changes, before, owners = {}, {}, {}
    for task in review["tasks"]:
        name = task_id(task["task_id"])
        folder = home / "data" / name
        rows = session_rows(folder)
        changed = False
        for candidate in task["candidates"]:
            if candidate.get("decision") != "accept":
                continue
            matching = next((c for c in current.get(name, {}).get("candidates", [])
                if c["session"] == candidate["session"]), None)
            if matching is None:
                raise ValueError("accepted candidate is no longer found: " + name)
            if matching["confidence"] != "explicit" and not candidate.get("corroboration", "").strip():
                raise ValueError("independent corroboration required: " + name)
            row = dict(matching["session"], recovery=dict(confidence=matching["confidence"],
                evidence=matching["evidence"], corroboration=candidate.get("corroboration", "")))
            owner = owners.setdefault(row["session"], name)
            if owner != name:
                raise ValueError("same transcript accepted for multiple tasks")
            if any(r.get("session") == row["session"] for r in rows):
                continue
            stamp = instant(row["started_at"])
            placeholders = [r for r in rows if r.get("session") is None and r.get("harness") == row["harness"]
                and stamp is not None and instant(r.get("started_at")) is not None
                and abs(instant(r["started_at"]) - stamp) <= 300]
            if len(placeholders) == 1:
                placeholder = placeholders[0]
                rows.remove(placeholder)
                row = dict(placeholder, session=row["session"], reason=None,
                    model=row.get("model") or placeholder.get("model"),
                    effort=row.get("effort") or placeholder.get("effort"), recovery=row["recovery"])
            rows.append(row)
            changed = True
        if changed:
            changes[name] = rows
            before[name] = {file: base64.b64encode((folder / file).read_bytes()).decode("ascii")
                if (folder / file).exists() else None for file in ("sessions.jsonl", "usage.json")}
    if not changes:
        return dict(applied=[], usage={})
    # The backup is the required manual 'conserve the before' step, before writes.
    with Path(backup).open("x") as stream:
        json.dump(dict(home=str(home), tasks=before), stream)
    for name, rows in changes.items():
        folder = home / "data" / name
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "sessions.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        # Recompute while retaining P08's pinned price snapshot and provenance.
        refresh(folder, force=True)
    return dict(applied=list(changes), backup=str(backup),
                usage={name: read_usage(home / "data" / name / "usage.json") for name in changes})


def restore(home, backup):
    from fm_delivery import fleet_event
    from fm_task_usage import read_usage
    value = json.loads(Path(backup).read_text())
    if value.get("home") != str(home):
        raise ValueError("backup belongs to another home")
    for name, files in value["tasks"].items():
        folder = home / "data" / task_id(name)
        for file in ("sessions.jsonl", "usage.json"):
            if files[file] is None:
                (folder / file).unlink(missing_ok=True)
            else:
                (folder / file).write_bytes(base64.b64decode(files[file]))
        fleet_event(home, "task.usage", name, read_usage(folder / "usage.json"))
    return dict(restored=list(value["tasks"]))


def backfill_cli(args):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("home", type=Path)
    parser.add_argument("roots", nargs="*")
    parser.add_argument("--tasks", nargs="+")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--apply", type=Path)
    action.add_argument("--restore", type=Path)
    parser.add_argument("--backup", type=Path)
    opts = parser.parse_args(args)
    home = opts.home.resolve()
    roots = opts.roots or [str(Path.home() / ".claude/projects"), str(Path.home() / ".codex/sessions")]
    if len(roots) != 2 or (opts.apply and not opts.backup):
        parser.error("provide both transcript roots; --apply requires --backup")
    if opts.restore:
        result = restore(home, opts.restore)
    else:
        review = json.loads(opts.apply.read_text()) if opts.apply else None
        selected = [t["task_id"] for t in review["tasks"]] if review else opts.tasks
        result = diagnose(home, *roots, selected)
        if review:
            result = recover(home, review, opts.backup, result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    if sys.argv[1:] in (["--help"], ["-h"]):
        print(__doc__)
    elif sys.argv[1:2] == ["list"]:
        parser = argparse.ArgumentParser(description="Read task/project sessions without changing historical evidence")
        parser.add_argument("home")
        group = parser.add_mutually_exclusive_group()
        group.add_argument("--task")
        group.add_argument("--project")
        parser.add_argument("--status", choices=("active", "archived", "unknown"))
        list_sessions(**vars(parser.parse_args(sys.argv[2:])))
    elif sys.argv[1:2] == ["backfill"]:
        backfill_cli(sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "resume-id":
        resume_id(*sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "start":
        record(*sys.argv[2:])
    elif len(sys.argv) == 5 and sys.argv[1] == "bind":
        bind(*sys.argv[2:], json.load(sys.stdin).get("transcript_path"))
    else:
        raise SystemExit(__doc__)
