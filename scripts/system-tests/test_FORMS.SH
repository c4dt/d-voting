#!/usr/bin/env bash

set -Eeuo pipefail

# Requirements:
#   - D-voting system already running
#   - Development login enabled
#   - Admin user already configured
#   - curl
#   - jq
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   FORM_TITLE="System test form"
#   TX_POLL_INTERVAL=1
#   TX_MAX_ATTEMPTS=60
#
# Examples:
#   ./scripts/system-tests/test_forms.sh
#   FORM_TITLE="Custom test form" ./scripts/system-tests/test_forms.sh

echo "Here"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

FORM_TITLE="${FORM_TITLE:-System test form}"
FORM_ID=""

echo "Here"

# Remove the form if the test exits before normal cleanup
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

# Create a simple form
info "Creating form"

FORM_JSON="$(jq -cn \
    --arg title "$FORM_TITLE" \
    '{
        Configuration: {
            Title: {
                En: $title,
                Fr: "",
                De: "",
                URL: ""j
            },
            Scaffold: [
                {
                    ID: "ozCI7gKv",
                    Title: {
                        En: "System test subject",
                        Fr: "",
                        De: "",
                        URL: ""
                    },
                    Order: ["nVjQ0jMK"],
                    Ranks: [],
                    Selects: [
                        {
                            ID: "nVjQ0jMK",
                            Title: {
                                En: "Choose an option",
                                Fr: "",
                                De: "",
                                URL: ""
                            },
                            MaxN: 1,
                            MinN: 1,
                            Choices: [
                                {
                                    Choice: "{\"en\":\"one\"}",
                                    URL: ""
                                },
                                {
                                    Choice: "{\"en\":\"two\"}",
                                    URL: ""
                                }
                            ],
                            Hint: {
                                En: "",
                                Fr: "",
                                De: ""
                            }
                        }
                    ],
                    Texts: [],
                    Subjects: []
                }
            ],
            AdditionalInfo: ""
        }
    }'
)"

response="$(api_post "/api/evoting/forms" "$FORM_JSON")"

FORM_ID="$(jq -r '.FormID // empty' <<<"$response")"

if [[ -z "$FORM_ID" || "$FORM_ID" == "null" ]]; then
    fail "create form response did not contain FormID"
fi

assert_transaction_status "$response" "1" "create form"

pass "created form $FORM_ID"

# Read the form
info "Reading form"

response="$(api_get "/api/evoting/forms/${FORM_ID}")"

actual_id="$(jq -r '.FormID' <<<"$response")"
actual_status="$(jq -r '.Status' <<<"$response")"
actual_title="$(jq -r '.Configuration.Title.En' <<<"$response")"

assert_eq "$actual_id" "$FORM_ID" "form ID matches"
assert_eq "$actual_status" "0" "new form is in Initial state"
assert_eq "$actual_title" "$FORM_TITLE" "form title matches"

# Verify creator became an owner
info "Checking form owner"

owner_exists="$(jq -r --arg admin "$ADMIN_ID" '.Owners | index($admin) != null' <<<"$response")"

assert_eq "$owner_exists" "true" "form creator is an owner"

# Verify form appears in the list
info "Checking forms list"

response="$(api_get "/api/evoting/forms")"

form_exists="$(jq -r --arg id "$FORM_ID" '.Forms | any(.FormID == $id)' <<<"$response")"

assert_eq "$form_exists" "true" "form appears in forms list"

# Read a form that does not exist
info "Reading nonexistent form"

INVALID_FORM_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

status="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    -b "$COOKIE_FILE" \
    "${BASE_URL}/api/evoting/forms/${INVALID_FORM_ID}")"

if [[ "$status" == "200" ]]; then
    fail "nonexistent form unexpectedly returned 200"
fi

pass "nonexistent form is rejected with HTTP $status"

# Close before opening
info "Trying to close form before opening"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"close"}')"

assert_transaction_status "$response" "2" "close before open is rejected"

# Verify failed transition did not change state
response="$(api_get "/api/evoting/forms/${FORM_ID}")"
actual_status="$(jq -r '.Status' <<<"$response")"

assert_eq "$actual_status" "0" "form remains Initial after rejected close"

# Open without DKG
info "Trying to open form without DKG"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"open"}')"

assert_transaction_status "$response" "2" "open without DKG is rejected"

# Verify failed open did not change state
response="$(api_get "/api/evoting/forms/${FORM_ID}")"
actual_status="$(jq -r '.Status' <<<"$response")"

assert_eq "$actual_status" "0" "form remains Initial after rejected open"

# Cancel form
info "Cancelling form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"cancel"}')"

assert_transaction_status "$response" "1" "cancel form"

response="$(api_get "/api/evoting/forms/${FORM_ID}")"
actual_status="$(jq -r '.Status' <<<"$response")"

assert_eq "$actual_status" "6" "form is Canceled"

# Open canceled form
info "Trying to open canceled form"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"open"}')"

assert_transaction_status "$response" "2" "opening canceled form is rejected"

# Cancel form again
info "Cancelling form again"

response="$(api_put \
    "/api/evoting/forms/${FORM_ID}" \
    '{"Action":"cancel"}')"

assert_transaction_status "$response" "1" "repeated cancel is accepted"

response="$(api_get "/api/evoting/forms/${FORM_ID}")"
actual_status="$(jq -r '.Status' <<<"$response")"

assert_eq "$actual_status" "6" "repeated cancel keeps form Canceled"

# Delete form
info "Deleting form"

response="$(api_delete "/api/evoting/forms/${FORM_ID}")"

assert_transaction_status "$response" "1" "delete form"

# Verify form disappeared from list
info "Checking form was deleted"

response="$(api_get "/api/evoting/forms")"

form_exists="$(jq -r --arg id "$FORM_ID" '.Forms | any(.FormID == $id)' <<<"$response")"

assert_eq "$form_exists" "false" "deleted form no longer appears in forms list"

FORM_ID=""
trap - EXIT

info "Form system tests completed"