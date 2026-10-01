#!/bin/sh
# tests/harness.sh - the harness itself, guarded.
#
# WHY THIS FILE EXISTS. `tests/lib.sh` documents, at length and from a real
# measurement, that a test helper which answers nothing counts nothing:
#
#   Measured: `t_is "" 'wanted' 'desc'` printed FAIL and left TESTS_FAIL at 0,
#   so a test file whose only broken clause was a helper that answered nothing
#   exited 0 and the suite reported the file green.
#
# That measurement is the best argument in the tree and it is enforced by a
# comment. A comment cannot fail, so nothing would notice if the behaviour
# regressed. This file is the guard: it calls the harness in the exact way the
# bug was measured, and fails when the counters do not move.
#
# # STOP: A TEST THAT CANNOT FAIL IS NOT A TEST, AND THIS IS THE FILE THAT
# SAYS SO ABOUT ITSELF. Everything below is an executed clause about the code
# that grades the rest of the suite, so a break in t_ok/t_is/t_end cannot make
# the whole suite green. It is run by `sandhome selftest` and by tests/run.sh.
#
# Exit 2 only when this file itself cannot run, which is exit 2 from a broken
# harness rather than from a machine that lacks something.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

t_begin harness

# # STOP: THIS FILE'S OWN ASSERTIONS DO NOT USE t_is, AND THAT IS THE POINT.
# The first version graded itself with `t_is`, which is the helper it exists to
# guard. When the plant was made - `t_is` printing FAIL without incrementing
# TESTS_FAIL, the exact defect tests/lib.sh documents - the harness's own
# clauses stopped counting, it printed 13 run / 0 failed against a plant that
# had broken two of them, and it exited 0. A guard built from the thing it
# guards is not a guard; it is a copy of the failure. Every assertion below
# therefore counts its own failure with arithmetic and prints through `h_fail`
# and `h_ok`, which have no counters to break.
h_fail=0
h_run=0
h_ok()   { h_run=$((h_run + 1)); printf '  ok   %s\n' "$1"; }
h_no()   { h_run=$((h_run + 1)); h_fail=$((h_fail + 1)); printf '  FAIL %s\n' "$1"; }
h_is() {
    h_run=$((h_run + 1))
    if [ "$1" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        h_fail=$((h_fail + 1))
        printf '  FAIL %s (got %s, wanted %s)\n' "$3" "$1" "$2"
    fi
}

# Each case below runs in a SUBSHELL with its own counters, so one case cannot
# satisfy another's expectation, and the totals printed by this file are the
# real ones rather than an artefact of the last case.
#   h_case SCRIPT -> runs SCRIPT and prints ONLY "<run> <fail> <skip> <rc>".
#
# # STOP: THE STATUS HERE IS COMPUTED FROM THE COUNTERS AND NOT READ FROM t_end.
# The helper used to call the library's t_end to get the status, and when the
# `t_end exits` regression was planted, that call `exit`ed inside a command
# substitution and the whole harness produced NO OUTPUT and exited 2 - a
# detection, but a silent one that looks like the harness failed to run rather
# than a guard that fired. A guard must fail LOUDLY and it must not depend on the
# very helper it is grading. So the status here is the same three-way decision
# t_end makes, written out, and no clause below calls t_end at all; clauses 8
# and 9 drive a real file in a real shell, where t_end's behaviour is the thing
# under test.
#
# t_skip is a SKIP, not a run: it deliberately does not increment TESTS_RUN, so
# a case that only skips has run=0. That is the harness's own contract and this
# file measures it rather than working around it.
h_case() {
    (
        TESTS_RUN=0; TESTS_FAIL=0; TESTS_SKIP=0
        eval "$1" >/dev/null 2>&1
        h_rc=0
        if [ "$TESTS_FAIL" -gt 0 ]; then
            h_rc=1
        elif [ "$TESTS_SKIP" -gt 0 ]; then
            h_rc=2
        fi
        printf '%s %s %s %s' "$TESTS_RUN" "$TESTS_FAIL" "$TESTS_SKIP" "$h_rc"
    )
}
# h_case_exit SCRIPT -> the SCRIPT chooses its own status by calling t_end with
# an argument, and the counters are read from a second pass that does not call
# it. The exit code of the first pass is the status t_end chose.
h_case_exit() {
    ( TESTS_RUN=0; TESTS_FAIL=0; TESTS_SKIP=0; eval "$1" >/dev/null 2>&1 )
    h_er=$?
    h_counts=$(
        TESTS_RUN=0; TESTS_FAIL=0; TESTS_SKIP=0
        eval "${1%% t_end*}" >/dev/null 2>&1
        printf '%s %s %s' "$TESTS_RUN" "$TESTS_FAIL" "$TESTS_SKIP"
    )
    # shellcheck disable=SC2086
    set -- $h_counts
    printf '%s %s %s %s' "$1" "$2" "$3" "$h_er"
}
# h_case_ret is the in-process form: the script calls `t_end --return` itself.
h_case_ret() { h_case "$@"; }

# --- 1: a FAILING t_is COUNTS -------------------------------------------
# The exact measurement from tests/lib.sh's own note. A helper that prints FAIL
# and leaves the counter at zero is what made a broken file report green.
out=$(h_case "t_is '' wanted 'a failing t_is'")
# shellcheck disable=SC2086
set -- $out
h_is "$1 $2 $3" '1 1 0' 'a failing t_is counts one run and one failure'
h_is "$4" '1' 'a file whose only clause failed exits 1'

# --- 2: a FAILING t_ok COUNTS -------------------------------------------
out=$(h_case "t_ok 1 'a failing t_ok'")
# shellcheck disable=SC2086
set -- $out
h_is "$1 $2 $3" '1 1 0' 'a failing t_ok counts one run and one failure'
h_is "$4" '1' 'a failing t_ok alone exits 1'

# --- 3: A PASSING CLAUSE COUNTS A RUN AND NOT A FAILURE -----------------
out=$(h_case "t_ok 0 'a passing t_ok'; t_is one one 'a passing t_is'")
# shellcheck disable=SC2086
set -- $out
h_is "$1 $2 $3" '2 0 0' 'two passing clauses count two runs and no failures'
h_is "$4" '0' 'a file whose clauses all passed exits 0'

# --- 4: A SKIP IS EXIT 2 AND NEVER A PASS ------------------------------
# The third claim in t_end's contract. `skipped` inherits the meaning "could
# not run", which is only true when the missing thing is the test's own
# dependency; a file that skips because it could not do its job is not a pass,
# and it must not be 0. A skip is NOT a run: t_skip increments the skip counter
# only, so this case has zero runs and one skip.
out=$(h_case "t_skip 'nothing to run'")
# shellcheck disable=SC2086
set -- $out
h_is "$1 $2 $3" '0 0 1' 'a skip counts a skip and not a run'
h_is "$4" '2' 'a file whose only clause skipped exits 2, not 0'

# --- 5: A FAIL BEATS A SKIP -------------------------------------------
# A file with both a failure and a skip is a failure. The order of the two arms
# in t_end is the whole of that claim.
out=$(h_case "t_skip 'nothing'; t_ok 1 'this failed'")
# shellcheck disable=SC2086
set -- $out
h_is "$4" '1' 'a failure outranks a skip: the file is 1, not 2'

# --- 6: AN EXPLICIT EXIT CODE IS NOT LOST ------------------------------
# t_end takes an argument, and a caller may pass 1. The failure arm must not
# be the only way to reach a non-zero status, but it must also not lose the
# caller's intent when the clauses all passed.
out=$(h_case_exit "t_ok 0 'passed'; t_end 1")
# shellcheck disable=SC2086
set -- $out
h_is "$4" '1' 'an explicit non-zero from the caller survives when nothing failed'
out=$(h_case_exit "t_ok 0 'passed'; t_end 2")
# shellcheck disable=SC2086
set -- $out
h_is "$4" '2' 'an explicit 2 from the caller survives when nothing failed'

# --- 7: A MIS-CALLED t_is FAILS AND DOES NOT SILENTLY PASS --------------
# t_is with too few arguments used to be a line that did nothing. A helper
# called wrongly must be a FAILURE, not a shrug, or a typo in a test file is a
# clause that never ran and a file that never failed.
out=$(h_case "t_is onearg")
# shellcheck disable=SC2086
set -- $out
h_is "$1 $2 $3" '1 1 0' 'a t_is called with too few arguments is a failure'
h_is "$4" '1' 'a mis-called t_is still exits non-zero'

# --- 8: A FILE THAT PRINTS FAIL EXITS NON-ZERO --------------------------
# The claim `tests/run.sh` depends on and the one every file in the suite was
# getting wrong. t_end used to `return` its status, a script cannot exit with
# another function's return value, and so a file whose last command was NOT
# t_end ended 0:
#   $ sh tests/harness.sh | tail -1
#   harness: 13 run, 3 failed, 0 skipped
#   $ sh tests/harness.sh >/dev/null 2>&1; echo $?
#   0
# The distinction that matters, and that a first version of this clause got
# wrong, is WHERE t_end sits. A script whose LAST command is t_end inherits its
# status either way - `t_end 1` as the last line returns 1, which is the
# script's status - so a probe file ending in t_end cannot tell the two
# behaviours apart and reported the regression as clean. The defect is a file
# that keeps running after t_end, which every file with a `trap` or a final
# summary does. Both shapes are driven here, and only the second one can
# distinguish them.
probe="$HERE/.harness-probe.$$"
cat > "$probe" <<PROBE
. "$ROOT/tests/lib.sh"
t_begin probe
t_is x y 'a clause that must fail'
t_end
: 'a last command after t_end, as any file with a trap or a summary has'
PROBE
probe_out=$(sh "$probe" 2>&1)
probe_rc=$?
rm -f "$probe"
h_is "$probe_rc" '1' 'a file that printed FAIL exits 1 even with a command after t_end'
case "$probe_out" in
    *'1 run, 1 failed'*) h_ok 'a file that printed FAIL says so in its summary' ;;
    *) h_no "a file that printed FAIL says so in its summary (got: $probe_out)" ;;
esac

# --- 9: AND A CLEAN FILE EXITS ZERO -------------------------------------
# The other half of claim 8, and the half that matters for a guard nobody has
# seen refuse: a harness that refuses everything looks exactly like a good one
# until it blocks real work.
probe="$HERE/.harness-probe2.$$"
cat > "$probe" <<PROBE
. "$ROOT/tests/lib.sh"
t_begin probe2
t_is x x 'a clause that passes'
t_end
: 'a last command after t_end'
PROBE
probe_out=$(sh "$probe" 2>&1)
probe_rc=$?
rm -f "$probe"
h_is "$probe_rc" '0' 'a file whose clauses all passed exits 0'

# --- 10: AND A SKIPPED FILE IS NOT A PASS, ON THE SAME SHAPE ------------
# The third status, on the same "something runs after t_end" shape, because
# tests/run.sh maps 2 to `skipped` and a file that skipped into a green suite.
probe="$HERE/.harness-probe3.$$"
cat > "$probe" <<PROBE
. "$ROOT/tests/lib.sh"
t_begin probe3
t_skip 'nothing to run here'
t_end
: 'a last command after t_end'
PROBE
probe_out=$(sh "$probe" 2>&1)
probe_rc=$?
rm -f "$probe"
h_is "$probe_rc" '2' 'a file whose only clause skipped exits 2, with a command after t_end'

printf 'harness: %s run, %s failed, 0 skipped\n' "$h_run" "$h_fail"
[ "$h_fail" -gt 0 ] && exit 1
exit 0
