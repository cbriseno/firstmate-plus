# Upgrading existing homes

Pulling code does not authorize data migrations.
The primary checks these notes at locked session startup and after `/updatefirstmate`, offers pending actions once through a captain hold, and applies them only after acceptance.
A manual `git pull` is covered by the next session start; run `FM_HOME=/absolute/home bash bin/fm-upgrade.sh check` to check immediately.
The command's header and help own detection, per-home records and application.

## Manual procedure

1. Read each dated entry below and compare its id with the home's applied ids.
2. Ask once whether to apply the pending actions, recording the question with `bin/fm-captain-hold.sh`.
3. After acceptance, run each entry's command with that home's `FM_HOME`, resolve any reported work, and record its id only after success.

## v11b - 2026-11-10

Action: Migrate historical Deck results and explicit projects.

Historical reports and project declarations need the v11b migration to appear correctly in Deck.
Preview with `FM_HOME=/absolute/home bash bin/fm-migrate-v11b.sh --plan`.
After acceptance, apply the mechanical migration with the command below.
If it reports unresolved requests or projects, a worker follows the [v11b procedure](docs/configuration.md#v11b-migration), preserving documentary evidence and existing review marks, then reruns the upgrade command.
An unresolved migration remains pending without another automatic question.
The migration's help describes backups and rollback.

Command: `bash bin/fm-migrate-v11b.sh --apply`

## deck-event-publication - 2026-11-10

Locked session startup now creates `config/fleet-ledger` before publishing fleet events.
Existing homes receive this automatically; there is no separate activation to approve or mark applied.
If Deck was already running before that startup, restart it using its normal launch command so it reads the enabled journal.
See [fleet event publication](docs/fleet-ledger.md).

## deck-short-aliases - 2026-11-11

Action: Activate persistent short aliases for Deck in each existing home.

Prepare a separate private seed for each authorized home before applying this entry.
Use the seed format and activation rules in the header/help of `bin/fm-tasks-axi.sh` (`work aliases-init`).
Keep any approved historical aliases in the seed; for a home without historical assignments to import, prepare an empty seed:

```sh
FM_HOME=/absolute/home python3 - <<'PYSEED'
import json, os
from pathlib import Path
home = Path(os.environ['FM_HOME']).resolve()
seed = home / 'data/upgrades/deck-short-aliases-seed.json'
seed.parent.mkdir(parents=True, exist_ok=True)
with seed.open('x', encoding='utf-8') as stream:
    json.dump({'schema': 'fm-work-alias-seed.v1', 'home': str(home), 'entries': []}, stream)
PYSEED
```

If the seed already exists, review and reuse it.
After acceptance, apply this entry with the same home's `FM_HOME`; existing alias assignments and reservations are preserved.
Verify with `FM_HOME=/absolute/home bash bin/fm-tasks-axi.sh work snapshot`: `aliases.state` must be `active`, and projected projects, subprojects and tasks must have aliases.
Repeat for each authorized home; a snapshot or code update alone does not activate aliases.

Command: `bash -c 'exec bash bin/fm-tasks-axi.sh work aliases-init --map "$FM_HOME/data/upgrades/deck-short-aliases-seed.json" --request-id deck-short-aliases-20261111'`
