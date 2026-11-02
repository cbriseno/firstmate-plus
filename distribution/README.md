# Offline distribution scenarios

The scenario JSON files use the clean-room runner supplied separately by firstmate-extensions.
They clone supplied local bare repositories into a fresh sandbox with an empty HOME and no network.
The standalone case checks read-only prerequisites, local project registration, a real work snapshot, lock-release help, and absent extension degradation.
The extension pair checks the actual work capabilities, refuses retirement of an unowned lock without altering it, and exercises extension installation, scoped planning, hook execution, absent-relay diagnostics, and uninstall.
Successful retirement of a live shared-runtime session is outside this offline scenario.
The Deck pair negotiates capabilities and uses the actual work API for snapshot, priority preview, apply, idempotent receipt, and Undo.
It also verifies that an absent producer disables controls.
All three scenarios require the installed `tasks-axi` package tree as the clean-room runtime named `tasks-axi`; an entrypoint-only bind cannot provide its canonical reader modules.
These are offline contract checks, not live model dispatch, automatic session replacement, browser acceptance, or terminal lifecycle certification.
Optional external tool availability and every skipped capability must be read from the run report.

The standalone fixture reads the supplied release commit identity in memory for its disposable example-project commit.
It passes that identity through per-invocation Git options and writes no identity configuration.
Operators running the README use their own public identity.

A scenario result is acceptance evidence only when its actual source revisions, execution and cleanup are recorded.
A capability probe or a safe refusal does not establish live relay activation or a successful shared-runtime retirement.
