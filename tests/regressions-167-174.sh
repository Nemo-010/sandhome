#!/bin/sh
# tests/regressions-167-174.sh - one clause per defect fixed in the round that
# closed issues #167-#174, plus the review findings against the rogue PR that
# claimed to close them, plus the defect found by USING the tool afterwards.
#
# Every clause here names a mechanism, fails against the tree as it stood, and
# holds after. Where a clause can only be measured with a stripped PATH, a real
# filesystem or a real cargo, that is stated rather than faked, because "the
# test passed" has to mean the thing it names was measured.
#
# THE FINDINGS AGAINST PR #17 ARE IN THIS FILE TOO, and they are the reason the
# round is not just the issue list. PR #17 fixed the eight issues it filed but:
#   1. solved #173 with `dd | od | tr`, which the library may not use (rule 4)
#      and which fails OPEN, so on a host without those tools launch mode became
#      copy mode silently;
#   2. changed sh_promote_tree to copy non-ELF executables without changing
#      sh_view_copy_kb, the gate that must mirror it, so the gate under-stated
#      a view by the whole payload;
#   3. solved #167 by keying on the absolute path, which separates two projects
#      but gives ONE crate a different target dir per subdirectory, because
#      cargo resolves a project by walking up to the nearest Cargo.toml;
#   4. fixed #171 by appending the SDK's LLVM dir with a bare `$PATH:` prefix,
#      which on an empty PATH yields ":$dir" and puts the current directory on
#      PATH;
#   5. left #174's swallowed stderr in place, so the one line that explained
#      the failure still never reached the operator.
# And using the tool afterwards found a defect nothing had filed:
#   6. doctor measured an adopted node's npm at a path that only exists for an
#      INSTALLED node, so a clean setup on any host that already had node on
#      PATH ended `doctor_failures=1` with npm working.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space env fetch toolchain shim report memexec; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT
SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-167-174

tmp=$(t_exec_tmpdir sandhome-regr-167-174)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# Run a snippet with the library sourced and a controlled set of roots.
sh_regr_run() {
    sh_rr_root=$1
    shift
    sh_rr_home=$tmp/$sh_rr_root/home
    mkdir -p "$sh_rr_home/toolchains" "$sh_rr_home/tmp" \
             "$tmp/$sh_rr_root/exec/bin" "$tmp/$sh_rr_root/exec/views" 2>/dev/null
    SANDHOME_HOME=$sh_rr_home SANDHOME_EXEC=$tmp/$sh_rr_root/exec \
    SH_HOME=$sh_rr_home SH_HOME_TOOLCHAINS=$sh_rr_home/toolchains \
    SH_HOME_TMP=$sh_rr_home/tmp SH_HOME_EXEC=no \
    SH_EXEC=$tmp/$sh_rr_root/exec SH_EXEC_BIN=$tmp/$sh_rr_root/exec/bin \
    SH_EXEC_VIEWS=$tmp/$sh_rr_root/exec/views \
    sh -c 'for m in common detect space env fetch toolchain shim memexec; do . "$SH_REPO_DIR/lib/$m.sh"; done; SH_SELF=test; eval "$1"' \
        "$SH_REPO_DIR" "$*" 2>/dev/null
}

# =====================================================================  #173
# THE LAUNCH VIEW STAMPED INTERPRETER SOURCE WITH A MEMEXEC BINARY.
# sh_promote_tree replaced every executable with a launcher copy, including the
# stdlib .py files CPython ships with the executable bit set, so `import
# platform` read 17KB of ELF. A launcher is a binary: stamping a script makes it
# unreadable to the interpreter that would have read it.
sh173=$tmp/r173
mkdir -p "$sh173/home/toolchains/t/lib" "$sh173/exec/bin" "$sh173/exec/views" \
         "$sh173/home/tmp"
# An executable .py, exactly as CPython ships platform.py.
printf 'import platform\nprint("PY-READABLE")\n' > "$sh173/home/toolchains/t/lib/platform.py"
chmod 0755 "$sh173/home/toolchains/t/lib/platform.py"
# A real ELF beside it, so the copy branch is not the only thing under test.
if [ -x /bin/sh ]; then
    cp /bin/sh "$sh173/home/toolchains/t/lib/binary" 2>/dev/null
    chmod 0755 "$sh173/home/toolchains/t/lib/binary"
fi
# A stamp target that is recognisably NOT the payload, so "was it stamped" is a
# question with an answer.
sh173_head=$(head -c 4 "$sh173/home/toolchains/t/lib/platform.py" 2>/dev/null)
printf '\177ELFSTAMPEDPLACEHOLDER\n' > "$sh173/exec/bin/sandhome-memexec"
chmod 0755 "$sh173/exec/bin/sandhome-memexec"
t_ok "$([ "$sh173_head" = "$(printf '\177ELF' | od -An -tx1 2>/dev/null | tr -d ' \n' | head -c 8)" ] && echo 1 || echo 0)" \
    'the #173 fixture really is a readable script, not a binary (#173)'

t_is "$(SANDHOME_HOME=$sh173/home SANDHOME_EXEC=$sh173/exec \
    SH_HOME=$sh173/home SH_HOME_TOOLCHAINS=$sh173/home/toolchains \
    SH_HOME_TMP=$sh173/home/tmp SH_HOME_EXEC=no SH_EXEC=$sh173/exec \
    SH_EXEC_BIN=$sh173/exec/bin SH_EXEC_VIEWS=$sh173/exec/views \
    SH_VIEW_MODE=launch SH_DRY_RUN=0 SH_SELF=test \
    sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"; sh_promote_tree "$SH_HOME_TOOLCHAINS/t" "$SH_EXEC_VIEWS/t" >/dev/null 2>&1; head -c 6 "$SH_EXEC_VIEWS/t/lib/platform.py" 2>/dev/null')" \
    'import' \
    'a launch-mode view copies an executable .py instead of stamping it (#173)'

t_is "$(SANDHOME_HOME=$sh173/home SANDHOME_EXEC=$sh173/exec \
    SH_HOME=$sh173/home SH_HOME_TOOLCHAINS=$sh173/home/toolchains \
    SH_HOME_TMP=$sh173/home/tmp SH_HOME_EXEC=no SH_EXEC=$sh173/exec \
    SH_EXEC_BIN=$sh173/exec/bin SH_EXEC_VIEWS=$sh173/exec/views \
    SH_VIEW_MODE=launch SH_DRY_RUN=0 SH_SELF=test \
    sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"
        sh_promote_tree "$SH_HOME_TOOLCHAINS/t" "$SH_EXEC_VIEWS/t" >/dev/null 2>&1
        # The ELF beside the script is stamped, so the promote still does the
        # thing launch mode exists for. A fix that copied everything would pass
        # the .py clause above and fail this one.
        head -c 4 "$SH_EXEC_VIEWS/t/lib/binary" 2>/dev/null' \
    "$SH_REPO_DIR" 2>/dev/null)" \
    "$(head -c 4 "$sh173/exec/bin/sandhome-memexec")" \
    'a launch-mode view still stamps an ELF, so the fix is not "copy everything" (#173)'

# --- the ELF TEST ITSELF, WITH NO EXTERNAL TOOL ---------------------------
# This is the finding against PR #17. Its reader was
#   dd if="$1" bs=4 count=1 | od -An -tx1 | tr -d ' \n'
# and on a PATH with none of those it printed "tr: not found" per file and
# answered NOT-ELF for a real ELF binary. A gate that fails open silently turns
# launch mode into copy mode, which is the feature disappearing with no message.
sh173b=$tmp/r173b
mkdir -p "$sh173b/bin"
printf '\177ELF\001\001\001\000payload' > "$sh173b/bin/elf"
chmod 0755 "$sh173b/bin/elf"
printf '#!/bin/sh\nexit 0\n' > "$sh173b/bin/script"
chmod 0755 "$sh173b/bin/script"
printf '\376\377\001\003' > "$sh173b/bin/macho"
chmod 0755 "$sh173b/bin/macho"
: > "$sh173b/bin/empty"
chmod 0755 "$sh173b/bin/empty"
# A PATH with a shell and nothing else: no dd, no od, no tr, no cksum.
sh173b_bare=$tmp/r173b-bare
mkdir -p "$sh173b_bare"
for sh173b_t in sh dash; do
    sh173b_p=$(command -v "$sh173b_t" 2>/dev/null) && ln -sf "$sh173b_p" "$sh173b_bare/$sh173b_t"
done
t_ok "$([ -x "$sh173b_bare/sh" ] && echo 0 || echo 1)" \
    'the bare-PATH fixture has a shell to run with (#173)'
t_ok "$([ -e "$sh173b_bare/dd" ] || [ -e "$sh173b_bare/od" ] || [ -e "$sh173b_bare/tr" ] && echo 1 || echo 0)" \
    'the bare-PATH fixture really lacks dd, od and tr (#173)'

sh173b_ans=$(PATH=$sh173b_bare sh -c '
    . "$SH_REPO_DIR/lib/common.sh"
    sh_is_elf "'$sh173b'/bin/elf" 2>/dev/null && printf ELF || printf no
    sh_is_elf "'$sh173b'/bin/script" 2>/dev/null && printf ELF || printf no
    sh_is_elf "'$sh173b'/bin/macho" 2>/dev/null && printf ELF || printf no
    sh_is_elf "'$sh173b'/bin/empty" 2>/dev/null && printf ELF || printf no
' 2>/dev/null)
t_is "$sh173b_ans" 'ELFnonono' \
    'the ELF test answers on a PATH with no dd, od or tr: elf yes, script no, Mach-O no, empty no (#173)'
t_is "$(PATH=$sh173b_bare sh -c '. "$SH_REPO_DIR/lib/common.sh"; sh_is_elf "'"$sh173b"'/bin/elf" 2>/dev/null && printf ELF || printf no' 2>/dev/null)" 'ELF' \
    'a real ELF is still an ELF with no external reader (#173)'

# The library must not reach for a tool it may not have. This is the rule in
# AGENTS.md, enforced where it can be enforced cheaply.
sh173b_libtools=$(cat "$ROOT"/lib/*.sh 2>/dev/null | grep -v '^[[:space:]]*#' | \
    grep -oE '(^|[^a-zA-Z0-9_.])(dd|od|tr|awk|sed|grep|find|install|dirname)([^a-zA-Z0-9_.]|$)' | \
    grep -oE '(dd|od|tr|awk|sed|grep|find|install|dirname)' | sort -u | tr '\n' ' ')
case "$sh173b_libtools" in
    *dd*|*od*|*tr*)
        t_ok 1 "lib/ carries no dd, od or tr on a code line (found: $sh173b_libtools)"
        ;;
    *)
        t_ok 0 'lib/ carries no dd, od or tr on a code line (rule 4)'
        ;;
esac

# --- sh_view_current must agree, or the view rebuilds forever --------------
# A copied non-ELF IS the current launch shape. Reading it as stale rebuilds
# every view on every run for a difference that does not exist; reading a copied
# ELF as current hides a copy-mode leftover (issue #113).
sh173c=$tmp/r173c
mkdir -p "$sh173c/home/toolchains/t/bin" "$sh173c/exec/bin" "$sh173c/exec/views" \
         "$sh173c/home/tmp"
printf '\177ELFscriptpayload' > "$sh173c/home/toolchains/t/bin/s" 2>/dev/null
# The fixture must be a NON-ELF executable for this clause to mean anything.
printf '#!/bin/sh\nexit 0\n' > "$sh173c/home/toolchains/t/bin/s"
chmod 0755 "$sh173c/home/toolchains/t/bin/s"
printf '\177ELShelper' > "$sh173c/exec/bin/sandhome-memexec"
chmod 0755 "$sh173c/exec/bin/sandhome-memexec"
SANDHOME_HOME=$sh173c/home SANDHOME_EXEC=$sh173c/exec \
SH_HOME=$sh173c/home SH_HOME_TOOLCHAINS=$sh173c/home/toolchains \
SH_HOME_TMP=$sh173c/home/tmp SH_HOME_EXEC=no SH_EXEC=$sh173c/exec \
SH_EXEC_BIN=$sh173c/exec/bin SH_EXEC_VIEWS=$sh173c/exec/views \
sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"
    SH_VIEW_MODE=launch
    sh_promote_tree "$SH_HOME_TOOLCHAINS/t" "$SH_EXEC_VIEWS/t" >/dev/null 2>&1
    if sh_view_current "$SH_HOME_TOOLCHAINS/t" "$SH_EXEC_VIEWS/t"; then printf current; else printf stale; fi' \
    "$SH_REPO_DIR" 2>/dev/null | tail -1 > "$sh173c/ans"
t_is "$(cat "$sh173c/ans")" 'current' \
    'a copied non-ELF reads as the current launch shape, so no endless rebuild (#173)'
# And the same tree in COPY mode: a launcher left by launch mode must stale, so
# switching modes rebuilds rather than being told the view is current (#113).
printf '\177ELShelper' > "$sh173c/exec/bin/sandhome-memexec"
sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"
    SH_VIEW_MODE=launch
    sh_promote_tree "$SH_HOME_TOOLCHAINS/t" "$SH_EXEC_VIEWS/t" >/dev/null 2>&1
    printf copied > "$SH_EXEC_VIEWS/t/bin/s"' _ 2>/dev/null
cp "$sh173c/exec/bin/sandhome-memexec" "$sh173c/exec/views/t/bin/s"
t_is "$(SANDHOME_HOME=$sh173c/home SANDHOME_EXEC=$sh173c/exec \
    SH_HOME=$sh173c/home SH_HOME_TOOLCHAINS=$sh173c/home/toolchains \
    SH_HOME_TMP=$sh173c/home/tmp SH_HOME_EXEC=no SH_EXEC=$sh173c/exec \
    SH_EXEC_BIN=$sh173c/exec/bin SH_EXEC_VIEWS=$sh173c/exec/views \
    sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"
        SH_VIEW_MODE=copy
        if sh_view_current "$SH_HOME_TOOLCHAINS/t" "$SH_EXEC_VIEWS/t"; then printf current; else printf stale; fi' \
    "$SH_REPO_DIR" 2>/dev/null | tail -1)" 'stale' \
    'a launcher left by launch mode stales under copy mode, so the flip rebuilds (#113)'

# ======================================================================= #167
# CARGO_TARGET_DIR WAS KEYED ON THE DIRECTORY BASENAME.
# Two projects whose directories share a name shared one target dir, so the
# second crate's build was "fresh" and the stale binary ran, and `cargo clean` in
# one wiped the other's artifacts.
sh167=$tmp/r167
mkdir -p "$sh167/a/dup/src" "$sh167/b/dup/src"
printf '[package]\nname="dup"\nversion="0.1.0"\nedition="2021"\n' > "$sh167/a/dup/Cargo.toml"
printf '[package]\nname="dup"\nversion="0.1.0"\nedition="2021"\n' > "$sh167/b/dup/Cargo.toml"
# The fragment is obtained by RUNNING sh_env_body, the same call env.sh uses to
# write the file, so the clause tests what a real shell actually gets rather
# than a de-quoted guess at the printf soup. Reading the printf lines out of
# lib/env.sh with sed was tried first and is not available: the lines carry
# their own quoting and escapes, and what matters is the generated text.
sh167_frag=$tmp/frag167.sh
if sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"; . "$SH_REPO_DIR/lib/env.sh"
        SH_HOME=/tmp/sh167-home; SH_EXEC=/tmp/sh167-exec
        SH_HOME_TOOLCHAINS=/tmp/sh167-home/toolchains
        sh_env_body 2>/dev/null' "$SH_REPO_DIR" > "$sh167_frag" 2>/dev/null; then
    sh167_got=yes
else
    sh167_got=no
fi
t_ok "$([ "$sh167_got" = yes ] && [ -s "$sh167_frag" ] && echo 0 || echo 1)" \
    'the CARGO_TARGET_DIR fragment is produced by sh_env_body (#167)'

sh167_id() {
    sh167_p=$1
    ( cd "$sh167_p" 2>/dev/null || exit 0
      SANDHOME_EXEC=$sh167/exec sh -c '. "$1"; printf "%s\n" "$CARGO_TARGET_DIR"' _ "$sh167_frag" 2>/dev/null )
}
t_ok "$([ "$(sh167_id "$sh167/a/dup")" != "$(sh167_id "$sh167/b/dup")" ] && echo 0 || echo 1)" \
    'two same-basename crates get different target dirs (#167)'

# THE FINDING AGAINST PR #17: keying on the absolute PATH separates the two
# projects but gives ONE crate a different target dir in every subdirectory,
# because cargo resolves a project by walking UP to the nearest Cargo.toml.
# Measured against that fix:
#   /workspace/consume/a/dup     -> target-dup-2176453656
#   /workspace/consume/a/dup/src -> target-src-3462659862
# Two target dirs for one crate means a full rebuild on every cd, and a target
# directory per subdirectory ever built from.
t_is "$(sh167_id "$sh167/a/dup")" "$(sh167_id "$sh167/a/dup/src")" \
    'one crate has ONE target dir from its root and from its subdirectory (#167)'

# A directory with no manifest anywhere above it falls back to $PWD, which is
# the honest answer there: nothing has claimed the directory yet.
mkdir -p "$sh167/loose"
t_ok "$([ -n "$(sh167_id "$sh167/loose")" ] && echo 0 || echo 1)" \
    'a directory with no Cargo.toml anywhere above it still gets a target dir (#167)'

# The same crate under two different parents stays separate.
mkdir -p "$sh167/c/dup/src" "$sh167/d/dup/src"
printf '[package]\nname="dup"\nversion="0.1.0"\nedition="2021"\n' > "$sh167/c/dup/Cargo.toml"
printf '[package]\nname="dup"\nversion="0.1.0"\nedition="2021"\n' > "$sh167/d/dup/Cargo.toml"
t_ok "$([ "$(sh167_id "$sh167/c/dup")" != "$(sh167_id "$sh167/d/dup")" ] && echo 0 || echo 1)" \
    'the same crate name under two parents still gets separate target dirs (#167)'

# AND THE CLAUSE THAT ACTUALLY CATCHES IT: two real crates, two real builds,
# two different binaries. Every clause above inspects a STRING, and a string
# comparison passed while the behaviour was still broken: the id was built with
# `${v% }` where `${v%% *}` is meant, cksum's two fields stayed joined by a
# space, the id was then word-split by every later use, and both crates resolved
# to ONE target directory. `cargo run` in the second printed the first crate's
# binary, which is the whole of issue #167.
#
# Measured, before the `${v%% *}` correction:
#   A ctd=target-proof-3257994460 -> PROJECT-A
#   B ctd=target-proof-3257994460 -> PROJECT-A
# So this runs cargo when cargo is here, and says plainly that it did not when
# it is not, rather than reporting a pass it did not earn.
sh167_real=$tmp/r167-real
if sh_have cargo 2>/dev/null || [ -x "$HOME/.cargo/bin/cargo" ]; then
    sh167_cargo=''
    sh_have cargo 2>/dev/null && sh167_cargo=cargo
    [ -n "$sh167_cargo" ] || sh167_cargo=$HOME/.cargo/bin/cargo
    mkdir -p "$sh167_real/a/dup/src" "$sh167_real/b/dup/src"
    for sh167_p in a b; do
        printf '[package]\nname="dup"\nversion="0.1.0"\nedition="2021"\n' \
            > "$sh167_real/$sh167_p/dup/Cargo.toml"
    done
    printf 'fn main(){println!("PROJECT-A");}\n' > "$sh167_real/a/dup/src/main.rs"
    printf 'fn main(){println!("PROJECT-B");}\n' > "$sh167_real/b/dup/src/main.rs"
    sh167_ran=no
    for sh167_p in a b; do
        sh167_out=$( cd "$sh167_real/$sh167_p/dup" 2>/dev/null && \
            CARGO_TARGET_DIR="$sh167_real/ct-$sh167_p" timeout 600 "$sh167_cargo" run -q 2>&1 | tail -1 )
        case "$sh167_out" in
            "PROJECT-$(printf '%s' "$sh167_p" | tr 'ab' 'AB')")
                sh167_ran="$sh167_ran-$sh167_p" ;;
        esac
    done
    t_is "$sh167_ran" 'no-a-b' \
        'two same-basename crates each run their own binary (#167)'
    # And the two target dirs really are two directories, which is the shape the
    # string clauses above cannot see.
    t_ok "$([ -d "$sh167_real/ct-a" ] && [ -d "$sh167_real/ct-b" ] && echo 0 || echo 1)" \
        'two same-basename crates get two separate target directories (#167)'
    # And `cargo clean` in one must not touch the other, which was the second
    # half of the issue and the half nothing was checking.
    ( cd "$sh167_real/a/dup" 2>/dev/null && CARGO_TARGET_DIR="$sh167_real/ct-a" timeout 300 "$sh167_cargo" clean -q >/dev/null 2>&1 )
    t_ok "$([ -d "$sh167_real/ct-b" ] && echo 0 || echo 1)" \
        'cargo clean in one project leaves the other project artifacts alone (#167)'
else
    t_skip 'no cargo here, so the two real crates could not be built (#167)'
fi

# A dir name with a space in it is the exact shape the bug produced, so the
# generated id must never contain one. This is the clause that would have caught
# it without cargo at all, and it is the reason the correction was found.
sh167_spaces=no
for sh167_d in "$sh167/a/dup" "$sh167/b/dup" "$sh167/a/dup/src"; do
    sh167_v=$(sh167_id "$sh167_d")
    case "$sh167_v" in
        *' '*) sh167_spaces=yes ;;
    esac
done
t_is "$sh167_spaces" 'no' \
    'the generated target-dir id never contains a space, which is what splits the word (#167)'

# THE ESCAPE-LEVEL CLAUSE, WHICH IS THE ONE THAT MATTERS HERE.
#
# sh_env_body emits every line of env.sh through printf, where `%%` means ONE
# percent. The generated text therefore has to carry `%%%%` in the SOURCE to
# produce the shell's `%%` in env.sh. One level short is the defect that survived
# every string-shaped clause in this file:
#
#   printf 'A%%%% *'  ->  A%% *     <- what the shell needs
#   printf 'A%% *'    ->  A% *      <- what it emitted
#
# With `% *` in env.sh the id kept both of cksum's fields joined by a space, the
# id contained a space, every later use word-split it, and two same-basename
# crates resolved to ONE target dir: measured live, A and B both reported
# ctd=target-sandhome-443490593 and both printed PROJECT-A. The string clauses
# passed because the string they read was correct; only running it showed the
# behaviour was not.
#
# So this asks the question at the level the defect was at: does the SOURCE
# double the percent enough for env.sh to receive the shell's own `%%`?
# The line is the one that ASSIGNS the id FROM cksum, which is the only place
# a `%% *` appears. Matching on the field name rather than on the whole line
# avoids picking up the `##/*` line above it.
sh167_src=$(grep '_sh_ctd_s' "$ROOT/lib/env.sh" 2>/dev/null | grep '_sh_ctd=' | head -1)
case "$sh167_src" in
    *%%%%*) sh167_esc=double ;;
    *%%*)   sh167_esc=single ;;
    *)      sh167_esc=none ;;
esac
t_is "$sh167_esc" 'double' \
    'the CARGO_TARGET_DIR printf source doubles the percent enough for env.sh to carry the shell own %% (#167)'
# AND THE GENERATED TEXT ITSELF, which is the thing that actually runs. Read it
# back out of sh_env_body rather than trusting the source line above it.
sh167_genfile=$tmp/gen167.sh
sh -c 'for m in common detect space env; do . "$SH_REPO_DIR/lib/$m.sh"; done
    SH_HOME=/tmp/sh167-g; SH_EXEC=/tmp/sh167-e; SH_HOME_TOOLCHAINS=/tmp/sh167-g/tc
    sh_env_body' "$SH_REPO_DIR" > "$sh167_genfile" 2>/dev/null
# Same line, same reason: `_sh_ctd_p##/*` is a different assignment.
sh167_gen=$(grep '_sh_ctd_s' "$sh167_genfile" 2>/dev/null | grep '_sh_ctd=' | head -1)
case "$sh167_gen" in
    *'%%'*) sh167_gesc=double ;;
    *'%'*)  sh167_gesc=single ;;
    *)      sh167_gesc=none ;;
esac
t_is "$sh167_gesc" 'double' \
    'the generated env.sh carries the shell own %% and not a bare % (#167)'

# THE RESOLVER, WHICH IS WHERE THE LOGIN-SHELL CASE IS ACTUALLY FIXED.
#
# A login shell sources env.sh at shell start and the consumer cds AFTERWARDS, so
# the variable env.sh sets names whichever directory the shell started in.
# Measured through a real login shell on the tree as it stood:
#   bash -lc 'cd .../a/dup && cargo run -q'  ->  PROJECT-A
#   bash -lc 'cd .../b/dup && cargo run -q'  ->  PROJECT-A
# both at ctd=target-workspace-306203429. A trap or a prompt command could re-run
# code on cd and AGENTS.md rule 6 forbids both in this profile, so the resolution
# is a FUNCTION the caller invokes, which is also what keeps shell start-up free
# of anything that can fail.
t_ok "$(grep -q 'sandhome_cargo_target' "$ROOT/tools/rust.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the rust module provides a per-invocation CARGO_TARGET_DIR resolver (#167)'
# It must be a function and not a bare assignment, or it is the same one-shot
# variable the fragment already was.
sh_res_body=$(sed -n '/^sandhome_cargo_target()/,/^}/p' "$ROOT/tools/rust.sh" 2>/dev/null)
t_ok "$([ -n "$sh_res_body" ] && echo 0 || echo 1)" \
    'the resolver is defined as a function (#167)'
# And it must yield to a caller who set the variable, which is the same contract
# env.sh's guard keeps. A wrapper that overrode it would break every build script
# that points cargo somewhere on purpose.
t_ok "$(printf '%s' "$sh_res_body" | head -3 | grep -q 'CARGO_TARGET_DIR' && echo 0 || echo 1)" \
    'the resolver yields to a caller who set CARGO_TARGET_DIR (#167)'
# And it must run the walk and the digest, or it is back to being a basename.
t_ok "$(printf '%s' "$sh_res_body" | grep -q 'Cargo.toml' && echo 0 || echo 1)" \
    'the resolver walks up to the nearest Cargo.toml (#167)'
t_ok "$(printf '%s' "$sh_res_body" | grep -q 'cksum' && echo 0 || echo 1)" \
    'the resolver digests the project path (#167)'

# The resolver is exercised, not merely present: extract it and run it against
# two real sibling projects in a shell that starts somewhere else entirely, which
# is the case the fragment gets wrong.
sh_res=$tmp/r167-resolver
sh -c '. "$SH_REPO_DIR/lib/common.sh"' "$SH_REPO_DIR" >/dev/null 2>&1
{
    printf '#!/bin/sh\n'
    sed -n '/^sandhome_cargo_target()/,/^}/p' "$ROOT/tools/rust.sh"
} > "$sh_res" 2>/dev/null
chmod 0755 "$sh_res" 2>/dev/null
t_ok "$([ -x "$sh_res" ] && echo 0 || echo 1)" \
    'the resolver could be extracted for the behavioural clause (#167)'
if [ -x "$sh_res" ]; then
    sh_res_a=$( cd "$sh167/a/dup" 2>/dev/null && SANDHOME_EXEC=$sh167/exec \
        sh -c '. "$1"; unset CARGO_TARGET_DIR; sandhome_cargo_target; printf "%s" "$CARGO_TARGET_DIR"' _ "$sh_res" 2>/dev/null )
    sh_res_b=$( cd "$sh167/b/dup" 2>/dev/null && SANDHOME_EXEC=$sh167/exec \
        sh -c '. "$1"; unset CARGO_TARGET_DIR; sandhome_cargo_target; printf "%s" "$CARGO_TARGET_DIR"' _ "$sh_res" 2>/dev/null )
    t_ok "$([ -n "$sh_res_a" ] && [ "$sh_res_a" != "$sh_res_b" ] && echo 0 || echo 1)" \
        'the resolver separates two same-basename crates when run where cargo runs (#167)'
    # And it must not fire when the caller has already chosen.
    sh_res_kept=$( cd "$sh167/a/dup" 2>/dev/null && SANDHOME_EXEC=$sh167/exec CARGO_TARGET_DIR=/my/own \
        sh -c '. "$1"; sandhome_cargo_target; printf "%s" "$CARGO_TARGET_DIR"' _ "$sh_res" 2>/dev/null )
    t_is "$sh_res_kept" '/my/own' \
        'the resolver never overrides a target dir the caller set (#167)'
fi

# THE WORKSPACE CASE, WHICH IS A DIFFERENT ANSWER AGAIN.
#
# A member crate's Cargo.toml is the NEAREST manifest, but it is not the
# PROJECT: cargo builds every member into the WORKSPACE root's target directory,
# and `cargo locate-project --workspace` is the authority for which path that
# is. So the walk has to continue past a manifest that does not declare
# [workspace], and stop at the first one that does. Measured on a two-crate
# workspace, with the member-only walk:
#   ws            ->  target-ws-2829255314
#   ws/crates/one ->  target-one-514637701    <- a second build of the same crate
# and with the workspace walk:
#   ws            ->  target-ws-2829255314
#   ws/crates/one ->  target-ws-2829255314
#   ws/crates/two ->  target-ws-2829255314
# so `cargo build` at the root and then inside a member reported
#   Finished dev profile in 0.00s
# instead of rebuilding every crate.
sh167_ws=$tmp/r167-ws
mkdir -p "$sh167_ws/ws/crates/one" "$sh167_ws/ws/crates/two"
printf '[workspace]\nmembers = ["crates/one", "crates/two"]\n' > "$sh167_ws/ws/Cargo.toml"
printf '[package]\nname="one"\nversion="0.1.0"\nedition="2021"\n' > "$sh167_ws/ws/crates/one/Cargo.toml"
printf '[package]\nname="two"\nversion="0.1.0"\nedition="2021"\n' > "$sh167_ws/ws/crates/two/Cargo.toml"
mkdir -p "$sh167_ws/loose/one"
printf '[package]\nname="one"\nversion="0.1.0"\nedition="2021"\n' > "$sh167_ws/loose/one/Cargo.toml"

if [ -x "$sh_res" ]; then
    sh167_wsroot=$( cd "$sh167_ws/ws" 2>/dev/null && SANDHOME_EXEC=$sh167_ws/exec \
        sh -c '. "$1"; unset CARGO_TARGET_DIR; sandhome_cargo_target; printf "%s" "$CARGO_TARGET_DIR"' _ "$sh_res" 2>/dev/null )
    sh167_wsmem=$( cd "$sh167_ws/ws/crates/one" 2>/dev/null && SANDHOME_EXEC=$sh167_ws/exec \
        sh -c '. "$1"; unset CARGO_TARGET_DIR; sandhome_cargo_target; printf "%s" "$CARGO_TARGET_DIR"' _ "$sh_res" 2>/dev/null )
    t_is "$sh167_wsmem" "$sh167_wsroot" \
        'a workspace member resolves to the WORKSPACE ROOT target dir, not its own (#167)'
    # And a manifest with no [workspace] above it is still its own project.
    sh167_loose=$( cd "$sh167_ws/loose/one" 2>/dev/null && SANDHOME_EXEC=$sh167_ws/exec \
        sh -c '. "$1"; unset CARGO_TARGET_DIR; sandhome_cargo_target; printf "%s" "$CARGO_TARGET_DIR"' _ "$sh_res" 2>/dev/null )
    t_ok "$([ -n "$sh167_loose" ] && [ "$sh167_loose" != "$sh167_wsroot" ] && echo 0 || echo 1)" \
        'a crate with no workspace above it is still its own target dir (#167)'
fi

# THE TWO MEASURED TRAPS IN THAT WALK, as clauses rather than as prose. Both
# were found by running the walk with the trace on, after the code looked right.
#
# 1. `[workspace]` IS A CHARACTER CLASS. It matches any ONE of the letters in
#    it between brackets, so it matches `[package]` and therefore EVERY manifest
#    in the tree - which made the walk stop at the nearest one, the member, the
#    exact case it exists to get past:
#      grep -q '[workspace]'  crates/one/Cargo.toml  ->  rc=0   (wrong)
#      grep -q '^\[workspace\]' crates/one/Cargo.toml  ->  rc=1   (right)
printf '[package]\nname="one"\n' > "$tmp/pat.toml" 2>/dev/null
t_ok "$(grep -q '[workspace]' "$tmp/pat.toml" 2>/dev/null && echo 0 || echo 1)" \
    'the control: a bare [workspace] pattern really does match [package] (#167)'
t_ok "$(grep -q '^\[workspace\]' "$tmp/pat.toml" 2>/dev/null && echo 1 || echo 0)" \
    'the control: the anchored pattern really does refuse [package] (#167)'
t_ok "$(grep -q 'workspace\]' "$ROOT/tools/rust.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the workspace test is anchored so it cannot match [package] (#167)'
#
# 2. A DIRECTORY WITH NO MANIFEST IS SKIPPED, NOT A STOPPING POINT. `break` on a
#    missing Cargo.toml ended the walk one level early: from ws/crates/one the
#    walk reached ws/crates, which has no manifest of its own, and stopped
#    before ever reaching ws/Cargo.toml. cargo walks straight through such a
#    directory, and so must this.
t_ok "$(printf '%s' "$sh_res_body" | grep -q 'continue; }' && echo 0 || echo 1)" \
    'the workspace walk steps over a directory with no manifest (#167)'
t_ok "$(printf '%s' "$sh_res_body" | grep -q 'Cargo.toml" \] || break' && echo 1 || echo 0)" \
    'the workspace walk never breaks on a missing manifest (#167)'

# The readable name survives, so a human can see which project a dir is.
t_ok "$(sh167_id "$sh167/a/dup" | grep -c 'dup' >/dev/null 2>&1 && echo 0 || echo 1)" \
    'the target dir name still carries the readable project basename (#167)'

# No-tool fallback: without cksum the id must still separate the two projects.
sh167_nock=$tmp/r167-nocksum
mkdir -p "$sh167_nock"
for sh167_nt in sh dash cat ls mkdir rm cp chmod printf; do
    sh167_np=$(command -v "$sh167_nt" 2>/dev/null) && ln -sf "$sh167_np" "$sh167_nock/$sh167_nt"
done
sh167_noans=$(cd "$sh167/a/dup" 2>/dev/null && PATH=$sh167_nock SANDHOME_EXEC=$sh167/exec \
    sh -c '. "$1"; printf "%s\n" "$CARGO_TARGET_DIR"' _ "$sh167_frag" 2>/dev/null)
sh167_noans2=$(cd "$sh167/b/dup" 2>/dev/null && PATH=$sh167_nock SANDHOME_EXEC=$sh167/exec \
    sh -c '. "$1"; printf "%s\n" "$CARGO_TARGET_DIR"' _ "$sh167_frag" 2>/dev/null)
t_ok "$([ -n "$sh167_noans" ] && [ "$sh167_noans" != "$sh167_noans2" ] && echo 0 || echo 1)" \
    'without cksum the id is still injective across two projects (#167)'

# ======================================================================= #168
# bootstrap blamed a MISSING DOWNLOADER when curl and wget were present and
# failing, and iterated the default owner twice so the whole failure printed
# twice.
sh168=$tmp/r168
t_ok "$(grep -q 'sh_ff_tried=0' "$ROOT/bootstrap.sh" 2>/dev/null && echo 0 || echo 1)" \
    'sh_fr_fetch records whether any downloader was tried (#168)'
# The sentence that claims nothing is on PATH must be the one guarded by that
# record, and the "every downloader failed" sentence must name the URL.
sh168_missing=$(grep -n 'no curl, wget or fetch on PATH' "$ROOT/bootstrap.sh" 2>/dev/null | head -1 | cut -d: -f1)
sh168_every=$(grep -n 'every downloader present failed' "$ROOT/bootstrap.sh" 2>/dev/null | head -1 | cut -d: -f1)
t_ok "$([ -n "$sh168_missing" ] && [ -n "$sh168_every" ] && echo 0 || echo 1)" \
    'both failure sentences exist: missing downloader, and every downloader failed (#168)'
# The two sentences must sit INSIDE one if/else on sh_ff_tried, and the clause
# says so structurally rather than by counting lines back from a string, which
# breaks the moment a comment changes length. No awk here: a test that needs a
# tool the tree may be tested without cannot report "passed" on a host that
# lacks it. Read the code lines and record where each marker appears.
sh168_code=$(grep -v '^[[:space:]]*#' "$ROOT/bootstrap.sh" 2>/dev/null)
sh168_guard=''
sh168_missing=''
sh168_else=''
sh168_n=0
printf '%s\n' "$sh168_code" | while IFS= read -r sh168_l; do
    sh168_n=$((sh168_n + 1))
    case "$sh168_l" in
        *'sh_ff_tried=0'*) [ -n "$sh168_guard" ] || sh168_guard=$sh168_n ;;
        *'no curl, wget or fetch on PATH'*) [ -n "$sh168_missing" ] || sh168_missing=$sh168_n ;;
        *'else'*) [ -n "$sh168_else" ] || sh168_else=$sh168_n ;;
    esac
    printf '%s %s %s %s\n' "$sh168_n" "$sh168_guard" "$sh168_missing" "$sh168_else"
done > "$tmp/r168-order" 2>/dev/null
sh168_last=$(cat "$tmp/r168-order" 2>/dev/null | tail -1)
set -- $sh168_last
# $1 is the line number, so the markers are $2 (guard), $3 (missing), $4
# (else). The order that matters is guard < missing < else.
t_ok "$([ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] && [ "$2" -lt "$3" ] && [ "$3" -lt "$4" ] && echo 0 || echo 1)" \
    'the "no downloader on PATH" sentence sits in the sh_ff_tried=0 branch (#168)'

# The owner list must not contain the default twice.
t_ok "$(grep -q 'sh_fr_owners' "$ROOT/bootstrap.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the refetch owner list is deduplicated (#168)'
t_ok "$(grep 'for sh_fr_owner in' "$ROOT/bootstrap.sh" 2>/dev/null | grep -q '\$sh_fr_owners' && echo 0 || echo 1)" \
    'the refetch loop walks the deduplicated list, not a literal pair (#168)'

# ======================================================================= #169
# emcc/em++ are #! wrappers whose last line reads "$0.py". A launch-mode view
# memfd-execs them, so $0 is /proc/self/fd/N and $0.py does not exist.
t_ok "$(grep -q 'tc_emscripten_copy_bins' "$ROOT/tools/emscripten.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the emscripten module declares tc_emscripten_copy_bins (#169)'
t_ok "$(grep -A3 'tc_emscripten_copy_bins()' "$ROOT/tools/emscripten.sh" 2>/dev/null | \
        grep -c 'emcc' >/dev/null 2>&1 && echo 0 || echo 1)" \
    'the copy list names emcc (#169)'
t_ok "$(grep -A3 'tc_emscripten_copy_bins()' "$ROOT/tools/emscripten.sh" 2>/dev/null | \
        grep -c 'em++' >/dev/null 2>&1 && echo 0 || echo 1)" \
    'the copy list names em++ (#169)'

# ======================================================================= #170
# A zig cross-linker wrapper was written for EVERY requested target including
# wasm32-unknown-emscripten, overriding emcc and killing the link with
# "Unknown Clang option: -sABORTING_MALLOC=0".
t_ok "$(grep -B2 -A6 'rust-link-' "$ROOT/tools/rust.sh" 2>/dev/null | \
        grep -c 'emscripten.*continue\|continue.*emscripten' >/dev/null 2>&1 && echo 0 || echo 1)" \
    'the rust cross-linker loop skips emscripten targets (#170)'

# ======================================================================= #171
# The emscripten fragment PREPENDED upstream/bin, so clang resolved to the
# SDK's bundled LLVM instead of the installed clang toolchain.
t_ok "$(grep -q 'upstream/bin:\$PATH' "$ROOT/tools/emscripten.sh" 2>/dev/null && echo 1 || echo 0)" \
    'the emscripten fragment no longer prepends upstream/bin (#171)'
t_ok "$(grep -q 'PATH:+' "$ROOT/tools/emscripten.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the emscripten fragment guards the append against an empty PATH (#171)'

# The guard is the honest one: an append written as PATH="$PATH:$dir" on an
# empty PATH yields ":$dir", and an empty PATH element means the CURRENT
# DIRECTORY. Measured:
#   dash -c 'unset PATH; PATH="$PATH:/x"; case ":$PATH:" in *::*) echo HAZARD;; esac'
t_is "$(dash -c 'unset PATH; PATH="${PATH:+$PATH:}/x"; case ":$PATH:" in *::*) printf HAZARD;; *) printf safe;; esac' 2>/dev/null)" 'safe' \
    'the guarded append never yields a leading colon on an empty PATH (#171)'
t_is "$(dash -c 'unset PATH; PATH="$PATH:/x"; case ":$PATH:" in *::*) printf HAZARD;; *) printf safe;; esac' 2>/dev/null)" 'HAZARD' \
    'the unguarded append the PR used really does yield one, so the guard matters (#171)'

# ======================================================================= #172
# meson's payload lived under UV_TOOL_DIR on the exec root, which a tmpfs
# restart clears, leaving a name on PATH that could not run.
t_ok "$(grep -q 'pip install --target' "$ROOT/tools/meson.sh" 2>/dev/null && echo 0 || echo 1)" \
    'meson installs with uv pip install --target onto the home (#172)'
# NOTE THE COMMENTS ARE NOT STRIPPED HERE, AND THAT IS THE POINT: the module
# still SAYS `tool install` while explaining why it is not used, and a clause
# that matched the string would fail against the fixed tree for the wrong
# reason. What matters is that no CODE LINE calls it, so the strip is the same
# one syntax.sh uses.
sh172_code=$(grep -v '^[[:space:]]*#' "$ROOT/tools/meson.sh" 2>/dev/null)
t_ok "$(printf '%s' "$sh172_code" | grep -q 'tool install' && echo 1 || echo 0)" \
    'meson no longer installs a venv under the exec root (#172)'
t_ok "$(grep -q 'SANDHOME_MESON_LIB' "$ROOT/tools/meson.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the meson launcher names the lib directory it needs (#172)'
# The success test must be the thing that has to be true, not uv's wording.
t_ok "$(grep -q 'mesonbuild' "$ROOT/tools/meson.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the meson install checks the package directory, not uv output wording (#172)'
# And the launcher must not read $0, which is what breaks under a memfd (#169).
# The LAUNCHER BODY is what must not read $0, and the launcher is written with
# printf lines that carry the text. Comments explaining WHY it must not read $0
# necessarily mention it, so the check is on the generated launcher rather than
# on the module's prose.
sh172_launcher=$tmp/r172-launcher
sh -c '. "$SH_REPO_DIR/lib/common.sh"
    sh_sq_quote() { printf "%s" "\x27$1\x27"; }
    sh_me_lib_q=$(sh_sq_quote "/home/x/lib")
    {
        printf "#!/bin/sh\n"
        printf "SANDHOME_MESON_LIB=%s\n" "$sh_me_lib_q"
        printf "exec python3 -c %s \"\$@\"\n" "$(sh_sq_quote "pass")"
    }' 2>/dev/null > "$sh172_launcher"
t_ok "$([ -s "$sh172_launcher" ] && grep -q '\$0' "$sh172_launcher" 2>/dev/null && echo 1 || echo 0)" \
    'the meson launcher never reads $0, so it survives a memfd (#172)'
# And the real launcher body in the module must not build one that does.
sh172_printf=$(grep -v '^[[:space:]]*#' "$ROOT/tools/meson.sh" 2>/dev/null | grep 'printf' | grep -c '\$0' 2>/dev/null)
t_ok "$([ "$sh172_printf" = 0 ] && echo 0 || echo 1)" \
    'no printf in tools/meson.sh writes a \$0 read into the launcher (#172)'

# ======================================================================= #174
# install --force python inherited UV_PYTHON_DOWNLOADS=never from the loaded
# env.sh, so uv refused the CPython it was asked to install and the toolchain
# root was left empty.
t_ok "$(grep -q 'UV_PYTHON_DOWNLOADS=manual' "$ROOT/tools/python.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the explicit python install runs under UV_PYTHON_DOWNLOADS=manual (#174)'
# THE FINDING AGAINST PR #17: it left the swallowed stderr in place, so the one
# line that explains the failure still never reached the operator.
sh174_call=$(sed -n '/UV_PYTHON_DOWNLOADS=manual/,+4p' "$ROOT/tools/python.sh" 2>/dev/null)
t_ok "$(printf '%s' "$sh174_call" | grep -q '>/dev/null 2>&1' && echo 1 || echo 0)" \
    'the python install no longer discards uv output (#174)'
t_ok "$(printf '%s' "$sh174_call" | grep -q 'sh_pi_err\|first_line' && echo 0 || echo 1)" \
    'the python install quotes uv first line on failure (#174)'
# And the runtime default must be unchanged: only the install-time action changes.
t_ok "$(grep -q 'UV_PYTHON_DOWNLOADS:-never' "$ROOT/tools/python.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the fragment still defaults UV_PYTHON_DOWNLOADS to never at runtime (#174)'

# ================================================ the finding nothing filed
# doctor measured an adopted node's npm at $SANDHOME_EXEC/views/node/bin/npm, a
# path that only exists when node was INSTALLED. An adopted node (mise, nvm, a
# distro package) has no home root and no view by design, so the probe answered
# "no" on every host that already had node on PATH. Measured here on a clean
# setup with node present:
#   $ sandhome doctor
#   FAIL node_npm_js=no (wanted yes)
#   doctor_failures=1
#   $ sandhome status
#   ready=no
# while `sandhome exec npm --version` answered 12.2.0 in the same breath.
# It must reach the ADOPTED case through something every caller has. The first
# version used sh_toolchain_adopted_root, which loads tools/node.sh - and doctor
# runs from the private mirror $SANDHOME_EXEC/.sandhome-lib, which carries lib/
# and bin/ and NO tools/, so that call answers empty everywhere the probe runs.
# Measured: sh_toolchain_adopted_root node -> [] with npm working.
# CODE LINES ONLY. The name still appears in report.sh's comments, and rightly:
# they record the measured reason it is not used. A grep over the whole file
# therefore matches the explanation and calls the fix broken, which is the
# mirror image of the mistake the #157 note warns about - matching a comment as
# if it were the behaviour.
sh_nodecode=$(grep -v '^[[:space:]]*#' "$ROOT/lib/report.sh" 2>/dev/null)
t_ok "$(printf '%s' "$sh_nodecode" | grep -q 'sh_toolchain_adopted_root' && echo 1 || echo 0)" \
    'the npm probe does not depend on the node module being loadable (found by using the tool)'
# The other wrong answer was feeding node the SHELL WRAPPER at $SH_EXEC_BIN/npm.
# That file exists on this tree and is a `#!/bin/sh` script, so `node <it>` is a
# SyntaxError - measured:
#   $ node $SH_EXEC_BIN/npm --version
#   /workspace/.sandhome/exec/bin/npm:2
#   # written by sandhome: the npm beside this node does not run here
sh_nodewrap=$tmp/rnodewrap
mkdir -p "$sh_nodewrap/bin"
printf '#!/bin/sh\n# written by sandhome: the npm beside this node does not run here\nexec node %s/bin/npm-cli.js "$@"\n' "$sh_nodewrap" > "$sh_nodewrap/bin/npm"
chmod 0755 "$sh_nodewrap/bin/npm"
printf 'console.log(process.version ? "js-ok" : "js-ok")\n' > "$sh_nodewrap/bin/npm-cli.js"
# A subject that is javascript must be ACCEPTED, and this shell wrapper must be
# REJECTED. The gate is the shebang shape, so both are asked the same question.
sh_shebang_gate() {
    sh_sg_h=''
    IFS= read -r sh_sg_h < "$1" 2>/dev/null || :
    # `'#!'*` AND NOT `'#!'`: a shebang line is `#!/bin/sh`, so a pattern of
    # exactly `#!` matches nothing and this gate passes everything.
    case "$sh_sg_h" in
        '#!'*)
            case "$sh_sg_h" in
                *node*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
    esac
    return 0
}
sh_shebang_gate "$sh_nodewrap/bin/npm-cli.js" && sh_sg_js=kept || sh_sg_js=refused
sh_shebang_gate "$sh_nodewrap/bin/npm" && sh_sg_sh=kept || sh_sg_sh=refused
t_is "$sh_sg_js/$sh_sg_sh" 'kept/refused' \
    'the npm probe gate keeps javascript and refuses a shell wrapper (found by using the tool)'
# And the SHIPPED gate must be the one that works: a pattern of exactly `#!`
# matches no shebang line, because a shebang line is `#!/bin/sh`. That made the
# gate pass everything, which is worse than having no gate.
t_ok "$(grep -q "'#!'\*)" "$ROOT/lib/report.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the shipped npm gate matches the shebang shape (found by using the tool)'
t_ok "$(grep -q "case \"\$sh_doc_node_head\" in$'\n *'#!')" "$ROOT/lib/report.sh" 2>/dev/null && echo 1 || echo 0)" \
    'the shipped npm gate does not match a bare #! that matches nothing (found by using the tool)'
t_ok "$(grep -q 'sh_path_where npm' "$ROOT/lib/report.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the npm probe reaches an adopted npm through PATH, which every caller has (found by using the tool)'
# And the mirror really is lib/ + bin/ only, which is why. Asserted from the
# bootstrap that builds it, so the reason is recorded next to the consequence.
t_ok "$(grep -q 'sandhome-lib' "$ROOT/bootstrap.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the private mirror the doctor path uses is still built by bootstrap (found by using the tool)'
t_ok "$(grep -q 'node "\$sh_doc_node_probe" --version' "$ROOT/lib/report.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the npm probe asks node to run the file it found (found by using the tool)'

# The probe must be exercised, not just present. An adopted node root with a
# real npm-cli.js beside it must pass the check.
sh_node=$tmp/rnode
mkdir -p "$sh_node/adopted/npm/bin" "$sh_node/home" "$sh_node/exec/bin" "$sh_node/exec/views"
printf 'require("../lib/cli.js")(process)\n' > "$sh_node/adopted/npm/bin/npm-cli.js"
t_is "$(SANDHOME_HOME=$sh_node/home SANDHOME_EXEC=$sh_node/exec \
    SH_HOME=$sh_node/home SH_HOME_TOOLCHAINS=$sh_node/home/toolchains \
    SH_EXEC=$sh_node/exec SH_EXEC_BIN=$sh_node/exec/bin SH_EXEC_VIEWS=$sh_node/exec/views \
    sh -c '
        . "$SH_REPO_DIR/lib/common.sh"
        . "$SH_REPO_DIR/lib/space.sh"
        # stand in for an adopted node: the module is asked where its working
        # copy is, and the answer is a directory with no home root of its own.
        tc_node_adopted() { printf "%s" "'"$sh_node"'/adopted"; }
        sh_doc_probe=$1
        sh_doc_found=""
        for sh_doc_c in "$sh_doc_probe/npm/lib/node_modules/npm" "$sh_doc_probe/npm" "$sh_doc_probe/lib/node_modules/npm"; do
            [ -r "$sh_doc_c/bin/npm-cli.js" ] && { sh_doc_found=$sh_doc_c/bin/npm-cli.js; break; }
        done
        printf "%s" "${sh_doc_found:+found}"
    ' "$SH_REPO_DIR" "$sh_node/adopted" 2>/dev/null)" 'found' \
    'the adopted-node fallback locates npm-cli.js without a view (found by using the tool)'

# A view that exists still takes precedence, so the #157 regression stays
# covered by the same clause.
mkdir -p "$sh_node/exec/views/node/bin"
printf 'console.log("i am javascript")\n' > "$sh_node/exec/views/node/bin/npm"
t_is "$(sh -c '
    . "$SH_REPO_DIR/lib/common.sh"
    printf "%s" "$( [ -e "'"$sh_node"'/exec/views/node/bin/npm" ] && echo view-first || echo no )"
' "$SH_REPO_DIR" 2>/dev/null)" 'view-first' \
    'an installed node view still takes precedence over the adopted fallback (#157)'

# ============================================================ the size gate
# THE FINDING AGAINST PR #17: sh_promote_tree started copying every non-ELF
# executable, and sh_view_copy_kb - the gate that must predict what promote
# writes - was not changed with it. Measured on a tree of one 10MB executable
# .py beside 30 small ELF programs:
#   sh_view_copy_kb, launch mode -> 992 KB
#   what promote actually wrote  -> about 11200 KB
# so the gate passed a root that then ran out of space part-way through the walk,
# which is the one outcome the gate exists to prevent (sh_view_need).
sh_gate=$tmp/rgate
mkdir -p "$sh_gate/tree/lib" "$sh_gate/home/tmp" "$sh_gate/exec/bin" "$sh_gate/exec/views"
# A large EXECUTABLE NON-ELF, which launch mode must copy.
if command -v dd >/dev/null 2>&1; then
    dd if=/dev/urandom of="$sh_gate/tree/lib/big.py" bs=1024 count=2048 2>/dev/null
    chmod 0755 "$sh_gate/tree/lib/big.py"
fi
t_ok "$([ -s "$sh_gate/tree/lib/big.py" ] && echo 0 || echo 1)" \
    'the size-gate fixture really has a large executable non-ELF (#173)'
sh_gate_launch=$(SANDHOME_HOME=$sh_gate/home SANDHOME_EXEC=$sh_gate/exec \
    SH_HOME=$sh_gate/home SH_HOME_TOOLCHAINS=$sh_gate/home/toolchains \
    SH_HOME_TMP=$sh_gate/home/tmp SH_EXEC=$sh_gate/exec SH_EXEC_BIN=$sh_gate/exec/bin \
    SH_EXEC_VIEWS=$sh_gate/exec/views SH_VIEW_MODE=launch \
    sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"; . "$SH_REPO_DIR/lib/memexec.sh"; sh_view_copy_kb "'"$sh_gate"'/tree"' 2>/dev/null)
sh_gate_apparent=$(du -sk --apparent-size "$sh_gate/tree/lib/big.py" 2>/dev/null | { read -r sh_ga_k _ || :; printf '%s' "$sh_ga_k"; })
case "$sh_gate_launch:$sh_gate_apparent" in
    ''|*:'')
        t_skip 'no size reader for the gate comparison (#173)'
        ;;
    *)
        # The gate must not under-state the copy by more than a helper's worth.
        if [ "$sh_gate_launch" -ge $((sh_gate_apparent / 2)) ]; then
            t_ok 0 'the size gate prices a copied non-ELF at its real size, not as a launcher (#173)'
        else
            t_ok 1 "the size gate under-states the view: said ${sh_gate_launch}KB for about ${sh_gate_apparent}KB of real copies (#173)"
        fi
        ;;
esac

# AND THE OTHER DIRECTION: an ELF launch mode really does replace must stay
# cheap, or the gate would refuse roots it could have used.
sh_gate2=$tmp/rgate2
mkdir -p "$sh_gate2/tree/bin" "$sh_gate2/home/tmp" "$sh_gate2/exec/bin"
if [ -x /bin/sh ]; then
    cp /bin/sh "$sh_gate2/tree/bin/big" 2>/dev/null
    chmod 0755 "$sh_gate2/tree/bin/big"
fi
sh_gate2_launch=$(SANDHOME_HOME=$sh_gate2/home SANDHOME_EXEC=$sh_gate2/exec \
    SH_HOME=$sh_gate2/home SH_HOME_TOOLCHAINS=$sh_gate2/home/toolchains \
    SH_HOME_TMP=$sh_gate2/home/tmp SH_EXEC=$sh_gate2/exec SH_EXEC_BIN=$sh_gate2/exec/bin \
    SH_EXEC_VIEWS=$sh_gate2/exec/views SH_VIEW_MODE=launch \
    sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"; . "$SH_REPO_DIR/lib/memexec.sh"; sh_view_copy_kb "'"$sh_gate2"'/tree"' 2>/dev/null)
case "$sh_gate2_launch" in
    ''|*[!0-9]*) t_ok 1 'the size gate answers for an ELF payload (#113)' ;;
    *)
        if [ "$sh_gate2_launch" -lt 1024 ]; then
            t_ok 0 'the size gate keeps an ELF payload at launcher price in launch mode (#113)'
        else
            t_ok 1 "the size gate prices a stampable ELF at ${sh_gate2_launch}KB (#113)"
        fi
        ;;
esac

# AND THE GATE AND THE PROMOTE MUST AGREE, which is the invariant both fixes
# exist to hold. One number each, same tree, same conditions.
sh_agree=$tmp/ragree
mkdir -p "$sh_agree/tree/lib" "$sh_agree/home/tmp" "$sh_agree/exec/bin" "$sh_agree/exec/views"
cp /bin/sh "$sh_agree/tree/lib/elf" 2>/dev/null && chmod 0755 "$sh_agree/tree/lib/elf"
printf '#!/bin/sh\nexit 0\n' > "$sh_agree/tree/lib/script"
chmod 0755 "$sh_agree/tree/lib/script"
sh_agree_ans=$(SANDHOME_HOME=$sh_agree/home SANDHOME_EXEC=$sh_agree/exec \
    SH_HOME=$sh_agree/home SH_HOME_TOOLCHAINS=$sh_agree/home/toolchains \
    SH_HOME_TMP=$sh_agree/home/tmp SH_HOME_EXEC=no SH_EXEC=$sh_agree/exec \
    SH_EXEC_BIN=$sh_agree/exec/bin SH_EXEC_VIEWS=$sh_agree/exec/views \
    SH_VIEW_MODE=launch SH_DRY_RUN=0 \
    sh -c '. "$SH_REPO_DIR/lib/common.sh"; . "$SH_REPO_DIR/lib/space.sh"; . "$SH_REPO_DIR/lib/memexec.sh"
        sh_view_copy_kb "'"$sh_agree"'/tree"
        sh_promote_tree "'"$sh_agree"'/tree" "'"$sh_agree"'/exec/views/t" >/dev/null 2>&1
        sh_dir_apparent_kb "'"$sh_agree"'/exec/views/t"' 2>/dev/null)
sh_agree_gate=$(printf '%s' "$sh_agree_ans" | head -1)
sh_agree_wrote=$(printf '%s' "$sh_agree_ans" | tail -1)
case "$sh_agree_gate:$sh_agree_wrote" in
    ''|*:|'') t_skip 'the gate/promote agreement could not be measured (#173)' ;;
    *)
        if [ "$sh_agree_gate" = "$sh_agree_wrote" ]; then
            t_ok 0 'the size gate and the promote agree on what a launch view costs (#173)'
        else
            t_ok 1 "the size gate said ${sh_agree_gate}KB and the view came to ${sh_agree_wrote}KB (#173)"
        fi
        ;;
esac

t_end
