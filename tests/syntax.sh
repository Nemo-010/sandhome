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
    # No array here either: the brackets are a grep character class matching
    # a literal : or = after the flag name.
    # shellcheck disable=SC1087
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
    # The default exec root is `$PWD/.sandhome/exec`, and it holds installed
    # binaries. It is gitignored, so a tree that carries one still ships no
    # ELF files; without this the repo suite went red after its own
    # bootstrap (found by consuming the checkout).
    if ".sandhome" in dirnames:
        dirnames.remove(".sandhome")
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

# ShellCheck over the tree, when it is here to run. The module in tools/
# provides it (`sandhome install shellcheck`); without it the clause reports it could not run
# rather than passing blind. Severity error: warnings are advisory and differ
# across ShellCheck versions, while an error is a defect on any version.
if command -v shellcheck >/dev/null 2>&1; then
    sh_sc_out=$(shellcheck -S error -s sh \
        "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome "$ROOT"/lib/*.sh \
        "$ROOT"/tools/*.sh "$ROOT"/tests/*.sh "$ROOT"/shell/errandsh 2>&1) || true
    # The linter names the file and line for every finding; the clause holds
    # when it printed nothing. The output is quoted in full on failure, because
    # a lint failure without its lines is a direction, not a defect.
    if [ -z "$sh_sc_out" ]; then
        t_ok 0 'shellcheck -S error is clean over the tree'
    else
        t_ok 1 "shellcheck -S error over the tree: $sh_sc_out"
    fi
else
    t_skip 'no shellcheck on PATH to lint with (sandhome install shellcheck)'
fi

# --- #136: the bare command, and the help word, on a POSIX shell ------------
# A scratch dir for the stderr captures below, on a root that runs binaries (a
# noexec root would refuse the command and the clause would report a property
# of the host instead of of the code).
work=$(t_exec_tmpdir sandhome-syntax136)
mkdir -p "$work" 2>/dev/null

# `sandhome` with no arguments matched the help branch, which then ran `shift`
# with $#=0. bash ignores that, dash writes "shift: can't shift that many" to
# stderr, and the one screen a person sees when they forget the subcommand was
# a shell diagnostic instead of the usage text (issue #136). The clause runs the
# real command under every shell this host has and reads stderr SEPARATELY
# from the status, because the two are the whole claim: exit 0 on stdout, and
# nothing on stderr.
for sh_136 in dash sh bash; do
    command -v "$sh_136" >/dev/null 2>&1 || continue
    sh_136_out=$("$sh_136" "$ROOT/bin/sandhome" 2>"$work/.e136" </dev/null); sh_136_rc=$?
    sh_136_err=$(cat "$work/.e136" 2>/dev/null)
    t_is "$sh_136_rc" '0' "a bare sandhome exits 0 on $sh_136 (issue #136)"
    t_is "$sh_136_err" '' "a bare sandhome writes nothing to stderr on $sh_136 (issue #136)"
    case "$sh_136_out" in
        'usage: sandhome'*) t_ok 0 "a bare sandhome prints the usage on stdout on $sh_136 (issue #136)" ;;
        *) t_ok 1 "a bare sandhome prints the usage on stdout on $sh_136 (issue #136)" ;;
    esac
    # `sandhome help <cmd>` must reach the page for that command, which the
    # first fix for #136 broke by reading the word AFTER the shift.
    sh_136_h=$("$sh_136" "$ROOT/bin/sandhome" help doctor 2>"$work/.e136h" </dev/null); sh_136_hrc=$?
    case "$sh_136_h" in
        'usage: sandhome doctor'*) t_ok 0 "sandhome help doctor prints the doctor page on $sh_136 (issue #136)" ;;
        *) t_ok 1 "sandhome help doctor prints the doctor page on $sh_136 (issue #136)" ;;
    esac
    t_is "$sh_136_hrc" '0' "sandhome help doctor exits 0 on $sh_136 (issue #136)"
    # and the flag form, which used to answer "no help for '--help'" with exit 2
    "$sh_136" "$ROOT/bin/sandhome" --help >/dev/null 2>"$work/.e136f" </dev/null
    t_is "$?" '0' "sandhome --help exits 0 on $sh_136 (issue #136)"
    t_is "$(cat "$work/.e136f" 2>/dev/null)" '' "sandhome --help writes nothing to stderr on $sh_136 (issue #136)"
    "$sh_136" "$ROOT/bin/sandhome" -h >/dev/null 2>&1 </dev/null
    t_is "$?" '0' "sandhome -h exits 0 on $sh_136 (issue #136)"
done
# A shift inside a function cannot move the caller's list, and a guard written
# there is a silent no-op: the file once routed every dispatcher branch through
# a `sh_dispatch_shift` helper, and `cmd_project` then received the SUBCOMMAND as
# its first argument. The clause refuses that shape outright, because the guard
# looks right and does nothing: $# and $1 inside a function are the function's.
# The rule is about the DISPATCHER specifically: a `shift` inside a function
# cannot move the caller's list, and a guard written there is a silent no-op
# (measured: $# read 0 inside the function while the caller held one argument,
# and cmd_project then received the subcommand as its first argument). The
# clause reads only the dispatcher's own function, so an ordinary command's
# `for arg; do shift; done` is not implicated.
ds_fn=$(sed -n '/^sh_dispatch_shift() {/,/^}/p' "$ROOT/bin/sandhome" 2>/dev/null)
case "$ds_fn" in
    '') t_ok 0 'the dispatcher has no shift helper whose shift would be a no-op (POSIX sh)' ;;
    *shift*) t_ok 1 'the dispatcher has no shift helper whose shift would be a no-op (POSIX sh)' ;;
    *) t_ok 0 'the dispatcher has no shift helper whose shift would be a no-op (POSIX sh)' ;;
esac

t_end
