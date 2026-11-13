#!/usr/bin/env bash
# Rendered-state helpers, sourced by fm-busy-lib.sh.

# --- launch-prompt signatures (fm_busy_launch_prompt_parked) ----------------
#
# Each function consumes a captured pane tail on stdin (the caller's whole
# tail40, NOT reduced to the last 12 non-blank lines the way the Grok
# busy footers above are): a bordered dialog box renders many short lines of
# pure border/padding (`│  ...  │`) that are NOT whitespace-only, so a 12-line
# non-blank reduction was verified live to push the box's own heading text
# (for example, a first-run authentication prompt)
# outside the window entirely, silently defeating the match. Matching the
# full capture avoids that trap; a signature is still best-effort exactly like
# the footer fallbacks - a screen taller than the capture can still scroll a
# signature out, so absence never proves the pane is NOT parked, only that
# this check cannot confirm it.

# fm_busy_claude_launch_prompt_tail: Claude's workspace-trust dialog
# ("Quick safety check: Is this a project you created or one you trust?",
# re-verified live on Claude Code 2.1.278, docs/verification/runtime-backends.md
# "Launch-prompt backstop signatures") and its separate external-CLAUDE.md-
# imports dialog ("Allow external CLAUDE.md file imports?", verified by
# disassembly, .agents/skills/harness-adapters/references/harness/claude.md
# "Hook trust" sibling section). fm-claude-trust.sh pre-registers both before
# launch; this is the backstop for when that registration did not take effect.
# Each dialog's own question text is paired with one of its own rendered
# option/footer lines, both required together: the question text alone is
# plausible self-referential prose a firstmate-repo worker could easily render
# on its own (fm-claude-trust.sh's header literally quotes both questions),
# but the option/footer pairing only ever renders inside the real dialog.
fm_busy_claude_launch_prompt_tail() {
  local buf
  buf=$(cat)
  if printf '%s' "$buf" | grep -qiE "${FM_BUSY_CLAUDE_TRUST_PROMPT_REGEX:-Quick safety check: Is this a project you created or one you trust\\?}" \
    && printf '%s' "$buf" | grep -qiE 'No, exit|Enter to confirm'; then
    return 0
  fi
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_CLAUDE_IMPORTS_PROMPT_REGEX:-Allow external CLAUDE\\.md file imports\\?}" \
    && printf '%s' "$buf" | grep -qiE 'No, disable external imports|Yes, allow external imports'
}

# fm_busy_pi_launch_prompt_tail: Pi's project-trust dialog. Live-verified on
# pi 0.86.1 (2026-09-22) in a fresh untrusted worktree carrying a project-local
# .pi/extensions/ file (the shape a real ship/scout spawn always launches
# into): the rendered heading is "Trust project folder?" and its declining
# option is literally "Do not trust". An initial guess sourced only from the
# installed binary's UI strings ("Project trust", the internal panel-title
# component name, not this dialog's own rendered heading) was proven wrong by
# that live run and never matched the real screen - which is exactly why this
# class of check must be proven end to end rather than read off strings or a
# name. Matching BOTH the heading and "Do not trust" keeps this from firing on
# a worker's own prose that happens to use the common word "trust" alone.
fm_busy_pi_launch_prompt_tail() {
  local buf
  buf=$(cat)
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_PI_LAUNCH_PROMPT_REGEX:-Trust project folder\\?}" \
    && printf '%s' "$buf" | grep -qiE 'Do not trust'
}

# fm_busy_launch_prompt_parked: dispatch to the signature above for <harness>,
# or fail when this harness has none. Consumes the tail on stdin. Scoped to
# exactly the harnesses fm-spawn.sh arms with the fm-spawn busy source
# (claude*, opencode*, pi, pi-signed) since only those can ever
# read a pinned "busy fm-spawn" record; codex and standalone Kimi already
# classify unknown before a record is ever consulted, and opencode ships no
# trust dialog at all.
fm_busy_launch_prompt_parked() {  # <harness>
  case "${1:-}" in
    claude*) fm_busy_claude_launch_prompt_tail ;;
    pi | pi-signed ) fm_busy_pi_launch_prompt_tail ;;
    *) return 1 ;;
  esac
}
