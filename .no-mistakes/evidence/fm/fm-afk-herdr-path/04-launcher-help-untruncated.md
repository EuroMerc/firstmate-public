# Launcher help window no longer truncates mid-sentence

## BEFORE (base f7a387f) - last lines of `fm-afk-launch.sh --help`
```
  fm-afk-launch.sh start-native
                             Prepare lifecycle state for a harness-native
                             background job and record that no terminal exists.
  fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
                             cleanup flushes WHILE state/.afk is still present,
                             wait for it, close the recorded terminal by exact
```
Cut off inside the `stop` description; the `reconcile` subcommand and the supported-backend line never printed.

## AFTER (head 933c5c5)
```
                             Prepare lifecycle state for a harness-native
                             background job and record that no terminal exists.
                             Redirects to `start` when the supervisor backend
                             reports native busy state (see above), because an
                             in-pane daemon would defer every escalation there.
  fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
                             cleanup flushes WHILE state/.afk is still present,
                             wait for it, close the recorded terminal by exact
                             id, then clear state/.afk last.
  fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
                             id and drop the record (recovery after a crash).

Supported backends: herdr, tmux. Others (zellij, orca, cmux) have no verified
non-visible-launch primitive here yet and refuse loudly.
```
