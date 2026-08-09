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

SYSTEM_TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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

    if ! curl -fsS "${BASE_URL}/api/config/proxy" >/dev/null; then
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
        -X POST \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data "$body" \
        "${BASE_URL}${path}"
}

api_put() {
    local path="$1"
    local body="${2:-}"

    if [[ -z "$body" ]]; then
        body='{}'
    fi

    curl -sS \
        -X PUT \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data "$body" \
        "${BASE_URL}${path}"
}

api_delete() {
    local path="$1"

    curl -sS \
        -X DELETE \
        -b "$COOKIE_FILE" \
        "${BASE_URL}${path}"
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
                return
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