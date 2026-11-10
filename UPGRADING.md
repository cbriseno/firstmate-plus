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
