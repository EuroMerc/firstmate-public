#!/usr/bin/env bash
# Shared visible presentation for declared external waits.
#
# A worker-declared `paused:` event and a validated PR-poll observation both
# render through this owner so current-state readers, fleet views, and the
# worker-facing direct-PR contract use one captain-facing vocabulary.
# Timestamps remain canonical: a worker wait uses the status-log mtime, while a
# PR wait stores its transition epoch and validated forge head in the existing
# identity-bound poll registration (initial pending starts at registration).
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
#   Accept one observation from fm-pr-poll.sh --observe-phase-validated, the
#   production form that carries the validated forge head phase continuity
#   needs (--observe-validated is the head-less diagnostic form, and an
#   observation without a head can never bind or change a phase head). Each
#   observation is <kind>, optionally followed by <TAB><validated head or ->
#   and <TAB><qualifier>:
#     pending (qualifier: comma-separated pending check names)
#     empty (GitHub reported no checks; registration-age grace decides pending)
#     none (GitHub reported no checks once the startup grace expired)
#     no-pipeline (GitLab's head pipeline is absent, or `skipped` when the
#       qualifier says so, and neither is merge-ready)
#     green
#     merged
#     closed
#     failed (qualifier: comma-separated failed check names)
#     unreadable
#   `empty` stays pending for FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS (default
#   120) from the registration mtime, then becomes a truthful no-checks result.
#   An unreadable observation is a gap in reading the same check run rather than
#   the end of a wait, so for the same head it keeps the interrupted phase whole
#   - a pending phase keeps its published start, and a startup grace keeps both
#   its epoch and its remaining time. A structured observation proving a
#   different head, or pending after any other publisher state, starts a new
#   phase; an unknown head never does. A proven different head starts its phase
#   epoch at that observation even when the observation itself was unreadable,
#   so the new head keeps its own startup grace and a truthful start.
#   Append a standard paused/done/failed event only when its normalized
#   registration-bound fingerprint changes (or a validated new head starts a
#   phase), so an unrelated worker event and a silent same-head re-arm both keep
#   an unchanged observation silent and keep the published start stamp. Sets
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
# any worker event that landed in between.
fm_external_wait_owned_pr_last_event() {  # <status-log> <pause-verb> <url>
  local log=$1 pause_verb=$2 url=$3 line match=
  [ -f "$log" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$pause_verb: External check running | "*|"$pause_verb: External PR checks pending | "*)
        case "$line" in *" | $url | "*) match=$line ;; esac
        ;;
      "failed: PR $url external check status unreadable")
        match=$line
        ;;
      "done: PR $url merged"|"done: PR $url checks green"|\
      "done: PR $url no external checks reported"|\
      "failed: PR $url closed before merge"|\
      "failed: PR $url external checks failed"|"failed: PR $url external checks failed | "*|\
      "failed: PR $url no pipeline reported, not merge-ready"|\
      "failed: PR $url pipeline skipped, not merge-ready")
        match=$line
        ;;
    esac
  done < "$log"
  [ -n "$match" ] || return 1
  printf '%s\n' "$match"
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
      "failed: PR $url no pipeline reported, not merge-ready"|\
      "failed: PR $url pipeline skipped, not merge-ready")
        return 0
        ;;
    esac
  done < "$log"
  return 1
}

# 0 when the status-log line is one this publisher wrote for a validated
# canonical PR URL. Provenance is the exact published form plus a URL that
# re-parses to itself, never a label prefix, so a worker's own prose can never
# be mistaken for a publisher event and the answer survives poll retirement.
fm_external_wait_pr_event_is_publisher_owned() {  # <status-line>
  local line=$1 pause_verb head url
  pause_verb=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  case "$line" in
    "$pause_verb: External check running | "*" | worker finished and healthy"|\
    "$pause_verb: External PR checks pending | "*" | worker finished and healthy")
      case "$line" in *" | since "*) ;; *) return 1 ;; esac
      head=${line%" | since "*}
      url=${head##*" | "}
      ;;
    "done: PR "*|"failed: PR "*)
      head=${line#*": PR "}
      url=${head%% *}
      case "$line" in
        "done: PR $url merged"|"done: PR $url checks green"|\
        "done: PR $url no external checks reported"|\
        "failed: PR $url closed before merge"|\
        "failed: PR $url external checks failed"|"failed: PR $url external checks failed | "*|\
        "failed: PR $url external check status unreadable"|\
        "failed: PR $url no pipeline reported, not merge-ready"|\
        "failed: PR $url pipeline skipped, not merge-ready") ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  declare -F fm_pr_url_parse >/dev/null || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_URL" = "$url" ]
}

# The crew's own most recent status event, skipping every event this publisher
# wrote for the task. A firstmate-published PR wait is presentation about the
# forge, never evidence about what the pane's foreground call is doing, so the
# watcher's declared-wait cadence must read the crew's own last declaration
# rather than whichever line landed last.
fm_external_wait_worker_last_status_line() {  # <status-log>
  local f=$1 line match=
  [ -e "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    fm_external_wait_pr_event_is_publisher_owned "$line" && continue
    match=$line
  done < "$f"
  [ -n "$match" ] || return 0
  printf '%s\n' "$match"
}

fm_external_wait_publish_pr() {  # <state-dir> <task-id> <url> <registration> <observation>
  local state=$1 id=$2 url=$3 registration=$4 observation=$5 kind rest observed_head names
  local epoch since detail event log pause_verb grace now age owned_last signature record_kind
  local phase_head phase_kind phase_epoch phase_signature next_head next_epoch head_changed=0 phase_changed=0
  FM_EXTERNAL_WAIT_CHANGED=0
  FM_EXTERNAL_WAIT_DISPLAY=
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$url" in https://*) ;; *) return 1 ;; esac
  [ -d "$state" ] && [ -f "$registration" ] && [ ! -L "$registration" ] || return 1
  declare -F fm_pr_poll_registration_parse >/dev/null \
    && declare -F fm_pr_poll_registration_phase_update >/dev/null \
    && declare -F fm_pr_sha256_text >/dev/null || return 1
  fm_pr_poll_registration_parse "$registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] && [ "$FM_PR_REG_URL" = "$url" ] || return 1
  phase_head=$FM_PR_REG_PHASE_HEAD
  phase_kind=$FM_PR_REG_PHASE_KIND
  phase_epoch=$FM_PR_REG_PHASE_EPOCH
  phase_signature=$FM_PR_REG_PHASE_SIGNATURE
  pause_verb=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  log="$state/$id.status"

  kind=${observation%%$'\t'*}
  observed_head=-
  names=
  if [ "$observation" != "$kind" ]; then
    rest=${observation#*$'\t'}
    if [ "$rest" != "${rest%%$'\t'*}" ]; then
      observed_head=${rest%%$'\t'*}
      names=${rest#*$'\t'}
      [ "$observed_head" = - ] || fm_pr_head_valid "$observed_head" || observed_head=-
    else
      # Backward-compatible test and migration input has names but no head.
      names=$rest
    fi
  fi
  names=$(fm_external_wait_clean_names "$names")
  next_head=$phase_head
  if [ "$observed_head" != - ]; then
    if [ "$phase_head" = - ]; then
      next_head=$observed_head
      phase_changed=1
    elif [ "$phase_head" != "$observed_head" ]; then
      next_head=$observed_head
      head_changed=1
      phase_changed=1
    fi
  fi

  record_kind=$kind
  if [ "$kind" = empty ]; then
    grace=${FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS:-$FM_EXTERNAL_WAIT_CHECK_START_GRACE_SECS_DEFAULT}
    case "$grace" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s) || return 1
    # The startup grace is a one-way phase: it opens once per head and can only
    # be re-entered by a proven different head, so a same-head rollup that has
    # already resolved to no-checks stays no-checks instead of oscillating. An
    # unreadable tick is a gap in the same phase, not the end of one, so it
    # neither reopens the grace nor cuts the remaining time short.
    epoch=
    if [ "$head_changed" -eq 1 ]; then
      epoch=$now
    elif { [ "$phase_kind" = empty-pending ] || [ "$phase_kind" = unreadable ]; } \
      && [ "$phase_epoch" -gt 0 ]; then
      epoch=$phase_epoch
    elif [ "$phase_kind" = unset ]; then
      epoch=$(fm_external_wait_file_mtime "$registration") || return 1
    fi
    if [ -z "$epoch" ]; then
      kind=none
      record_kind=none
    else
      age=$((now - epoch))
      [ "$age" -ge 0 ] || age=0
      if [ "$age" -lt "$grace" ]; then
        kind=pending
        record_kind=empty-pending
      else
        kind=none
        record_kind=none
      fi
    fi
  fi

  next_epoch=0
  case "$kind" in
    pending)
      if [ "$record_kind" = empty-pending ]; then
        next_epoch=$epoch
      elif [ "$head_changed" -eq 0 ] && [ "$phase_epoch" -gt 0 ] \
        && { [ "$phase_kind" = pending ] || [ "$phase_kind" = empty-pending ] || [ "$phase_kind" = unreadable ]; }; then
        next_epoch=$phase_epoch
      elif [ "$phase_kind" = unset ] && [ "$head_changed" -eq 0 ]; then
        next_epoch=$(fm_external_wait_file_mtime "$registration") || return 1
      else
        next_epoch=$(date +%s) || return 1
      fi
      since=$(fm_external_wait_berlin_time "$next_epoch") || return 1
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
      if [ "$names" = skipped ]; then
        detail="PR $url pipeline skipped, not merge-ready"
      else
        detail="PR $url no pipeline reported, not merge-ready"
      fi
      event="failed: $detail"
      ;;
    green)
      detail="PR $url checks green"
      event="done: $detail"
      ;;
    merged)
      detail="PR $url merged"
      event="done: $detail"
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
      if [ "$head_changed" -eq 1 ]; then
        next_epoch=$(date +%s) || return 1
      else
        next_epoch=$phase_epoch
        record_kind=$phase_kind
      fi
      detail="PR $url external check status unreadable"
      event="failed: $detail"
      ;;
    *) return 1 ;;
  esac

  # shellcheck disable=SC2034 # Caller reads the sourced library's result globals.
  FM_EXTERNAL_WAIT_DISPLAY=$detail
  case "$kind" in merged|closed) ;;
    *)
      signature=$(fm_pr_sha256_text "$kind"$'\t'"$names") || return 1
      if [ "$signature" != "$phase_signature" ] || [ "$head_changed" -eq 1 ]; then
        printf '%s\n' "$event" >> "$log" || return 1
        # shellcheck disable=SC2034 # Caller reads the sourced library's result globals.
        FM_EXTERNAL_WAIT_CHANGED=1
      fi
      if [ "$next_head" != "$phase_head" ] || [ "$record_kind" != "$phase_kind" ] \
        || [ "$next_epoch" != "$phase_epoch" ] || [ "$signature" != "$phase_signature" ]; then
        phase_changed=1
      fi
      if [ "$phase_changed" -eq 1 ]; then
        fm_pr_poll_registration_phase_update "$registration" "$next_head" "$record_kind" \
          "$next_epoch" "$signature" || return 1
      fi
      return 0
      ;;
  esac

  owned_last=$(fm_external_wait_owned_pr_last_event "$log" "$pause_verb" "$url") || owned_last=
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
