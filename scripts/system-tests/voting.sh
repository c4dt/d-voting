#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test vote authorization, ballot validation, and revoting rules.
#
# Requirements:
#   - D-voting is running with development login and DELA proxies enabled.
#   - The configured administrator exists.
#   - Frontend dependencies are available locally or in a Docker container.
#   - curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   VOTER1=920001
#   NON_VOTER=920003
#   FRONTEND_CONTAINER=<container name/id>
#
# Test steps:
#   1. Create a form, register a voter, and reject voting before opening.
#   2. Complete DKG setup and open the form.
#   3. Reject unauthenticated, wrong-size, spoofed, and malformed ballots.
#   4. Cast a valid encrypted ballot and verify it is stored.
#   5. Cast a replacement ballot and verify only one effective vote remains.
#   6. Close the form, reject another vote, and delete the form.
#
# Example:
#   ./scripts/system-tests/voting.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VOTER1="${VOTER1:-920001}"
NON_VOTER="${NON_VOTER:-920003}"
FRONTEND_CONTAINER="${FRONTEND_CONTAINER:-}"

TMP_DIR="$(mktemp -d)"
VOTER1_COOKIE="$TMP_DIR/voter1.cookie"
NON_VOTER_COOKIE="$TMP_DIR/nonvoter.cookie"

FORM_ID=""

cleanup() {
    if [[ -n "$FORM_ID" ]]; then
        curl -s \
            -X DELETE \
            -b "$COOKIE_FILE" \
            "${BASE_URL}/api/evoting/forms/${FORM_ID}" \
            >/dev/null 2>&1 || true
    fi

    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

check_system
login

login_cookie "$VOTER1" "$VOTER1_COOKIE"
login_cookie "$NON_VOTER" "$NON_VOTER_COOKIE"

# Create form

info "Creating voting test form"

FORM_JSON="$(jq -cn '
{
    Configuration:{
        Title:{En:"Voting system test", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"subject",
            Title:{En:"Voting", Fr:"", De:"", URL:""},
            Order:["text1"],
            Subjects:[],
            Selects:[],
            Ranks:[],
            Texts:[{
                ID:"text1",
                Title:{En:"Answer", Fr:"", De:"", URL:""},
                MaxN:1,
                MinN:1,
                MaxLength:64,
                Regex:".*",
                Choices:[
                    {Choice:"{\"en\":\"Answer\"}", URL:""}
                ],
                Hint:{En:"", Fr:"", De:""}
            }]
        }],
        AdditionalInfo:""
    }
}')"

response="$(api_post "/api/evoting/forms" "$FORM_JSON")"
FORM_ID="$(jq -r '.FormID // empty' <<<"$response")"

[[ -n "$FORM_ID" ]] || fail "form creation did not return FormID"

assert_transaction_status "$response" "1" "create voting form"

add_voter "$FORM_ID" "$VOTER1"

# Vote before open

info "Voting before form is open"

response="$(api_post_as \
    "$VOTER1_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    '{"Ballot":[]}')"

assert_transaction_status "$response" "2" "vote before open is rejected"

# Setup and open

info "Opening form"

setup_dkg "$FORM_ID"

form_action "$FORM_ID" "open" "1" "open voting form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq "$(jq -r '.Status' <<<"$form")" "1" "form is Open"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
BALLOT_SIZE="$(jq -r '.BallotSize' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

TEXT_ID="$(jq -rn --arg id 'text1' '$id | @base64')"
FIRST_TEXT="$(jq -rn --arg value 'first vote' '$value | @base64')"
SECOND_TEXT="$(jq -rn --arg value 'second vote' '$value | @base64')"
FIRST_ANSWER="text:${TEXT_ID}:${FIRST_TEXT}"$'\n\n'
SECOND_ANSWER="text:${TEXT_ID}:${SECOND_TEXT}"$'\n\n'
BALLOT1="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "$FIRST_ANSWER")"
BALLOT2="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "$SECOND_ANSWER")"

# Unauthenticated

info "Checking unauthenticated vote"

status="$(curl -s \
    --max-time "$CURL_MAX_TIME" \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    "${BASE_URL}/api/evoting/forms/${FORM_ID}/vote" \
    <<<"$BALLOT1")"

assert_eq "$status" "401" "unauthenticated vote is rejected"

# Wrong number of chunks

info "Checking invalid ballot size"

response="$(api_post_as \
    "$VOTER1_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    '{"Ballot":[]}')"

assert_transaction_status "$response" "2" "wrong ballot chunk count is rejected"

# Spoof VoterID

info "Checking voter identity spoofing"

spoofed="$(jq \
    --arg voter "$VOTER1" \
    '. + {VoterID:$voter}' \
    <<<"$BALLOT1")"

response="$(api_post_as \
    "$NON_VOTER_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    "$spoofed")"

assert_transaction_status "$response" "2" "non-voter cannot spoof VoterID"

# Malformed encrypted ballot

info "Checking malformed encrypted ballot"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -b "$VOTER1_COOKIE" \
    --data '{"Ballot":[{"K":[1,2,3],"C":[4,5,6]}]}' \
    "${BASE_URL}/api/evoting/forms/${FORM_ID}/vote")"

if [[ "$status" == "200" ]]; then
    fail "malformed encrypted ballot unexpectedly returned HTTP 200"
fi

pass "malformed encrypted ballot rejected with HTTP $status"

# Valid vote

info "Casting valid vote"

response="$(api_post_as \
    "$VOTER1_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    "$BALLOT1")"

assert_transaction_status "$response" "1" "voter 1 vote accepted"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq -r --arg id "$VOTER1" '.BallotVoters | index($id) != null' <<<"$form")" \
    "true" \
    "voter 1 ballot stored"

# Revote

info "Casting replacement vote"

response="$(api_post_as \
    "$VOTER1_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    "$BALLOT2")"

assert_transaction_status "$response" "1" "voter 1 can revote"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

count="$(jq -r \
    --arg id "$VOTER1" \
    '[.BallotVoters[] | select(. == $id)] | length' \
    <<<"$form")"

assert_eq "$count" "1" "revote keeps one effective ballot per voter"

# Close

info "Closing form"

form_action "$FORM_ID" "close" "1" "close voting form"

# Vote after close

info "Voting after close"

response="$(api_post_as \
    "$VOTER1_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    "$BALLOT1")"

assert_transaction_status "$response" "2" "vote after close is rejected"

# Cleanup

info "Deleting voting test form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"
assert_transaction_status "$response" "1" "delete voting form"

FORM_ID=""
trap - EXIT
rm -rf "$TMP_DIR"

info "Voting system tests completed"
