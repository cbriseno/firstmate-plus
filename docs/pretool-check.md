# Single PreToolUse review

`bin/fm-pretool-check.sh` is the one PreToolUse hook Claude and Codex run for Bash, `apply_patch` and the file tools.
It replaces three separate hooks per action: the [watcher-arm seatbelt](arm-pretool-check.md), the [cd-guard](cd-guard.md) and the [primary write guard](primary-write-guard.md).
Those three scripts and their classifiers are unchanged and remain the sole owners of every decision and of the deny output; this entry only decides which of them an action can reach.

## Why

Every worker action paid for three hooks, each starting a shell and most starting `jq`, `git` and Node, about 0.9 s p50 per action on a loaded host and about 1,000 actions per hour.
Almost all of those actions touch nothing protected.
The measured per-hook `hook.run` p50 before this change was 465 ms (arm), 341 ms (cd) and 555 ms (write) for workers.

## Flow

1. Read the payload once with shell builtins.
2. Decode `tool_name` and, for Bash, `command` with the shell only. A payload with a unicode escape, an unknown shape or more than 64 KiB is never skipped: it runs every seatbelt that applies to its tool, exactly as the three hooks did.
3. Decide the home scope without starting git: a plain `.git` file naming a `/worktrees/` gitdir, with no `.fm-secondmate-home` marker, is a linked task worktree, where the cd and write seatbelts are inert by their own contract. The arm seatbelt has no home scope.
4. Apply the strict-superset prefilters in `bin/fm-pretool-prefilter-lib.sh` (the same ones the three scripts use, now shared) and run only the seatbelts whose prefilter matches, in the order arm, cd, write.
5. The first seatbelt that denies (exit 2) ends the hook with its own stderr and stdout unchanged.

| Action | Before | Now |
| --- | --- | --- |
| Worker, `ls`, any file tool | 3 hooks | 1 hook, no child process |
| Worker, command naming the watcher | 3 hooks | arm seatbelt only |
| Primary, command with no `cd`, redirect or write-shaped word | 3 hooks | 1 hook, no child process |
| Primary, `cd x` | 3 hooks | cd seatbelt |
| Primary, file tool | 3 hooks | write seatbelt |

## Diagnostics

The entry records one `hook.run` named `pretool` per action (`bin/fm-diag.sh`). The seatbelts it runs record nothing, so the entry's time covers them.
The acceptance measure is the `pretool` p50 in `hook.run`, taken per role.

## Registration

`.claude/settings.json` registers it once for `Bash` and once for the file tools, with `--claude`.
`.codex/hooks.json` registers it once for `^(Bash|apply_patch)$` through the same anchored wrapper the three Codex hooks used.
Grok, Cursor, OpenCode and Pi keep calling the individual scripts, which still work on their own.

## Validation

`tests/fm-pretool-check.test.sh` proves which seatbelts each action reaches (stub seatbelts), deny pass-through, the single diagnostic record, one real end-to-end deny per seatbelt kind, and the registrations.
It uses only Bash 3.2 constructs and no GNU tools, so it behaves the same on macOS.
