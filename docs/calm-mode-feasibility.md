# Calm-mode harness feasibility

This document owns the version-scoped Claude Code feasibility evidence and supported-API boundaries for Firstmate calm mode.
[`calm.md`](calm.md) owns the current user-facing `/calm` usage and limitation contract.

## Required extension surface

A qualifying implementation must auto-load from the trusted project, persist the toggle choice for the effective Firstmate home across session starts and resumes, keep working activity visible, emit no Calm status row, redraw already-rendered controllable rows, remove supported hidden rows without gaps, restore ordinary rendering, and leave delivery, tool execution, model context, session storage, export and share operation, diagnostics, and expansion state unchanged.
The governing presentation policy allows genuine original user prompts, genuine user-facing assistant text, and working activity.
Working activity may be presented through the harness's stock row or through a supported Calm-owned drawing, but Calm must leave the stock row untouched whenever Calm is off.
Changing persisted context to remove hidden content, filtering provider context, patching installed harness code, or claiming coverage outside a supported renderer does not satisfy that boundary.

## 2026-09-15 Claude Code 2.1.272 mods feasibility and the shipped mod

Claude Code 2.1.272 exposes exactly the capability the 2026-07-22 row found missing, through its early-access "Claude Mods" surface, whose engineering primitive is the function hook: a plugin whose behavior lives in one hooks module exporting `register(on, options)`, hooking dotted engine events as `($, e, next)` middleware, with `ui.render` drawing per-component transcript rows and the working row, `$.ui.invalidate("ui.render")` redrawing every hooked drawing, and `$.ui.blit` repainting a mounted `Raster` without a render pass.
The surface is default-off: hooks modules load only when the `tengu_plugin_hooks_modules` rollout flag or the `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` environment variable turns them on, never under safe mode, `disableAllHooks`, or a managed-hooks-only policy, and only after workspace trust is accepted.
The generated declarations (`/plugin-types`) carry the header "EARLY ACCESS: this surface may change between releases without notice", and the public proposal invites testing behind that variable while the feature is not yet in the public docs or CHANGELOG.
The feasibility spike (scout `fm-claude-mods-calm-sailboat-s1`, whose private report holds the raw captures) and the shipped `firstmate-calm` mod both use only that documented-in-binary plugin API; the shipped mod also checks that `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` is exactly `1` before any preference read, transcript read, timer, command registration, or drawing change, so loading its module through the rollout flag alone remains a complete no-op. Nothing patches installed Claude Code code, and no prompt, tool, or session event is rewritten.

```text
$ claude --version
2.1.272 (Claude Code)
$ tmux -V
tmux 3.6a
```

### What the API allows, per surface

| Surface | Can it own the working indicator? | Can it hide or redraw transcript rows? | Evidence |
| --- | --- | --- | --- |
| Mods, `ui.render` | Yes: the `Spinner` component (`word`, `message`, `mode`, `requestId` the agent id, `e.viewport.columns`), replaced by a `Raster` repainted through `$.ui.blit` at the frame rate. | Yes: `UserMessage`, `AssistantMessage` (one text block), `ToolUse`, `ToolResult`, `ToolGroup`, `CommandOutput`, `TurnDuration`, and more, each rewrite changing the drawing and leaving the stored message alone; `$.ui.invalidate("ui.render")` redraws every instance the plugin may draw. | The declarations' `RenderComponent`, `RenderPropsOf`, `UiBlitArgs`, and `RasterProps`, the spike captures below, and the shipped mod's tests. |
| `statusLine` command | No: it renders in the footer, its input has no turn-running field, and it refreshes at most once per second. | No. | Binary settings schema and the status-line docs; not spiked. |
| Spinner settings (`spinnerVerbs`, `spinnerTipsEnabled`, `prefersReducedMotion`) | No: text and tips only, no frames or hiding. | No. | Binary settings schema. |
| `/focus` view mode | No. | Coarse only: the stock "prompt, summary, and response" view, fullscreen only, not a per-row policy. | Binary command source. |
| Classic settings hooks | No. | No: decision, context, system message, and terminal-sequence outputs only. | Unchanged from the 2026-07-22 record. |

### Spike-verified behavior

Every capture came from real Claude Code 2.1.272 TUIs under tmux at 160 by 44 cells, driven by Haiku, with an isolated `FM_HOME` and the inherited session markers stripped.

- The stock `✽ Verb… (Ns · tokens)` row is absent while the boat draws in its place; over 23 working frames at 0.4s spacing the hull advanced one column every 0.8s to 0.9s (the 880ms cadence), the water row changed on every frame (the quarter-cell swell), the water width was exactly 158 (the 160-cell viewport minus the transcript's 2-cell margin), and the sail stayed one column right of the hull.
- When the turn settled the boat was gone with no residual row, on both the fullscreen (`CLAUDE_CODE_NO_FLICKER=1`) and main-screen (`CLAUDE_CODE_NO_FLICKER=0`) layouts.
- Resizing the running TUI 160 to 64 to 12 to 160 columns reflowed the boat to 62, 10, and 158 cells of water within one frame of each resize settling, with the track clamped and direction flipping at the narrow edges.
- A narrated two-tool turn drawn with Calm off redrew after `/calm` with only the prompt and the final reply, at the same single-row spacing as a turn that never used tools; toggling off restored the narration, the `Bash(...)` row, and the `Read 1 file` group, and toggling on hid them again.
- An exact watcher-shaped operational input typed at idle drew no user row while the genuine prompt that followed stayed visible, and session storage held it as one ordinary user entry with its exact U+2063 bytes, answered once.
- The first Calm-on turn's storage held both tool uses, both results, its text, and its thinking blocks intact.
- Launching with `config/calm` already `on` started Calm on, and after `/exit` and `claude --continue` the restored tool rows and operational row stayed hidden from the first frame; the first spike build failed that, because restored rows drew before its `session.start` loaded the preference, which is why every hook of the shipped mod awaits one cached load.
- A trusted project folder holding only `.claude/skills/<mod>` (a symlink to the plugin) loaded the mod with no launch flag once the flag was on, logging `hooks module <name> loaded (worker, environment 1, tier user)`; without the flag the same folder logged `hooks modules not loaded: rollout flag (tengu_plugin_hooks_modules) is off`.
- Each render dispatch settled well under 3ms in the debug log.

An escape-preserving capture of the boat from the spike, taken before the palette was unified on 2026-09-15 and so still showing a cyan crest and a red sail half, shows the Raster's RGB quantized to 256-color escapes; the shipped mod paints Claude Code's own theme colors through the same quantization, the spinner blue of the active family for every water cell (`#93a5ff` dark, `#5769f7` light) and the Claude orange of the stock spinner (`#d77757`) for the whole boat, choosing the family from the `theme` setting's prefix at load and on every theme change, with the light set as the both-readable fallback for `auto`, custom, missing, or unreadable values, while the Pi extension keeps standard ANSI blue and yellow:

```text
\x1b[38;5;184m◿│\x1b[38;5;167m◣\x1b[39m
\x1b[38;5;69m▁▁▁\x1b[38;5;184m╲\x1b[38;5;69m▁▁▁\x1b[38;5;184m╱\x1b[38;5;69m▁▁▁▁▁▂▂▂\x1b[38;5;38m▃▃▄▄▄▄▄▃▃▃\x1b[38;5;69m▂▂
```

### Parity against the required extension surface

| Requirement | Result on Claude Code 2.1.272 |
| --- | --- |
| Auto-load from the trusted project | Met, behind the flag: the project's `.claude/skills/<mod>` entry, a symlink or directory, is adopted as a `<mod>@skills-dir` plugin after trust; dot-prefixed entries are skipped, and hooks-module imports must resolve physically inside the plugin folder. |
| Persist the toggle for the effective home across starts and resumes | Met: the same `config/calm` file and values as Pi, resolved the same way; the plugin API's `$.fs.write` is a plain write rather than Pi's temp-plus-rename. |
| Keep working activity visible | Met: the boat draws in place of `Spinner` on every working frame on both layouts. |
| Emit no Calm status row | Met: `/calm` answers with a transient toast and no output row. |
| Redraw already-rendered controllable rows | Met through `$.ui.invalidate("ui.render")`, with the main-screen scrollback caveat below. |
| Remove supported hidden rows without gaps | Met: zero-height `display: "none"` boxes; spacing equals the no-tool baseline. |
| Restore ordinary rendering when off | Met: hooks return `next(e)`; the stock rows and stock spinner return. |
| Leave delivery, tool execution, model context, session storage, and export unchanged | Met for storage and context; only `ui.render` rewrites drawings and no other event is hooked for effect. |
| Collapsed thinking | Not needed: no thinking row appears in the default view, and there is no thinking drawing to hook elsewhere. |
| Arbitrary third-party rows | Better than Pi: `ToolUse`, `ToolResult`, and `ToolGroup` hooks see every tool, built-in, MCP, or plugin, with no same-name override collision. |

### Bounded gaps

1. The whole surface is early access and default-off, and its API may change between releases without notice; the real TUI behavior is verified on Claude Code 2.1.272, the plugin compatibility guard also passes on 2.1.273, the mod refuses nothing newer, and `tests/fm-calm-claude-mod-plugin.test.sh` is the check that says when a newer Claude Code stops accepting it.
2. On the main-screen (non-fullscreen) layout a toggle redraws the live screen by clearing and reprinting the whole conversation, and the terminal's own scrollback keeps the previous rendering above it; the fullscreen layout has no such stale copy.
3. The Raster paints RGB through a quantized palette, so the boat renders as 256-color escapes rather than Pi's standard 16-color ANSI codes.

Three further observations, recorded so they are not read as failures: the `ctrl+o` detailed transcript view keeps its per-message timestamp and model headers where hidden assistant rows sat, because those headers are not a render component; on 2.1.272 the `/calm` toggle's answer was a transient toast under the prompt (`firstmate-calm: Calm on`) that expired within a few seconds and never became a transcript row; and the engine logs one benign debug-level warning at load, `options requested but its manifest declares no userConfig`, for every hooks module whose manifest declares no configuration fields, which an empty `userConfig` object does not silence.

### The shipped mod

`.claude/mods/firstmate-calm` holds the plugin: its manifest, `hooks/hooks.json` naming the one module, `hooks/register.ts` (the only file that touches `$`), and pure libraries the tests drive under Node: the sprite core both harnesses share, the Raster packing, the presentation policy, and a port of `bin/fm-operational-input.sh`'s `classify` guarded by a corpus parity test.
`.agents/skills/firstmate-calm` is a symlink to it, so the project's `.claude/skills` scan adopts it, and it carries no `SKILL.md` so other harnesses' skill loaders see nothing.
The mod declares no command file, skill, agent, or classic hook; its function-hooks handlers independently require the exact environment opt-in before `/calm` registration or any other side effect, including when Claude Code loads the module through its rollout flag.
Working-note and preserved-reply keys are recorded from `turn.step` per text block and seeded from `$.session.messages()` for a restored transcript, with [`calm.md`](calm.md#claude-code) owning the exact Claude Code visibility contract.

```text
$ CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate --strict .claude/mods/firstmate-calm
  ❯ ./register.ts hooks: session.start, command.run{command=calm}, config.set{key=theme}, turn.step, ui.render{component=Spinner}, ui.render{component=ToolUse}, ui.render{component=ToolResult}, ui.render{component=ToolGroup}, ui.render{component=UserMessage}, ui.render{component=AssistantMessage}
  ❯ ./register.ts calls: $.clock.every (via load), $.command.register, $.config.list (via readTheme), $.env.get (via isActivated, load), $.fs.read (via readPreference), $.fs.write, $.session.messages (via load), $.ui.blit (via repaintShip), $.ui.invalidate, $.ui.resolve, $.ui.toast
  ❯ ./register.ts env writes: nothing
  ❯ ./register.ts env reads: CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, FM_CONFIG_OVERRIDE, FM_HOME, FM_ROOT_OVERRIDE
✔ Validation passed

$ CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test .claude/mods/firstmate-calm
 40 pass
 0 fail
Ran 40 tests across 2 files.

$ bin/fm-test-run.sh tests/fm-calm-claude-mod.test.sh
ok - the Calm mod is one hooks module, linked into the project's auto-load path, with no command, skill, agent, or classic hook path that bypasses its exact opt-in
ok - the Pi working ship renders byte-for-byte the shared sprite core's frame painted in standard ANSI, at every width, cadence step, freeze, clamp, and reset
ok - the Raster packing lays the shared frame out row-major with the sprite's palette, plain padding, default backgrounds, BMP glyphs, clipping, and a standard base64 encoding
ok - the Calm policy resolves the shared preference exactly as Pi does, reads on, max, and off as Pi does, and shares Pi's 240-character-or-newline preservation behavior while classifying working notes by stop reason, tool use, and restored transcript shape
ok - the mod's operational-input classifier agrees with bin/fm-operational-input.sh on all 77 corpus cases: every current kind the owner encodes, every legacy shape, and every near miss

FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=68438
```

The Pi suite above ran against the extracted sprite core with every one of its thirteen cases green, including the working-ship geometry and the interactive TUI case, which is the evidence that the extraction left Pi's drawing unchanged.
Later the same day the installed Claude Code auto-updated to 2.1.273, and `tests/fm-calm-claude-mod-plugin.test.sh` passed there as well: strict validation accepts the mod from both paths, including the theme hook and configuration read shown above, and the plugin-kit suites pass with the theme cases added.

The opt-in live guard, run on this host against the installed Claude Code 2.1.272 with tmux 3.6a and Haiku, through the shipped `.claude/skills` auto-load path, an isolated project and `FM_HOME`, and the preference already `on` before the flag-off session:

```text
$ FM_CLAUDE_CALM_LIVE_E2E=1 tests/fm-calm-claude-mod-live-e2e.test.sh
ok - Claude Code 2.1.272 (Claude Code) with the flag unset: no hooks module, no /calm, stock working row, stock tool rows, preference on ignored
ok - Claude Code 2.1.272 (Claude Code) with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool and operational rows draw at zero height, /calm restores and re-hides them while persisting the shared preference
ok - Claude Code 2.1.272 (Claude Code) resumes the transcript with Calm's hidden rows still hidden and the preference intact

$ bin/fm-test-run.sh tests/fm-calm-claude-mod-plugin.test.sh
ok - Claude Code 2.1.272 (Claude Code) validates the Calm mod strictly at its folder and its auto-load path, hooking exactly the working row, tool, user, and assistant drawings and /calm
ok - Claude Code 2.1.272 (Claude Code) runs the Calm mod's plugin test suites clean: persisted toggle, hidden rows, working notes, and the clock-driven working ship
```

The flag-off session's settled screen, with the preference `on` on disk, drew Claude Code's own rows exactly as a session without the mod does:

```text
❯ Run this exact bash command with the Bash tool: sleep 5; cat notes.txt   Then reply with one short sentence naming the three words.

  Ran 1 shell command

⏺ The three words are alpha, beta, and gamma.

✻ Sautéed for 8s · done 11:07 AM
```

## 2026-09-25 Claude Code 2.1.280 verification and the record-backed operational doorbell

Claude Code 2.1.280 removes invisible characters, U+2063 included, from every submitted prompt, whether typed, pasted, or passed as the launch prompt.
A typed operational envelope first shows `Removed 1 invisible character · review and press Enter to send`, and the next Enter stores it as plain `FIRSTMATE_OP: ...` text that no consumer can tell apart from a human message.
No setting or environment variable turns the removal off.
For the current delivery and presentation contracts, see [`fm-operational-input.sh`](../bin/fm-operational-input.sh) and [`calm.md`](calm.md#claude-code).

2.1.280 also logs the module load as `hooks module firstmate-calm@<source> loaded` (`@skills-dir` for the project auto-load path), so the live guard matches either form.

Observed on 2.1.280 with the flag on, beyond the live guard:

```text
$ claude --version
2.1.280 (Claude Code)

$ bash tests/fm-calm-claude-mod.test.sh
ok - the mod's operational-input classifier agrees with bin/fm-operational-input.sh on all 77 corpus cases: every current kind the owner encodes, every legacy shape, and every near miss
ok - the mod's doorbell port agrees with bin/fm-operational-input.sh doorbell-kind on all 28 cases: every record the owner writes and every unbacked or malformed near miss

$ bash tests/fm-calm-claude-mod-plugin.test.sh
ok - Claude Code 2.1.280 (Claude Code) validates the Calm mod strictly at its folder and its auto-load path, hooking exactly the working row, tool, user, and assistant drawings and /calm
ok - Claude Code 2.1.280 (Claude Code) runs the Calm mod's plugin test suites clean: persisted toggle, hidden rows, working notes, and the clock-driven working ship
```

The live guard in its current form is recorded on 2.1.282 in the next section.

## 2026-09-25 Claude Code 2.1.282 reproduction on the installed build

The failure was reproduced end to end on the installed Claude Code 2.1.282 in a disposable lab home and project on a private tmux socket, never touching the default tmux server or any real home.

- Typed path: `tmux send-keys -l` of `⁣FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate <test events>`, then Enter, left the composer showing `Removed 1 invisible character · review and press Enter to send`; a second Enter submitted it, and the stored session transcript held `FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate ...` with no U+2063 byte.
- Launch-prompt path: launching `claude` with the encoded launch-brief envelope as the prompt argument printed `Removed 1 invisible character from the launch prompt before sending it`; the stored transcript row kept the brief text but no U+2063.
- With the record-backed doorbell: the away-mode daemon's `inject_msg` delivered the doorbell to the real Claude pane as a composer-visible ASCII line only, and the live guard passed.

```text
$ claude --version
2.1.282 (Claude Code)

$ FM_CLAUDE_CALM_LIVE_E2E=1 bash tests/fm-calm-claude-mod-live-e2e.test.sh
ok - Claude Code 2.1.282 (Claude Code) with the flag unset: no hooks module, no /calm, stock working row, stock tool rows, preference on ignored
ok - Claude Code 2.1.282 (Claude Code) with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool rows and the record-backed operational doorbell draw at zero height, /calm restores and re-hides them while persisting the shared preference
ok - Claude Code 2.1.282 (Claude Code) resumes the transcript with Calm's hidden rows still hidden and the preference intact
```

## 2026-09-28 Claude Code 2.1.283 supervision notes

The mod's supervision notes were verified on the installed Claude Code 2.1.283 in disposable lab homes and projects on private tmux sockets, with the outcome store written by the real `bin/fm-branch-outcome.sh`.

- `$.ui.log` draws each note as its own system-notice row: a gray `⏺` bullet, then the mod's name, then the text, for example `⏺ firstmate-calm: ⚓ [seq 1] fm-quiet-hold-for-return-landing-r1: PR https://...`, wrapped at the terminal width.
- The note is stored in the session transcript as a display-only entry, `{"type":"system","subtype":"informational","content":"firstmate-calm: ⚓ [seq 2] fm-live-b: LIVE_REPLAY_CAPTAIN still open","level":"notice",...}`, and `claude --continue` restores it.
  The 2.1.274 plugin declarations say only that the line is not sent to the model, so the mod records how far each session has shown the store in its plugin store and replays only newer outcomes on resume.
- A Haiku turn asked to quote every sailboat or anchor line in the conversation quoted none of the notes on screen, so they did not reach the model.
- Every rejected `$.fs.read` or `$.fs.stat` is logged as `[ERROR]` in the debug log, so the mod checks `$.fs.exists` first for the files it polls.

```text
$ claude --version
2.1.283 (Claude Code)

$ bash tests/fm-calm-claude-mod-plugin.test.sh
ok - Claude Code 2.1.283 (Claude Code) validates the Calm mod strictly at its folder and its auto-load path, hooking exactly the working row, tool, user, and assistant drawings and /calm, and logging supervision notes
ok - Claude Code 2.1.283 (Claude Code) runs the Calm mod's plugin test suites clean: persisted toggle, hidden rows, working notes, the clock-driven working ship, and supervision notes

$ FM_CLAUDE_CALM_LIVE_E2E=1 bash tests/fm-calm-claude-mod-live-e2e.test.sh
ok - Claude Code 2.1.283 (Claude Code) with the flag unset: no hooks module, no /calm, stock working row, stock tool rows, preference on ignored
ok - Claude Code 2.1.283 (Claude Code) with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool rows and the record-backed operational doorbell draw at zero height, /calm restores and re-hides them while persisting the shared preference
ok - Claude Code 2.1.283 (Claude Code) resumes the transcript with Calm's hidden rows still hidden and the preference intact
ok - Claude Code 2.1.283 (Claude Code) with Calm off shows the supervision notes: the session-start anchor for an unprocessed captain outcome, a sailboat for a new routine outcome, an anchor for a new captain outcome, and the latch-trip note, skipping processed and silent outcomes, moving no store marker, never reaching the model, and on resume showing each anchor once
```

## 2026-09-28 Claude Code 2.1.284 supervision-note label and the fm plugin name

The label in front of each supervision note is Claude Code's, not the mod's, so the plugin is named `fm` to keep it short.

- The mod hands `$.ui.log` the glyph-first line, as the debug log shows: `[DEBUG] [firstmate-calm] $.ui.log: ⚓ [seq 1] fm-repro-a: REPRO_CAPTAIN open`.
- Claude Code 2.1.284 turns every transcript `$.ui.log` line into a system-notice entry whose content is `<plugin name>: <text>`, after the `ui.log` hook chain has run; `UiLogOptions` offers only `to: "transcript" | "debug"`, no `ui.render` component draws that row, and no other `$` call appends a transcript row.
- With the manifest named `fm`, the row draws as `⏺ fm: ⚓ [seq 1] fm-repro-a: REPRO_CAPTAIN open`, is stored as `"content":"fm: ⚓ [seq 1] ..."`, and the module loads as `hooks module fm@skills-dir loaded`; the folders keep their `firstmate-calm` names, which `claude plugin validate --strict` accepts.
- `$.store` lives in one file per plugin id under Claude Code's configuration directory (`plugins/store/fm_skills-dir-<hash>.json`), so the rename starts an empty store and a session resumed across it replays its still-due notes once.

```text
$ claude --version
2.1.284 (Claude Code)

$ bash tests/fm-calm-claude-mod-plugin.test.sh
ok - Claude Code 2.1.284 (Claude Code) validates the Calm mod strictly at its folder and its auto-load path, hooking exactly the working row, tool, user, and assistant drawings and /calm, and logging supervision notes
ok - Claude Code 2.1.284 (Claude Code) runs the Calm mod's plugin test suites clean: persisted toggle, hidden rows, working notes, the clock-driven working ship, and supervision notes

$ FM_CLAUDE_CALM_LIVE_E2E=1 bash tests/fm-calm-claude-mod-live-e2e.test.sh
ok - Claude Code 2.1.284 (Claude Code) with the flag unset: no hooks module, no /calm, stock working row, stock tool rows, preference on ignored
ok - Claude Code 2.1.284 (Claude Code) with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool rows and the record-backed operational doorbell draw at zero height, /calm restores and re-hides them while persisting the shared preference
ok - Claude Code 2.1.284 (Claude Code) resumes the transcript with Calm's hidden rows still hidden and the preference intact
ok - Claude Code 2.1.284 (Claude Code) with Calm off shows the supervision notes: the session-start anchor for an unprocessed captain outcome, a sailboat for a new routine outcome, an anchor for a new captain outcome, and the latch-trip note, each behind the fm: label, skipping processed and silent outcomes, moving no store marker, never reaching the model, and on resume showing each anchor once
```
