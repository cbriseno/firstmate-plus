# Firstmate Plus

Firstmate Plus coordinates coding agents, isolated task branches, durable work records, and explicit delivery decisions.
It is an independent experimental derivative of [Kun Chen's Firstmate](https://github.com/kunchenguid/firstmate), with the original MIT license and attribution preserved in [LICENSE](LICENSE).
It is intended for operators who can review agent permissions and maintain their own CLI toolchain.

This distribution retains the work API, task hierarchy and dependencies, progress checkpoints, captain decision records, and explicit session-lock release endpoints from the customized source line.
Distribution-specific changes include English-default work-control copy with an optional Spanish locale, a generic notification argv interface, and offline standalone and pairwise acceptance scenarios.
Work-control messages default to English and support a per-installation Spanish locale.
The generic event notification command is disabled unless configured.
Existing away-mode fault alarms retain their separate [alarm configuration](docs/wedge-alarm.md).
The optional `firstmate-extensions` package owns context-relay automation; this repository does not itself implement automatic session replacement.
Firstmate works without that package or a web dashboard.
No acceptance of a live model session or terminal handoff is implied by the offline tests below.

## Install

Use Linux with GNU coreutils, or consult [platform setup](docs/platforms.md) for macOS and WSL2 limitations.
Windows requires WSL2.
Install dependencies through their upstream distributions before running the doctor.
The offline acceptance environment used Python 3.11.2, Node 22.23.4, Git 2.39.5, Bash 5.2.15, and tmux 3.3a.
The source supports Python 3.9+ and Bash 3.2+; older combinations were not accepted in this distribution test.
Use Node 22 LTS or newer and Git 2.39 or newer for this distribution.

Required tools are Bash, Git, Python, Node, Perl, jq, POSIX process utilities, GNU coreutils on Linux, GitHub CLI, `gh-axi`, `tasks-axi`, `quota-axi`, and `chrome-devtools-axi`.
The reference terminal backend needs tmux and a `treehouse` version with durable leases.
Use `tasks-axi` 0.2.6+, `quota-axi` 0.1.51+, and `gh-axi` 0.1.29+; bootstrap performs the detailed compatibility probes.
Choose and authenticate a supported agent CLI separately, such as Codex or Claude Code.
The doctor also reports the `no-mistakes` command used by delivery modes that select that pipeline.
The first-project example below selects local delivery.
Herdr is an optional alternative backend, with its own [capability requirements](docs/herdr-backend.md); it is not required for the tmux route.
The full toolchain and backend-specific dependencies are maintained in [configuration](docs/configuration.md).
No package manager command or automatic dependency download is hidden in these steps.

Set `FIRSTMATE_REPOSITORY` to the repository URL or local staging repository supplied by your distributor.
A public release URL is intentionally not assumed.
Run the clone command from a directory where `firstmate` does not already exist:

```sh
git clone "$FIRSTMATE_REPOSITORY" firstmate
```

From the cloned root, verify the prerequisites:

```sh
bash bin/fm-doctor.sh --backend tmux
```

A zero exit checks local command availability and Unix capabilities.
It does not prove authentication, tool-version compatibility, a working agent session, or live backend operation.
Read every missing prerequisite and install it before starting a supervisor.

## First local project

These commands create an empty installation-local example and register its safe local delivery posture.
Run them only in a fresh clone, before a supervisor has created private records.
Set `PUBLIC_GIT_NAME` and `PUBLIC_GIT_EMAIL` to your own public commit identity before running the block; the identity is passed per Git invocation and is not saved in Git configuration:

```sh
mkdir -p config data projects/example
git init -q -b main projects/example
git -C projects/example -c user.name="${PUBLIC_GIT_NAME:?Set PUBLIC_GIT_NAME}" -c user.email="${PUBLIC_GIT_EMAIL:?Set PUBLIC_GIT_EMAIL}" commit --quiet --allow-empty -m "Initialize example project"
printf '## In flight\n\n## Queued\n\n## Done\n' > data/backlog.md
printf '%s\n' '- example [local-only] - Local example project' > data/projects.md
FM_HOME="$PWD" bash bin/fm-project-mode.sh example
```

The final command must report `local-only off`.
This checks project discovery and delivery-mode resolution, not a dispatched coding task.
To begin actual work, open your authenticated agent CLI in the clone, review its native trust prompts, and ask it to add your real project under the [project intake procedure](.agents/skills/project-management/SKILL.md).
Keep generated `data`, `state`, `config`, and `projects` private.
A session-start digest, working backend, agent authentication, and explicit task authorization are required before real dispatch.
The extension is absent and disabled in the standalone path; no extension hook is installed here.
See [extension bindings](docs/extension-bindings.md) for the distinct process-event plugin API.

## Language and notification commands

English is the default for work-control responses and progress examples.
To select Spanish for this installation:

```sh
mkdir -p config
printf '%s\n' es > config/language
```

`FM_LANGUAGE=en` overrides that file for one process.
Unknown language values fall back to English.
This translates fixed control copy, not task content, wire keys, or every third-party CLI message.
See [notification commands](docs/notification-command.md) for the optional argv interface and its limits.

## Local tests

Development lint requires ShellCheck 0.11.0 and actionlint 1.7.12.
The local `--fast` lint disables extended shell dataflow analysis.
Workflow YAML lint is local analysis; it does not execute hosted workflows.
Run from the cloned root:

```sh
FM_LIVE=0 bash bin/fm-test-run.sh --check-coverage
FM_LIVE=0 bash bin/fm-test-run.sh tests/fm-notification-command.test.sh
FM_LIVE=0 bash bin/fm-test-run.sh --all --jobs 1
FM_LIVE=0 bash bin/fm-lint.sh --fast
```

`--all --jobs 1` runs stateful suites serially.
The standalone and two pairwise clean-room scenarios have offline acceptance for their documented scope.
The complete regression run remains pending acceptance; this distribution must not be described as fully validated.
Capability-dependent tests can skip when optional tools are absent; live inference tests remain off with `FM_LIVE=0`.
For a terminal-free machine, the standalone clean-room scenario records missing runtime tools explicitly rather than claiming a live dispatch.
See [CONTRIBUTING.md](CONTRIBUTING.md) for test-family selection and [distribution scenarios](distribution/README.md) for the standalone and pairwise offline acceptance scope.
