#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test when ballot shuffling is rejected and accepted.
#
# Requirements:
#   - D-voting is running with development login and DELA proxies enabled.
#   - The configured administrator exists.
#   - Frontend dependencies are available locally or in a Docker container.
#   - curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   VOTER1=930001
#   VOTER2=930002
#   SHUFFLE_TIMEOUT=120
#
# Test steps:
#   1. Create a form, register two voters, complete DKG, and open it.
#   2. Reject shuffling while the form is open.
#   3. Cast and verify two encrypted votes.
#   4. Close the form and successfully request a shuffle.
#   5. Verify the shuffled status and delete the form.
#
# Example:
#   SHUFFLE_TIMEOUT=240 ./scripts/system-tests/shuffle.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VOTER1="${VOTER1:-930001}"
VOTER2="${VOTER2:-930002}"
SHUFFLE_TIMEOUT="${SHUFFLE_TIMEOUT:-120}"

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

# Create form

info "Creating shuffle test form"

FORM_JSON="$(jq -cn '
{
    Configuration:{
        Title:{En:"Shuffle system test", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"subject",
            Title:{En:"Shuffle test", Fr:"", De:"", URL:""},
            Order:["select"],
            Ranks:[],
            Selects:[{
                ID:"select",
                Title:{En:"Choose", Fr:"", De:"", URL:""},
                MaxN:1,
                MinN:1,
                Choices:[
                    {Choice:"{\"en\":\"yes\"}", URL:""},
                    {Choice:"{\"en\":\"no\"}", URL:""}
                ],
                Hint:{En:"", Fr:"", De:""}
            }],
            Texts:[],
            Subjects:[]
        }],
        AdditionalInfo:""
    }
}')"

response="$(api_post "/api/evoting/forms" "$FORM_JSON")"
FORM_ID="$(jq -r '.FormID // empty' <<<"$response")"

[[ -n "$FORM_ID" ]] || fail "form creation did not return FormID"

assert_transaction_status "$response" "1" "create shuffle form"

add_voter "$FORM_ID" "$VOTER1"
add_voter "$FORM_ID" "$VOTER2"

# DKG and open

info "Preparing form"

setup_dkg "$FORM_ID"

form_action "$FORM_ID" "open" "1" "open form"

# Shuffle while open

info "Trying to shuffle open form"

status="$(shuffle_form "$FORM_ID" "$SHUFFLE_TIMEOUT" "$TMP_DIR/shuffle-response")"

if [[ "$status" == "200" ]]; then
    fail "shuffle unexpectedly succeeded while form was Open"
fi

pass "shuffle while Open is rejected with HTTP $status"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"
assert_eq "$(jq -r '.Status' <<<"$form")" "1" "form remains Open"

# Cast two votes

info "Casting votes"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
BALLOT_SIZE="$(jq -r '.BallotSize' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

BALLOT1="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" $'shuffle-one\n\n')"
BALLOT2="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" $'shuffle-two\n\n')"

cast_vote "$COOKIE1" "$FORM_ID" "$BALLOT1"
cast_vote "$COOKIE2" "$FORM_ID" "$BALLOT2"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.BallotVoters | length' <<<"$form")" \
    "2" \
    "two votes stored"

# Close

info "Closing form"

form_action "$FORM_ID" "close" "1" "close form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"
assert_eq "$(jq -r '.Status' <<<"$form")" "2" "form is Closed"

# Shuffle

info "Shuffling ballots"

status="$(shuffle_form "$FORM_ID" "$SHUFFLE_TIMEOUT" "$TMP_DIR/shuffle-response")"

assert_eq "$status" "200" "shuffle request succeeds"

# Verify final state

wait_form_status "$FORM_ID" "3" 30
pass "form reaches ShuffledBallots"

# Delete

info "Deleting shuffle test form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"
assert_transaction_status "$response" "1" "delete shuffle form"

FORM_ID=""
trap - EXIT
rm -rf "$TMP_DIR"

info "Shuffle system tests completed"
