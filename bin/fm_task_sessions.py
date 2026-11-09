#!/usr/bin/env python3
"""Durable launch records: harness, model, effort, started_at, session (transcript path).

start STATE ID appends metadata with session=null; bind STATE ID GEN reads a
Claude UserPromptSubmit payload on stdin and fills its transcript_path.
Codex calls bind() with its already validated rollout path. Unknown harnesses
keep null. sessions_file in task metadata selects data/<id>/sessions.jsonl,
which teardown leaves intact. Repeated callbacks do not add duplicate sessions.
backfill HOME [CLAUDE_PROJECTS CODEX_SESSIONS] is an explicit, repeatable one-off
scan of the first 60 transcript lines for the exact home-scoped worker contract.
Missing historical model/effort stays null. No pricing or usage calculation.
"""

import json
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


def record(state, task, session=None, gen=None):
    meta = metadata(state, task)
    if "sessions_file" not in meta or (gen is not None and meta.get("busy_gen") != gen):
        return
    save(meta["sessions_file"], dict(harness=meta["harness"], model=meta["model"],
         effort=meta["effort"], started_at=meta["spawned_at"], session=session), start=session is None)


def bind(state, task, gen, session):
    if session:
        record(state, task, session, gen)


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
    elif len(sys.argv) in (3, 5) and sys.argv[1] == "backfill":
        roots = sys.argv[3:] or [str(Path.home() / ".claude/projects"), str(Path.home() / ".codex/sessions")]
        backfill(sys.argv[2], *roots)
    elif len(sys.argv) == 4 and sys.argv[1] == "start":
        record(*sys.argv[2:])
    elif len(sys.argv) == 5 and sys.argv[1] == "bind":
        bind(*sys.argv[2:], json.load(sys.stdin).get("transcript_path"))
    else:
        raise SystemExit(__doc__)
