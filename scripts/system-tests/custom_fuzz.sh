#!/usr/bin/env bash

set -uo pipefail

# Custom system-test fuzzer. Run from the repository root; the target system must
# already be running. It runs every local_*.sh once, then varies their documented
# options until the time budget expires. Failures are recorded without stopping.
#
# Options:
#   FUZZ_SECONDS=3600
#   FUZZ_TEST_TIMEOUT=900               (maximum seconds for one test)
#   FUZZ_SEED=<integer>                 (default: current epoch time)
#   FUZZ_LOG_DIR=/tmp/dvoting-fuzz-...
#   SYSTEM_TEST_URL=http://127.0.0.1:3000
#
# Example:
#   FUZZ_SECONDS=3600 FUZZ_SEED=42 ./scripts/system-tests/custom_fuzz.sh

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

FUZZ_SECONDS="${FUZZ_SECONDS:-3600}"
FUZZ_TEST_TIMEOUT="${FUZZ_TEST_TIMEOUT:-900}"
FUZZ_SEED="${FUZZ_SEED:-$(date +%s)}"
FUZZ_LOG_DIR="${FUZZ_LOG_DIR:-$(mktemp -d /tmp/dvoting-fuzz-XXXXXX)}"
SYSTEM_TEST_URL="${SYSTEM_TEST_URL:-http://127.0.0.1:3000}"

[[ "$FUZZ_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "FUZZ_SECONDS must be positive" >&2; exit 2; }
[[ "$FUZZ_TEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "FUZZ_TEST_TIMEOUT must be positive" >&2; exit 2; }
[[ "$FUZZ_SEED" =~ ^[0-9]+$ ]] || { echo "FUZZ_SEED must be an integer" >&2; exit 2; }
command -v timeout >/dev/null || { echo "GNU timeout is required" >&2; exit 2; }
mkdir -p "$FUZZ_LOG_DIR"

RANDOM=$((FUZZ_SEED % 32768))
START_TIME="$(date +%s)"
DEADLINE=$((START_TIME + FUZZ_SECONDS))
RUNS=0
FAILURES=0
LOAD_RUNS=0
RESULTS_FILE="$FUZZ_LOG_DIR/results.tsv"
FAILURES_FILE="$FUZZ_LOG_DIR/failures.tsv"
printf 'run\ttest\tstatus\tduration_seconds\tlog\n' >"$RESULTS_FILE"
printf 'run\ttest\tstatus\tcommand\tlog\n' >"$FAILURES_FILE"

mapfile -t TESTS < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'local_*.sh' -printf '%f\n' | sort)
((${#TESTS[@]} > 0)) || { echo "No test scripts found" >&2; exit 2; }

# Put the potentially very long load test last on the first pass, so the rest of
# the suite still gets coverage if a large vote count consumes the time budget.
ORDERED_TESTS=()
for test in "${TESTS[@]}"; do
    [[ "$test" == "local_load.sh" ]] || ORDERED_TESTS+=("$test")
done
for test in "${TESTS[@]}"; do
    [[ "$test" != "local_load.sh" ]] || ORDERED_TESTS+=("$test")
done
TESTS=("${ORDERED_TESTS[@]}")

pick() {
    local values=("$@")
    printf '%s' "${values[RANDOM % ${#values[@]}]}"
}

# Give each iteration a disjoint block of six-digit development user IDs.
user_base() {
    printf '%d' $((100000 + (RUNS * 1100 + RANDOM) % 800000))
}

options_for() {
    local test="$1" base="$2"
    OPTIONS=("SYSTEM_TEST_URL=$SYSTEM_TEST_URL" "TX_POLL_INTERVAL=$(pick 1 1 2)" "TX_MAX_ATTEMPTS=$(pick 60 90 120)")

    case "$test" in
        local_access.sh)
            OPTIONS+=("TEST_ADMIN=$base" "TEST_OPERATOR=$((base + 1))" "TEST_OWNER=$((base + 2))"
                "TEST_VOTER=$((base + 3))" "TEST_USER=$((base + 4))" "EXTRA_OPERATOR=$((base + 5))"
                "TEST_POLICY_VOTER=$((base + 6))" "TEST_MISSING_USER=$((base + 99))") ;;
        local_dkg.sh)
            OPTIONS+=("DKG_POLL_INTERVAL=$(pick 1 2 3)" "DKG_MAX_ATTEMPTS=$(pick 30 60 120)") ;;
        local_form_configurations.sh)
            OPTIONS+=("LONG_QUESTIONS=$(pick 1 20 50 100)" "LONG_CHOICES=$(pick 2 12 32 64)"
                "LONG_TEXT_MAX=$(pick 1 500 4096 16384)" "LONG_TITLE_LENGTH=$(pick 1 2000 8192 32768)"
                "NESTING_DEPTH=$(pick 1 8 16 32)") ;;
        local_forms.sh)
            OPTIONS+=("FORM_TITLE=fuzz-${FUZZ_SEED}-${RUNS}-$(printf '%*s' "$(pick 1 64 512 2000)" '' | tr ' ' X)") ;;
        local_lifecycle.sh)
            OPTIONS+=("VOTER1=$base" "VOTER2=$((base + 1))") ;;
        local_load.sh)
            # Explicitly straddle the old 256-vote boundary, plus odd batch tails.
            # The first load run is always 513; subsequent runs cycle boundaries.
            load_sizes=(513 255 256 257 511 777 1025 2 31)
            OPTIONS+=("VOTES=${load_sizes[LOAD_RUNS % ${#load_sizes[@]}]}"
                "START_VOTER=$base" "BATCH_SIZE=$(pick 1 7 16 31 64 127)"
                "SHUFFLE_TIMEOUT=$(pick 180 300 600)") ;;
        local_proxies.sh)
            OPTIONS+=("PROXY_COUNT=$(pick 1 2 5 16 31 64)") ;;
        local_shuffle.sh)
            OPTIONS+=("VOTER1=$base" "VOTER2=$((base + 1))" "SHUFFLE_TIMEOUT=$(pick 120 240 480)") ;;
        local_voting.sh)
            OPTIONS+=("VOTER1=$base" "NON_VOTER=$((base + 1))") ;;
    esac
}

run_one() {
    local test="$1" now remaining limit base log status test_start duration command
    now="$(date +%s)"
    remaining=$((DEADLINE - now))
    ((remaining > 0)) || return 1

    RUNS=$((RUNS + 1))
    base="$(user_base)"
    options_for "$test" "$base"
    [[ "$test" != "local_load.sh" ]] || LOAD_RUNS=$((LOAD_RUNS + 1))
    log="$FUZZ_LOG_DIR/$(printf '%04d' "$RUNS")-${test%.sh}.log"
    limit=$FUZZ_TEST_TIMEOUT
    ((remaining >= limit)) || limit=$remaining

    printf -v command '%q ' env "${OPTIONS[@]}" timeout --signal=TERM \
        --kill-after=10s "${limit}s" bash "$SCRIPT_DIR/$test"

    printf '[%s] run=%d test=%s remaining=%ss timeout=%ss\nCOMMAND: %s\n' \
        "$(date -Is)" "$RUNS" "$test" "$remaining" "$limit" "$command" | tee "$log"

    test_start="$(date +%s)"
    # Show progress live while retaining the complete output in the run log.
    # PIPESTATUS[0] is the test/timeout result rather than tee's exit status.
    env "${OPTIONS[@]}" timeout --signal=TERM --kill-after=10s "${limit}s" \
        bash "$SCRIPT_DIR/$test" 2>&1 | tee -a "$log"
    status=${PIPESTATUS[0]}
    duration=$(($(date +%s) - test_start))
    printf '%d\t%s\t%d\t%d\t%s\n' "$RUNS" "$test" "$status" "$duration" "$log" >>"$RESULTS_FILE"

    if ((status != 0)); then
        FAILURES=$((FAILURES + 1))
        printf '%d\t%s\t%d\t%s\t%s\n' "$RUNS" "$test" "$status" "$command" "$log" >>"$FAILURES_FILE"
        printf 'FAIL status=%d log=%s\n' "$status" "$log" | tee -a "$log"
    else
        printf 'PASS log=%s\n' "$log" | tee -a "$log"
    fi
}

echo "D-voting custom fuzz: seed=$FUZZ_SEED duration=${FUZZ_SECONDS}s logs=$FUZZ_LOG_DIR"

# Baseline coverage: every discovered test is attempted at least once, subject to
# the global deadline. Later cycles rotate their starting point for varied order.
cycle=0
while (($(date +%s) < DEADLINE)); do
    for ((i = 0; i < ${#TESTS[@]}; i++)); do
        index=$(((i + cycle) % ${#TESTS[@]}))
        run_one "${TESTS[index]}" || break 2
    done
    cycle=$((cycle + 1))
done

elapsed=$(($(date +%s) - START_TIME))
printf 'Finished: runs=%d failures=%d elapsed=%ss seed=%s logs=%s\n' \
    "$RUNS" "$FAILURES" "$elapsed" "$FUZZ_SEED" "$FUZZ_LOG_DIR"
printf 'Results: %s\nFailures: %s\n' "$RESULTS_FILE" "$FAILURES_FILE"
((FAILURES == 0))
