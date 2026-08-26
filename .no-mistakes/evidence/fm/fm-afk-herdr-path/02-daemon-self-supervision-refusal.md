# Fail-closed backstop: the daemon refuses to supervise its own pane

The real bin/fm-supervise-daemon.sh is started IN the pane it would supervise
(herdr, HERDR_PANE_ID=w1:p1) - the wedge constellation - via any launch path.

## BEFORE (base f7a387f)
```
--- exit status: 124 ---
--- stderr (operator-visible) ---
Terminated
--- state/.supervise-daemon.log ---
[2026-08-26T06:47:02+0000] daemon starting (pid 924247); target=default:w1:p1; target_source=HERDR_ENV(HERDR_PANE_ID); backend=herdr; backend_source=FM_SUPERVISOR_BACKEND; afk=off; inject_skip='heartbeat'; stale_escalate=240s; batch=90s
[2026-08-26T06:47:21+0000] daemon shutting down
--- singleton lock left behind: no ---
```
The daemon starts happily; its startup line matches the incident log verbatim
(target=default:w1:p1; target_source=HERDR_ENV(HERDR_PANE_ID); backend=herdr).
It would then defer every escalation for the whole away stretch.

## AFTER (head 933c5c5)
```
--- exit status: 1 ---
--- stderr (operator-visible) ---
error: supervisor target 'default:w1:p1' is this daemon's own pane and backend 'herdr' reports native agent state; the daemon would read its own presence as a busy supervisor and never deliver an escalation. Launch it with 'bin/fm-afk-launch.sh start', which runs it in a separate non-visible terminal and passes the captain pane in as FM_SUPERVISOR_TARGET
--- state/.supervise-daemon.log ---
[2026-08-26T06:47:22+0000] startup failed: refusing to supervise own pane 'default:w1:p1' on backend 'herdr' with native busy state (source=HERDR_ENV(HERDR_PANE_ID))
--- singleton lock left behind: no ---
```
It refuses before any backend probe, names the reason, names the launch that works,
releases its singleton lock, and leaves no pid file.
