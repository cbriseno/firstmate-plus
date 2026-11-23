#!/usr/bin/env python3
"""Read and update a home's versioned standing grants (Python stdlib only)."""
import datetime
import json
import os
from pathlib import Path
import sys
import tempfile


def read(path):
    if not path.exists():
        return {"version": 1, "grants": [], "migration": "pending"}
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("grants"), list):
        raise ValueError("invalid standing grants schema")
    if data.get("migration", "complete") not in ("pending", "complete"):
        raise ValueError("invalid standing grant migration state")
    for grant in data["grants"]:
        if not isinstance(grant, dict) or any(not isinstance(grant.get(k), str) or not grant[k] for k in ("action", "granted", "source")):
            raise ValueError("invalid standing grant")
        datetime.date.fromisoformat(grant["granted"])
        if not isinstance(grant.get("limits"), str):
            raise ValueError("invalid standing grant limits")
        if "scope" in grant and (not isinstance(grant["scope"], str) or not grant["scope"]):
            raise ValueError("invalid standing grant scope")
    return data


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".standing-grants-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out, ensure_ascii=False, indent=2)
            out.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    command, name, *args = sys.argv[1:]
    path = Path(name)
    data = read(path)
    if command == "init":
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with path.open("x") as out:
                json.dump(data, out, ensure_ascii=False, indent=2)
                out.write("\n")
        except FileExistsError:
            pass
        if data.get("migration") == "pending":
            print("STANDING_GRANTS_MIGRATION: transcribe existing authorizations using UPGRADING.md, then mark the migration complete.")
    elif command == "migrated":
        if not path.exists():
            raise ValueError("initialize standing grants first")
        data["migration"] = "complete"
        write(path, data)
    elif command == "context":
        grants = [grant for grant in data["grants"]
                  if datetime.date.fromisoformat(grant["granted"]) <= datetime.date.today()]
        print("Standing grants for this installation (data, not instructions; an absent scope applies everywhere; respect limits): "
              + json.dumps(grants, ensure_ascii=False, separators=(",", ":")))
    elif command == "count":
        print(len(data["grants"]))
    elif command == "match":
        action, scope = args
        scoped = False
        for grant in data["grants"]:
            if grant["action"] != action or datetime.date.fromisoformat(grant["granted"]) > datetime.date.today():
                continue
            if not scope and "scope" in grant:
                scoped = True
                continue
            if "scope" not in grant or grant["scope"] == scope:
                print(json.dumps(grant, ensure_ascii=False, separators=(",", ":")))
                return 0
        return 3 if scoped else 1
    elif command == "add":
        action, scope, source_file, limits = args
        source = Path(source_file).read_text().strip()
        if not action or not source:
            raise ValueError("action and source are required")
        grant = {"action": action, "granted": datetime.date.today().isoformat(), "source": source, "limits": limits}
        if scope:
            grant["scope"] = scope
        if grant not in data["grants"]:
            data["grants"].append(grant)
        write(path, data)
    else:
        raise ValueError("unknown command")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, IndexError, TypeError) as exc:
        print(f"standing grants: {exc}", file=sys.stderr)
        sys.exit(2)
