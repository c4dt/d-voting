#!/usr/bin/env bash

set -Eeuo pipefail

# Requirements:
#   - D-voting system already running
#   - Development login enabled
#   - All individual system-test requirements installed
#   - Run from repository root

# Configuration

SYSTEM_TEST_URL="${SYSTEM_TEST_URL:-http://127.0.0.1:3000}"
TEST_TIMEOUT="${TEST_TIMEOUT:-900}"

# General tests
PROXY_COUNT="${PROXY_COUNT:-5}"

# Form configuration test
LONG_QUESTIONS="${LONG_QUESTIONS:-20}"
LONG_CHOICES="${LONG_CHOICES:-12}"
LONG_TEXT_MAX="${LONG_TEXT_MAX:-500}"
LONG_TITLE_LENGTH="${LONG_TITLE_LENGTH:-2000}"
NESTING_DEPTH="${NESTING_DEPTH:-8}"

# Load test
RUN_LOAD="${RUN_LOAD:-true}"
LOAD_VOTES="${LOAD_VOTES:-300}"
LOAD_BATCH_SIZE="${LOAD_BATCH_SIZE:-10}"
LOAD_SHUFFLE_TIMEOUT="${LOAD_SHUFFLE_TIMEOUT:-180}"

# Transaction polling
TX_POLL_INTERVAL="${TX_POLL_INTERVAL:-1}"
TX_MAX_ATTEMPTS="${TX_MAX_ATTEMPTS:-60}"

SYSTEM_TEST_DIR="./scripts/system-tests"

if [[ "$(git rev-parse --show-toplevel)" != "$(pwd)" ]]; then
    echo "ERROR: system tests must be run from repository root" >&2
    exit 1
fi

[[ "$TEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: TEST_TIMEOUT must be a positive integer" >&2
    exit 2
}
command -v timeout >/dev/null || {
    echo "ERROR: GNU timeout is required" >&2
    exit 2
}

export SYSTEM_TEST_URL
export PROXY_COUNT

export LONG_QUESTIONS
export LONG_CHOICES
export LONG_TEXT_MAX
export LONG_TITLE_LENGTH
export NESTING_DEPTH

export TX_POLL_INTERVAL
export TX_MAX_ATTEMPTS

# load.sh expects these names
export VOTES="$LOAD_VOTES"
export BATCH_SIZE="$LOAD_BATCH_SIZE"
export SHUFFLE_TIMEOUT="$LOAD_SHUFFLE_TIMEOUT"

TESTS=(
    "proxies.sh"
    "forms.sh"
    "form_configurations.sh"
    "access.sh"
    "dkg.sh"
    "voting.sh"
    "shuffle.sh"
    "lifecycle.sh"
)

if [[ "$RUN_LOAD" == "true" ]]; then
    TESTS+=("load.sh")
fi

start_time="$(date +%s)"

echo
echo "Running D-voting system tests"
echo
echo "Configuration:"
echo "  Proxies:       $PROXY_COUNT"
echo "  Load test:     $RUN_LOAD"
echo "  Test timeout:  ${TEST_TIMEOUT}s"

if [[ "$RUN_LOAD" == "true" ]]; then
    echo "  Load voters:   $LOAD_VOTES"
    echo "  Load batch:    $LOAD_BATCH_SIZE"
fi

echo

for test_script in "${TESTS[@]}"; do
    echo "============================================================"
    echo "RUN: $test_script"
    echo "============================================================"

    test_start="$(date +%s)"

    if timeout --signal=TERM --kill-after=10s "${TEST_TIMEOUT}s" \
        bash "${SYSTEM_TEST_DIR}/${test_script}"; then
        :
    else
        status=$?
        test_seconds=$(( $(date +%s) - test_start ))

        if ((status == 124)); then
            echo "FAIL: $test_script timed out after ${test_seconds}s" >&2
        else
            echo "FAIL: $test_script exited $status after ${test_seconds}s" >&2
        fi
        exit 1
    fi

    test_seconds=$(( $(date +%s) - test_start ))

    echo
    echo "PASS: $test_script (${test_seconds}s)"
    echo
done

total_seconds=$(( $(date +%s) - start_time ))

echo "============================================================"
echo "ALL SYSTEM TESTS PASSED"
echo "============================================================"
echo "Tests: ${#TESTS[@]}"
echo "Time:  ${total_seconds}s"
