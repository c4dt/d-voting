#!/usr/bin/env bash

set -Eeuo pipefail

# Purpose:
#   Test valid, boundary, large, nested, and invalid form configurations.
#
# Requirements:
#   - D-voting is running with development login enabled.
#   - The configured administrator exists; curl and jq are installed.
#
# Options:
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#   LONG_QUESTIONS=20
#   LONG_CHOICES=12
#   LONG_TEXT_MAX=500
#   LONG_TITLE_LENGTH=2000
#   NESTING_DEPTH=8
#
# Test steps:
#   1. Create and verify select, rank, and text configurations.
#   2. Create a deeply nested configuration.
#   3. Test zero-choice and large mixed-form boundaries.
#   4. Verify ballot-size and chunk metadata for the large form.
#   5. Reject duplicate IDs, invalid MinN/MaxN, and unknown Order IDs.
#   6. Delete every form created by the test.
#
# Example:
#   LONG_QUESTIONS=30 NESTING_DEPTH=15 ./scripts/system-tests/local_form_configurations.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

LONG_QUESTIONS="${LONG_QUESTIONS:-20}"
LONG_CHOICES="${LONG_CHOICES:-12}"
LONG_TEXT_MAX="${LONG_TEXT_MAX:-500}"
LONG_TITLE_LENGTH="${LONG_TITLE_LENGTH:-2000}"
NESTING_DEPTH="${NESTING_DEPTH:-8}"

FORM_IDS=()
LAST_FORM_ID=""
LAST_FORM=""

cleanup() {
    for form_id in "${FORM_IDS[@]:-}"; do
        curl -s \
            -X DELETE \
            -b "$COOKIE_FILE" \
            "${BASE_URL}/api/evoting/forms/${form_id}" \
            >/dev/null 2>&1 || true
    done
}

trap cleanup EXIT

check_system
login

# Create a configuration that should be accepted
create_valid() {
    local name="$1"
    local body="$2"
    local response
    local form_id

    info "$name"

    response="$(api_post "/api/evoting/forms" "$body")"
    form_id="$(jq -r '.FormID // empty' <<<"$response")"

    if [[ -z "$form_id" ]]; then
        fail "$name did not return FormID"
    fi

    assert_transaction_status "$response" "1" "$name"

    FORM_IDS+=("$form_id")
    LAST_FORM_ID="$form_id"
    LAST_FORM="$(api_get "/api/evoting/forms/${form_id}")"
}

# Create a configuration that should be rejected
create_invalid() {
    local name="$1"
    local body="$2"
    local response

    info "$name"

    response="$(api_post "/api/evoting/forms" "$body")"
    assert_transaction_status "$response" "2" "$name"
}

# Select
SELECT_FORM="$(jq -cn '
{
    Configuration: {
        Title: {En:"Select form", Fr:"", De:"", URL:""},
        Scaffold: [{
            ID:"subject-select",
            Title:{En:"Select", Fr:"", De:"", URL:""},
            Order:["select-1"],
            Subjects:[],
            Selects:[{
                ID:"select-1",
                Title:{En:"Choose several", Fr:"", De:"", URL:""},
                MaxN:3,
                MinN:1,
                Choices:[
                    {Choice:"{\"en\":\"one\"}", URL:""},
                    {Choice:"{\"en\":\"two\"}", URL:""},
                    {Choice:"{\"en\":\"three\"}", URL:""},
                    {Choice:"{\"en\":\"four\"}", URL:""}
                ],
                Hint:{En:"", Fr:"", De:""}
            }],
            Ranks:[],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

create_valid "Select configuration" "$SELECT_FORM"

assert_eq \
    "$(jq '.Configuration.Scaffold[0].Selects | length' <<<"$LAST_FORM")" \
    "1" \
    "select stored"

assert_eq \
    "$(jq '.Configuration.Scaffold[0].Selects[0].Choices | length' <<<"$LAST_FORM")" \
    "4" \
    "select choices stored"

# Rank
RANK_FORM="$(jq -cn '
{
    Configuration: {
        Title:{En:"Rank form", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"subject-rank",
            Title:{En:"Ranking", Fr:"", De:"", URL:""},
            Order:["rank-1"],
            Subjects:[],
            Selects:[],
            Ranks:[{
                ID:"rank-1",
                Title:{En:"Rank these", Fr:"", De:"", URL:""},
                MaxN:5,
                MinN:2,
                Choices:[
                    {Choice:"{\"en\":\"A\"}", URL:""},
                    {Choice:"{\"en\":\"B\"}", URL:""},
                    {Choice:"{\"en\":\"C\"}", URL:""},
                    {Choice:"{\"en\":\"D\"}", URL:""},
                    {Choice:"{\"en\":\"E\"}", URL:""}
                ],
                Hint:{En:"", Fr:"", De:""}
            }],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

create_valid "Rank configuration" "$RANK_FORM"

assert_eq \
    "$(jq '.Configuration.Scaffold[0].Ranks[0].Choices | length' <<<"$LAST_FORM")" \
    "5" \
    "rank choices stored"

# Text
TEXT_FORM="$(jq -cn '
{
    Configuration: {
        Title:{En:"Text form", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"subject-text",
            Title:{En:"Text", Fr:"", De:"", URL:""},
            Order:["text-1"],
            Subjects:[],
            Selects:[],
            Ranks:[],
            Texts:[{
                ID:"text-1",
                Title:{En:"Explain your answer", Fr:"", De:"", URL:""},
                MaxN:2,
                MinN:1,
                MaxLength:2048,
                Regex:".*",
                Choices:[
                    {Choice:"{\"en\":\"Answer 1\"}", URL:""},
                    {Choice:"{\"en\":\"Answer 2\"}", URL:""}
                ],
                Hint:{En:"Unicode: é ü 中文 🚀", Fr:"", De:""}
            }]
        }],
        AdditionalInfo:""
    }
}')"

create_valid "Text configuration" "$TEXT_FORM"

assert_eq \
    "$(jq '.Configuration.Scaffold[0].Texts[0].MaxLength' <<<"$LAST_FORM")" \
    "2048" \
    "text MaxLength stored"

# Deep nesting
info "Building nested configuration"

nested='{
    "ID":"nested-final",
    "Title":{"En":"Final subject","Fr":"","De":"","URL":""},
    "Order":["nested-select"],
    "Subjects":[],
    "Selects":[{
        "ID":"nested-select",
        "Title":{"En":"Deep question","Fr":"","De":"","URL":""},
        "MaxN":1,
        "MinN":1,
        "Choices":[
            {"Choice":"{\"en\":\"yes\"}","URL":""},
            {"Choice":"{\"en\":\"no\"}","URL":""}
        ],
        "Hint":{"En":"","Fr":"","De":""}
    }],
    "Ranks":[],
    "Texts":[]
}'

for ((i = NESTING_DEPTH; i >= 1; i--)); do
    child_id="$(jq -r '.ID' <<<"$nested")"

    nested="$(jq -cn \
        --argjson child "$nested" \
        --arg id "nested-${i}" \
        --arg child_id "$child_id" \
        '{
            ID:$id,
            Title:{En:("Nested level " + $id), Fr:"", De:"", URL:""},
            Order:[$child_id],
            Subjects:[$child],
            Selects:[],
            Ranks:[],
            Texts:[]
        }'
    )"
done

NESTED_FORM="$(jq -cn \
    --argjson subject "$nested" \
    '{
        Configuration:{
            Title:{En:"Deep nested form", Fr:"", De:"", URL:""},
            Scaffold:[$subject],
            AdditionalInfo:""
        }
    }'
)"

create_valid "${NESTING_DEPTH}-level nested configuration" "$NESTED_FORM"

# Weird boundary: zero choices is valid when MinN and MaxN are zero
ZERO_CHOICE_FORM="$(jq -cn '
{
    Configuration:{
        Title:{En:"Zero choice form", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"zero-subject",
            Title:{En:"Boundary", Fr:"", De:"", URL:""},
            Order:["zero-select"],
            Subjects:[],
            Selects:[{
                ID:"zero-select",
                Title:{En:"Nothing can be selected", Fr:"", De:"", URL:""},
                MaxN:0,
                MinN:0,
                Choices:[],
                Hint:{En:"", Fr:"", De:""}
            }],
            Ranks:[],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

create_valid "Zero-choice boundary configuration" "$ZERO_CHOICE_FORM"

# Large mixed form
info "Building large mixed configuration"

LONG_TITLE="$(printf '%*s' "$LONG_TITLE_LENGTH" '' | tr ' ' 'X')"

LONG_FORM="$(jq -cn \
    --arg title "$LONG_TITLE" \
    --argjson questions "$LONG_QUESTIONS" \
    --argjson choices "$LONG_CHOICES" \
    --argjson textmax "$LONG_TEXT_MAX" \
    '
    def makechoices($prefix):
        [range(0; $choices) |
            {
                Choice: ({en:($prefix + "-" + tostring)} | tojson),
                URL:""
            }
        ];

    [range(0; $questions) |
        {
            ID:("long-select-" + tostring),
            Title:{En:("Select " + tostring), Fr:"", De:"", URL:""},
            MaxN:$choices,
            MinN:0,
            Choices:makechoices("select"),
            Hint:{En:"", Fr:"", De:""}
        }
    ] as $selects |

    [range(0; $questions) |
        {
            ID:("long-rank-" + tostring),
            Title:{En:("Rank " + tostring), Fr:"", De:"", URL:""},
            MaxN:$choices,
            MinN:0,
            Choices:makechoices("rank"),
            Hint:{En:"", Fr:"", De:""}
        }
    ] as $ranks |

    [range(0; $questions) |
        {
            ID:("long-text-" + tostring),
            Title:{En:("Text " + tostring), Fr:"", De:"", URL:""},
            MaxN:$choices,
            MinN:0,
            MaxLength:$textmax,
            Regex:".*",
            Choices:makechoices("text"),
            Hint:{En:"", Fr:"", De:""}
        }
    ] as $texts |

    {
        Configuration:{
            Title:{En:$title, Fr:"Titre", De:"Titel", URL:""},
            Scaffold:[{
                ID:"long-subject",
                Title:{En:"Large mixed subject", Fr:"", De:"", URL:""},
                Order:
                    ([$selects[].ID] + [$ranks[].ID] + [$texts[].ID]),
                Subjects:[],
                Selects:$selects,
                Ranks:$ranks,
                Texts:$texts
            }],
            AdditionalInfo:"Special chars: !@#$%^&*() [] {} <> éèü 中文 🚀"
        }
    }
    '
)"

create_valid \
    "Large mixed configuration (${LONG_QUESTIONS} of each question type)" \
    "$LONG_FORM"

assert_eq \
    "$(jq '.Configuration.Scaffold[0].Selects | length' <<<"$LAST_FORM")" \
    "$LONG_QUESTIONS" \
    "all long-form selects stored"

assert_eq \
    "$(jq '.Configuration.Scaffold[0].Ranks | length' <<<"$LAST_FORM")" \
    "$LONG_QUESTIONS" \
    "all long-form ranks stored"

assert_eq \
    "$(jq '.Configuration.Scaffold[0].Texts | length' <<<"$LAST_FORM")" \
    "$LONG_QUESTIONS" \
    "all long-form texts stored"

ballot_size="$(jq -r '.BallotSize' <<<"$LAST_FORM")"
chunks="$(jq -r '.ChunksPerBallot' <<<"$LAST_FORM")"

if (( ballot_size <= 29 || chunks <= 1 )); then
    fail "large form did not produce a multi-chunk ballot"
fi

pass "large form uses $ballot_size ballot bytes and $chunks chunks"

# Duplicate IDs
DUPLICATE_ID_FORM="$(jq -cn '
{
    Configuration:{
        Title:{En:"Duplicate IDs", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"dup-subject",
            Title:{En:"", Fr:"", De:"", URL:""},
            Order:["duplicate"],
            Subjects:[],
            Selects:[{
                ID:"duplicate",
                Title:{En:"", Fr:"", De:"", URL:""},
                MaxN:0,
                MinN:0,
                Choices:[],
                Hint:{En:"", Fr:"", De:""}
            }],
            Ranks:[{
                ID:"duplicate",
                Title:{En:"", Fr:"", De:"", URL:""},
                MaxN:0,
                MinN:0,
                Choices:[],
                Hint:{En:"", Fr:"", De:""}
            }],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

create_invalid "Duplicate IDs are rejected" "$DUPLICATE_ID_FORM"

# MinN greater than MaxN
INVALID_MIN_FORM="$(jq -cn '
{
    Configuration:{
        Title:{En:"Invalid MinN", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"invalid-min-subject",
            Title:{En:"", Fr:"", De:"", URL:""},
            Order:["invalid-min"],
            Subjects:[],
            Selects:[{
                ID:"invalid-min",
                Title:{En:"", Fr:"", De:"", URL:""},
                MaxN:1,
                MinN:2,
                Choices:[
                    {Choice:"{\"en\":\"A\"}", URL:""},
                    {Choice:"{\"en\":\"B\"}", URL:""}
                ],
                Hint:{En:"", Fr:"", De:""}
            }],
            Ranks:[],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

create_invalid "MinN greater than MaxN is rejected" "$INVALID_MIN_FORM"

# MaxN greater than number of choices
INVALID_MAX_FORM="$(jq -cn '
{
    Configuration:{
        Title:{En:"Invalid MaxN", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"invalid-max-subject",
            Title:{En:"", Fr:"", De:"", URL:""},
            Order:["invalid-max"],
            Subjects:[],
            Selects:[],
            Ranks:[{
                ID:"invalid-max",
                Title:{En:"", Fr:"", De:"", URL:""},
                MaxN:3,
                MinN:0,
                Choices:[
                    {Choice:"{\"en\":\"A\"}", URL:""},
                    {Choice:"{\"en\":\"B\"}", URL:""}
                ],
                Hint:{En:"", Fr:"", De:""}
            }],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

create_invalid "MaxN greater than choices is rejected" "$INVALID_MAX_FORM"

# Unknown ID in Order
INVALID_ORDER_FORM="$(jq -cn '
{
    Configuration:{
        Title:{En:"Invalid order", Fr:"", De:"", URL:""},
        Scaffold:[{
            ID:"order-subject",
            Title:{En:"", Fr:"", De:"", URL:""},
            Order:["does-not-exist"],
            Subjects:[],
            Selects:[],
            Ranks:[],
            Texts:[]
        }],
        AdditionalInfo:""
    }
}')"

create_invalid "Unknown Order ID is rejected" "$INVALID_ORDER_FORM"

# Cleanup
info "Deleting configuration test forms"

for form_id in "${FORM_IDS[@]}"; do
    response="$(api_delete "/api/evoting/forms/${form_id}")"
    assert_transaction_status "$response" "1" "delete $form_id"
done

FORM_IDS=()
trap - EXIT

info "Form configuration system tests completed"
