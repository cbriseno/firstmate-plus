# Primary write guard

This document is the authoritative human-readable contract for the guard for primary direct operations and host tasks.
`bin/fm-primary-write-policy.mjs` is the single decision owner for each write target.
`bin/fm-primary-write-pretool-check.sh` is the harness transport: it owns primary-home scope, the allowed-path set, the escape hatch, and harness rendering.
`bin/fm-primary-write-grant.sh` owns the captain-approval grants that let one approved operation through.

## Direct operations and host tasks

`config/primary-direct-ops` accepts `host` (the default when absent) or `off`.
With `host`, the primary performs simple host-level operations directly and delegates project work and substantial engineering.
With `off`, the legacy operational-path carve-outs below remain, but host writes require a worker and host tasks cannot be created or launched.
Invalid configuration fails closed to the legacy policy.

The host allowance covers reading, writing, editing, moving, and deleting host files wherever the operating system permits, subject to the boundaries below.
It never grants access to any registered project clone or its linked worktrees, `projects/`, or shared tracked material in this home's checkout.
Symlink targets are resolved before checking these boundaries.
Existing narrow captain-approved grants remain available.
Without `FM_ALLOW_PRIMARY_WRITE=1`, writes are refused under `/etc`, `/bin`, `/sbin`, `/boot`, `/dev`, `/proc`, `/sys`, `/usr` except `/usr/local`, `/var/lib`, `/var/db`, `/lib`, `/lib64`, `/System`, `/Library`, `/private/etc`, `/private/var` except `/private/var/folders`, and `/Applications/Utilities`.
`/private/tmp` remains allowed.
The operating system already protects system locations from ordinary non-root users; this denylist also protects administrator or root sessions and mistakes.
The primary never uses `sudo`, `doas`, `su`, or other privilege escalation.
Recursive deletes refuse `$HOME` itself, `/`, any entire top-level system directory, globs, substitutions, or any target that cannot resolve exactly from the hook environment.
Secrets must never be printed; the guard rejects recognized reads of `.ssh/`, `.gnupg/`, `.env` files, credential files, private keys, and PEM files through covered read tools and common shell printing commands.

Every allowed host-changing tool call appends a UTC timestamp, tool name, normalized target, and command class to `state/direct-ops.log` for each detected target.
This is a pre-execution authorization audit, not proof that the operation succeeded.
Audit failures do not block the operation, and neither command text nor file contents are logged.

A host task uses `bin/fm-brief.sh <id> --host --path <absolute-or-HOME-relative-path>` with repeatable `--path`, then `bin/fm-spawn.sh <id> --host [--harness <name>]`.
The scaffold records canonical outside paths in its brief and a private path manifest; launch revalidates both, and optional spawn `--path` arguments must match that manifest.
Paths into this checkout, `projects/`, or the linked worktrees of its clones are refused.
The worker starts in a fresh non-repository `data/<id>/work` with a Git discovery ceiling at its task directory, follows the usual status, card, and steering-inbox protocols, and reports its verified result without a delivery mode, branch, or merge.
Teardown validates that exact scratch directory and removes only scratch and task runtime records, leaving authorized outside paths untouched.
Terminal backends use their existing launch path.

## Purpose and boundary

The guard decides one thing: whether a tool call makes the primary write outside the allowed paths below.
It does not judge whether read-and-think work should have been delegated, which has no tool-shape signal.
It is not a sandbox: its threat model is agent mistakes, the same as the [cd-guard](cd-guard.md) and the [watcher-arm seatbelt](arm-pretool-check.md), not deliberate obfuscation.
A refusal means dispatch a worker; the deny text says so, and routing around it with another tool is a contract violation even where the guard cannot see it.

## Scope

The guard fires only in a genuine primary home, using `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh`, the predicate the [delegation guard](subagent-guard.md) and the turn-end guard share.
A plain firstmate checkout and a marked secondmate home are in scope.
A linked task worktree or a non-repository host-task scratch directory is out of scope, so workers are never affected.
A non-firstmate repo is out of scope, and any failure to confirm the home is inert rather than a block.

## Allowed paths

Each carve-out is a firstmate operation the contract keeps legitimate.

| Allowed | Why |
| --- | --- |
| The effective `state/`, `data/`, and `config/` directories, honoring `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, and `FM_CONFIG_OVERRIDE` | Private operational state: status, backlog, briefs, reports, decision records, configuration. |
| `state/`, `data/`, `config/`, and `.lavish/` under both `FM_HOME` and the code root | The code root's private directories during a home migration, and hand-written Lavish review surfaces. |
| The home's gitignored `.env` file and root-level `scratchpad*` paths | Captain-private settings and the gitignored scratch convention ([configuration](configuration.md#operational-home-layout-and-state)). |
| `/tmp`, `/var/tmp`, `$TMPDIR`, and `/dev/null`-style device files | Temporary files such as a `--body-file` or a composed reply. |
| `state/`, `data/`, and `config/` of every local secondmate home registered in `data/secondmates.md` | The main home curates a mate's memory files and charter (secondmate-provisioning, stow). |
| In a secondmate home, its parent channel resolved by `bin/fm-parent-channel-lib.sh` | A mate reports judgement by appending there. |
| A live grant from `bin/fm-primary-write-grant.sh` | Hard rule 1's captain-approved operations; see below. |
| `rm -- <home>/.git/index.lock` when it is a regular empty file older than ten minutes and `pgrep -x git` finds no process | Recover an orphaned index lock; all other `.git` writes retain the ordinary policy. |
| `git checkout` and `git switch` on the home's own checkout | The sanctioned worktree-tangle restore in `bootstrap-diagnostics`. |

Commands that only invoke guarded fleet scripts, such as `bin/fm-spawn.sh` or `bin/fm-pr-merge.sh`, are never refused, because the guard judges only the command line's own write shapes and those scripts write in their own processes.
Their redirections are judged like any other, so `bin/fm-brief.sh ... > data/<id>/brief.md` is allowed and a redirect into a dotfile follows the configured host policy.

`FM_PRIMARY_WRITE_TEMP_DIRS`, a colon-separated list, replaces the temp-directory set for tests and specialized setup.

## Refused write shapes

| Code | Meaning |
| --- | --- |
| `primary-write` | The target is outside permitted paths, unresolved under host policy, or shared checkout material. |
| `primary-write-project` | The target is inside projects or a registered clone worktree, without a live grant. |
| `primary-delete`, `primary-privilege`, `primary-secret` | A host safety rail refused the operation. |
| `primary-write-grant-record` | The target is a grant record, which only `bin/fm-primary-write-grant.sh` writes. |

Write tools are judged by their target path: Claude `Edit`, `MultiEdit`, `Write`, and `NotebookEdit`, and Codex `apply_patch` (every `Add File`, `Update File`, `Delete File`, and `Move to` path).
Shell commands are lexed with the shared classifier in `bin/fm-arm-command-policy.mjs` and judged at these shapes:

- output redirections, including heredocs into a file;
- `tee`, `cp`, `mv` (both sides), `install`, `ln`, `rsync`, `rm`, `rmdir`, `unlink`, `shred`, `touch`, `mkdir`, `truncate`, `chmod`, `chown`, `chgrp`, and `dd of=`;
- in-place editors: `sed -i`, `perl -i`, and `ruby -i`;
- downloads: `curl -o` or `-O` and `wget`;
- mutating `git` subcommands on a repository outside the allowed paths, including `clone` and `init` destinations;
- inline interpreter code (`python -c`, `node -e`, `perl -e`, `ruby -e`, and heredoc stdin) that calls a common write API on a literal path;
- nested programs: subshells, brace groups, command substitutions, `bash -c` and other shell payloads, `eval`, `find -exec` and `-delete`, and `xargs`.

Durable knowledge still follows the ownership rules in [`AGENTS.md`](../AGENTS.md) section 6.
A relative target resolves against the payload's working directory, tracking `cd` inside a subshell.
`~`, `$HOME`, and `$FM_HOME` are expanded; under `off`, other variables defined in the hook environment retain their legacy expansion.
In host-mode shell commands, simple literal absolute or home-relative assignments earlier in the same command, including chains and `export`, can resolve later targets.
Computed assignments and unresolved variables remain refused.
Under `off`, unresolved targets retain the legacy literal-prefix policy; `host` refuses unresolved writes.

## Captain-approved operations: grants

Hard rule 1 keeps one exception for project files: a concrete operation the captain approves in the moment.
Firstmate records that approval before acting:

```sh
bin/fm-primary-write-grant.sh grant projects/<name> --approval "<the captain's words>"
```

A grant names one path, stores the captain's words, lives 30 minutes by default and at most 240, and allows writes only inside that path; revoke it as soon as the operation ends.
Project add, create, and removal intake use the same grant for the clone path ([`project-management`](../.agents/skills/project-management/SKILL.md)).
A grant may also cover an untracked path inside the home's own checkout, or that checkout's repository-local exclude file, for firstmate-owned local material such as a stow-approved local skill.
The script refuses everything else: a path outside the home, a tracked file, the whole home, `.git` internals other than the exclude file, and the whole projects directory.
The captain's personal environment uses the configured host allowance or a host worker rather than project grants.
The script header owns the exact usage and record format.

## Escape hatch

`FM_ALLOW_PRIMARY_WRITE=1` in the session environment overrides the system-location denylist while retaining host-mode safety rails and project protection.
With `off`, it retains the legacy full write override; any other value is ignored.
Like `FM_ALLOW_SUBAGENT`, it must be present when the harness launches, so no tool call can enable it for the call that follows.

## Residual limits

The guard covers the common write shapes above and does not claim completeness.
These writes are not refused:

- a script file the primary runs (`bash /tmp/x.sh`, `python3 tool.py`), and any program that writes through its own logic, including editors and package managers such as `npm install -g` or `brew install`;
- inline interpreter code whose target path is computed rather than a literal, or written through an API outside the recognized set;
- under `off`, a target built from a command substitution or a variable assigned earlier in the same command;
- `>|` clobber redirections, `crontab`, `systemctl --user`, and other configuration tools;
- untokenizable shell syntax, which fails open like the cd-guard;
- any harness not wired below, and any future write tool name outside the Claude matcher.

Package installs stay unrefused on purpose: `bootstrap-diagnostics` directs the primary to run firstmate's own printed tool upgrades, and simple user-home tool installation is permitted by the host contract.

## Transport and output

Processing order is cheapest-first: tool-name filter, a strict-superset shell prefilter, the escape hatch, the primary-home scope, then the Node policy.
The prefilter's command list is coupled to the policy's command classes, and the script header names that coupling.
Empty or malformed stdin, missing `jq` on the stdin path, missing Node, a missing policy, or an invalid policy response all fail open with exit 0 and no output.

The output contract is identical to [`cd-guard.md`](cd-guard.md):

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[<code>] ..."}` to stderr.
- Default mode also writes a `{"decision":"deny","reason":...}` object to stdout, and `--claude` keeps stdout empty because Claude ignores a deny with nonempty stdout.

## Harness wiring

| Harness | Entry | Status |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse: the `Bash` group and a `^(Read\|Edit\|MultiEdit\|Write\|NotebookEdit)$` group, each passing `--claude` | Bash and edit transports live-verified below; the Read route is covered by offline tests. |
| Codex | `.codex/hooks.json` PreToolUse group matching `^(Bash\|apply_patch)$`, anchored from `pwd -P` like the cd-guard entry | Wired and live-verified; Codex fires PreToolUse for `apply_patch` with the patch in `tool_input.command`. An updated home shows Codex's hook-review dialog once for the new hook ([Codex reference](../.agents/skills/harness-adapters/references/harness/codex.md#hook-trust)). |
| Grok, OpenCode, Pi, pi-signed, Cursor, Kimi | Their shell hook surfaces carry the cd-guard, but their file-edit tool names and this guard's behavior there are unverified | Not wired. |

The two tracked Claude entries do not carry the Grok marker guard, matching the delegation guard's documented exception in [`turnend-guard.md`](turnend-guard.md): Grok has no counterpart registration, so standing down would remove the guard from Grok rather than deduplicate it.
That reach under Grok is incidental, because `--claude` suppresses the stdout object Grok reads.
A Cursor-delivered duplicate of the tracked Claude settings stands down through `bin/fm-hook-host-lib.sh`, so Cursor is not covered.
Wiring another harness means enumerating its file-edit tool names, adding its adapter entry, and repeating the live check below on that harness.

## Live validation record, 2026-10-29

This transport record predates the host default; its outside-write refusals describe the `off` policy.

Harness versions:

```text
2.1.312 (Claude Code)
codex-cli 0.164.0
```

Each harness ran against a scratch primary-shaped home: a plain git repo with `AGENTS.md`, `state/`, `data/`, a copy of `bin/`, and only the tracked write-guard hook entries.
Denied writes targeted sentinel files in a scratch directory outside that home, never a real dotfile.
The launch commands were:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
```

Each prompt asked for five separate tool calls: a file-tool write outside the home (`Write` for Claude, `apply_patch` for Codex), `echo alias x=y >> <outside>/sentinel`, `echo ok > state/allowed.txt`, a file-tool write into `data/`, and `ls state data`.

- Claude reported calls 1 and 2 blocked with `[primary-write]` and calls 3 to 5 run.
- Codex logged `PreToolUse Blocked` with the `[primary-write]` deny for the `apply_patch` and the shell append, then `PreToolUse Completed` for the other three calls.
- Neither outside sentinel existed afterwards, and all four allowed files did.

The negative scope case ran the same two outside writes on each harness from a linked task worktree of this repository carrying the tracked hooks.
Both harnesses ran all four writes and every sentinel existed, so the guard is inert for workers.

## Automated validation

`tests/fm-primary-write-pretool-check.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
It covers every refused shape above, every carve-out, the grant lifecycle and its refusals, inertness in a linked task worktree and a non-firstmate repo, enforcement in a marked secondmate home, the escape hatch, the Claude, Codex, and `apply_patch` stdin transports, the Cursor stand-down, fail-open transport, the policy CLI contract, and the tracked Claude and Codex registrations executed the way each harness runs them.

Run:

```sh
node --check bin/fm-primary-write-policy.mjs
bin/fm-lint.sh
tests/fm-primary-write-pretool-check.test.sh
```
