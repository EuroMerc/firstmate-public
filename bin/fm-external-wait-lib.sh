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
#     none (GitHub reported no checks once the startup grace expired)
#     no-pipeline (GitLab has no head pipeline, so it is not merge-ready)
#     green
#     merged
#     closed
#     failed<TAB><optional comma-separated failed check names>
#     unreadable
#   `empty` stays pending for FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS (default
#   120) from the registration mtime, then becomes a truthful no-checks result.
#   An unreadable observation is a gap in reading the same check run rather than
#   the end of a wait, so a pending phase interrupted by one keeps its published
#   start; every other publisher state, and a registration re-armed for a later
#   head, starts a new phase.
#   Append a standard paused/done/failed event only when its state differs from
#   the most recent event this publisher itself wrote for the same canonical PR,
#   so an unrelated worker event in between and a silent re-arm both keep an
#   unchanged observation silent and keep the published start stamp. Sets
#   FM_EXTERNAL_WAIT_CHANGED to 1 or 0 and FM_EXTERNAL_WAIT_DISPLAY to the
#   captain-facing detail without the event verb. An unchanged observation is
#   silent and performs no write.

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
FM_EXTERNAL_WAIT_PR_NAMES_MAX=600
FM_EXTERNAL_WAIT_PR_URL_MAX=400
# One multibyte character, so a bound can tell a character-aware locale from a
# byte-oriented one instead of assuming either.
_FM_EXTERNAL_WAIT_UTF8_PROBE=$'\303\274'

# Bound a display string to <max> characters without ever leaving a split
# multibyte sequence in persistent state, whatever the ambient locale is.
fm_external_wait_cut_display() {  # <text> <max-characters>
  local text=$1 max=$2 byte probe expected drop
  local lead='' trailing=0
  # Below the bound the value is returned unchanged, so no locale can alter a
  # string this owner did not truncate.
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
    return 0
  fi
  text=${text:0:$max}
  if [ "${#_FM_EXTERNAL_WAIT_UTF8_PROBE}" -eq 1 ]; then
    printf '%s' "$text"
    return 0
  fi
  # The cut above counted bytes, so drop at most the one sequence it split.
  probe=$text
  while [ -n "$probe" ] && [ "$trailing" -le 3 ]; do
    byte=$(printf '%s' "${probe: -1}" | od -An -tu1 | tr -d ' \n')
    case "$byte" in ''|*[!0-9]*) break ;; esac
    [ "$byte" -ge 128 ] || break
    if [ "$byte" -ge 192 ]; then
      lead=$byte
      break
    fi
    trailing=$((trailing + 1))
    probe=${probe%?}
  done
  if [ -n "$lead" ]; then
    if [ "$lead" -ge 240 ]; then expected=4
    elif [ "$lead" -ge 224 ]; then expected=3
    else expected=2
    fi
    if [ "$((trailing + 1))" -ne "$expected" ]; then
      drop=$((trailing + 1))
      while [ "$drop" -gt 0 ] && [ -n "$text" ]; do
        text=${text%?}
        drop=$((drop - 1))
      done
    fi
  fi
  printf '%s' "$text"
}

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
  fm_external_wait_cut_display "$clean" "$FM_EXTERNAL_WAIT_PR_NAMES_MAX"
}

# A publisher-written PR wait is structurally complete: a pipe-free bounded
# name list, one validated absolute URL, and one Europe/Berlin start stamp.
# Worker prose that merely imitates the label fails this and stays bounded.
fm_external_wait_pr_detail_valid() {  # <detail>
  local detail=$1 rest names url since zone
  case "$detail" in
    'External check running | '*' | worker finished and healthy')
      rest=${detail#'External check running | '}
      rest=${rest%' | worker finished and healthy'}
      case "$rest" in *' | since '*) ;; *) return 1 ;; esac
      since=${rest##*' | since '}
      rest=${rest%' | since '*}
      case "$rest" in *' | '*) ;; *) return 1 ;; esac
      url=${rest##*' | '}
      names=${rest%' | '*}
      ;;
    'External PR checks pending | '*' | worker finished and healthy')
      rest=${detail#'External PR checks pending | '}
      rest=${rest%' | worker finished and healthy'}
      case "$rest" in *' | since '*) ;; *) return 1 ;; esac
      since=${rest##*' | since '}
      url=${rest%' | since '*}
      names=
      ;;
    *) return 1 ;;
  esac
  case "$names" in *'|'*) return 1 ;; esac
  [ "${#names}" -le "$FM_EXTERNAL_WAIT_PR_NAMES_MAX" ] || return 1
  case "$url" in https://*) ;; *) return 1 ;; esac
  case "$url" in *[[:space:]]*|*'|'*) return 1 ;; esac
  [ "${#url}" -le "$FM_EXTERNAL_WAIT_PR_URL_MAX" ] || return 1
  case "$since" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]' '*) ;;
    *) return 1 ;;
  esac
  zone=${since##* }
  case "${since% *}" in *' '*' '*) return 1 ;; esac
  case "$zone" in ''|*[!A-Za-z0-9+-]*) return 1 ;; esac
  [ "${#zone}" -le 8 ] || return 1
}

fm_external_wait_worker_detail() {  # <reason> <status-log>
  local reason=$1 status_log=$2 epoch since max
  case "$reason" in
    'External check running | '*|'External PR checks pending | '*)
      if fm_external_wait_pr_detail_valid "$reason"; then
        printf '%s' "$reason"
        return 0
      fi
      ;;
  esac
  max=${FM_EXTERNAL_WAIT_WORKER_REASON_MAX:-$FM_EXTERNAL_WAIT_WORKER_REASON_MAX_DEFAULT}
  case "$max" in ''|*[!0-9]*) max=$FM_EXTERNAL_WAIT_WORKER_REASON_MAX_DEFAULT ;; esac
  if [ "${#reason}" -gt "$max" ]; then
    reason="$(fm_external_wait_cut_display "$reason" "$max")…"
  fi
  epoch=$(fm_external_wait_file_mtime "$status_log") || return 1
  since=$(fm_external_wait_berlin_time "$epoch") || return 1
  printf 'External wait | %s | since %s | worker healthy' "$reason" "$since"
}

# The signature of a publisher-written event without its start stamp, so an
# identical transition stays one transition even when the start display would
# be re-derived from a rewritten registration.
fm_external_wait_pr_event_signature() {  # <event-line>
  case "$1" in
    *' | since '*' | worker finished and healthy')
      printf '%s' "${1%' | since '*} | worker finished and healthy"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# The most recent event this publisher wrote for this canonical PR, ignoring
# any worker event that landed in between. With <ignore-unreadable> the
# unreadable form is skipped, which yields the state the observed check run was
# actually in rather than the last failed read of it.
fm_external_wait_owned_pr_last_event() {  # <status-log> <pause-verb> <url> [ignore-unreadable]
  local log=$1 pause_verb=$2 url=$3 ignore_unreadable=${4:-0} line match=
  [ -f "$log" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$pause_verb: External check running | "*|"$pause_verb: External PR checks pending | "*)
        case "$line" in *" | $url | "*) match=$line ;; esac
        ;;
      "failed: PR $url external check status unreadable")
        [ "$ignore_unreadable" = 1 ] || match=$line
        ;;
      "done: PR $url merged"|"done: PR $url checks green"|\
      "done: PR $url no external checks reported"|\
      "failed: PR $url closed before merge"|\
      "failed: PR $url external checks failed"|"failed: PR $url external checks failed | "*|\
      "failed: PR $url no pipeline reported, not merge-ready")
        match=$line
        ;;
    esac
  done < "$log"
  [ -n "$match" ] || return 1
  printf '%s\n' "$match"
}

fm_external_wait_epoch_from_display() {  # <YYYY-MM-DD HH:MM ZONE>
  local display=$1
  case "$display" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]' '*) ;;
    *) return 1 ;;
  esac
  if [ "$(uname)" = Darwin ]; then
    TZ=Europe/Berlin date -j -f '%Y-%m-%d %H:%M %Z' "$display" +%s 2>/dev/null
  else
    TZ=Europe/Berlin date -d "$display" +%s 2>/dev/null
  fi
}

# A re-arm rewrites the validated registration, which is also how a later head
# is recorded, so a registration newer than the running phase means the wait
# restarted. An unparsable start keeps the published phase rather than
# inventing a newer one.
fm_external_wait_phase_restarted() {  # <registration> <published-since>
  local registration=$1 since=$2 armed started
  armed=$(fm_external_wait_file_mtime "$registration") || return 1
  case "$armed" in ''|*[!0-9]*) return 1 ;; esac
  started=$(fm_external_wait_epoch_from_display "$since") || return 1
  case "$started" in ''|*[!0-9]*) return 1 ;; esac
  [ "$armed" -gt "$((started + 60))" ]
}

fm_external_wait_owned_pr_event_seen() {  # <status-log> <pause-verb> <url>
  local log=$1 pause_verb=$2 url=$3 line
  [ -f "$log" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$pause_verb: External check running | "*|"$pause_verb: External PR checks pending | "*)
        case "$line" in *" | $url | "*) return 0 ;; esac
        ;;
      "failed: PR $url closed before merge"|\
      "failed: PR $url external checks failed"*|"failed: PR $url external check status unreadable"|\
      "failed: PR $url no pipeline reported, not merge-ready")
        return 0
        ;;
    esac
  done < "$log"
  return 1
}

fm_external_wait_publish_pr() {  # <state-dir> <task-id> <url> <registration> <observation>
  local state=$1 id=$2 url=$3 registration=$4 observation=$5 kind names epoch since detail event log pause_verb
  local grace now age owned_last owned_phase owned_since
  FM_EXTERNAL_WAIT_CHANGED=0
  FM_EXTERNAL_WAIT_DISPLAY=
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$url" in https://*) ;; *) return 1 ;; esac
  [ -d "$state" ] && [ -f "$registration" ] && [ ! -L "$registration" ] || return 1
  pause_verb=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  log="$state/$id.status"
  owned_last=$(fm_external_wait_owned_pr_last_event "$log" "$pause_verb" "$url") || owned_last=
  owned_phase=$(fm_external_wait_owned_pr_last_event "$log" "$pause_verb" "$url" 1) || owned_phase=
  owned_since=
  case "$owned_phase" in
    *' | since '*' | worker finished and healthy')
      owned_since=${owned_phase%' | worker finished and healthy'}
      owned_since=${owned_since##*' | since '}
      ;;
  esac

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
      if [ -n "$owned_since" ] \
        && { [ "$owned_last" = "$owned_phase" ] \
             || ! fm_external_wait_phase_restarted "$registration" "$owned_since"; }; then
        # A still-running wait keeps the start it was first published with, so
        # neither a silent re-arm nor an unreadable read of it can move that
        # start. Only a registration re-armed after the phase began, which is
        # how a later head is recorded, ends it.
        since=$owned_since
      elif [ -n "$owned_last" ]; then
        # A pending phase that follows one of this publisher's non-pending
        # states began at this transition, not at the older arming time.
        now=$(date +%s) || return 1
        since=$(fm_external_wait_berlin_time "$now") || return 1
      else
        epoch=$(fm_external_wait_file_mtime "$registration") || return 1
        since=$(fm_external_wait_berlin_time "$epoch") || return 1
      fi
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
    no-pipeline)
      detail="PR $url no pipeline reported, not merge-ready"
      event="failed: $detail"
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
  if [ -n "$owned_last" ] && [ "$(fm_external_wait_pr_event_signature "$event")" \
      = "$(fm_external_wait_pr_event_signature "$owned_last")" ]; then
    # shellcheck disable=SC2034 # Caller reads the sourced library's result globals.
    FM_EXTERNAL_WAIT_DISPLAY=${owned_last#*': '}
    return 0
  fi
  printf '%s\n' "$event" >> "$log" || return 1
  # shellcheck disable=SC2034 # Caller reads the sourced library's result globals.
  FM_EXTERNAL_WAIT_CHANGED=1
}
