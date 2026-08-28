#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# Its legacy --validated and sidecar forms emit exactly one `merged` line for a
# merged PR or MR and stay silent otherwise, including on every error.
# The watcher uses --observe-validated with the same validated identity to emit
# one structural observation: merged, green, unreadable, or pending/failed plus
# sanitized concrete check names after one tab when the forge supplies them.
# It never waits or loops; bin/fm-watch.sh owns cadence and the shared external-
# wait presentation owner deduplicates unchanged observations.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

observe=0
if [ "$#" -eq 6 ] && { [ "$1" = --validated ] || [ "$1" = --observe-validated ]; }; then
  [ "$1" = --observe-validated ] && observe=1
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    if [ "$observe" -eq 0 ]; then
      state=$(gh pr view "$url" --json state -q .state 2>/dev/null) || exit 0
      [ "$state" = MERGED ] && printf '%s\n' merged
      exit 0
    fi
    # gh applies this jq expression before returning output, so raw forge JSON
    # never enters fleet state. Names are control-stripped, pipe-neutralized,
    # bounded, and limited before they cross the process boundary.
    # shellcheck disable=SC2016 # The single-quoted program is gh's jq expression.
    observation=$(gh pr view "$url" --json state,statusCheckRollup -q '
      .state as $pr
      | [(.statusCheckRollup // [])[]
          | if .__typename == "CheckRun" then
              {name:(.name // ""), pending:(.status != "COMPLETED"),
               failed:(.status == "COMPLETED" and ((.conclusion // "") | IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE","STALE")))}
            elif .__typename == "StatusContext" then
              {name:(.context // ""), pending:(.state == "PENDING" or .state == "EXPECTED"),
               failed:((.state // "") | IN("ERROR","FAILURE"))}
            else {name:"",pending:false,failed:false} end
        ] as $checks
      | def names($which):
          [$checks[] | select(.[$which]) | .name
           | gsub("[\\u0000-\\u001f\\u007f|]"; " ")
           | gsub("^[ ]+|[ ]+$"; "") | .[:120] | select(length > 0)][0:5]
          | join(", ");
      if $pr == "MERGED" then "merged"
      elif $pr == "CLOSED" then "failed\tpull request closed before merge"
      elif any($checks[]; .failed) then "failed\t" + names("failed")
      elif any($checks[]; .pending) then "pending\t" + names("pending")
      else "green" end
    ' 2>/dev/null) || { printf '%s\n' unreadable; exit 0; }
    case "$observation" in
      '') ;;
      merged|green|unreadable|pending|pending$'\t'*|failed|failed$'\t'*) printf '%s\n' "$observation" ;;
      *) printf '%s\n' unreadable ;;
    esac
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab receives the validated host both as GITLAB_HOST and in the project
    # URL passed to -R, so it never falls through to a configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(GITLAB_HOST="$host" glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || {
      [ "$observe" -eq 0 ] || printf '%s\n' unreadable
      exit 0
    }
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    if [ "$state" = merged ]; then
      printf '%s\n' merged
      exit 0
    fi
    [ "$observe" -eq 1 ] || exit 0
    [ "$state" = opened ] || { printf 'failed\tmerge request closed before merge\n'; exit 0; }
    pipeline=$(printf '%s\n' "$raw" | sed -n 's/^pipeline:[[:space:]]*//p' | head -1)
    case "$pipeline" in
      success|passed) printf '%s\n' green ;;
      failed|canceled|cancelled|skipped|manual) printf 'failed\t%s\n' "pipeline $pipeline" ;;
      *) printf '%s\n' pending ;;
    esac
    ;;
  *) exit 0 ;;
esac
exit 0
