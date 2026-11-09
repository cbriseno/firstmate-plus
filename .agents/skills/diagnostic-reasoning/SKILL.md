---
name: diagnostic-reasoning
description: >-
  Load before scoping a reported bug and before acting on a diagnostic report.
user-invocable: false
metadata:
  internal: true
---

# diagnostic-reasoning

Use this procedure before scoping a reported bug and before acting on a diagnostic report.
This skill is the single owner of Firstmate's bug-diagnosis reasoning procedure.
The subordinate performs this procedure and returns its result and concise evidence summary; firstmate uses that summary to scope or route work under `AGENTS.md` section 1.

## Read the diagnostic logs first

Before reproducing, and before asking anyone for more data, read the always-on anonymized logs in the directory above `bin/fm-diag.sh path`.
`firstmate/events.jsonl` times every hook, session-start stage, wake acknowledgement, and task snapshot, and samples each worker's processes and zombies; `deck/events.jsonl` holds the Deck's snapshot reads and errors, animations, layout shifts, and overlays; each rotates to `events.1.jsonl`.
`bin/fm-diag.sh`'s header owns the Firstmate event schema.
Summarize the incident window with `jq` - counts and p50, p90, and maximum per event and field - and cite those numbers as observed facts.
Name a number the logs lack as a gap rather than asking the captain for it.

## Establish the observed behavior

Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Require an end-to-end reproduction aligned with the real user path whenever it is feasible and safe.
If a faithful reproduction is not feasible, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Separate these three facts explicitly:

- The **initiating trigger** is the event, input, or transition that starts the faulty behavior.
- The **masking condition** is the independent state, environment, timing, cache, configuration, or path difference that hides or exposes the fault.
- The **visible symptom** is what the end user or operator can actually observe.

Do not collapse those facts into one label.
A masking condition may explain why a fault appears only sometimes without being the initiating cause, and the visible symptom may be several layers downstream from both.

## Test the causal explanation

Inspect the failing path and a proven path where the intended behavior is known to work.
Compare their inputs, state transitions, dependencies, timing, and control flow to find the earliest meaningful divergence.
Inspect relevant history, including blame, commits, migrations, and prior implementations, when it can explain why the paths diverged or which invariant was intended.
Do not treat the most recent nearby change as causal without evidence.

Identify the smallest counterfactual that should change the outcome if the leading explanation is true.
Change one condition at a time where practical, and record whether the symptom appears, disappears, or remains unchanged.
Seek disconfirming evidence deliberately: name what observation would falsify the leading explanation, run that check when feasible, and retain contradictory results instead of explaining them away.
Compare the final explanation against the proven path and show why the proposed causal boundary accounts for both the failure and the success.

## Scope and act on the result

A diagnosis brief should ask for the diagnostic-log summary, the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before accepting "not reproduced", require a brief coverage matrix for relevant runtime/device variants, environment, time or zone, account/data state, and trigger path.
Mark each dimension tested, excluded with a reason, or unknown, and name the untested dimensions that limit the negative result.
Scale coverage to the reported defect rather than mechanically testing every combination.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.
Implementation still requires the captain's request or another existing lifecycle authority, and the reproduction should become the regression test when a fix is authorized.
