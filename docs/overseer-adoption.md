# Adopting a hand-made overseer

Design record for `fm-overseer.sh adopt`.

## Situation

Some installations already run an overseer that a person built by hand: a directory with its own `CLAUDE.md` or `AGENTS.md`, a handoff document, and a private watcher process.
The official overseer needs the same directory to hold links to the shipped contract, so the two cannot coexist there.

## Manual procedure, implemented in this order

1. Copy the hand-made contract files and any handoff documents to `state/overseer/adopted/<stamp>/` and prove each copy identical.
2. Remove only the two hand-made contract files from the directory.
3. Run `setup` on the directory; if it refuses, put the contract files back.
4. Write `config/overseer` when the installation has none.
5. After the new overseer is started and `status` shows it alive with its watch armed, stop the old watcher.
6. Tell the primary to drop any old alert line from the captain's notes.

## Decisions

- Adoption is explicit; updating never adopts. A handoff is archived, never imported: the contract keeps `state/overseer/handoff.md` under 4 KB.
- The old watcher is stopped by process id supplied by the person, and only after confirmation. Repeating the command is the confirmation step, so no extra state is stored.
- Alerts are not migrated: the old private alert script is out of scope; the generic notification command replaces it.
