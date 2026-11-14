#!/usr/bin/env python3
"""Durable launch records: harness, model, effort, started_at, session (transcript path).

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
backfill HOME [CLAUDE_PROJECTS CODEX_SESSIONS] is an explicit, repeatable one-off
scan of the first 60 transcript lines for the exact home-scoped worker contract.
Missing historical model/effort stays null. No pricing or usage calculation.
"""

import argparse
import json
import subprocess
from pathlib import Path
import re
import sys


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


def backfill(home, claude, codex):
    home = Path(home).resolve()
    contract = re.compile(r"Your steering inbox is `" + re.escape(str(home / "state")) +
                          r"/([A-Za-z0-9._-]+)\.inbox`; this exact path belongs to your current task")
    for harness, paths in (("claude", Path(claude).glob("*/*.jsonl")),
                           ("codex", Path(codex).rglob("rollout-*.jsonl"))):
        for path in paths:
            rows = []
            with path.open(encoding="utf-8", errors="replace") as handle:
                for _ in range(60):
                    try:
                        rows.append(json.loads(handle.readline()))
                    except ValueError:
                        continue
            matches = contract.findall("".join(json.dumps(row, ensure_ascii=False) for row in rows))
            if len(set(matches)) != 1:
                continue
            model = effort = None
            for row in rows:
                params = row.get("params", {}) if harness == "claude" else row.get("payload", {})
                if row.get("type") in ("api-request", "turn_context"):
                    model = model or params.get("model")
                    effort = effort or params.get("effort") or params.get("output_config", {}).get("effort")
                if row.get("type") == "assistant":
                    model = model or row.get("message", {}).get("model")
            save(home / "data" / matches[0] / "sessions.jsonl", dict(harness=harness,
                 model=model, effort=effort, started_at=next((r["timestamp"] for r in rows if r.get("timestamp")), None), session=str(path.resolve())))


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
    elif len(sys.argv) in (3, 5) and sys.argv[1] == "backfill":
        roots = sys.argv[3:] or [str(Path.home() / ".claude/projects"), str(Path.home() / ".codex/sessions")]
        backfill(sys.argv[2], *roots)
    elif len(sys.argv) == 4 and sys.argv[1] == "start":
        record(*sys.argv[2:])
    elif len(sys.argv) == 5 and sys.argv[1] == "bind":
        bind(*sys.argv[2:], json.load(sys.stdin).get("transcript_path"))
    else:
        raise SystemExit(__doc__)
