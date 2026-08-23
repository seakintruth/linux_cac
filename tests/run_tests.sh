#!/usr/bin/env bash
# tests/run_tests.sh
#
# Test suite for cac_setup.sh.
#
# Pure-bash, dependency-free runner (no bats required). Sources the script's
# function definitions without executing main() by truncating the file at the
# final "main" invocation line, then exercises individual functions and the
# full main() flow against stubbed external commands on PATH.
#
# Usage:  bash tests/run_tests.sh [-v]
#   -v  verbose: print each passing test name

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CAC_SCRIPT="$PROJECT_ROOT/cac_setup.sh"

VERBOSE=false
[ "${1:-}" = "-v" ] && VERBOSE=true

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""

# ---------------------------------------------------------------- helpers ---

# Load only the function definitions from cac_setup.sh (strip trailing `main`).
load_script_functions() {
    # The script calls `main` as its last line; drop everything from that line
    # onward so sourcing defines functions but does not run anything.
    awk '/^main$/{exit} {print}' "$CAC_SCRIPT"
}

# Run one test function in a fresh subshell with a clean environment.
# Test functions are named test_* and live in tests/test_*.sh files.
run_test() {
    local test_name="$1" test_file="$2"
    CURRENT_TEST="$test_name"

    local output exit_code
    output="$(bash "$test_file" "$test_name" 2>&1)"
    exit_code=$?

    if [ "$exit_code" -eq 0 ]
    then
        PASS_COUNT=$((PASS_COUNT + 1))
        $VERBOSE && echo "PASS: $test_name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "FAIL: $test_name"
        echo "$output" | sed 's/^/    /'
    fi
}

# Assertions used inside test bodies (sourced by the runner shim below).
assert_equals() {
    # assert_equals <expected> <actual> [message]
    if [ "$1" != "$2" ]
    then
        echo "assert_equals failed${3:+: $3}"
        echo "  expected: [$1]"
        echo "  actual:   [$2]"
        exit 1
    fi
}

assert_contains() {
    # assert_contains <haystack> <needle> [message]
    case "$1" in
        *"$2"*) return 0 ;;
        *)
            echo "assert_contains failed${3:+: $3}"
            echo "  haystack: [$1]"
            echo "  needle:   [$2]"
            exit 1
            ;;
    esac
}

assert_not_contains() {
    if [[ "$1" == *"$2"* ]]
    then
        echo "assert_not_contains failed${3:+: $3}"
        echo "  haystack must not contain: [$2]"
        exit 1
    fi
}

assert_exit_code() {
    # assert_exit_code <expected_code> — checks $? captured by caller
    local expected="$1" actual="${2:-$?}"
    if [ "$expected" != "$actual" ]
    then
        echo "assert_exit_code failed: expected $expected, got $actual"
        exit 1
    fi
}

# --------------------------------------------------------------- discovery ---

# Each tests/test_*.sh must define run_case() dispatching on $1 to its own
# test_ functions. The runner executes each registered test name in isolation.
collect_tests() {
    # Emits "<file>:<test_name>" lines.
    for f in "$SCRIPT_DIR"/test_*.sh
    do
        [ -e "$f" ] || continue
        while IFS= read -r name; do
            echo "$f:$name"
        done < <(bash "$f" --list)
    done
}

TEST_SPECS="$(collect_tests)"

for spec in $TEST_SPECS
do
    f="${spec%%:*}"
    t="${spec#*:}"
    run_test "$t" "$f"
done

echo
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed."

if [ "$FAIL_COUNT" -gt 0 ]
then
    exit 1
fi
exit 0
