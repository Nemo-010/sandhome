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
t_end
