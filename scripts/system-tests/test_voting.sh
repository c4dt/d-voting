#!/usr/bin/env bash

set -Eeuo pipefail

# Requirements:
# D-voting system already running
# Development login enabled
#
# Options:
# VOTER1=920001
# VOTER2=920002
# NON_VOTER=920003
# FRONTEND_CONTAINER=<container name/id>
# SYSTEM_TEST_URL=http://127.0.0.1:3000
#
# Example:
# ./scripts/system-tests/test_voting.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

VOTER1="${VOTER1:-920001}"
VOTER2="${VOTER2:-920002}"
NON_VOTER="${NON_VOTER:-920003}"
FRONTEND_CONTAINER="${FRONTEND_CONTAINER:-}"

TMP_DIR="$(mktemp -d)"
VOTER1_COOKIE="$TMP_DIR/voter1.cookie"
VOTER2_COOKIE="$TMP_DIR/voter2.cookie"
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

login_cookie() {
    local user="$1"
    local cookie="$2"

    curl -fsS -L \
        -c "$cookie" \
        "${BASE_URL}/api/get_dev_login/${user}" \
        >/dev/null
}

post_as() {
    local cookie="$1"
    local path="$2"
    local body="$3"

    curl -sS \
        -X POST \
        -H 'Content-Type: application/json' \
        -b "$cookie" \
        --data "$body" \
        "${BASE_URL}${path}"
}

add_voter() {
    local voter="$1"
    local response

    response="$(api_post \
        "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
        "$(jq -cn --arg id "$voter" '{TargetUserID:$id}')")"

    assert_transaction_status "$response" "1" "add voter $voter"
}

setup_dkg() {
    local form
    local proxy_data
    local proxy
    local ready

    form="$(api_get "/api/evoting/forms/${FORM_ID}")"
    proxy_data="$(api_get "/api/proxies")"

    mapfile -t roster < <(jq -r '.Roster[]' <<<"$form")

    proxies=()

    for node in "${roster[@]}"; do
        proxy="$(jq -r \
            --arg node "$node" \
            '.Proxies[$node] // empty' \
            <<<"$proxy_data")"

        [[ -n "$proxy" ]] || fail "no proxy for $node"
        proxies+=("$proxy")
    done

    for proxy in "${proxies[@]}"; do
        curl -sS \
            -X POST \
            -H 'Content-Type: application/json' \
            -b "$COOKIE_FILE" \
            --data "$(jq -cn \
                --arg id "$FORM_ID" \
                --arg proxy "$proxy" \
                '{FormID:$id, Proxy:$proxy}')" \
            "${BASE_URL}/api/evoting/services/dkg/actors" \
            >/dev/null
    done

    curl -sS \
        -X PUT \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data "$(jq -cn \
            --arg proxy "${proxies[0]}" \
            '{Action:"setup", Proxy:$proxy}')" \
        "${BASE_URL}/api/evoting/services/dkg/actors/${FORM_ID}" \
        >/dev/null

    for ((attempt = 1; attempt <= 30; attempt++)); do
        ready=0

        for proxy in "${proxies[@]}"; do
            actor="$(curl -sS \
                "${proxy}/evoting/services/dkg/actors/${FORM_ID}")"

            status="$(jq -r '.Status' <<<"$actor")"

            [[ "$status" != "2" ]] || fail "DKG failed at $proxy"

            if [[ "$status" == "1" || "$status" == "6" ]]; then
                ready=$((ready + 1))
            fi
        done

        [[ "$ready" -eq "${#proxies[@]}" ]] && return

        sleep 1
    done

    fail "DKG setup timed out"
}

make_ballot() {
    local pubkey="$1"
    local ballot_size="$2"
    local chunks="$3"
    local answer="$4"

    docker exec -i \
        "$FRONTEND_CONTAINER" \
        node - \
        "$pubkey" \
        "$ballot_size" \
        "$chunks" \
        "$answer" <<'NODE'
const kyber = require('@dedis/kyber');

const pubKeyHex = process.argv[2];
const ballotSize = Number(process.argv[3]);
const chunks = Number(process.argv[4]);
const answer = process.argv[5];

const curve = kyber.curve.newCurve('edwards25519');
const questionID = Buffer.from('text1').toString('base64');

let encoded =
    `text:${questionID}:${Buffer.from(answer).toString('base64')}\n\n`;

while (Buffer.byteLength(encoded) < ballotSize) {
    encoded += 'x';
}

if (Buffer.byteLength(encoded) > ballotSize) {
    throw new Error('encoded ballot is too large');
}

const pub = curve.point();
pub.unmarshalBinary(Buffer.from(pubKeyHex, 'hex'));

const ballot = [];

for (let i = 0; i < chunks; i++) {
    const chunk = encoded.substring(i * 29, (i + 1) * 29);

    const M = curve.point().embed(Buffer.from(chunk));
    const k = curve.scalar().pick();
    const K = curve.point().mul(k, null);
    const S = curve.point().mul(k, pub);
    const C = S.add(S, M);

    ballot.push({
        K: Array.from(K.marshalBinary()),
        C: Array.from(C.marshalBinary())
    });
}

process.stdout.write(JSON.stringify({Ballot: ballot}));
NODE
}

check_system
login

login_cookie "$VOTER1" "$VOTER1_COOKIE"
login_cookie "$VOTER2" "$VOTER2_COOKIE"
login_cookie "$NON_VOTER" "$NON_VOTER_COOKIE"

if [[ -z "$FRONTEND_CONTAINER" ]]; then
    FRONTEND_CONTAINER="$(
        docker ps \
            --filter "name=frontend" \
            --format '{{.ID}}' |
            head -n 1
    )"
fi

[[ -n "$FRONTEND_CONTAINER" ]] || fail "frontend container not found"

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

add_voter "$VOTER1"
add_voter "$VOTER2"

# Vote before open

info "Voting before form is open"

response="$(post_as \
    "$VOTER1_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    '{"Ballot":[]}')"

assert_transaction_status "$response" "2" "vote before open is rejected"

# Setup and open

info "Opening form"

setup_dkg

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"open"}')"

assert_transaction_status "$response" "1" "open voting form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq "$(jq -r '.Status' <<<"$form")" "1" "form is Open"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
BALLOT_SIZE="$(jq -r '.BallotSize' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

BALLOT1="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "first vote")"
BALLOT2="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "second vote")"

# Unauthenticated

info "Checking unauthenticated vote"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "$BALLOT1" \
    "${BASE_URL}/api/evoting/forms/${FORM_ID}/vote")"

assert_eq "$status" "401" "unauthenticated vote is rejected"

# Wrong number of chunks

info "Checking invalid ballot size"

response="$(post_as \
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

response="$(post_as \
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

response="$(post_as \
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

response="$(post_as \
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

# Second voter

info "Casting second voter ballot"

response="$(post_as \
    "$VOTER2_COOKIE" \
    "/api/evoting/forms/${FORM_ID}/vote" \
    "$BALLOT1")"

assert_transaction_status "$response" "1" "voter 2 vote accepted"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.BallotVoters | length' <<<"$form")" \
    "2" \
    "two effective voters stored"

# Close

info "Closing form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"close"}')"

assert_transaction_status "$response" "1" "close voting form"

# Vote after close

info "Voting after close"

response="$(post_as \
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