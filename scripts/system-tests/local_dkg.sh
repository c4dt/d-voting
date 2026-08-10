#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test DKG actor initialization, validation, and setup.
#
# Requirements:
#   - D-voting is running with development login enabled.
#   - The administrator exists and all DELA proxies are registered.
#   - curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   DKG_POLL_INTERVAL=1
#   DKG_MAX_ATTEMPTS=30
#
# Test steps:
#   1. Create a form and resolve every roster node to its proxy.
#   2. Verify an uninitialized actor is absent.
#   3. Reject initialization without a proxy and setup before initialization.
#   4. Initialize every actor and test duplicate initialization.
#   5. Reject an invalid DKG action, then complete DKG setup.
#   6. Open the form, verify its public key, and delete it.
#
# Example:
#   DKG_MAX_ATTEMPTS=60 ./scripts/system-tests/local_dkg.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DKG_POLL_INTERVAL="${DKG_POLL_INTERVAL:-1}"
DKG_MAX_ATTEMPTS="${DKG_MAX_ATTEMPTS:-30}"

FORM_ID=""

cleanup() {
    if [[ -n "$FORM_ID" ]]; then
        curl -s \
            -X DELETE \
            -b "$COOKIE_FILE" \
            "${BASE_URL}/api/evoting/forms/${FORM_ID}" \
            >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

check_system
login

# Create form
info "Creating DKG test form"

FORM_JSON="$(jq -cn '
{
    Configuration:{
        Title:{En:"DKG system test", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"subject",
            Title:{En:"Subject", Fr:"", De:"", URL:""},
            Order:["select"],
            Subjects:[],
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
            Ranks:[],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

response="$(api_post "/api/evoting/forms" "$FORM_JSON")"
FORM_ID="$(jq -r '.FormID // empty' <<<"$response")"

[[ -n "$FORM_ID" ]] || fail "form creation did not return FormID"

assert_transaction_status "$response" "1" "create DKG test form"

# Find the proxies belonging to the form roster
info "Reading roster proxies"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"
proxy_data="$(api_get "/api/proxies")"

mapfile -t ROSTER < <(jq -r '.Roster[]' <<<"$form")

PROXIES=()

for node in "${ROSTER[@]}"; do
    proxy="$(jq -r --arg node "$node" '.Proxies[$node] // empty' <<<"$proxy_data")"

    [[ -n "$proxy" ]] || fail "no proxy mapping for roster node $node"

    PROXIES+=("$proxy")
done

pass "found ${#PROXIES[@]} roster proxies"

FIRST_PROXY="${PROXIES[0]}"

# Actor should not exist yet
info "Checking uninitialized actor"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    "${FIRST_PROXY}/evoting/services/dkg/actors/${FORM_ID}")"

assert_eq "$status" "404" "DKG actor does not exist before initialization"

# Proxy is required
info "Checking missing proxy"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data "$(jq -cn --arg id "$FORM_ID" '{FormID:$id}')" \
    "${BASE_URL}/api/evoting/services/dkg/actors")"

assert_eq "$status" "400" "DKG init without proxy is rejected"

# Setup before initialization
info "Checking setup before initialization"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data "$(jq -cn \
        --arg proxy "$FIRST_PROXY" \
        '{Action:"setup", Proxy:$proxy}')" \
    "${BASE_URL}/api/evoting/services/dkg/actors/${FORM_ID}")"

if [[ "$status" == "200" ]]; then
    fail "DKG setup unexpectedly succeeded before initialization"
fi

pass "setup before initialization is rejected"

# Initialize all actors
info "Initializing DKG actors"

for proxy in "${PROXIES[@]}"; do
    status="$(curl -s \
        -o /dev/null \
        -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/json' \
        -b "$COOKIE_FILE" \
        --data "$(jq -cn \
            --arg id "$FORM_ID" \
            --arg proxy "$proxy" \
            '{FormID:$id, Proxy:$proxy}')" \
        "${BASE_URL}/api/evoting/services/dkg/actors")"

    assert_eq "$status" "200" "initialize actor at $proxy"

    actor="$(curl -s "${proxy}/evoting/services/dkg/actors/${FORM_ID}")"
    assert_eq "$(jq -r '.Status' <<<"$actor")" "0" "actor is Initialized"
done

# Duplicate initialization should be harmless
info "Initializing an actor twice"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data "$(jq -cn \
        --arg id "$FORM_ID" \
        --arg proxy "$FIRST_PROXY" \
        '{FormID:$id, Proxy:$proxy}')" \
    "${BASE_URL}/api/evoting/services/dkg/actors")"

assert_eq "$status" "200" "duplicate initialization is accepted"

# Invalid action
info "Checking invalid DKG action"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data "$(jq -cn \
        --arg proxy "$FIRST_PROXY" \
        '{Action:"invalid", Proxy:$proxy}')" \
    "${BASE_URL}/api/evoting/services/dkg/actors/${FORM_ID}")"

if [[ "$status" == "200" ]]; then
    fail "invalid DKG action unexpectedly succeeded"
fi

pass "invalid DKG action is rejected"

# Setup DKG
info "Setting up DKG"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: application/json' \
    -b "$COOKIE_FILE" \
    --data "$(jq -cn \
        --arg proxy "$FIRST_PROXY" \
        '{Action:"setup", Proxy:$proxy}')" \
    "${BASE_URL}/api/evoting/services/dkg/actors/${FORM_ID}")"

assert_eq "$status" "200" "start DKG setup"

# Wait for all actors
info "Waiting for DKG setup"

for ((attempt = 1; attempt <= DKG_MAX_ATTEMPTS; attempt++)); do
    ready=0

    for proxy in "${PROXIES[@]}"; do
        actor="$(curl -s "${proxy}/evoting/services/dkg/actors/${FORM_ID}")"
        dkg_status="$(jq -r '.Status' <<<"$actor")"

        if [[ "$dkg_status" == "2" ]]; then
            fail "DKG failed at $proxy: $(jq -r '.Error.Message' <<<"$actor")"
        fi

        if [[ "$dkg_status" == "1" || "$dkg_status" == "6" ]]; then
            ((ready += 1))
        fi
    done

    if [[ "$ready" -eq "${#PROXIES[@]}" ]]; then
        break
    fi

    sleep "$DKG_POLL_INTERVAL"
done

assert_eq "$ready" "${#PROXIES[@]}" "all DKG actors are ready"

# Open form to verify the generated key works
info "Opening form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"open"}')"

assert_transaction_status "$response" "1" "open form after DKG"

form="$(api_get "/api/evoting/forms/${FORM_ID}")"

assert_eq "$(jq -r '.Status' <<<"$form")" "1" "form is Open"

pubkey="$(jq -r '.Pubkey // empty' <<<"$form")"

[[ -n "$pubkey" ]] || fail "form has no DKG public key"

pass "form contains DKG public key"

# Delete test form
info "Deleting DKG test form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"
assert_transaction_status "$response" "1" "delete DKG test form"

FORM_ID=""
trap - EXIT

info "DKG system tests completed"
