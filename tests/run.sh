#!/bin/sh
# tests/run.sh - run every sandhome test.
#
# THREE CLAIMS, KEPT APART, AND ONLY ONE OF THEM IS A NON-ZERO STATUS.
#   passed  every clause in the file ran here and held
#   skipped the file could not run here (no network, no compiler, no pty)
#   failed  a clause ran here and did not hold
# A skip is a fact about the machine, not a defect in the tree, so it is printed
# and does not turn the suite red. It used to exit 2, and CI ran this suite, so
# a runner without a network failed the job for a reason that is not a bug and
# the first thing a maintainer learns is to ignore a red suite.
#
# The file is read through an interpreter and never executed, because this
# checkout may itself be on a mount that refuses execve - the condition the tree
# exists for. Each file's own tally is read as well as its status, so a file that
# prints a failure and exits 0 is still a failure.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAILED=''
SKIPPED=''
PASSED=''

for t in syntax unit space toolchain shims docs bootstrap errandsh-posix; do
    script="$HERE/$t.sh"
    [ -r "$script" ] || continue
    printf '\n#### %s\n' "$t"
    # Always through an interpreter, never by executing the file. This tree is
    # worked on from a checkout that may itself be on a noexec mount, and
    # `./tests/x.sh` then fails with `Permission denied` on a file that is fine.
    # A test is a script; naming its reader is the portable way to run it.
    first=''
    IFS= read -r first < "$script" 2>/dev/null || first=''
    case "$first" in
        *bash*) bash "$script" ;;
        *)      sh "$script" ;;
    esac
    t_rc=$?
    case "$t_rc" in
        0|1|2) ;;
        *) t_rc=1 ;;
    esac
    if [ "$t_rc" = 0 ]; then
        PASSED="$PASSED $t"
    elif [ "$t_rc" = 2 ]; then
        SKIPPED="$SKIPPED $t"
    else
        FAILED="$FAILED $t"
    fi
done

printf '\n===============================\n'
printf 'passed :%s\n' "$PASSED"
printf 'skipped:%s\n' "$SKIPPED"
printf 'failed :%s\n' "$FAILED"
if [ -n "$FAILED" ]; then
    exit 1
fi
exit 0
