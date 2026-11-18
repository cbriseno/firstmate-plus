#!/usr/bin/env python3
"""List a task copy's repository skills and instruction files for its launch brief.

Usage: fm-repo-skills.py <task-copy>

Prints a Markdown "# Target repository skills" section naming every skill
found at <task-copy>/.<dir>/skills/<skill>/SKILL.md (the hidden per-tool skill
roots such as .agents, .claude, or .codex), each with its front-matter name,
description, and absolute file path, plus the root instruction files AGENTS.md
and CLAUDE.md that exist. A skill reached through more than one root (for
example a .claude/skills symlink to .agents/skills) is listed once. Prints
nothing when the copy has neither. bin/fm-spawn.sh appends the output to every
ship and scout launch brief, so a worker sees the repository's own skills and
their load triggers whether or not its tool also registers them natively.
"""
import os
import sys

INSTRUCTION_FILES = ("AGENTS.md", "CLAUDE.md")


def front_matter(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return {}
    if not lines or lines[0].strip() != "---":
        return {}
    fields, key, parts = {}, None, []
    for line in lines[1:] + ["---"]:
        top_level = line and not line[0].isspace()
        if line.strip() == "---" or (top_level and ":" in line):
            if key:
                text = " ".join(p.strip() for p in parts if p.strip())
                if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
                    text = text[1:-1]
                fields[key] = text
            if line.strip() == "---":
                break
            key, rest = line.split(":", 1)
            key, rest = key.strip(), rest.strip()
            parts = [] if rest in (">", ">-", ">+", "|", "|-", "|+") else [rest]
        elif key:
            parts.append(line)
    return fields


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: fm-repo-skills.py <task-copy>\n")
        return 2
    copy = os.path.realpath(sys.argv[1])
    skills, seen = [], set()
    for root in sorted(os.listdir(copy)):
        base = os.path.join(copy, root, "skills")
        if not root.startswith(".") or root == ".git" or not os.path.isdir(base):
            continue
        for entry in sorted(os.listdir(base)):
            skill = os.path.join(base, entry, "SKILL.md")
            real = os.path.realpath(skill)
            if not os.path.isfile(skill) or real in seen:
                continue
            seen.add(real)
            fields = front_matter(skill)
            skills.append((fields.get("name") or entry, fields.get("description") or "(no description)", skill))
    instructions = [f for f in INSTRUCTION_FILES if os.path.isfile(os.path.join(copy, f))]
    if not skills and not instructions:
        return 0
    print("# Target repository skills")
    if skills:
        print("This task's repository provides these agent skills; each description states when to use it.")
        print("Before starting, and again whenever the work reaches a new area such as CI, release, sign-in, or deployment, load and follow every skill whose description matches, by name or by reading its file.")
        for name, description, path in skills:
            print(f"- `{name}`: {description}")
            print(f"  File: `{path}`")
    if instructions:
        listed = ", ".join(f"`{os.path.join(copy, f)}`" for f in instructions)
        print(f"Repository instruction files: {listed}; read any your tool did not load automatically, and follow them wherever they do not conflict with this brief's worker role.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
