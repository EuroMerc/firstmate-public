#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=f6441c96c352a18b9cadcaef6b6c7017e9ac3970
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'
WORKFLOW_EVENTS=
WORKFLOW_ACTION=

load_workflow_contract() {
  local contract kind value
  if command -v ruby >/dev/null 2>&1; then
    contract=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
trigger = doc["on"] || doc[true]
pull_request = trigger.fetch("pull_request")
pull_request.fetch("types").each { |event| puts "event\t#{event}" }
step = doc.fetch("jobs").fetch("check").fetch("steps").find { |candidate|
  candidate.is_a?(Hash) && candidate.key?("uses")
}
raise "check job has no action step" if step.nil?
puts "action\t#{step.fetch("uses")}"
' "$WORKFLOW") || fail "could not normalize the no-mistakes workflow contract with Ruby YAML"
  elif python3 -c 'import yaml' >/dev/null 2>&1; then
    contract=$(python3 - "$WORKFLOW" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as workflow_file:
    document = yaml.safe_load(workflow_file)
trigger = document.get("on") or document.get(True)
pull_request = trigger["pull_request"]
for event in pull_request["types"]:
    print(f"event\t{event}")
step = next(candidate for candidate in document["jobs"]["check"]["steps"] if "uses" in candidate)
print(f'action\t{step["uses"]}')
PY
    ) || fail "could not normalize the no-mistakes workflow contract with Python YAML"
  else
    fail "Ruby YAML or Python PyYAML is required to normalize the workflow contract"
  fi

  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      event)
        WORKFLOW_EVENTS="${WORKFLOW_EVENTS}${WORKFLOW_EVENTS:+
}${value}"
        ;;
      action) WORKFLOW_ACTION=$value ;;
      *) fail "unknown normalized workflow field: $kind" ;;
    esac
  done <<EOF
$contract
EOF
}

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

attestation_body() {
  local head=$1
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":%s} -->\n' \
    "$SIGNATURE" "$head" "$COMPLETED_STEPS"
}

workflow_dispatches_event() {
  local wanted=$1 configured
  while IFS= read -r configured; do
    [ "$configured" = "$wanted" ] && return 0
  done <<EOF
$WORKFLOW_EVENTS
EOF
  return 1
}

run_workflow_event() {
  local event=$1 body=$2 head=$3
  if ! workflow_dispatches_event "$event"; then
    printf 'not-dispatched\n'
    return 0
  fi
  run_verifier "$body" "$head"
}

test_workflow_and_action_publish_the_same_event_contract() {
  local actual expected
  actual=$(printf '%s\n' "$WORKFLOW_EVENTS" | LC_ALL=C sort)
  expected=$(printf '%s\n' edited opened reopened)
  [ "$actual" = "$expected" ] \
    || fail "workflow events must be exactly opened, edited, and reopened; got: $actual"
  [ "$WORKFLOW_ACTION" = "kunchenguid/no-mistakes/.github/actions/require-no-mistakes@$ACTION_REF" ] \
    || fail "workflow does not invoke the verifier pinned by this regression: $WORKFLOW_ACTION"
  pass "workflow and pinned shared action use opened, edited, and reopened"
}

test_existing_pr_push_waits_for_body_update() {
  local old_body new_body output rc
  old_body=$(attestation_body "$OLD_SHA")
  new_body=$(attestation_body "$NEW_SHA")

  rc=0
  output=$(run_workflow_event opened "$old_body" "$OLD_SHA") || rc=$?
  expect_code 0 "$rc" "opened event rejected the matching initial attestation"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "opened event did not execute the pinned verifier"

  rc=0
  output=$(run_verifier "$old_body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "stale pre-update body unexpectedly matched the pushed head"
  assert_contains "$output" "$OLD_SHA" \
    "stale-body counterfactual did not exercise the old attestation head"
  assert_contains "$output" "$NEW_SHA" \
    "stale-body counterfactual did not exercise the newly pushed head"

  rc=0
  output=$(run_workflow_event synchronize "$old_body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "synchronize event unexpectedly ran the head-bound verifier"
  [ "$output" = "not-dispatched" ] \
    || fail "synchronize pinned a verifier verdict before the PR body update: $output"

  rc=0
  output=$(run_workflow_event edited "$new_body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "edited event rejected the updated head-bound attestation"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "edited event did not execute the pinned verifier after the body update"

  rc=0
  output=$(run_workflow_event reopened "$new_body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "reopened event rejected the current head-bound attestation"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "reopened event did not execute the pinned verifier"
  pass "existing PR pushes do not pin a stale-body failure before edited validates the new head"
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

load_workflow_contract
fetch_shared_verifier
test_workflow_and_action_publish_the_same_event_contract
test_existing_pr_push_waits_for_body_update
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
