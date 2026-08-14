#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test the complete election lifecycle under a configurable voter load.
#
# Requirements:
#   - D-voting is running with development login and DELA proxies enabled.
#   - The configured administrator exists.
#   - Frontend dependencies are available locally or in a Docker container.
#   - curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   VOTES=300
#   START_VOTER=950000
#   BATCH_SIZE=10
#   SHUFFLE_TIMEOUT=180
#
# Test steps:
#   1. Create a yes/no form and register the configured number of voters.
#   2. Complete DKG setup and open the form.
#   3. Generate and cast alternating encrypted yes/no ballots in batches.
#   4. Verify the stored ballot count and unique voter count.
#   5. Close and shuffle all ballots.
#   6. Compute public shares, decrypt, and verify every expected result.
#   7. Delete the form and print operation timings.
#
# Example:
#   VOTES=513 BATCH_SIZE=20 ./scripts/system-tests/load.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VOTES="${VOTES:-300}"
START_VOTER="${START_VOTER:-950000}"
BATCH_SIZE="${BATCH_SIZE:-10}"
SHUFFLE_TIMEOUT="${SHUFFLE_TIMEOUT:-180}"

FORM_ID=""
TMP_DIR="$(mktemp -d)"

END_VOTER=$((START_VOTER + VOTES - 1))

if (( VOTES < 2 )); then
    fail "VOTES must be at least 2"
fi

if (( START_VOTER < 100000 || END_VOTER > 999999 )); then
    fail "generated voter IDs must stay between 100000 and 999999"
fi

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

# Create form

info "Creating load-test form"

FORM_JSON="$(jq -cn '
{
    Configuration:{
        Title:{En:"Load system test", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"subject",
            Title:{En:"Load test", Fr:"", De:"", URL:""},
            Order:["select1"],
            Subjects:[],
            Selects:[{
                ID:"select1",
                Title:{En:"Choose", Fr:"", De:"", URL:""},
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

assert_transaction_status "$response" "1" "create load form"

# Add voters

info "Adding $VOTES voters"

for ((start = 0; start < VOTES; start += BATCH_SIZE)); do
    tokens=()

    for ((j = 0; j < BATCH_SIZE && start + j < VOTES; j++)); do
        voter=$((START_VOTER + start + j))

        body_file="$TMP_DIR/add-voter-response"
        request_body="$(jq -cn --arg id "$voter" '{TargetUserID:$id}')"

        status="$(curl -sS \
            --max-time "$CURL_MAX_TIME" \
            -o "$body_file" \
            -w '%{http_code}' \
            -X POST \
            -H 'Content-Type: application/json' \
            -b "$COOKIE_FILE" \
            --data-binary @- \
            "${BASE_URL}/api/evoting/auth/forms/${FORM_ID}/addvoter" \
            <<<"$request_body")"

        response="$(cat "$body_file")"

        if [[ "$status" != "200" ]]; then
            fail "adding voter $voter failed with HTTP $status: $response"
        fi

        if ! token="$(jq -er '.Token' <<<"$response" 2>/dev/null)"; then
            fail "adding voter $voter returned invalid response: $response"
        fi

        tokens+=("$token")
    done

    for token in "${tokens[@]}"; do
        poll_transaction "$token"

        if [[ "$TX_STATUS" != "1" ]]; then
            fail "add voter transaction rejected: $TX_RESPONSE"
        fi
    done

    done_count=$((start + BATCH_SIZE))
    (( done_count > VOTES )) && done_count="$VOTES"

    printf 'Added %d/%d voters\n' "$done_count" "$VOTES"
done

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.Voters | length' <<<"$form")" \
    "$VOTES" \
    "$VOTES voters registered"

# DKG

info "Setting up DKG"

setup_dkg "$FORM_ID"
pass "DKG ready"

# Open

info "Opening form"

form_action "$FORM_ID" "open" "1" "open load form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
BALLOT_SIZE="$(jq -r '.BallotSize' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

# Generate encrypted ballots using the frontend's Kyber library

info "Generating $VOTES encrypted ballots"

SELECT_ID="$(jq -rn --arg id 'select1' '$id | @base64')"
YES_ANSWER="select:${SELECT_ID}:1,0"$'\n\n'
NO_ANSWER="select:${SELECT_ID}:0,1"$'\n\n'
mapfile -t BALLOTS < <(make_ballots \
    "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "$VOTES" \
    "$YES_ANSWER" "$NO_ANSWER")

assert_eq "${#BALLOTS[@]}" "$VOTES" "$VOTES ballots generated"

# Cast votes

info "Casting $VOTES votes"

start_time="$(date +%s)"

for ((start = 0; start < VOTES; start += BATCH_SIZE)); do
    tokens=()

    for ((j = 0; j < BATCH_SIZE && start + j < VOTES; j++)); do
        index=$((start + j))
        voter=$((START_VOTER + index))
        voter_cookie="$TMP_DIR/voter-${voter}.cookie"

        login_cookie "$voter" "$voter_cookie"

        response="$(api_post_as \
            "$voter_cookie" \
            "/api/evoting/forms/${FORM_ID}/vote" \
            "${BALLOTS[$index]}")"

        token="$(jq -r '.Token // empty' <<<"$response")"

        [[ -n "$token" ]] || fail "vote $((index + 1)) returned no token"

        tokens+=("$token")

        rm -f "$voter_cookie"
    done

    for token in "${tokens[@]}"; do
        poll_transaction "$token"
        [[ "$TX_STATUS" == "1" ]] || fail "vote transaction was rejected"
    done

    done_count=$((start + BATCH_SIZE))
    (( done_count > VOTES )) && done_count="$VOTES"

    printf 'Cast %d/%d votes\n' "$done_count" "$VOTES"
done

vote_seconds=$(( $(date +%s) - start_time ))

pass "$VOTES votes accepted in ${vote_seconds}s"

# Verify ballots

info "Checking stored ballots"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.BallotVoters | length' <<<"$form")" \
    "$VOTES" \
    "$VOTES ballots stored"

unique_voters="$(jq '[.BallotVoters[]] | unique | length' <<<"$form")"

assert_eq "$unique_voters" "$VOTES" "all ballot voters are unique"

# Close

info "Closing form"

form_action "$FORM_ID" "close" "1" "close load form"

wait_form_status "$FORM_ID" "2" 120

# Shuffle

info "Shuffling $VOTES ballots"

shuffle_start="$(date +%s)"

status="$(shuffle_form "$FORM_ID" "$SHUFFLE_TIMEOUT" "$TMP_DIR/shuffle.out")"

assert_eq "$status" "200" "shuffle load election"

wait_form_status "$FORM_ID" "3" 120

shuffle_seconds=$(( $(date +%s) - shuffle_start ))

pass "shuffled $VOTES ballots in ${shuffle_seconds}s"

# Public shares

info "Computing public shares"

compute_pubshares "$FORM_ID"

wait_form_status "$FORM_ID" "4" 120

# Combine

info "Decrypting ballots"

decrypt_start="$(date +%s)"

form_action "$FORM_ID" "combineShares" "1" "combine public shares"

wait_form_status "$FORM_ID" "5" 120

decrypt_seconds=$(( $(date +%s) - decrypt_start ))

# Verify results

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.Result | length' <<<"$form")" \
    "$VOTES" \
    "$VOTES ballots decrypted"

expected_yes=$(((VOTES + 1) / 2))
expected_no=$((VOTES / 2))

yes_votes="$(
    jq '
        [.Result[] | select(.SelectResult[0] == [true, false])]
        | length
    ' <<<"$form"
)"

no_votes="$(
    jq '
        [.Result[] | select(.SelectResult[0] == [false, true])]
        | length
    ' <<<"$form"
)"

assert_eq "$yes_votes" "$expected_yes" "yes results correct"
assert_eq "$no_votes" "$expected_no" "no results correct"

pass "decrypted $VOTES ballots in ${decrypt_seconds}s"

# Delete

info "Deleting load-test form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"
assert_transaction_status "$response" "1" "delete load form"

FORM_ID=""
trap - EXIT
rm -rf "$TMP_DIR"

info "Load system test completed"
printf 'Votes:      %d\n' "$VOTES"
printf 'Casting:    %ds\n' "$vote_seconds"
printf 'Shuffling:  %ds\n' "$shuffle_seconds"
printf 'Decrypting: %ds\n' "$decrypt_seconds"
