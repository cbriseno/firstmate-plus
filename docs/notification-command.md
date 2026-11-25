# Optional notification command

The executable header and `python3 bin/fm-notify.py --help` own the command interface, bounds, and exit codes.
The interface is disabled by default and installs no hooks or services.
An installation can create private `config/notification-command.json` containing a JSON array of executable arguments.
Use an executable you control and an absolute executable path when PATH resolution is unsuitable.
Firstmate appends the event name and text as separate arguments and supplies the same values as JSON on stdin.
There is no shell expansion.
A five-second deadline bounds the consumer call; a failed or unavailable command returns failure without changing work records.
The caller must keep notification text free of secrets and must not treat a successful consumer exit as device delivery.
When configured, Firstmate tells the captain through it whenever something starts waiting on them, without relying on an agent to remember: a new captain hold (`captain-question`, `captain-approval` or `captain-action`), a result newly declared for review (`captain-review`), a Lavish board armed for the first time (`captain-board`), and one daily summary of everything in the Deck's needs-you set (`captain-reminder`).
`bin/fm-captain-notice.py` owns those texts, their Deck or board link, and which transitions call it; the link reaches the command only in the stdin JSON as `link`.
An installation with another channel for an event, such as a private integration that already announces captain holds, lets its command accept and ignore that event.
`tests/fm-notification-command.test.sh` verifies absence, literal arguments, invalid configuration, failure, deadline, installation language selection, the link and the captain notices without sending an external notification.

The publication gate (`bin/fm-publication-gate.py`) also announces each successful push or forge publication it ran as `captain-published`, when `FM_HOME` is set, so nobody has to remember to relay it.
The overseer sends its own alerts with `bin/fm-overseer.sh alert TEXT` (event `overseer-alert`).
Before updating Firstmate, make sure its alert adapter returns a reference to a verifiable acceptance record from its destination, using the receipt format in the executable help.
The alert reports failure if the reference is missing and prints the receipt when delivery is confirmed.
An installation can create `config/notification-quiet-hours` with one line such as `23:00-07:00` (local time, may span midnight).
Notices sent with the configured command during that window are held.
An overseer alert reports pending delivery and stays in the queue until its individual delivery has a receipt.
Other held notices are combined into a digest when there is more than one.
The overseer's watch sends held notices without waking any model.
Without a running overseer, the next notice after the window sends them.
The window applies to the configured command, not to an explicit `--command-file` such as the watcher's login-expiry alert.

The executable also accepts a command file for one invocation, without editing installation configuration; its help owns that option.
