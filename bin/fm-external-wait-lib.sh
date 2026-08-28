#!/usr/bin/env bash
# Shared visible presentation for declared external waits.
#
# A worker-declared `paused:` event and a validated PR-poll observation both
# render through this owner so current-state readers, fleet views, and the
# worker-facing direct-PR contract use one captain-facing vocabulary.
# Timestamps remain canonical filesystem metadata: a worker wait uses the
# status log mtime, while a PR wait uses the validated poll-registration mtime.
# They are formatted only at presentation time in Europe/Berlin, including the
# active CET/CEST daylight-saving abbreviation.
#
# fm_external_wait_worker_detail <reason> <status-log>
#   Print the persistent current-state detail for a worker-declared wait. The
#   free worker-authored reason is bounded to
#   FM_EXTERNAL_WAIT_WORKER_REASON_MAX (default 240) characters so one verbose
#   worker cannot dominate a fleet or Bearings projection, while the since-time
#   and health fields stay complete.
#
# fm_external_wait_publish_pr <state-dir> <task-id> <pr-url>
#                             <registration-file> <observation>
#   Accept one observation from fm-pr-poll.sh --observe-validated:
#     pending<TAB><optional comma-separated check names>
#     empty (GitHub reported no checks; registration-age grace decides pending)
#     none (GitLab definitively has no running pipeline)
#     green
#     merged
#     closed
#     failed<TAB><optional comma-separated failed check names>
#     unreadable
#   `empty` stays pending for FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS (default
#   120) from the registration mtime, then becomes a truthful no-checks result.
#   Append a standard paused/done/failed event only when its rendered state
#   differs from the latest event. Sets FM_EXTERNAL_WAIT_CHANGED to 1 or 0 and
#   FM_EXTERNAL_WAIT_DISPLAY to the captain-facing detail without the event
#   verb. An unchanged observation is silent and performs no write.

_FM_EXTERNAL_WAIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_EXTERNAL_WAIT_LIB_DIR=.
if [ -z "${FM_CLASSIFY_PAUSED_VERB_DEFAULT+x}" ]; then
  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_EXTERNAL_WAIT_LIB_DIR/fm-classify-lib.sh"
fi

FM_EXTERNAL_WAIT_CHANGED=0
FM_EXTERNAL_WAIT_DISPLAY=
FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS_DEFAULT=120
FM_EXTERNAL_WAIT_WORKER_REASON_MAX_DEFAULT=240

fm_external_wait_file_mtime() {  # <file>
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_external_wait_berlin_time() {  # <epoch>
  local epoch=$1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$(uname)" = Darwin ]; then
    TZ=Europe/Berlin date -r "$epoch" '+%Y-%m-%d %H:%M %Z'
  else
    TZ=Europe/Berlin date -d "@$epoch" '+%Y-%m-%d %H:%M %Z'
  fi
}

fm_external_wait_clean_names() {  # <forge-supplied names>
  local clean
  clean=$(printf '%s' "$1" | tr '\t\r\n|' '    ' | tr -d '[:cntrl:]' | tr -s ' ')
  clean=${clean#"${clean%%[![:space:]]*}"}
  clean=${clean%"${clean##*[![:space:]]}"}
  printf '%.600s' "$clean"
}

fm_external_wait_worker_detail() {  # <reason> <status-log>
  local reason=$1 status_log=$2 epoch since max
  case "$reason" in
    'External check running | '*|'External PR checks pending | '*)
      printf '%s' "$reason"
      return 0
      ;;
  esac
  max=${FM_EXTERNAL_WAIT_WORKER_REASON_MAX:-$FM_EXTERNAL_WAIT_WORKER_REASON_MAX_DEFAULT}
  case "$max" in ''|*[!0-9]*) max=$FM_EXTERNAL_WAIT_WORKER_REASON_MAX_DEFAULT ;; esac
  if [ "${#reason}" -gt "$max" ]; then reason="${reason:0:$max}…"; fi
  epoch=$(fm_external_wait_file_mtime "$status_log") || return 1
  since=$(fm_external_wait_berlin_time "$epoch") || return 1
  printf 'External wait | %s | since %s | worker healthy' "$reason" "$since"
}

fm_external_wait_last_event() {  # <status-log>
  [ -f "$1" ] || return 0
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

fm_external_wait_owned_pr_event_seen() {  # <status-log> <pause-verb> <url>
  local log=$1 pause_verb=$2 url=$3 line
  [ -f "$log" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$pause_verb: External check running | "*|"$pause_verb: External PR checks pending | "*)
        case "$line" in *" | $url | "*) return 0 ;; esac
        ;;
      "failed: PR $url external checks failed"*|"failed: PR $url external check status unreadable")
        return 0
        ;;
    esac
  done < "$log"
  return 1
}

fm_external_wait_publish_pr() {  # <state-dir> <task-id> <url> <registration> <observation>
  local state=$1 id=$2 url=$3 registration=$4 observation=$5 kind names epoch since detail event log last pause_verb
  local grace now age
  FM_EXTERNAL_WAIT_CHANGED=0
  FM_EXTERNAL_WAIT_DISPLAY=
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$url" in https://*) ;; *) return 1 ;; esac
  [ -d "$state" ] && [ -f "$registration" ] && [ ! -L "$registration" ] || return 1
  pause_verb=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  log="$state/$id.status"
  last=$(fm_external_wait_last_event "$log")

  kind=${observation%%$'\t'*}
  if [ "$observation" = "$kind" ]; then names=; else names=${observation#*$'\t'}; fi
  names=$(fm_external_wait_clean_names "$names")
  if [ "$kind" = empty ]; then
    grace=${FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS:-$FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS_DEFAULT}
    case "$grace" in ''|*[!0-9]*) return 1 ;; esac
    epoch=$(fm_external_wait_file_mtime "$registration") || return 1
    now=$(date +%s) || return 1
    age=$((now - epoch))
    [ "$age" -ge 0 ] || age=0
    if [ "$age" -lt "$grace" ]; then kind=pending; else kind=none; fi
  fi
  case "$kind" in
    pending)
      epoch=$(fm_external_wait_file_mtime "$registration") || return 1
      since=$(fm_external_wait_berlin_time "$epoch") || return 1
      if [ -n "$names" ]; then
        detail="External check running | $names | $url | since $since | worker finished and healthy"
      else
        detail="External PR checks pending | $url | since $since | worker finished and healthy"
      fi
      event="$pause_verb: $detail"
      ;;
    none)
      detail="PR $url no external checks reported"
      event="done: $detail"
      ;;
    green)
      detail="PR $url checks green"
      event="done: $detail"
      ;;
    merged)
      detail="PR $url merged"
      event="done: $detail"
      # Merge clears any prior wait or recoverable failure this publisher
      # emitted for the same canonical PR, even if another event followed it.
      # A merge with no owned presentation continues through the existing merge
      # notification path without manufacturing another status transition.
      fm_external_wait_owned_pr_event_seen "$log" "$pause_verb" "$url" \
        || { FM_EXTERNAL_WAIT_DISPLAY=$detail; return 0; }
      ;;
    closed)
      detail="PR $url closed before merge"
      event="failed: $detail"
      ;;
    failed)
      if [ -n "$names" ]; then
        detail="PR $url external checks failed | $names"
      else
        detail="PR $url external checks failed"
      fi
      event="failed: $detail"
      ;;
    unreadable)
      detail="PR $url external check status unreadable"
      event="failed: $detail"
      ;;
    *) return 1 ;;
  esac

  # shellcheck disable=SC2034 # Caller reads the sourced library's result globals.
  FM_EXTERNAL_WAIT_DISPLAY=$detail
  [ "$last" != "$event" ] || return 0
  printf '%s\n' "$event" >> "$log" || return 1
  # shellcheck disable=SC2034 # Caller reads the sourced library's result globals.
  FM_EXTERNAL_WAIT_CHANGED=1
}
