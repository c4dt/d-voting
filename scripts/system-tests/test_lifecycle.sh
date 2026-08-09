#!/usr/bin/env bash

set -Eeuo pipefail

# Requirements:
# D-voting system already running
# Development login enabled
# All DELA proxies registered
# Docker
# curl
# jq
#
# Options:
# VOTER1=940001
# VOTER2=940002
# SYSTEM_TEST_URL=http://127.0.0.1:3000
#
# Example:
# ./scripts/system-tests/test_lifecycle.sh

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

login_user() {
    local user="$1"
    local cookie="$2"

    curl -fsS -L \
        -c "$cookie" \
        "${BASE_URL}/api/get_dev_login/${user}" \
        >/dev/null
}

wait_form_status() {
    local expected="$1"

    for ((i = 1; i <= 60; i++)); do
        form="$(api_get "/api/evoting/forms/${FORM_ID}")"
        status="$(jq -r '.Status' <<<"$form")"

        [[ "$status" == "$expected" ]] && return

        sleep 1
    done

    fail "form did not reach status $expected"
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

        curl -fsS \
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

    curl -fsS \
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
            actor="$(curl -fsS \
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
    local container

    container="$(
        docker ps \
            --filter "name=frontend" \
            --format '{{.ID}}' |
            head -n 1
    )"

    [[ -n "$container" ]] || fail "frontend container not found"

    docker exec -i \
        "$container" \
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

const id = Buffer.from('select1').toString('base64');

let encoded =
    answer === 'yes'
        ? `select:${id}:1,0\n\n`
        : `select:${id}:0,1\n\n`;

while (Buffer.byteLength(encoded) < ballotSize) {
    encoded += 'x';
}

const curve = kyber.curve.newCurve('edwards25519');
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

cast_vote() {
    local cookie="$1"
    local ballot="$2"
    local response

    response="$(curl -sS \
        -X POST \
        -H 'Content-Type: application/json' \
        -b "$cookie" \
        --data "$ballot" \
        "${BASE_URL}/api/evoting/forms/${FORM_ID}/vote")"

    assert_transaction_status "$response" "1" "cast vote"
}

check_system
login

login_user "$VOTER1" "$COOKIE1"
login_user "$VOTER2" "$COOKIE2"

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

add_voter "$VOTER1"
add_voter "$VOTER2"

# DKG

info "Setting up DKG"

setup_dkg
pass "DKG ready"

# Open

info "Opening form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"open"}')"

assert_transaction_status "$response" "1" "open form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq "$(jq -r '.Status' <<<"$form")" "1" "form is Open"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
BALLOT_SIZE="$(jq -r '.BallotSize' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

# Vote

info "Casting votes"

BALLOT1="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "yes")"
BALLOT2="$(make_ballot "$PUBKEY" "$BALLOT_SIZE" "$CHUNKS" "no")"

cast_vote "$COOKIE1" "$BALLOT1"
cast_vote "$COOKIE2" "$BALLOT2"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.BallotVoters | length' <<<"$form")" \
    "2" \
    "two ballots stored"

# Close

info "Closing form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"close"}')"

assert_transaction_status "$response" "1" "close form"

wait_form_status "2"
pass "form is Closed"

# Shuffle

info "Shuffling ballots"

status="$(curl -s \
    --max-time 120 \
    -o /dev/null \
    -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data '{"Action":"shuffle"}' \
    "${BASE_URL}/api/evoting/services/shuffle/${FORM_ID}")"

assert_eq "$status" "200" "shuffle ballots"

wait_form_status "3"
pass "ballots shuffled"

# Public shares

info "Computing public shares"

curl -fsS \
    -X PUT \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data '{"Action":"computePubshares"}' \
    "${BASE_URL}/api/evoting/services/dkg/actors/${FORM_ID}" \
    >/dev/null

wait_form_status "4"
pass "public shares submitted"

# Combine shares

info "Combining shares"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"combineShares"}')"

assert_transaction_status "$response" "1" "combine shares"

wait_form_status "5"
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