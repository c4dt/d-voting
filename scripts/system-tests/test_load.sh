#!/usr/bin/env bash

set -Eeuo pipefail

# Requirements:
# D-voting system already running
# Development login enabled
# All DELA proxies registered
#
#
# Options:
# VOTES=300
# START_VOTER=950000
# BATCH_SIZE=10
# SHUFFLE_TIMEOUT=180
# SYSTEM_TEST_URL=http://127.0.0.1:3000
#
# Examples:
# ./scripts/system-tests/test_load.sh
# VOTES=500 ./scripts/system-tests/test_load.sh
# VOTES=1000 BATCH_SIZE=20 ./scripts/system-tests/test_load.sh

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

wait_tx() {
    local response="$1"
    local label="$2"
    local token

    token="$(jq -r '.Token // empty' <<<"$response")"

    [[ -n "$token" ]] || fail "$label did not return transaction token"

    poll_transaction "$token"

    [[ "$TX_STATUS" == "1" ]] || fail "$label was rejected"
}

wait_form_status() {
    local expected="$1"

    for ((i = 1; i <= 120; i++)); do
        form="$(api_get "/api/evoting/forms/${FORM_ID}")"
        status="$(jq -r '.Status' <<<"$form")"

        [[ "$status" == "$expected" ]] && return

        sleep 1
    done

    fail "form did not reach status $expected"
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

        status="$(curl -sS \
            -o "$body_file" \
            -w '%{http_code}' \
            -X POST \
            -H 'Content-Type: application/json' \
            -b "$COOKIE_FILE" \
            --data "$(jq -cn --arg id "$voter" '{TargetUserID:$id}')" \
            "${BASE_URL}/api/evoting/auth/forms/${FORM_ID}/addvoter")"

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

setup_dkg
pass "DKG ready"

# Open

info "Opening form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"open"}')"

assert_transaction_status "$response" "1" "open load form"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

PUBKEY="$(jq -r '.Pubkey' <<<"$form")"
BALLOT_SIZE="$(jq -r '.BallotSize' <<<"$form")"
CHUNKS="$(jq -r '.ChunksPerBallot' <<<"$form")"

# Generate encrypted ballots using the frontend's Kyber library

info "Generating $VOTES encrypted ballots"

FRONTEND_CONTAINER="$(
    docker ps \
        --filter "name=frontend" \
        --format '{{.ID}}' |
        head -n 1
)"

[[ -n "$FRONTEND_CONTAINER" ]] || fail "frontend container not found"

mapfile -t BALLOTS < <(
    docker exec -i \
        "$FRONTEND_CONTAINER" \
        node - \
        "$PUBKEY" \
        "$BALLOT_SIZE" \
        "$CHUNKS" \
        "$VOTES" <<'NODE'
const kyber = require('@dedis/kyber');

const pubKeyHex = process.argv[2];
const ballotSize = Number(process.argv[3]);
const chunks = Number(process.argv[4]);
const count = Number(process.argv[5]);

const curve = kyber.curve.newCurve('edwards25519');

const pub = curve.point();
pub.unmarshalBinary(Buffer.from(pubKeyHex, 'hex'));

const id = Buffer.from('select1').toString('base64');

for (let n = 0; n < count; n++) {
    let encoded =
        n % 2 === 0
            ? `select:${id}:1,0\n\n`
            : `select:${id}:0,1\n\n`;

    while (Buffer.byteLength(encoded) < ballotSize) {
        encoded += 'x';
    }

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

    console.log(JSON.stringify({Ballot: ballot}));
}
NODE
)

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

        curl -fsS -L \
            -c "$voter_cookie" \
            "${BASE_URL}/api/get_dev_login/${voter}" \
            >/dev/null

        response="$(curl -sS \
            -X POST \
            -H 'Content-Type: application/json' \
            -b "$voter_cookie" \
            --data "${BALLOTS[$index]}" \
            "${BASE_URL}/api/evoting/forms/${FORM_ID}/vote")"

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

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"close"}')"

assert_transaction_status "$response" "1" "close load form"

wait_form_status "2"

# Shuffle

info "Shuffling $VOTES ballots"

shuffle_start="$(date +%s)"

status="$(curl -s \
    --max-time "$SHUFFLE_TIMEOUT" \
    -o "$TMP_DIR/shuffle.out" \
    -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data '{"Action":"shuffle"}' \
    "${BASE_URL}/api/evoting/services/shuffle/${FORM_ID}")"

assert_eq "$status" "200" "shuffle load election"

wait_form_status "3"

shuffle_seconds=$(( $(date +%s) - shuffle_start ))

pass "shuffled $VOTES ballots in ${shuffle_seconds}s"

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

# Combine

info "Decrypting ballots"

decrypt_start="$(date +%s)"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"combineShares"}')"

assert_transaction_status "$response" "1" "combine public shares"

wait_form_status "5"

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