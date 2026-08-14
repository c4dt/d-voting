#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test a complete election from creation through decrypted results.
#
# Requirements:
#   - D-voting is running with development login and DELA proxies enabled.
#   - The configured administrator exists.
#   - Frontend dependencies are available locally or in a Docker container.
#   - curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   VOTER1=940001
#   VOTER2=940002
#
# Test steps:
#   1. Create a yes/no form and register two voters.
#   2. Complete DKG setup and open the form.
#   3. Cast one yes and one no vote, then verify both are stored.
#   4. Close and shuffle the election.
#   5. Compute and combine public shares.
#   6. Verify both decrypted answers and delete the form.
#
# Example:
#   ./scripts/system-tests/lifecycle.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VOTER1="${VOTER1:-940001}"
VOTER2="${VOTER2:-940002}"

FORM_ID=""
TMP_DIR="$(mktemp -d)"

COOKIE1="$TMP_DIR/voter1.cookie"
COOKIE2="$TMP_DIR/voter2.cookie"

cleanup() {
    if [[ -n "$FORM_ID" ]]; then
        curl -s -X DELETE -b "$COOKIE_FILE" \
            "${BASE_URL}/api/evoting/forms/${FORM_ID}" \
            >/dev/null 2>&1 || true
    fi

    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

check_system
login

login_cookie "$VOTER1" "$COOKIE1"
login_cookie "$VOTER2" "$COOKIE2"

# Create

info "Creating form"

FORM_JSON="$(jq -cn '
{
    Configuration:{
        Title:{En:"Lifecycle system test", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"subject",
            Title:{En:"Question", Fr:"", De:"", URL:""},
            Order:["select1"],
            Subjects:[],
            Selects:[{
                ID:"select1",
                Title:{En:"Yes or no?", Fr:"", De:"", URL:""},
                MaxN:1,
                MinN:1,
                Choices:[
                    {Choice:"{\"en\":\"yes\"}", URL:""},
                    {Choice:"{\"en\":\"no\"}", URL:""}
                ],
                Hint:{En:"", Fr:"", De:""}
            }],
            Ranks:[],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

response="$(api_post "/api/evoting/forms" "$FORM_JSON")"
FORM_ID="$(jq -r '.FormID // empty' <<<"$response")"

[[ -n "$FORM_ID" ]] || fail "form creation did not return FormID"

assert_transaction_status "$response" "1" "create form"

# Voters

info "Adding voters"

add_voter "$FORM_ID" "$VOTER1"
add_voter "$FORM_ID" "$VOTER2"

# DKG

info "Setting up DKG"

setup_dkg "$FORM_ID"
pass "DKG ready"

# Open

info "Opening form"

form_action "$FORM_ID" "open" "1" "open form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq "$(jq -r '.Status' <<<"$form")" "1" "form is Open"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
BALLOT_SIZE="$(jq -r '.BallotSize' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

# Vote

info "Casting votes"

SELECT_ID="$(jq -rn --arg id 'select1' '$id | @base64')"
YES_ANSWER="select:${SELECT_ID}:1,0"$'\n\n'
NO_ANSWER="select:${SELECT_ID}:0,1"$'\n\n'
BALLOT1="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "$YES_ANSWER")"
BALLOT2="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "$NO_ANSWER")"

cast_vote "$COOKIE1" "$FORM_ID" "$BALLOT1"
cast_vote "$COOKIE2" "$FORM_ID" "$BALLOT2"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.BallotVoters | length' <<<"$form")" \
    "2" \
    "two ballots stored"

# Close

info "Closing form"

form_action "$FORM_ID" "close" "1" "close form"

wait_form_status "$FORM_ID" "2"
pass "form is Closed"

# Shuffle

info "Shuffling ballots"

status="$(shuffle_form "$FORM_ID" 120)"

assert_eq "$status" "200" "shuffle ballots"

wait_form_status "$FORM_ID" "3"
pass "ballots shuffled"

# Public shares

info "Computing public shares"

compute_pubshares "$FORM_ID"

wait_form_status "$FORM_ID" "4"
pass "public shares submitted"

# Combine shares

info "Combining shares"

form_action "$FORM_ID" "combineShares" "1" "combine shares"

wait_form_status "$FORM_ID" "5"
pass "result available"

# Verify result

info "Checking result"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.Result | length' <<<"$form")" \
    "2" \
    "two ballots decrypted"

yes_votes="$(
    jq '
        [
            .Result[]
            | select(.SelectResult[0] == [true, false])
        ]
        | length
    ' <<<"$form"
)"

no_votes="$(
    jq '
        [
            .Result[]
            | select(.SelectResult[0] == [false, true])
        ]
        | length
    ' <<<"$form"
)"

assert_eq "$yes_votes" "1" "yes vote decrypted correctly"
assert_eq "$no_votes" "1" "no vote decrypted correctly"

# Delete

info "Deleting form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"
assert_transaction_status "$response" "1" "delete form"

FORM_ID=""
trap - EXIT

rm -rf "$TMP_DIR"

info "Full lifecycle system test completed"
