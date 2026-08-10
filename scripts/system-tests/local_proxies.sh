#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test proxy registration and CRUD behavior.
#
# Requirements:
#   - D-voting is running with development login enabled.
#   - The configured administrator exists; curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   PROXY_COUNT=5
#
# Test steps:
#   1. Read the existing proxy list.
#   2. Register temporary proxies and verify list and individual reads.
#   3. Update every temporary proxy and verify the new addresses.
#   4. Delete the temporary proxies and verify they return HTTP 404.
#
# Example:
#   PROXY_COUNT=20 ./scripts/system-tests/local_proxies.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PROXY_COUNT="${PROXY_COUNT:-5}"

declare -a NODE_ADDRS=()

# Remove temporary proxies created by this test
cleanup() {
    for node_addr in "${NODE_ADDRS[@]}"; do
        encoded="$(jq -nr --arg value "$node_addr" '$value | @uri')"

        curl -s \
            -X DELETE \
            -b "$COOKIE_FILE" \
            "${BASE_URL}/api/proxies/${encoded}" \
            >/dev/null 2>&1 || true
    done
}

trap cleanup EXIT

check_system
login

# List existing proxies
info "Listing existing proxies"

response="$(api_get "/api/proxies")"

if ! jq -e '.Proxies | type == "object"' >/dev/null <<<"$response"; then
    fail "proxy list response does not contain a Proxies object"
fi

pass "list proxies"

# Register temporary proxies
info "Registering ${PROXY_COUNT} temporary proxies"

for i in $(seq 1 "$PROXY_COUNT"); do
    node_addr="grpc://zz-system-test-${i}:2000"
    proxy_addr="http://zz-system-test-${i}:8080"

    NODE_ADDRS+=("$node_addr")

    response="$(api_post "/api/proxies" "$(jq -cn \
        --arg node "$node_addr" \
        --arg proxy "$proxy_addr" \
        '{NodeAddr: $node, Proxy: $proxy}')")"

    assert_eq "$response" "ok" "register proxy $i"
done

# Verify all proxies were registered
info "Verifying registered proxies"

response="$(api_get "/api/proxies")"

for i in $(seq 1 "$PROXY_COUNT"); do
    node_addr="grpc://zz-system-test-${i}:2000"
    expected_proxy="http://zz-system-test-${i}:8080"

    actual_proxy="$(jq -r --arg node "$node_addr" '.Proxies[$node]' <<<"$response")"

    assert_eq "$actual_proxy" "$expected_proxy" "proxy $i appears in list"
done

# Read each proxy individually
info "Reading proxies individually"

for i in $(seq 1 "$PROXY_COUNT"); do
    node_addr="grpc://zz-system-test-${i}:2000"
    expected_proxy="http://zz-system-test-${i}:8080"

    encoded="$(jq -nr --arg value "$node_addr" '$value | @uri')"

    response="$(api_get "/api/proxies/${encoded}")"

    actual_node="$(jq -r '.NodeAddr' <<<"$response")"
    actual_proxy="$(jq -r '.Proxy' <<<"$response")"

    assert_eq "$actual_node" "$node_addr" "proxy $i node address"
    assert_eq "$actual_proxy" "$expected_proxy" "proxy $i proxy address"
done

# Update each proxy
info "Updating proxies"

for i in $(seq 1 "$PROXY_COUNT"); do
    node_addr="grpc://zz-system-test-${i}:2000"
    updated_proxy="http://zz-system-test-${i}:8081"

    encoded="$(jq -nr --arg value "$node_addr" '$value | @uri')"

    response="$(api_put "/api/proxies/${encoded}" "$(jq -cn \
        --arg proxy "$updated_proxy" \
        '{Proxy: $proxy}')")"

    assert_eq "$response" "ok" "update proxy $i"
done

# Verify updates
info "Verifying proxy updates"

for i in $(seq 1 "$PROXY_COUNT"); do
    node_addr="grpc://zz-system-test-${i}:2000"
    expected_proxy="http://zz-system-test-${i}:8081"

    encoded="$(jq -nr --arg value "$node_addr" '$value | @uri')"

    response="$(api_get "/api/proxies/${encoded}")"
    actual_proxy="$(jq -r '.Proxy' <<<"$response")"

    assert_eq "$actual_proxy" "$expected_proxy" "updated proxy $i"
done

# Delete temporary proxies
info "Deleting temporary proxies"

for node_addr in "${NODE_ADDRS[@]}"; do
    encoded="$(jq -nr --arg value "$node_addr" '$value | @uri')"

    response="$(api_delete "/api/proxies/${encoded}")"

    assert_eq "$response" "ok" "delete $node_addr"
done

# Verify deletion
info "Verifying proxies were deleted"

for node_addr in "${NODE_ADDRS[@]}"; do
    encoded="$(jq -nr --arg value "$node_addr" '$value | @uri')"

    status="$(curl -s \
        -o /dev/null \
        -w '%{http_code}' \
        -b "$COOKIE_FILE" \
        "${BASE_URL}/api/proxies/${encoded}")"

    assert_eq "$status" "404" "$node_addr returns 404 after deletion"
done

NODE_ADDRS=()
trap - EXIT

info "Proxy system tests completed"
