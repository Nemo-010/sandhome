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
# SCOPE, stated so a future edit does not assume it is wider: the rule lives in
# AGENTS.md rule 4 for "the library", so lib/*.sh and the pre-library
# bootstrap.sh are scanned. bin/sandhome, tools/*.sh and shell/errandsh load
# the library before doing anything and carry no dirname today; if one ever
# grows a dirname call, extend the loop rather than assuming the guard is
# already there.
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

# The profile fragment never prompts (issue #17): a consent gate belongs in
# the bootstrap, which runs once, not in the login path, where a prompt is
# the failure mode the fragment exists to avoid.
if grep -v '^[[:space:]]*#' "$ROOT"/lib/profile.sh 2>/dev/null | \
        grep -qE '(^|[^a-zA-Z0-9_])read +-p|(^|[^a-zA-Z0-9_])select([^a-zA-Z0-9_]|$)' 2>/dev/null; then
    t_ok 1 'lib/profile.sh never prompts at shell start'
else
    t_ok 0 'lib/profile.sh never prompts at shell start'
fi

# No committed ELF objects (issue #12 counter-example): in-tree binaries with
# no version manifest are the thing NOTICE refuses. A vendored binary fails
# here before it can gain a caller. Without python3 the clause reports it
# could not run rather than passing blind.
if command -v python3 >/dev/null 2>&1; then
    sh_elf_bad=$(SH_SANDHOME_ROOT=$ROOT python3 -c '
import os
bad = []
root = os.environ["SH_SANDHOME_ROOT"]
for dirpath, dirnames, filenames in os.walk(root):
    if ".git" in dirnames:
        dirnames.remove(".git")
    for fn in filenames:
        fpath = os.path.join(dirpath, fn)
        try:
            with open(fpath, "rb") as fh:
                if fh.read(4) == b"\x7fELF":
                    bad.append(os.path.relpath(fpath, root))
        except OSError:
            pass
print(" ".join(sorted(bad)))
' 2>/dev/null)
    t_is "$sh_elf_bad" '' 'the tree ships no committed ELF binaries'
else
    t_skip 'no python3 to scan for committed ELF binaries'
fi

# Sourcing a module must be silent. `dash -n` accepts a bare word on its own
# line (it is syntactically valid), so a truncated comment that leaves one
# behind parses cleanly and then fails at every source with `X: not found`.
# Measured: a `driver.` line in tools/rust.sh passed both parsers and broke
# every repair. Sourcing must print nothing.
sh_src_noise=$(for f in "$ROOT"/lib/*.sh "$ROOT"/tools/*.sh; do
    [ -f "$f" ] || continue
    sh -c '. "$1"' sh "$f" 2>&1
 done)
t_is "$sh_src_noise" '' 'sourcing every library and tool module prints nothing'

t_end
