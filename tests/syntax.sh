#!/bin/sh
# tests/syntax.sh - every shell file in this tree parses under the POSIX shells
# that will read it. `dash -n` is the check that matters; bash --posix is a
# second reader, so a file that is valid under dash and not under bash is found
# here rather than on the machine it was installed on.
#
# Exit 2 when there is no dash at all: `could not run` is not `passed`.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

if ! command -v dash >/dev/null 2>&1; then
    echo 'syntax: no dash to check with' >&2
    exit 2
fi
HAS_BASH=no
command -v bash >/dev/null 2>&1 && HAS_BASH=yes

t_begin syntax
for f in "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome "$ROOT"/lib/*.sh \
         "$ROOT"/tools/*.sh "$ROOT"/tests/*.sh "$ROOT"/shell/errandsh; do
    [ -f "$f" ] || continue
    rel=${f#"$ROOT"/}
    if dash -n "$f" 2>/tmp/sandhome-syntax.err; then
        t_ok 0 "dash -n $rel"
    else
        t_ok 1 "dash -n $rel: $(cat /tmp/sandhome-syntax.err)"
    fi
    if [ "$HAS_BASH" = yes ]; then
        if bash --posix -n "$f" 2>/tmp/sandhome-syntax.err; then
            t_ok 0 "bash --posix -n $rel"
        else
            t_ok 1 "bash --posix -n $rel: $(cat /tmp/sandhome-syntax.err)"
        fi
    fi
done
rm -f /tmp/sandhome-syntax.err

# The library may not use dirname (issue #16): a bootstrap whose job is
# installing the missing tools cannot require them first. sh_dirname in
# lib/common.sh is the shell-only equivalent. This scans code lines, not
# comments, so a comment naming dirname does not fail.
for f in "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh; do
    [ -f "$f" ] || continue
    rel=${f#"$ROOT"/}
    if grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -qE '(^|[^a-zA-Z0-9_.])dirname([^a-zA-Z0-9_.]|$)' 2>/dev/null; then
        t_ok 1 "$rel invokes dirname on a code line; use sh_dirname from lib/common.sh"
    else
        t_ok 0 "$rel carries no dirname dependency"
    fi
done
# The guard above must be able to fail: a planted dirname line is reported.
if printf 'x=$(dirname -- "$y")\n' | grep -qE '(^|[^a-zA-Z0-9_.])dirname([^a-zA-Z0-9_.]|$)' 2>/dev/null; then
    t_ok 0 'the dirname guard catches a planted dirname invocation'
else
    t_ok 1 'the dirname guard catches a planted dirname invocation'
fi

# Dead-guard detector (issue #6 anti-pattern): a flag that is READ in four
# places and SET in none is a constant, not a switch. ecs shipped
# `noninteractive` guards that always ran; the twin here was a stale
# SH_EXEC_UNUSABLE reset. Two clauses: the literal name never appears, and
# every SH_ flag tested anywhere is assigned somewhere in the tree.
if grep -rin 'noninteractive' "$ROOT"/lib "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome \
        "$ROOT"/tools "$ROOT"/shell 2>/dev/null | grep -qv '^.*:.*#'; then
    if grep -rin 'noninteractive' "$ROOT"/lib "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome \
            "$ROOT"/tools "$ROOT"/shell 2>/dev/null | grep -v '#' >/dev/null; then
        t_ok 1 'no noninteractive dead guard in the tree'
    else
        t_ok 0 'no noninteractive dead guard in the tree'
    fi
else
    t_ok 0 'no noninteractive dead guard in the tree'
fi
sh_dg_dead=''
for sh_dg_v in $(cat "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome \
        "$ROOT"/tools/*.sh "$ROOT"/shell/errandsh 2>/dev/null | \
        grep -o '\<SH_[A-Z][A-Z0-9_]*\>' | sort -u); do
    if grep -rq "$sh_dg_v[:=]" "$ROOT"/lib "$ROOT"/bootstrap.sh \
            "$ROOT"/bin/sandhome "$ROOT"/tools "$ROOT"/shell 2>/dev/null; then
        :
    else
        sh_dg_dead="$sh_dg_dead $sh_dg_v"
    fi
done
t_is "$sh_dg_dead" '' 'every SH_ flag read anywhere is assigned somewhere'
# The detector must be able to fail: a read-without-assign is reported.
sh_dg_probe=$(printf 'if [ "$SH_SHOULD_NOT_EXIST" = 1 ]; then :; fi\n' | \
    grep -o '\<SH_[A-Z][A-Z0-9_]*\>' | sort -u)
if [ "$sh_dg_probe" = SH_SHOULD_NOT_EXIST ] && \
   ! grep -rq 'SH_SHOULD_NOT_EXIST[:=]' "$ROOT"/lib "$ROOT"/bootstrap.sh \
        "$ROOT"/bin/sandhome "$ROOT"/tools "$ROOT"/shell 2>/dev/null; then
    t_ok 0 'the dead-guard detector catches a read-without-assign'
else
    t_ok 1 'the dead-guard detector catches a read-without-assign'
fi
t_end
