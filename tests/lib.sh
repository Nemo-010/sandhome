#!/bin/sh
# tests/lib.sh - the tiny harness every sandhome test sources. POSIX sh.
# Sourced, never executed. Each test file counts and prints its own result.

: "${TESTS_NAME:=test}"
TESTS_RUN=0
TESTS_FAIL=0
TESTS_SKIP=0

t_begin() {
    TESTS_NAME=$1
    TESTS_RUN=0
    TESTS_FAIL=0
    TESTS_SKIP=0
    printf '== %s\n' "$TESTS_NAME"
}

# STOP: t_ok AND t_is COMPARE WITH THE SHELL AND NOT WITH `test`. A `test`/`[` that
# answers "too many arguments" for an empty operand, or a non-numeric string
# where an integer was wanted, RETURNS 2, prints its own error to stderr and
# counts nothing. Measured: `t_is "" 'wanted' 'desc'` printed FAIL and left
# TESTS_FAIL at 0, so a test file whose only broken clause was a helper that
# answered nothing exited 0 and the suite reported the file green.
t_ok() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$#" -lt 2 ]; then
        printf '  FAIL (harness) t_ok called with %s arguments\n' "$#"
        TESTS_FAIL=$((TESTS_FAIL + 1))
        return 0
    fi
    if [ "$1" = 0 ]; then
        printf '  ok   %s\n' "$2"
    else
        printf '  FAIL %s\n' "$2"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

t_is() {
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$#" -lt 3 ]; then
        printf '  FAIL (harness) t_is called with %s arguments\n' "$#"
        TESTS_FAIL=$((TESTS_FAIL + 1))
        return 0
    fi
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        printf '  FAIL %s (got %s, wanted %s)\n' "$3" "$1" "$2"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

t_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$1" in
        *"$2"*) printf '  ok   %s\n' "$3" ;;
        *)      printf '  FAIL %s (no %s in %s)\n' "$3" "$2" "$1"
                TESTS_FAIL=$((TESTS_FAIL + 1)) ;;
    esac
}

# t_skip DESCRIPTION -> the clause could not run here. It is printed, counted
# separately and reported at the end, so "could not run" never reads as "passed"
# and never turns a red file green.
t_skip() {
    TESTS_SKIP=$((TESTS_SKIP + 1))
    printf '  skip %s\n' "$1"
}

# t_end [EXIT_CODE] -> summarise and hand back the exit code the file should
# use. Every test file ends with `t_end`, so this is where the three claims are
# kept apart:
#   0  every clause that could run here passed
#   2  a clause could not run here (the suite maps this to "skipped")
#   1  a clause failed
t_end() {
    t_end_rc=${1:-0}
    if [ "$TESTS_FAIL" -gt 0 ]; then
        t_end_rc=1
    elif [ "${TESTS_SKIP:-0}" -gt 0 ] && [ "$t_end_rc" = 0 ]; then
        t_end_rc=2
    fi
    printf '%s: %s run, %s failed, %s skipped\n' \
        "$TESTS_NAME" "$TESTS_RUN" "$TESTS_FAIL" "${TESTS_SKIP:-0}"
    return "$t_end_rc"
}

# tests_repo_dir -> the checkout root, from this file's location.
tests_repo_dir() {
    CDPATH='' cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd
}
