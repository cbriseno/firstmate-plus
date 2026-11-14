# Model and effort

Load this with the selected tool reference before choosing, validating, or changing either axis.
Add `references/common/dispatch.md` for configured profile precedence.

## Axes and precedence

`../../../bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values selected at intake; scripts never parse natural-language dispatch rules.
The tool reference records verified flags, accepted values, omission behavior, and discovery.

Choose the required reasoning class at every dispatch, including host tasks and replacement workers, before ranking quota candidates.
Use the matrix below when no explicit captain choice or applicable configured profile fixes an axis.
Select concrete models from the chosen harness's current authoritative catalog, never from a permanent model-name list.

| Work | Model class | Effort fallback |
| --- | --- | --- |
| Simple lookup or mechanical edit with a known path | Smallest capable available model | low |
| Bounded implementation, report, or analysis with several interacting steps | Balanced model capable of the whole task | medium to high |
| Ambiguous design or diagnosis, critical/high-risk work, or large cross-source analysis | Strongest available reasoning model | high to xhigh |

Judge difficulty from uncertainty, scale, reader needs, and consequences, not whether the output is code; a large spreadsheet edit or nontechnical synthesis can need the strongest class.
If a configured choice cannot meet the required class, report the mismatch rather than silently downgrading the task or replacing an explicit choice.
Record the selected concrete model, effort, class, and short fit rationale in the dispatch note; `fm-spawn.sh` records the concrete axes in task metadata.
For profile arrays, `quota-array-dispatch` owns selection among candidates that meet this class.

Effort precedence is a per-task captain instruction, then applicable dispatch profile or secondmate pin, then the fallback below.
Never replace either higher-precedence value.
Use the fallback only when neither specifies effort.

Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels as complexity, uncertainty, blast radius, or open-ended reasoning rises.
If an adapter lacks `xhigh`, cap at its highest supported non-`max` level rather than silently omitting the intent.
Never select `max` through this fallback; only an explicit per-task or standing captain preference permits it.

The explicit native `ultra` value is unsupported by the verified adapters and refuses through `bin/fm-harness.sh validate-native-effort`.
For other values, if requested effort is outside the adapter's accepted set, the spawn records `effort=` in task metadata but emits no effort flag.
This preserves launch success instead of passing a known-bad value.
A harness with no verified interactive effort flag follows the same record-and-omit contract.

## Harness and provider identity

Harness identity is independent of model provider.

No script resolves credential provenance for you.
Establish it from the tool's discovery surface and `quota-axi auth --json` per-provider sources, and show the reasoning rather than inferring it from a name.

## Discovery

Treat model and provider knowledge as current discovery, not a permanent namespace or mapping.
Use the selected tool reference's authoritative surface in the current authenticated environment because availability changes by version, account, and configuration.

For an unfamiliar namespace, establish support and provider identity from that harness's CLI help, model listing, or current documentation.
An account-reaching listing that omits a model is concrete unsupported evidence; block the candidate and quote it.
An unreachable surface establishes nothing; report uncertainty instead of a verdict.

For a matched profile array, return to `quota-array-dispatch` only after establishing every candidate's harness support, provider relationship, and uncertainty.
