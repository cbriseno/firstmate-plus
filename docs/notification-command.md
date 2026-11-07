# Optional notification command

The executable header and `python3 bin/fm-notify.py --help` own the command interface, bounds, and exit codes.
The interface is disabled by default and installs no hooks or services.
An installation can create private `config/notification-command.json` containing a JSON array of executable arguments.
Use an executable you control and an absolute executable path when PATH resolution is unsuitable.
Firstmate appends the event name and text as separate arguments and supplies the same values as JSON on stdin.
There is no shell expansion.
A five-second deadline bounds the consumer call; a failed or unavailable command returns failure without changing work records.
The caller must keep notification text free of secrets and must not treat a successful consumer exit as device delivery.
Task transitions do not implicitly invoke this command; an operator-owned integration chooses the events to forward.
`tests/fm-notification-command.test.sh` verifies absence, literal arguments, invalid configuration, failure, deadline, and installation language selection without sending an external notification.

The executable also accepts a command file for one invocation, without editing installation configuration; its help owns that option.
