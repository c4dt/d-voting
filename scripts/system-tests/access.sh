#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test global and form-level authorization rules.
#
# Requirements:
#   - D-voting is running with development login enabled.
#   - The configured administrator exists; curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   TEST_ADMIN=910001
#   TEST_OPERATOR=910002
#   TEST_OWNER=910003
#   TEST_VOTER=910004
#   TEST_USER=910005
#   EXTRA_OPERATOR=910006
#   TEST_POLICY_VOTER=910007
#   TEST_MISSING_USER=910099
#
# Test steps:
#   1. Verify test identities are unused and unauthenticated mutations fail.
#   2. Add, reject duplicates for, and validate administrators and operators.
#   3. Verify operator, ordinary-user, and revoked-user permissions.
#   4. Reject PerformingUserID and UserID identity spoofing.
#   5. Verify operator form creation and last-owner protection.
#   6. Test non-owner operator, user, and administrator behavior.
#   7. Test owner/voter management, invalid IDs, and duplicate roles.
#   8. Remove created roles and verify permissions are revoked immediately.
#
# Example:
#   ./scripts/system-tests/access.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TEST_ADMIN="${TEST_ADMIN:-910001}"
TEST_OPERATOR="${TEST_OPERATOR:-910002}"
TEST_OWNER="${TEST_OWNER:-910003}"
TEST_VOTER="${TEST_VOTER:-910004}"
TEST_USER="${TEST_USER:-910005}"
EXTRA_OPERATOR="${EXTRA_OPERATOR:-910006}"
TEST_POLICY_VOTER="${TEST_POLICY_VOTER:-910007}"
TEST_MISSING_USER="${TEST_MISSING_USER:-910099}"

TMP_DIR="$(mktemp -d)"

ADMIN_COOKIE="$COOKIE_FILE"
TEST_ADMIN_COOKIE="$TMP_DIR/admin.cookie"
OPERATOR_COOKIE="$TMP_DIR/operator.cookie"
OWNER_COOKIE="$TMP_DIR/owner.cookie"
VOTER_COOKIE="$TMP_DIR/voter.cookie"
USER_COOKIE="$TMP_DIR/user.cookie"

FORM_ID=""
OPERATOR_FORM_ID=""

TEST_ADMIN_ADDED=false
TEST_OPERATOR_ADDED=false
EXTRA_OPERATOR_ADDED=false

warn() {
    printf 'WARN: %s\n' "$1"
}

# POST a permission operation
permission_as() {
    local cookie="$1"
    local path="$2"
    local target="$3"

    api_post_as \
        "$cookie" \
        "$path" \
        "$(jq -cn --arg id "$target" '{TargetUserID:$id}')"
}

# Poll a response containing a transaction token
poll_response() {
    local response="$1"
    local token

    token="$(jq -r '.Token // empty' <<<"$response")"

    if [[ -z "$token" ]]; then
        fail "response did not contain transaction token: $response"
    fi

    poll_transaction "$token"
}

# Check a global admin
assert_admin() {
    local user="$1"
    local expected="$2"

    response="$(api_get "/api/evoting/adminlist")"

    exists="$(jq -r \
        --arg id "$user" \
        '.Admins | index($id) != null' \
        <<<"$response")"

    assert_eq "$exists" "$expected" "admin $user membership"
}

# Check a global operator
assert_operator() {
    local user="$1"
    local expected="$2"

    response="$(api_get "/api/evoting/operatorlist")"

    exists="$(jq -r \
        --arg id "$user" \
        '.Operators | index($id) != null' \
        <<<"$response")"

    assert_eq "$exists" "$expected" "operator $user membership"
}

# Check owner or voter membership on the test form
assert_form_role() {
    local field="$1"
    local user="$2"
    local expected="$3"
    local message

    response="$(api_get "/api/evoting/forms/${FORM_ID}")"

    exists="$(jq -r \
        --arg field "$field" \
        --arg id "$user" \
        '(.[$field] // []) | index($id) != null' \
        <<<"$response")"

    if [[ "$expected" == "true" ]]; then
        message="$field contains $user"
    else
        message="$field does not contain $user"
    fi

    assert_eq "$exists" "$expected" "$message"
}

# Count occurrences to detect duplicate owners or voters
form_role_count() {
    local field="$1"
    local user="$2"

    response="$(api_get "/api/evoting/forms/${FORM_ID}")"

    jq -r \
        --arg field "$field" \
        --arg id "$user" \
        '[.[$field][]? | select(. == $id)] | length' \
        <<<"$response"
}

# Simple valid form
make_form() {
    jq -cn '
    {
        Configuration:{
            Title:{En:"Access control system test", Fr:"", De:"", URL:""},
            Scaffold:[{
                ID:"access-subject",
                Title:{En:"Access test", Fr:"", De:"", URL:""},
                Order:["access-select"],
                Subjects:[],
                Selects:[{
                    ID:"access-select",
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
    }'
}

# Best-effort cleanup if a test fails
cleanup() {
    set +e

    if [[ -n "$FORM_ID" ]]; then
        curl -s \
            -X DELETE \
            -b "$ADMIN_COOKIE" \
            "${BASE_URL}/api/evoting/forms/${FORM_ID}" \
            >/dev/null 2>&1
    fi

    if [[ -n "$OPERATOR_FORM_ID" ]]; then
        curl -s \
            -X DELETE \
            -b "$ADMIN_COOKIE" \
            "${BASE_URL}/api/evoting/forms/${OPERATOR_FORM_ID}" \
            >/dev/null 2>&1
    fi

    if [[ "$EXTRA_OPERATOR_ADDED" == true ]]; then
        permission_as \
            "$ADMIN_COOKIE" \
            "/api/evoting/auth/removeoperator" \
            "$EXTRA_OPERATOR" \
            >/dev/null 2>&1
    fi

    if [[ "$TEST_OPERATOR_ADDED" == true ]]; then
        permission_as \
            "$ADMIN_COOKIE" \
            "/api/evoting/auth/removeoperator" \
            "$TEST_OPERATOR" \
            >/dev/null 2>&1
    fi

    if [[ "$TEST_ADMIN_ADDED" == true ]]; then
        permission_as \
            "$ADMIN_COOKIE" \
            "/api/evoting/auth/removeadmin" \
            "$TEST_ADMIN" \
            >/dev/null 2>&1
    fi

    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

check_system
login

# Check test identities are not already privileged
info "Checking test users"

admins="$(api_get "/api/evoting/adminlist")"
operators="$(api_get "/api/evoting/operatorlist")"

for user in \
    "$TEST_ADMIN" \
    "$TEST_OPERATOR" \
    "$TEST_OWNER" \
    "$TEST_VOTER" \
    "$TEST_USER" \
    "$EXTRA_OPERATOR" \
    "$TEST_POLICY_VOTER"
do
    if jq -e --arg id "$user" '.Admins | index($id) != null' <<<"$admins" >/dev/null; then
        fail "$user is already an admin; choose another test ID"
    fi

    if jq -e --arg id "$user" '.Operators | index($id) != null' <<<"$operators" >/dev/null; then
        fail "$user is already an operator; choose another test ID"
    fi
done

assert_admin "$ADMIN_ID" "true"

login_cookie "$TEST_ADMIN" "$TEST_ADMIN_COOKIE"
login_cookie "$TEST_OPERATOR" "$OPERATOR_COOKIE"
login_cookie "$TEST_OWNER" "$OWNER_COOKIE"
login_cookie "$TEST_VOTER" "$VOTER_COOKIE"
login_cookie "$TEST_USER" "$USER_COOKIE"

# Unauthenticated mutation
info "Checking unauthenticated access"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg id "$TEST_ADMIN" '{TargetUserID:$id}')" \
    "${BASE_URL}/api/evoting/auth/addadmin")"

assert_eq "$status" "401" "unauthenticated role mutation is rejected"

# Admin management
info "Testing administrator management"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/addadmin" \
    "$TEST_ADMIN")"

assert_transaction_status "$response" "1" "add administrator"
TEST_ADMIN_ADDED=true

assert_admin "$TEST_ADMIN" "true"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/addadmin" \
    "$TEST_ADMIN")"

assert_transaction_status "$response" "2" "duplicate administrator is rejected"

for invalid in "99999" "1000000" "not-a-sciper"; do
    response="$(permission_as \
        "$ADMIN_COOKIE" \
        "/api/evoting/auth/addadmin" \
        "$invalid")"

    assert_transaction_status "$response" "2" "invalid administrator $invalid is rejected"
done

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/removeadmin" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "removing unknown administrator is rejected"

# Operator management
info "Testing operator management"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/addoperator" \
    "$TEST_OPERATOR")"

assert_transaction_status "$response" "1" "add operator"
TEST_OPERATOR_ADDED=true

assert_operator "$TEST_OPERATOR" "true"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/addoperator" \
    "$TEST_OPERATOR")"

assert_transaction_status "$response" "2" "duplicate operator is rejected"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/addoperator" \
    "not-a-sciper")"

assert_transaction_status "$response" "2" "invalid operator is rejected"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/removeoperator" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "removing unknown operator is rejected"

# Operator capabilities
info "Testing operator permissions"

response="$(permission_as \
    "$OPERATOR_COOKIE" \
    "/api/evoting/auth/addoperator" \
    "$EXTRA_OPERATOR")"

assert_transaction_status "$response" "1" "operator can add operator"
EXTRA_OPERATOR_ADDED=true

assert_operator "$EXTRA_OPERATOR" "true"

response="$(permission_as \
    "$OPERATOR_COOKIE" \
    "/api/evoting/auth/removeoperator" \
    "$EXTRA_OPERATOR")"

assert_transaction_status "$response" "1" "operator can remove operator"
EXTRA_OPERATOR_ADDED=false

assert_operator "$EXTRA_OPERATOR" "false"

response="$(permission_as \
    "$OPERATOR_COOKIE" \
    "/api/evoting/auth/addadmin" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "operator cannot add administrator"

# Ordinary user permissions
info "Testing ordinary user permissions"

response="$(permission_as \
    "$USER_COOKIE" \
    "/api/evoting/auth/addoperator" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "ordinary user cannot add operator"

# PerformingUserID spoofing
info "Testing PerformingUserID spoofing"

response="$(api_post_as \
    "$USER_COOKIE" \
    "/api/evoting/auth/addadmin" \
    "$(jq -cn \
        --arg target "$TEST_MISSING_USER" \
        --arg admin "$ADMIN_ID" \
        '{TargetUserID:$target, PerformingUserID:$admin}')")"

assert_transaction_status "$response" "2" "PerformingUserID spoofing is rejected"

assert_admin "$TEST_MISSING_USER" "false"

# UserID spoofing during form creation
info "Testing UserID spoofing"

spoof_form="$(make_form | jq \
    --arg admin "$ADMIN_ID" \
    '. + {UserID:$admin}')"

response="$(api_post_as \
    "$USER_COOKIE" \
    "/api/evoting/forms" \
    "$spoof_form")"

spoof_form_id="$(jq -r '.FormID // empty' <<<"$response")"

assert_transaction_status "$response" "2" "ordinary user cannot spoof admin to create form"

if [[ -n "$spoof_form_id" ]]; then
    forms="$(api_get "/api/evoting/forms")"

    exists="$(jq -r \
        --arg id "$spoof_form_id" \
        '.Forms | any(.FormID == $id)' \
        <<<"$forms")"

    assert_eq "$exists" "false" "rejected spoofed form was not created"
fi

# Operator can create a form
info "Testing operator form creation"

response="$(api_post_as \
    "$OPERATOR_COOKIE" \
    "/api/evoting/forms" \
    "$(make_form)")"

OPERATOR_FORM_ID="$(jq -r '.FormID // empty' <<<"$response")"

assert_transaction_status "$response" "1" "operator can create form"

operator_form="$(api_get "/api/evoting/forms/${OPERATOR_FORM_ID}")"

operator_is_owner="$(jq -r \
    --arg id "$TEST_OPERATOR" \
    '.Owners | index($id) != null' \
    <<<"$operator_form")"

assert_eq "$operator_is_owner" "true" "operator becomes owner of created form"

response="$(api_delete "/api/evoting/forms/${OPERATOR_FORM_ID}")"
assert_transaction_status "$response" "1" "delete operator-created form"
OPERATOR_FORM_ID=""

# Create main access-control form
info "Creating access-control form"

response="$(api_post "/api/evoting/forms" "$(make_form)")"

FORM_ID="$(jq -r '.FormID // empty' <<<"$response")"

if [[ -z "$FORM_ID" ]]; then
    fail "form creation did not return FormID"
fi

assert_transaction_status "$response" "1" "create access-control form"

assert_form_role "Owners" "$ADMIN_ID" "true"

# Last owner protection
info "Testing last owner protection"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/removeowner" \
    "$ADMIN_ID")"

assert_transaction_status "$response" "2" "last owner cannot be removed"

assert_form_role "Owners" "$ADMIN_ID" "true"

# Non-owner operator
info "Testing non-owner operator"

response="$(permission_as \
    "$OPERATOR_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "$TEST_VOTER")"

assert_transaction_status "$response" "2" "non-owner operator cannot add voter"

assert_form_role "Voters" "$TEST_VOTER" "false"

# Ordinary user
info "Testing non-owner user"

response="$(permission_as \
    "$USER_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "$TEST_VOTER")"

assert_transaction_status "$response" "2" "ordinary user cannot add voter"

# Spoof form owner/admin identity
response="$(api_post_as \
    "$USER_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "$(jq -cn \
        --arg target "$TEST_VOTER" \
        --arg admin "$ADMIN_ID" \
        '{TargetUserID:$target, PerformingUserID:$admin}')")"

assert_transaction_status "$response" "2" "spoofed form permission operation is rejected"

# Global administrators may manage a form without being one of its owners.
info "Checking non-owner administrator behavior"

assert_form_role "Owners" "$TEST_ADMIN" "false"

response="$(permission_as \
    "$TEST_ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "$TEST_POLICY_VOTER")"

assert_transaction_status \
    "$response" \
    "1" \
    "non-owner administrator can add voter"

assert_form_role "Voters" "$TEST_POLICY_VOTER" "true"

response="$(permission_as \
    "$TEST_ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/removevoter" \
    "$TEST_POLICY_VOTER")"

assert_transaction_status \
    "$response" \
    "1" \
    "non-owner administrator can remove voter"

assert_form_role "Voters" "$TEST_POLICY_VOTER" "false"

# Add owner
info "Testing owner management"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addowner" \
    "$TEST_OWNER")"

assert_transaction_status "$response" "1" "add owner"

assert_form_role "Owners" "$TEST_OWNER" "true"

# Owner can add voter
info "Testing owner permissions"

response="$(permission_as \
    "$OWNER_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "$TEST_VOTER")"

assert_transaction_status "$response" "1" "owner can add voter"

assert_form_role "Voters" "$TEST_VOTER" "true"

# Voter cannot manage permissions
info "Testing voter permissions"

response="$(permission_as \
    "$VOTER_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addowner" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "voter cannot add owner"

# Invalid form-role targets
info "Testing invalid target users"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addowner" \
    "99999")"

assert_transaction_status "$response" "2" "out-of-range owner is rejected"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "not-a-sciper")"

assert_transaction_status "$response" "2" "invalid voter is rejected"

# Remove users that were never present
response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/removeowner" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "removing unknown owner is rejected"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/removevoter" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "removing unknown voter is rejected"

# Duplicate owner
info "Checking duplicate owners"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addowner" \
    "$TEST_OWNER")"

poll_response "$response"

case "$TX_STATUS" in
    1)
        count="$(form_role_count "Owners" "$TEST_OWNER")"

        warn "duplicate owner was accepted; $TEST_OWNER appears $count times"

        response="$(permission_as \
            "$ADMIN_COOKIE" \
            "/api/evoting/auth/forms/${FORM_ID}/removeowner" \
            "$TEST_OWNER")"

        assert_transaction_status "$response" "1" "remove duplicate owner entry"

        count="$(form_role_count "Owners" "$TEST_OWNER")"
        assert_eq "$count" "1" "one owner entry remains"
        ;;
    2)
        pass "duplicate owner is rejected"
        ;;
    *)
        fail "unexpected duplicate-owner transaction status: $TX_STATUS"
        ;;
esac

# Duplicate voter
info "Checking duplicate voters"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "$TEST_VOTER")"

poll_response "$response"

case "$TX_STATUS" in
    1)
        count="$(form_role_count "Voters" "$TEST_VOTER")"

        warn "duplicate voter was accepted; $TEST_VOTER appears $count times"

        response="$(permission_as \
            "$ADMIN_COOKIE" \
            "/api/evoting/auth/forms/${FORM_ID}/removevoter" \
            "$TEST_VOTER")"

        assert_transaction_status "$response" "1" "remove duplicate voter entry"

        count="$(form_role_count "Voters" "$TEST_VOTER")"
        assert_eq "$count" "1" "one voter entry remains"
        ;;
    2)
        pass "duplicate voter is rejected"
        ;;
    *)
        fail "unexpected duplicate-voter transaction status: $TX_STATUS"
        ;;
esac

# Remove voter
info "Removing voter"

response="$(permission_as \
    "$OWNER_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/removevoter" \
    "$TEST_VOTER")"

assert_transaction_status "$response" "1" "owner can remove voter"

assert_form_role "Voters" "$TEST_VOTER" "false"

# Remove owner
info "Removing owner"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/removeowner" \
    "$TEST_OWNER")"

assert_transaction_status "$response" "1" "remove owner"

assert_form_role "Owners" "$TEST_OWNER" "false"

# Removed owner immediately loses permissions
response="$(permission_as \
    "$OWNER_COOKIE" \
    "/api/evoting/auth/forms/${FORM_ID}/addvoter" \
    "$TEST_VOTER")"

assert_transaction_status "$response" "2" "removed owner cannot manage form"

# Delete form
info "Deleting access-control form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"
assert_transaction_status "$response" "1" "delete access-control form"

FORM_ID=""

# Revoke operator
info "Revoking operator"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/removeoperator" \
    "$TEST_OPERATOR")"

assert_transaction_status "$response" "1" "remove operator"
TEST_OPERATOR_ADDED=false

assert_operator "$TEST_OPERATOR" "false"

response="$(permission_as \
    "$OPERATOR_COOKIE" \
    "/api/evoting/auth/addoperator" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "revoked operator immediately loses permissions"

# Revoke administrator
info "Revoking administrator"

response="$(permission_as \
    "$ADMIN_COOKIE" \
    "/api/evoting/auth/removeadmin" \
    "$TEST_ADMIN")"

assert_transaction_status "$response" "1" "remove administrator"
TEST_ADMIN_ADDED=false

assert_admin "$TEST_ADMIN" "false"

response="$(permission_as \
    "$TEST_ADMIN_COOKIE" \
    "/api/evoting/auth/addadmin" \
    "$TEST_MISSING_USER")"

assert_transaction_status "$response" "2" "revoked administrator immediately loses permissions"

# Verify original admin survived the test
assert_admin "$ADMIN_ID" "true"

trap - EXIT
rm -rf "$TMP_DIR"

info "Access-control system tests completed"
