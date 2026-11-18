# Firstmate repository

This file is for any agent working on Firstmate's own code; it carries no role.
The supervisor contract a Firstmate home runs on is [`SUPERVISOR.md`](SUPERVISOR.md); a home loads it through its untracked `CLAUDE.local.md` and `AGENTS.override.md`, written by `bin/fm-home-instructions.sh`.
Task workers load [`worker/AGENTS.md`](worker/AGENTS.md) at launch instead, so a task copy of this repository never makes its agent a first mate.

When changing Firstmate:

- Follow [`CONTRIBUTING.md`](CONTRIBUTING.md) and load `firstmate-coding-guidelines` before editing shared tracked material.
- Keep each rule in the one file its audience loads natively: the operator's global instruction file for every agent, `SUPERVISOR.md` for homes, `worker/AGENTS.md` for task workers, a project's own `AGENTS.md` for that project, and code for anything a program must enforce; never copy a rule into generated instructions.
- Check shell scripts with `bin/fm-lint.sh [paths...]`, never raw `shellcheck`; its header owns host serialization and memory protection.
- Verify any change to what an agent loads separately for Claude and Codex, and for primaries and workers, with a real minimal session.
- When syncing from upstream, keep each local fix that is still needed; retire or adapt one only after proving equivalence and with a way back.
