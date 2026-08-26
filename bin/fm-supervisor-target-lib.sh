#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# names and precedence both callers already used are unchanged from when this
# logic lived inline in bin/fm-supervise-daemon.sh, so its unit tests
# (tests/fm-daemon.test.sh) keep exercising the same names after the daemon
# sources this file. discover_own_pane_target below is the own-pane half of that
# same precedence, named so the daemon can compare its resolved target against
# the pane it is itself running in without a second copy of the rules.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# discover_own_pane_target: the pane THIS process is running in, resolved from
# its own inherited terminal env and never from FM_SUPERVISOR_TARGET. Priority:
#   1. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from that pane.
#   2. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
# Prints nothing and returns 1 when neither provider names a pane for this
# process. The away-mode daemon compares this against its resolved supervisor
# target so it can refuse to supervise its own pane on a backend whose native
# busy state its own presence would set (bin/fm-supervise-daemon.sh).
discover_own_pane_target() {
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s' "$TMUX_PANE"
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
    return 0
  fi
  return 1
}

# supervisor_self_supervision_refused: true when <target> is the pane THIS
# process runs in AND <backend> reports native agent state - the self-blocking
# arrangement bin/fm-afk-launch.sh's header owns the rule and rationale for.
# Every caller that must reject it (the daemon's startup backstop, the away
# entry's pre-flight) asks here, so the composed rule has one owner too.
# Requires bin/fm-backend.sh (fm_backend_has_native_busy_state) to be sourced,
# as every caller of this file already does.
supervisor_self_supervision_refused() {  # <backend> <target>
  local own
  own=$(discover_own_pane_target) || return 1
  [ -n "$own" ] || return 1
  [ "$own" = "$2" ] || return 1
  fm_backend_has_native_busy_state "$1"
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target or a
#      herdr "<session>:<pane-id>" target (paired with discover_supervisor_backend
#      to know which).
#   2. discover_own_pane_target - the pane this process itself runs in, which for
#      a process launched from firstmate's own pane IS firstmate's pane.
#   3. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  local own
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  if own=$(discover_own_pane_target); then
    printf '%s' "$own"
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux vs herdr) to dispatch through. Priority mirrors
# discover_supervisor_target and bin/fm-backend.sh's fm_backend_detect:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. $TMUX_PANE set - tmux.
#   3. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   4. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  if [ -n "${TMUX_PANE:-}" ]; then
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'herdr'
    return 0
  fi
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
