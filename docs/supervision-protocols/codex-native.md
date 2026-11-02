Mode: Codex opt-in native Stop supervision (live acceptance required).

This session has an explicit native target binding; [configuration](../configuration.md#codex-native-supervision) owns its scope and limits.
When supervision is required, the asynchronous Stop hook owns one watcher cycle and queues its wake to this bound thread through the configured CLI and endpoint.
Keep updates in progress messages while handling work.
For each native wake, drain with `bin/fm-wake-drain.sh`, handle every presented wake, open decision and unread status, then run its exact `WAKE_ACK_REQUIRED` command after handling.
End the handling turn when its actions are complete so the next Stop can arm its successor.
Do not start another watcher or acknowledge work before handling it.
A queue receipt is delivery acceptance; it is not evidence that a model handled the wake.
If the native guard reports fallback or an unproved owner, keep this turn open with foreground checkpoints and progress updates while repairing the bound owner under the [opt-in contract](../configuration.md#codex-native-supervision).
Away and quiet postures retain their existing supervision owners and protocol.
