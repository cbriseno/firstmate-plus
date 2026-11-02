# Primary write guard

This document is the authoritative human-readable contract for the guard that stops a firstmate primary from doing work itself.
`bin/fm-primary-write-policy.mjs` is the single decision owner for each write target.
`bin/fm-primary-write-pretool-check.sh` is the harness transport: it owns primary-home scope, the allowed-path set, the escape hatch, and harness rendering.
`bin/fm-primary-write-grant.sh` owns the captain-approval grants that let one approved operation through.

## Why this exists

[`AGENTS.md`](../AGENTS.md) section 1 makes firstmate a supervisor: it delegates every actionable request to a worker, and its own direct writes stay inside its private operational state.
Before this guard, the only written boundary was hard rule 1, which covers projects, and no mechanism enforced even that.
On 2026-10-29 a primary added a shell alias to the captain's `~/.bash_aliases` and wrote a plugin's user configuration file itself, instead of registering the request and dispatching a worker the captain could watch.
Nothing refused either write, because neither target was a project.

Delegating is also what keeps the primary's context window for supervision; every file the primary edits itself spends that context on implementation.
The guard therefore sits on the tool surface, before the write happens, and its refusal names the dispatch path.

## Purpose and boundary

The guard decides one thing: whether a tool call makes the primary write outside the allowed paths below.
It does not judge whether read-and-think work should have been delegated, which has no tool-shape signal.
It is not a sandbox: its threat model is agent mistakes, the same as the [cd-guard](cd-guard.md) and the [watcher-arm seatbelt](arm-pretool-check.md), not deliberate obfuscation.
A refusal means dispatch a worker; the deny text says so, and routing around it with another tool is a contract violation even where the guard cannot see it.

## Scope

The guard fires only in a genuine primary home, using `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh`, the predicate the [delegation guard](subagent-guard.md) and the turn-end guard share.
A plain firstmate checkout and a marked secondmate home are in scope.
A linked task worktree, which is the shape `bin/fm-spawn.sh` hands every crewmate and scout, is out of scope, so workers are never affected.
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
| `git checkout` and `git switch` on the home's own checkout | The sanctioned worktree-tangle restore in `bootstrap-diagnostics`. |

Commands that only invoke guarded fleet scripts, such as `bin/fm-spawn.sh` or `bin/fm-pr-merge.sh`, are never refused, because the guard judges only the command line's own write shapes and those scripts write in their own processes.
Their redirections are judged like any other, so `bin/fm-brief.sh ... > data/<id>/brief.md` is allowed and the same redirect into a dotfile is not.

`FM_PRIMARY_WRITE_TEMP_DIRS`, a colon-separated list, replaces the temp-directory set for tests and specialized setup.

## Refused write shapes

| Code | Meaning |
| --- | --- |
| `primary-write` | The target is outside every allowed path: the captain's shell, dotfiles, user configuration, installed tools' files, system files, or the firstmate repo's tracked material. |
| `primary-write-project` | The target is inside the projects directory with no live grant for it. |
| `primary-write-grant-record` | The target is a grant record, which only `bin/fm-primary-write-grant.sh` writes. |

File tools are judged by their target path: Claude `Edit`, `MultiEdit`, `Write`, and `NotebookEdit`, and Codex `apply_patch` (every `Add File`, `Update File`, `Delete File`, and `Move to` path).
Shell commands are lexed with the shared classifier in `bin/fm-arm-command-policy.mjs` and judged at these shapes:

- output redirections, including heredocs into a file;
- `tee`, `cp`, `mv` (both sides), `install`, `ln`, `rsync`, `rm`, `rmdir`, `unlink`, `shred`, `touch`, `mkdir`, `truncate`, `chmod`, `chown`, `chgrp`, and `dd of=`;
- in-place editors: `sed -i`, `perl -i`, and `ruby -i`;
- downloads: `curl -o` or `-O` and `wget`;
- mutating `git` subcommands on a repository outside the allowed paths, including `clone` and `init` destinations;
- inline interpreter code (`python -c`, `node -e`, `perl -e`, `ruby -e`, and heredoc stdin) that calls a common write API on a literal path;
- nested programs: subshells, brace groups, command substitutions, `bash -c` and other shell payloads, `eval`, `find -exec` and `-delete`, and `xargs`.

Harness-private files outside the home, such as a harness's own memory directory, are refused like any other outside path, because durable knowledge belongs in the home's `data/` records ([`AGENTS.md`](../AGENTS.md) section 6).
A relative target resolves against the payload's working directory, tracking `cd` inside a subshell.
`~`, `$HOME`, and other variables the hook environment defines are expanded.
A target the guard cannot resolve, such as `"$tmp"` from `mktemp`, is allowed unless its literal prefix already rules out every allowed path, so `~/.config/$NAME` is still refused.

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
The captain's personal environment is therefore never grantable; those changes go to a worker.
The script header owns the exact usage and record format.

## Escape hatch

`FM_ALLOW_PRIMARY_WRITE=1` in the session environment allows every write, and any other value is ignored.
Like `FM_ALLOW_SUBAGENT`, it must be present when the harness launches, so no tool call can enable it for the call that follows.

## Residual limits

The guard covers the common write shapes above and does not claim completeness.
These writes are not refused:

- a script file the primary runs (`bash /tmp/x.sh`, `python3 tool.py`), and any program that writes through its own logic, including editors and package managers such as `npm install -g` or `brew install`;
- inline interpreter code whose target path is computed rather than a literal, or written through an API outside the recognized set;
- a target built from a command substitution (`> "$(echo ~)/.bashrc"`) or a variable assigned earlier in the same command;
- `>|` clobber redirections, `crontab`, `systemctl --user`, and other configuration tools;
- untokenizable shell syntax, which fails open like the cd-guard;
- any harness not wired below, and any future write tool name outside the Claude matcher.

Package installs stay unrefused on purpose: `bootstrap-diagnostics` directs the primary to run firstmate's own printed tool upgrades, and a captain's tool install still goes to a worker under the contract.

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
| Claude | `.claude/settings.json` PreToolUse: the `Bash` group and a `^(Edit\|MultiEdit\|Write\|NotebookEdit)$` group, each passing `--claude` | Wired and live-verified. |
| Codex | `.codex/hooks.json` PreToolUse group matching `^(Bash\|apply_patch)$`, anchored from `pwd -P` like the cd-guard entry | Wired and live-verified; Codex fires PreToolUse for `apply_patch` with the patch in `tool_input.command`. An updated home shows Codex's hook-review dialog once for the new hook ([Codex reference](../.agents/skills/harness-adapters/references/harness/codex.md#hook-trust)). |
| Grok, OpenCode, Pi, pi-signed, omp, Cursor, Kimi | Their shell hook surfaces carry the cd-guard, but their file-edit tool names and this guard's behavior there are unverified | Not wired. |

The two tracked Claude entries do not carry the Grok marker guard, matching the delegation guard's documented exception in [`turnend-guard.md`](turnend-guard.md): Grok has no counterpart registration, so standing down would remove the guard from Grok rather than deduplicate it.
That reach under Grok is incidental, because `--claude` suppresses the stdout object Grok reads.
A Cursor-delivered duplicate of the tracked Claude settings stands down through `bin/fm-hook-host-lib.sh`, so Cursor is not covered.
Wiring another harness means enumerating its file-edit tool names, adding its adapter entry, and repeating the live check below on that harness.

## Live validation record, 2026-10-29

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
