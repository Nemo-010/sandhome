#!/bin/sh
# tests/lib.sh - the tiny harness every sandhome test sources. POSIX sh.
# Sourced, never executed. Each test file counts and prints its own result.

: "${TESTS_NAME:=test}"
TESTS_RUN=0
TESTS_FAIL=0
TESTS_SKIP=0

# Tests never write the global hook into the PATH directories of the machine
# they run on: the candidate is a real directory of the host, and a suite that
# dropped `sandhome` and a dispatcher into `$HOME/.local/bin` would change the
# next test. tests/global.sh unsets this for the clauses that exercise the hook.
SANDHOME_GLOBAL=0
export SANDHOME_GLOBAL

t_begin() {
    TESTS_NAME=$1
    TESTS_RUN=0
    TESTS_FAIL=0
    TESTS_SKIP=0
    T_STAMP=''
    TESTS_LAST_TIME=$(date +%s 2>/dev/null)
    case "$TESTS_LAST_TIME" in ''|*[!0-9]*) TESTS_LAST_TIME=0 ;; esac
    printf '== %s\n' "$TESTS_NAME"
}

# t_stamp -> sets T_STAMP to " +Ns" since the previous clause when
# SH_TEST_TIMING=1, and to nothing otherwise. A slow suite is then diagnosed
# from its own output (which clause paid) instead of guessed at. Test-only, so
# it is not part of the published reference.
t_stamp() {
    T_STAMP=''
    [ "${SH_TEST_TIMING:-0}" = 1 ] || return 0
    : "${TESTS_LAST_TIME:=0}"
    sh_t_now=$(date +%s 2>/dev/null)
    case "$sh_t_now" in ''|*[!0-9]*) return 0 ;; esac
    T_STAMP=" +$((sh_t_now - TESTS_LAST_TIME))s"
    TESTS_LAST_TIME=$sh_t_now
    return 0
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
        t_stamp
        printf '  ok   %s%s\n' "$2" "$T_STAMP"
    else
        t_stamp
        printf '  FAIL %s%s\n' "$2" "$T_STAMP"
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
        t_stamp
        printf '  ok   %s%s\n' "$3" "$T_STAMP"
    else
        t_stamp
        printf '  FAIL %s (got %s, wanted %s)%s\n' "$3" "$1" "$2" "$T_STAMP"
        TESTS_FAIL=$((TESTS_FAIL + 1))
    fi
}

t_contains() {
    TESTS_RUN=$((TESTS_RUN + 1))
    t_stamp
    case "$1" in
        *"$2"*) printf '  ok   %s%s\n' "$3" "$T_STAMP" ;;
        *)      printf '  FAIL %s (no %s in %s)%s\n' "$3" "$2" "$1" "$T_STAMP"
                TESTS_FAIL=$((TESTS_FAIL + 1)) ;;
    esac
}

# t_skip DESCRIPTION -> the clause could not run here. It is printed, counted
# separately and reported at the end, so "could not run" never reads as "passed"
# and never turns a red file green.
t_skip() {
    TESTS_SKIP=$((TESTS_SKIP + 1))
    t_stamp
    printf '  skip %s%s\n' "$1" "$T_STAMP"
}

# t_end [EXIT_CODE] -> summarise, EXIT with the code, and never merely return
# it.
#
# # STOP: t_end EXITS AND DOES NOT RETURN, BECAUSE A TEST FILE'S EXIT STATUS IS
# ITS LAST COMMAND'S AND EVERY FILE ENDS HERE. `t_end` used to `return` the code
# and every caller ignored it, because a script cannot exit with a value another
# function returned. The result was the whole suite's weakest property: a file
# printed its own FAIL lines, printed "3 run, 3 failed, 0 skipped", and exited
# 0. tests/run.sh read the exit code to decide passed/failed, so the three
# failures were reported under `passed`, and a test file that failed was green.
# Measured here, on tests/harness.sh itself:
#   $ sh tests/harness.sh | tail -1
#   harness: 13 run, 2 failed, 0 skipped
#   $ sh tests/harness.sh >/dev/null 2>&1; echo $?
#   0
# `return` is kept for the in-process callers - a subshell that only wants the
# number - but the default is `exit`, and a caller that wants a return passes
# `t_end --return`.
#
# The three claims are kept apart:
#   0  every clause that could run here passed
#   2  a clause could not run here (the suite maps this to "skipped")
#   1  a clause failed
t_end() {
    t_end_rc=${1:-0}
    t_end_ret=''
    if [ "$t_end_rc" = --return ]; then
        t_end_ret=1
        t_end_rc=0
    fi
    if [ "$TESTS_FAIL" -gt 0 ]; then
        t_end_rc=1
    elif [ "${TESTS_SKIP:-0}" -gt 0 ] && [ "$t_end_rc" = 0 ]; then
        t_end_rc=2
    fi
    printf '%s: %s run, %s failed, %s skipped\n' \
        "$TESTS_NAME" "$TESTS_RUN" "$TESTS_FAIL" "${TESTS_SKIP:-0}"
    if [ -n "$t_end_ret" ]; then
        return "$t_end_rc"
    fi
    exit "$t_end_rc"
}

# t_exec_tmpdir PREFIX -> a temp dir that actually runs binaries, printed on
# stdout. /tmp and /dev/shm refuse execve on some sandboxes while /workspace
# runs them (measured: this machine runs /workspace and refuses /tmp and
# /dev/shm), and the reverse holds on others, so a test that builds a probe
# into ${TMPDIR:-/tmp} fails with Permission denied on exactly the machine the
# tree exists for. The order is larger exec-capable volumes first, then the
# standard tmp roots, and every entry is probed with a real file before it can
# win; a dir that does not exist is made, a dir that refuses exec loses. Falls
# back to ${TMPDIR:-/tmp} even when nothing runs, so callers always get a dir
# and the exec failure is measured at run time rather than at mktemp time.
t_exec_tmpdir() {
    t_et_prefix=${1:-sandhome-test}
    t_et_probe() {
        [ -d "$1" ] || return 1
        t_et_f="$1/.sandhome.exec.$$"
        if ! printf '#!/bin/sh\nexit 0\n' > "$t_et_f" 2>/dev/null; then rm -f "$t_et_f" 2>/dev/null; return 1; fi
        chmod 0700 "$t_et_f" 2>/dev/null || true
        if "$t_et_f" >/dev/null 2>&1; then rm -f "$t_et_f" 2>/dev/null; return 0; fi
        rm -f "$t_et_f" 2>/dev/null; return 1
    }
    for t_et_base in "/workspace" "$PWD" "${TMPDIR:-}" /tmp /dev/shm "${HOME:-}/.cache"; do
        [ -n "$t_et_base" ] || continue
        [ -d "$t_et_base" ] || continue
        t_et_try="$t_et_base/.sandhome-test-$$"
        mkdir -p "$t_et_try" 2>/dev/null || continue
        if t_et_probe "$t_et_try"; then
            t_et_dir=$(mktemp -d "$t_et_try/$t_et_prefix.XXXXXX" 2>/dev/null) || t_et_dir="$t_et_try/$t_et_prefix.$$"
            mkdir -p "$t_et_dir" 2>/dev/null || continue
            printf '%s' "$t_et_dir"
            return 0
        fi
        rmdir "$t_et_try" 2>/dev/null || true
    done
    mktemp -d "${TMPDIR:-/tmp}/$t_et_prefix.XXXXXX" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/$t_et_prefix.$$"
}

# tests_repo_dir -> the checkout root, from this file's location.
tests_repo_dir() {
    CDPATH='' cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd
}
