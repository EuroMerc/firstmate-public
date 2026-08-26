# Backend review, checked rather than assumed

Real daemon startup per supervisor backend (own pane = default:w1:p1 under herdr env):
```
backend=zellij  error: away-mode daemon does not support supervisor backend 'zellij' yet (supported: tmux herdr); set FM_SUPERVISOR_BACKEND=tmux|herdr and FM_SUPERVISOR_TARGET to run firstmate's own pane under a supported backend

backend=orca    error: away-mode daemon does not support supervisor backend 'orca' yet (supported: tmux herdr); set FM_SUPERVISOR_BACKEND=tmux|herdr and FM_SUPERVISOR_TARGET to run firstmate's own pane under a supported backend

backend=cmux    error: away-mode daemon does not support supervisor backend 'cmux' yet (supported: tmux herdr); set FM_SUPERVISOR_BACKEND=tmux|herdr and FM_SUPERVISOR_TARGET to run firstmate's own pane under a supported backend

backend=tmux    error: supervisor target 'default:w1:p1' does not resolve to a tmux pane; set FM_SUPERVISOR_TARGET

backend=herdr   error: supervisor target 'default:w1:p1' is this daemon's own pane and backend 'herdr' reports native agent state; the daemon would read its own presence as a busy supervisor and never deliver an escalation. Launch it with 'bin/fm-afk-launch.sh start', which runs it in a separate non-visible terminal and passes the captain pane in as FM_SUPERVISOR_TARGET

```
zellij, orca and cmux cannot be away-mode supervisor backends at all and refuse earlier.
tmux keeps its previous behavior: it falls through to the ordinary target probe, no self-supervision refusal.
herdr is the only backend where the new refusal fires.
