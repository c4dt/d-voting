#!/usr/bin/env bash

set -Eeuo pipefail

# Requirements:
# D-voting system already running
# Development login enabled
#
# Options:
# VOTER1=930001
# VOTER2=930002
# SHUFFLE_TIMEOUT=120
# SYSTEM_TEST_URL=http://127.0.0.1:3000
#
# Example:
# ./scripts/system-tests/test_shuffle.sh

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

login_user() {
    local user="$1"
    local cookie="$2"

    curl -fsS -L \
        -c "$cookie" \
        "${BASE_URL}/api/get_dev_login/${user}" \
        >/dev/null
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
    local node
    local proxy
    local actor
    local status
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
    local chunks="$2"
    local container

    container="$(
        docker ps \
            --filter "name=frontend" \
            --format '{{.ID}}' |
            head -n 1
    )"

    [[ -n "$container" ]] || fail "frontend container not found"

    docker exec -i "$container" node - "$pubkey" "$chunks" <<'NODE'
const kyber = require('@dedis/kyber');

const pubKeyHex = process.argv[2];
const chunks = Number(process.argv[3]);

const curve = kyber.curve.newCurve('edwards25519');

const pub = curve.point();
pub.unmarshalBinary(Buffer.from(pubKeyHex, 'hex'));

const ballot = [];

for (let i = 0; i < chunks; i++) {
    const M = curve.point().embed(Buffer.from(`vote-${i}`));

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

shuffle_request() {
    curl -s \
        --max-time "$SHUFFLE_TIMEOUT" \
        -o "$TMP_DIR/shuffle-response" \
        -w '%{http_code}' \
        -X PUT \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data '{"Action":"shuffle"}' \
        "${BASE_URL}/api/evoting/services/shuffle/${FORM_ID}"
}

check_system
login

login_user "$VOTER1" "$COOKIE1"
login_user "$VOTER2" "$COOKIE2"

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

add_voter "$VOTER1"
add_voter "$VOTER2"

# DKG and open

info "Preparing form"

setup_dkg

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"open"}')"

assert_transaction_status "$response" "1" "open form"

# Shuffle while open

info "Trying to shuffle open form"

status="$(shuffle_request)"

if [[ "$status" == "200" ]]; then
    fail "shuffle unexpectedly succeeded while form was Open"
fi

pass "shuffle while Open is rejected with HTTP $status"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"
assert_eq "$(jq -r '.Status' <<<"$form")" "1" "form remains Open"

# Cast two votes

info "Casting votes"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

BALLOT1="$(make_ballot "$PUBKEY" "$CHUNKS")"
BALLOT2="$(make_ballot "$PUBKEY" "$CHUNKS")"

cast_vote "$COOKIE1" "$BALLOT1"
cast_vote "$COOKIE2" "$BALLOT2"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq \
    "$(jq '.BallotVoters | length' <<<"$form")" \
    "2" \
    "two votes stored"

# Close

info "Closing form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"close"}')"

assert_transaction_status "$response" "1" "close form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"
assert_eq "$(jq -r '.Status' <<<"$form")" "2" "form is Closed"

# Shuffle

info "Shuffling ballots"

status="$(shuffle_request)"

assert_eq "$status" "200" "shuffle request succeeds"

# Verify final state

for ((attempt = 1; attempt <= 30; attempt++)); do
    form="$(api_get "/api/evoting/forms/${FORM_ID}")"
    form_status="$(jq -r '.Status' <<<"$form")"

    [[ "$form_status" == "3" ]] && break

    sleep 1
done

assert_eq "$form_status" "3" "form reaches ShuffledBallots"

# Delete

info "Deleting shuffle test form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"
assert_transaction_status "$response" "1" "delete shuffle form"

FORM_ID=""
trap - EXIT
rm -rf "$TMP_DIR"

info "Shuffle system tests completed"