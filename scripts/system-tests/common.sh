#!/usr/bin/env bash

set -Eeuo pipefail

# All system-test scripts must be run from the repository root.
if [[ "$(git rev-parse --show-toplevel)" != "$(pwd)" ]]; then
    echo "ERROR: system tests must be run from the repository root" >&2
    exit 1
fi

# Load Docker/local configuration when available.
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

BASE_URL="${SYSTEM_TEST_URL:-${FRONT_END_URL:-http://127.0.0.1:3000}}"
ADMIN_ID="${REACT_APP_SCIPER_ADMIN:-123456}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

SYSTEM_TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"
COOKIE_FILE="${SYSTEM_TEST_DIR}/.cookies"

# Output helpers
pass() {
    printf 'PASS: %s\n' "$1"
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

info() {
    printf '\n==> %s\n' "$1"
}


# Environment
check_system() {
    info "Checking system"

    if ! curl -fsS --max-time "$CURL_MAX_TIME" \
        "${BASE_URL}/api/config/proxy" >/dev/null; then
        fail "D-voting is not reachable at ${BASE_URL}"
    fi

    pass "D-voting reachable at ${BASE_URL}"
}

# Authentication
login() {
    local user_id="${1:-$ADMIN_ID}"

    info "Logging in as ${user_id}"

    rm -f "$COOKIE_FILE"

    curl -fsS \
        --max-time "$CURL_MAX_TIME" \
        -L \
        -c "$COOKIE_FILE" \
        "${BASE_URL}/api/get_dev_login/${user_id}" \
        >/dev/null

    if [[ ! -s "$COOKIE_FILE" ]]; then
        fail "login did not create a session cookie"
    fi

    pass "logged in as ${user_id}"
}

logout() {
    curl -fsS \
        --max-time "$CURL_MAX_TIME" \
        -X POST \
        -b "$COOKIE_FILE" \
        "${BASE_URL}/api/logout" \
        >/dev/null || true

    rm -f "$COOKIE_FILE"
}

# HTTP helpers
api_get() {
    local path="$1"

    curl -sS \
        --max-time "$CURL_MAX_TIME" \
        -b "$COOKIE_FILE" \
        "${BASE_URL}${path}"
}

api_post() {
    local path="$1"
    local body="${2:-}"

    if [[ -z "$body" ]]; then
        body='{}'
    fi

    curl -sS \
        --max-time "$CURL_MAX_TIME" \
        -X POST \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data-binary @- \
        "${BASE_URL}${path}" \
        <<<"$body"
}

api_put() {
    local path="$1"
    local body="${2:-}"

    if [[ -z "$body" ]]; then
        body='{}'
    fi

    curl -sS \
        --max-time "$CURL_MAX_TIME" \
        -X PUT \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data-binary @- \
        "${BASE_URL}${path}" \
        <<<"$body"
}

api_delete() {
    local path="$1"

    curl -sS \
        --max-time "$CURL_MAX_TIME" \
        -X DELETE \
        -b "$COOKIE_FILE" \
        "${BASE_URL}${path}"
}

# Make an authenticated request as a user with a separate cookie jar.
login_cookie() {
    local user="$1"
    local cookie="$2"

    curl -fsS \
        --max-time "$CURL_MAX_TIME" \
        -L \
        -c "$cookie" \
        "${BASE_URL}/api/get_dev_login/${user}" \
        >/dev/null
}

api_post_as() {
    local cookie="$1"
    local path="$2"
    local body="${3:-}"

    [[ -n "$body" ]] || body='{}'

    curl -sS \
        --max-time "$CURL_MAX_TIME" \
        -X POST \
        -H 'Content-Type: application/json' \
        -b "$cookie" \
        --data-binary @- \
        "${BASE_URL}${path}" \
        <<<"$body"
}


# Assertions
assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"

    if [[ "$actual" != "$expected" ]]; then
        fail "${message}: expected '${expected}', got '${actual}'"
    fi

    pass "$message"
}

assert_json_field() {
    local json="$1"
    local field="$2"
    local message="$3"

    if ! jq -e "$field" >/dev/null <<<"$json"; then
        fail "${message}: missing ${field}"
    fi

    pass "$message"
}

# Poll a DELA transaction until it is included or rejected
poll_transaction() {
    local token="$1"
    local max_attempts="${TX_MAX_ATTEMPTS:-60}"
    local interval="${TX_POLL_INTERVAL:-1}"
    local response
    local status
    local next_token

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        response="$(api_get "/api/evoting/transactions/${token}")"

        if ! jq -e . >/dev/null 2>&1 <<<"$response"; then
            fail "transaction status returned non-JSON response: $response"
        fi

        status="$(jq -r '.Status // empty' <<<"$response")"

        if [[ -z "$status" ]]; then
            fail "transaction status response has no Status field: $response"
        fi

        next_token="$(jq -r '.Token // empty' <<<"$response")"

        if [[ -n "$next_token" && "$next_token" != "null" ]]; then
            token="$next_token"
        fi

        case "$status" in
            0)
                sleep "$interval"
                ;;
            1|2)
                TX_STATUS="$status"
                TX_RESPONSE="$response"
                return 0
                ;;
            *)
                fail "unexpected transaction status '$status': $response"
                ;;
        esac
    done

    fail "transaction did not finish after ${max_attempts} attempts"
}

# Check the final state of a transaction response
assert_transaction_status() {
    local response="$1"
    local expected="$2"
    local message="$3"
    local token

    token="$(jq -r '.Token // empty' <<<"$response")"

    if [[ -z "$token" || "$token" == "null" ]]; then
        fail "${message}: response did not contain a transaction token"
    fi

    poll_transaction "$token"
    assert_eq "$TX_STATUS" "$expected" "$message"
}


# Shared election setup helpers. Tests keep their scenario assertions locally;
# these functions only remove repeated plumbing.
add_voter() {
    local form_id="$1"
    local voter="$2"
    local response

    response="$(api_post \
        "/api/evoting/auth/forms/${form_id}/addvoter" \
        "$(jq -cn --arg id "$voter" '{TargetUserID:$id}')")"

    assert_transaction_status "$response" "1" "add voter $voter"
}

form_action() {
    local form_id="$1"
    local action="$2"
    local expected="$3"
    local label="$4"
    local response

    response="$(api_put "/api/evoting/forms/${form_id}" \
        "$(jq -cn --arg action "$action" '{Action:$action}')")"
    assert_transaction_status "$response" "$expected" "$label"
}

wait_form_status() {
    local form_id="$1"
    local expected="$2"
    local max_attempts="${3:-60}"
    local interval="${4:-1}"
    local status

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        FORM_RESPONSE="$(api_get "/api/evoting/forms/${form_id}")"
        status="$(jq -r '.Status' <<<"$FORM_RESPONSE")"
        [[ "$status" == "$expected" ]] && return 0
        sleep "$interval"
    done

    fail "form $form_id did not reach status $expected"
}

setup_dkg() {
    local form_id="$1"
    local max_attempts="${2:-30}"
    local form proxy_data node proxy actor status ready request_body

    form="$(api_get "/api/evoting/forms/${form_id}")"
    proxy_data="$(api_get "/api/proxies")"
    mapfile -t roster < <(jq -r '.Roster[]' <<<"$form")
    FORM_PROXIES=()

    for node in "${roster[@]}"; do
        proxy="$(jq -r --arg node "$node" '.Proxies[$node] // empty' <<<"$proxy_data")"
        [[ -n "$proxy" ]] || fail "no proxy for $node"
        FORM_PROXIES+=("$proxy")

        request_body="$(jq -cn --arg id "$form_id" --arg proxy "$proxy" \
            '{FormID:$id, Proxy:$proxy}')"
        curl -fsS --max-time "$CURL_MAX_TIME" \
            -X POST \
            -H 'Content-Type: application/json' \
            -b "$COOKIE_FILE" \
            --data-binary @- \
            "${BASE_URL}/api/evoting/services/dkg/actors" \
            <<<"$request_body" \
            >/dev/null
    done

    request_body="$(jq -cn --arg proxy "${FORM_PROXIES[0]}" \
        '{Action:"setup", Proxy:$proxy}')"
    curl -fsS --max-time "$CURL_MAX_TIME" \
        -X PUT \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data-binary @- \
        "${BASE_URL}/api/evoting/services/dkg/actors/${form_id}" \
        <<<"$request_body" \
        >/dev/null

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        ready=0

        for proxy in "${FORM_PROXIES[@]}"; do
            actor="$(curl -fsS --max-time "$CURL_MAX_TIME" \
                "${proxy}/evoting/services/dkg/actors/${form_id}")"
            status="$(jq -r '.Status' <<<"$actor")"
            [[ "$status" != "2" ]] || fail "DKG failed at $proxy"
            [[ "$status" != "1" && "$status" != "6" ]] || ready=$((ready + 1))
        done

        # An argument-less `return` would reuse the failed `[[ ... ]]` status
        # and make callers exit under `set -e`, even though DKG is ready.
        [[ "$ready" -ne "${#FORM_PROXIES[@]}" ]] || return 0
        sleep 1
    done

    fail "DKG setup timed out"
}

frontend_container() {
    local configured="${FRONTEND_CONTAINER:-}"
    local containers=()

    if [[ -n "$configured" ]]; then
        printf '%s' "$configured"
        return 0
    fi

    if command -v docker >/dev/null; then
        mapfile -t containers < <(
            docker ps --filter 'name=frontend' --format '{{.ID}}' 2>/dev/null
        )
    fi

    ((${#containers[@]} == 0)) || printf '%s' "${containers[0]}"
}

# Print one encrypted ballot per line. The two encoded values alternate, which
# lets load tests generate balanced answers in a single container invocation.
make_ballots() {
    local pubkey="$1"
    local ballot_size="$2"
    local chunks="$3"
    local count="$4"
    local encoded_even="$5"
    local encoded_odd="${6:-$encoded_even}"
    local container
    local runner=()

    container="$(frontend_container)"
    if [[ -n "$container" ]]; then
        runner=(docker exec -i "$container" node -)
    elif command -v node >/dev/null && [[ -d web/frontend/node_modules ]]; then
        runner=(env "NODE_PATH=$REPO_ROOT/web/frontend/node_modules" node -)
    else
        fail "ballot generation needs the frontend container or local frontend dependencies"
    fi

    "${runner[@]}" \
        "$pubkey" "$ballot_size" "$chunks" "$count" \
        "$encoded_even" "$encoded_odd" <<'NODE'
const kyber = require('@dedis/kyber');

const pubKeyHex = process.argv[2];
const ballotSize = Number(process.argv[3]);
const chunks = Number(process.argv[4]);
const count = Number(process.argv[5]);
const values = [process.argv[6], process.argv[7]];
const curve = kyber.curve.newCurve('edwards25519');
const pub = curve.point();
pub.unmarshalBinary(Buffer.from(pubKeyHex, 'hex'));

for (let n = 0; n < count; n++) {
    let encoded = values[n % 2];
    while (Buffer.byteLength(encoded) < ballotSize) encoded += 'x';
    if (Buffer.byteLength(encoded) > ballotSize) {
        throw new Error('encoded ballot is too large');
    }

    const bytes = Buffer.from(encoded);
    const ballot = [];
    for (let i = 0; i < chunks; i++) {
        const M = curve.point().embed(bytes.subarray(i * 29, (i + 1) * 29));
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
}

make_ballot() {
    make_ballots "$1" "$2" "$3" 1 "$4"
}

cast_vote() {
    local cookie="$1"
    local form_id="$2"
    local ballot="$3"
    local label="${4:-cast vote}"
    local response

    response="$(api_post_as "$cookie" "/api/evoting/forms/${form_id}/vote" "$ballot")"
    assert_transaction_status "$response" "1" "$label"
}

shuffle_form() {
    local form_id="$1"
    local timeout_seconds="$2"
    local output_file="${3:-/dev/null}"

    curl -sS \
        --max-time "$timeout_seconds" \
        -o "$output_file" \
        -w '%{http_code}' \
        -X PUT \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data '{"Action":"shuffle"}' \
        "${BASE_URL}/api/evoting/services/shuffle/${form_id}"
}

compute_pubshares() {
    local form_id="$1"

    curl -fsS --max-time "$CURL_MAX_TIME" \
        -X PUT \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data '{"Action":"computePubshares"}' \
        "${BASE_URL}/api/evoting/services/dkg/actors/${form_id}" \
        >/dev/null
}
