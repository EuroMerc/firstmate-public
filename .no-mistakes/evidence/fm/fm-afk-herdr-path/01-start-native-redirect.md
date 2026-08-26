# start-native on a Herdr supervisor backend: before vs after

Constellation reproduced from the incident: captain pane default:w1:p1, backend=herdr,
agent invokes 'bin/fm-afk-launch.sh start-native' (what the afk skill used to instruct).
The herdr CLI is stubbed, so this observes the launcher's own decision, not a herdr server.

## BEFORE (base f7a387f)
```
--- exit status: 0 ---
state/.afk-daemon-terminal: none|-|native
state/.afk present: yes
```
The daemon is recorded as hosted IN the captain pane (mode 'native', no terminal).
That is the arrangement that logged 2018 consecutive 'supervisor pane busy' refusals.

## AFTER (head 933c5c5)
```
fm-afk-launch: backend 'herdr' reports native busy state; an in-pane daemon would read itself as busy and defer every escalation, so launching it in a separate non-visible terminal instead
fm-afk-launch: daemon launched in non-visible herdr workspace w7 (pane default:w7:p1), supervising default:w1:p1
--- exit status: 0 ---
state/.afk-daemon-terminal: herdr|default:w7:p1|w7
state/.afk present: yes
```
start-native now redirects onto the non-visible-terminal path: the daemon runs in its own
herdr workspace w7 and supervises default:w1:p1 - structurally the 05:13 manual counter-proof.
