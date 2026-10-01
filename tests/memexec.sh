#!/bin/sh
# tests/memexec.sh - the run-from-memory view: the helper builds and probes,
# launch mode stamps runnable launchers, copy mode stays the fallback, and
# the force decision is honored. The Nemo PR76 fixes this tree absorbs
# (command-hash reset, repair post-promote env, stale-symlink destination)
# are guarded here too, against this tree's code rather than that branch.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

t_begin memexec

work=$(t_exec_tmpdir sandhome-mx)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/toolchains" "$work/exec/bin" "$work/exec/views" "$work/home/tmp"

for m in common detect space fetch env toolchain shim memexec report; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_HOME="$work/home"
SH_EXEC="$work/exec"
SH_EXEC_BIN="$work/exec/bin"
SH_EXEC_VIEWS="$work/exec/views"
SH_HOME_TOOLCHAINS="$work/home/toolchains"
SH_HOME_TMP="$work/home/tmp"
SH_HOME_EXEC=no
SH_REPO_DIR="$ROOT"
SH_LIB_DIR="$ROOT/lib"
SH_DRY_RUN=0
SH_SELF=test
export SH_HOME SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TOOLCHAINS SH_HOME_TMP
export SH_HOME_EXEC SH_REPO_DIR SH_LIB_DIR SH_DRY_RUN SH_SELF

if sh_have cc || sh_have gcc; then
    t_ok 0 'a C compiler is present, so the helper clauses run'
    sh_memexec_build >/dev/null 2>&1
    t_ok "$([ -x "$work/exec/bin/sandhome-memexec" ]; echo $?)" \
        'the helper builds onto the exec bin'
    if sh_memexec_probe >/dev/null 2>&1; then
        t_ok 0 'the helper probes as working here'
    else
        t_ok 1 'the helper probes as working here'
    fi
    # Explicit spelling runs a payload and returns its status.
    printf '#!/bin/sh\nexit 42\n' > "$work/payload.sh"
    chmod 0755 "$work/payload.sh"
    "$work/exec/bin/sandhome-memexec" "$work/payload.sh" >/dev/null 2>&1
    t_is "$?" 42 'the helper runs a payload under its explicit spelling'
    # A view copy maps itself back to the home payload, argv unchanged.
    mkdir -p "$work/home/toolchains/demo/bin" "$work/exec/views/demo/bin"
    printf '#!/bin/sh\necho memexec-demo "$1"\n' > "$work/home/toolchains/demo/bin/demo"
    chmod 0755 "$work/home/toolchains/demo/bin/demo"
    cp "$work/exec/bin/sandhome-memexec" "$work/exec/views/demo/bin/demo"
    chmod 0755 "$work/exec/views/demo/bin/demo"
    SANDHOME_HOME="$work/home" SANDHOME_EXEC="$work/exec" \
        "$work/exec/views/demo/bin/demo" hello > "$work/got" 2>&1
    t_is "$(cat "$work/got" 2>/dev/null)" 'memexec-demo hello' \
        'a view copy maps itself back to the home payload'
else
    t_skip 'no C compiler here, so the helper build and probe clauses were skipped'
fi

# The memfd path itself, on a root that refuses exec. Every candidate is
# examined, so a machine whose first writable directory runs files still
# finds the noexec one it has.
noexec_base=''
for cand in /state/home /workspace; do
    [ -d "$cand" ] && [ -w "$cand" ] || continue
    if sh_exec_probe "$cand"; then
        :
    else
        [ -z "$noexec_base" ] && noexec_base=$cand
    fi
done
if [ -x "$work/exec/bin/sandhome-memexec" ] && [ -n "$noexec_base" ]; then
    nx="$noexec_base/.sandhome-mxprobe.$$"
    printf '#!/bin/sh\necho memfd-ok\n' > "$nx" 2>/dev/null
    chmod 0755 "$nx" 2>/dev/null
    if "$nx" >/dev/null 2>&1; then
        t_ok 1 'the noexec candidate really refuses exec (it ran the probe)'
    else
        t_ok 0 'the noexec candidate really refuses exec'
    fi
    "$work/exec/bin/sandhome-memexec" "$nx" > "$work/nxgot" 2>&1
    nx_rc=$?
    nx_got=$(cat "$work/nxgot" 2>/dev/null)
    case "$nx_got" in
        memfd-ok)
            t_is "$nx_got" 'memfd-ok' 'the helper runs a file its own mount refuses to execute' ;;
        *)
            # A sandbox that denies memfd_create blocks run-from-memory
            # entirely (measured: Operation not permitted here); the tree
            # falls back to copy views, so the memfd path is skipped rather
            # than failed. Failing here would demand a capability the kernel
            # refuses, not a defect in the helper.
            case "$nx_got" in
                *'memfd_create failed'*|*'Operation not permitted'*|*'Permission denied'*)
                    t_skip 'memfd is blocked here, so run-from-memory falls back to copies' ;;
                *)
                    t_is "$nx_got" 'memfd-ok' 'the helper runs a file its own mount refuses to execute' ;;
            esac ;;
    esac
    rm -f "$nx" 2>/dev/null
elif [ -x "$work/exec/bin/sandhome-memexec" ]; then
    t_skip 'this host has no writable noexec mount, so the memfd path was not exercised'
else
    t_skip 'the helper did not build, so the memfd path was not exercised'
fi

# Launch mode promotes to small runnable launchers, not full copies.
if [ -x "$work/exec/bin/sandhome-memexec" ] && sh_memexec_probe >/dev/null 2>&1; then
    SH_VIEW_MODE=launch
    export SH_VIEW_MODE
    mkdir -p "$work/home/toolchains/big/bin"
    printf '#!/bin/sh\necho big-ok\n' > "$work/home/toolchains/big/bin/big"
    chmod 0755 "$work/home/toolchains/big/bin/big"
    # A megabyte of executable payload beside it, so the gate has something
    # real to price: the point is kilobytes per entry versus megabytes of
    # payload, and a 30-byte fixture is smaller than the helper itself.
    # From urandom, not zero: this filesystem compresses zero runs, so a
    # zero-filled megabyte reports 1KB under du and prices nothing.
    dd if=/dev/urandom of="$work/home/toolchains/big/bin/blob" bs=1k count=1024 2>/dev/null
    chmod 0755 "$work/home/toolchains/big/bin/blob"
    # The filesystem delays block accounting for fresh files (a just-written
    # megabyte reports 1 block until seconds pass), and the gate reads du.
    # Wait for the blocks to land rather than asserting on the delay.
    if ! sh_have du; then
        t_skip 'no du here, so the size-gate pricing was not exercised'
    else
        sh_mx_wait=0
        while [ "$sh_mx_wait" -lt 30 ]; do
            sh_mx_kb=$(du -sk "$work/home/toolchains/big/bin/blob" 2>/dev/null | { read -r sh_mx_k _ || :; printf '%s' "$sh_mx_k"; })
            case "$sh_mx_kb" in ''|*[!0-9]*) sh_mx_kb=0 ;; esac
            [ "$sh_mx_kb" -gt 512 ] && break
            sleep 2
            sh_mx_wait=$((sh_mx_wait + 2))
        done
    sh_promote_toolchain big bin/big >/dev/null 2>&1
    if [ -f "$work/exec/views/big/bin/big" ] && [ ! -L "$work/exec/views/big/bin/big" ]; then
        t_ok 0 'a launch-mode view entry is a regular file, not a symlink'
    else
        t_ok 1 'a launch-mode view entry is a regular file, not a symlink'
    fi
    SANDHOME_HOME="$work/home" SANDHOME_EXEC="$work/exec" \
        "$work/exec/views/big/bin/big" > "$work/biggot" 2>&1
    t_is "$(cat "$work/biggot" 2>/dev/null)" 'big-ok' \
        'a launch-mode view entry runs its home payload'
    # The gate prices kilobytes per entry, not the payload size.
    SH_VIEW_MODE=copy
    export SH_VIEW_MODE
    kb_copy=$(sh_view_copy_kb "$work/home/toolchains/big" 2>/dev/null)
    SH_VIEW_MODE=launch
    export SH_VIEW_MODE
    kb_launch=$(sh_view_copy_kb "$work/home/toolchains/big" 2>/dev/null)
    case "$kb_copy:$kb_launch" in
        ''|*:|'') t_ok 1 'the size gate answers in both modes' ;;
        *)
            if [ "$kb_launch" -lt "$kb_copy" ]; then
                t_ok 0 'the size gate prices launch mode below copy mode'
            else
                t_ok 1 "the size gate prices launch mode below copy mode ($kb_launch vs $kb_copy)"
            fi ;;
    esac
    fi
else
    t_skip 'the helper does not probe here, so the launch-mode clauses were skipped'
fi

# Copy mode is the fallback and copies bytes.
SH_VIEW_MODE=copy
export SH_VIEW_MODE
mkdir -p "$work/home/toolchains/small/bin"
printf '#!/bin/sh\necho small-ok\n' > "$work/home/toolchains/small/bin/small"
chmod 0755 "$work/home/toolchains/small/bin/small"
sh_promote_toolchain small bin/small >/dev/null 2>&1
if [ -f "$work/exec/views/small/bin/small" ] && [ ! -L "$work/exec/views/small/bin/small" ]; then
    t_ok 0 'a copy-mode view entry is a full copy, not a symlink'
else
    t_ok 1 'a copy-mode view entry is a full copy, not a symlink'
fi
case "$(head -c 15 "$work/exec/views/small/bin/small" 2>/dev/null)" in
    '#!/bin/sh'*) t_ok 0 'the copy-mode entry carries the payload bytes' ;;
    *) t_ok 1 'the copy-mode entry carries the payload bytes' ;;
esac

# A STALE SYMLINK DESTINATION DOES NOT SURVIVE THE PROMOTE. An earlier view
# left bin/small as a link to the source; cp follows it and refuses with
# "are the same file", and the entry stays a symlink to a home that cannot
# run it. The destination is removed first, so the copy lands.
rm -f "$work/exec/views/small/bin/small"
ln -s "$work/home/toolchains/small/bin/small" "$work/exec/views/small/bin/small"
sh_promote_toolchain small bin/small >/dev/null 2>&1
if [ -f "$work/exec/views/small/bin/small" ] && [ ! -L "$work/exec/views/small/bin/small" ]; then
    t_ok 0 'a promote over a stale symlink destination still lands a copy'
else
    t_ok 1 'a promote over a stale symlink destination still lands a copy'
fi

# THE FORCE DECISION. A usable host copy is adopted by default; SANDHOME_FORCE
# (a list) and install --force (SH_FORCE=1) install instead.
SH_FORCE=0
SH_FORCE_LIST=''
export SH_FORCE SH_FORCE_LIST
sh_force_toolchain jq
t_is "$?" 1 'nothing forces by default, so a working copy is adopted'
SH_FORCE_LIST=',rust,'
export SH_FORCE_LIST
sh_force_toolchain rust
t_is "$?" 0 'SANDHOME_FORCE=rust forces rust'
sh_force_toolchain jq
t_is "$?" 1 'SANDHOME_FORCE=rust does not force jq'
SH_FORCE_LIST='*'
export SH_FORCE_LIST
sh_force_toolchain jq
t_is "$?" 0 'SANDHOME_FORCE=1 forces everything'
SH_FORCE_LIST=''
SH_FORCE=1
export SH_FORCE_LIST SH_FORCE
sh_force_toolchain jq
t_is "$?" 0 'install --force forces the names on its command line'
SH_FORCE=0
export SH_FORCE

# A COMMAND HASHED BEFORE THE INSTALL MUST NOT BE ANSWERED WITH AFTER. The
# install probe runs the tool it is about to replace, and the shell remembers
# where it found it; the verification probe afterwards must run the new
# binary, not the hashed old one. Fixture: a failing same-named stub on PATH
# and a module whose install puts a working one in the view.
mkdir -p "$work/fake-tools"
cat > "$work/fake-tools/hashed.sh" <<'EOF'
TC_hashed_BINS='bin/hashed'
tc_hashed_probe() { sh_have hashed && hashed --check; }
tc_hashed_install() {
    mkdir -p "$(sh_toolchain_root hashed)/bin" || return 1
    printf '#!/bin/sh\n[ "$1" = --check ] && exit 0\nexit 0\n' > "$(sh_toolchain_root hashed)/bin/hashed"
    chmod 0755 "$(sh_toolchain_root hashed)/bin/hashed"
    return 0
}
EOF
mkdir -p "$work/stub"
printf '#!/bin/sh\nexit 1\n' > "$work/stub/hashed"
chmod 0755 "$work/stub/hashed"
cat > "$work/hash-ensure.sh" <<EOF
for m in common detect space fetch env toolchain memexec; do
    . "$ROOT/lib/\$m.sh"
done
sh_toolchain_load() {
    case " \$SH_TOOLCHAIN_LOADED " in
        *" hashed "*) return 0 ;;
    esac
    . "$work/fake-tools/hashed.sh"
    SH_TOOLCHAIN_LOADED="\$SH_TOOLCHAIN_LOADED hashed"
    return 0
}
sh_toolchain_known() { [ "\$1" = hashed ] && return 0; return 1; }
mkdir -p "\$SH_EXEC_BIN" "\$SH_EXEC_VIEWS" "\$SH_HOME_TOOLCHAINS" "\$SH_HOME_TMP" 2>/dev/null
PATH="$work/stub:\$PATH"
export PATH
hashed --check >/dev/null 2>&1 || true
sh_toolchain_install_one hashed 2>&1
echo "STATUS=\$?"
EOF
hashed_out=$(SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
    SH_HOME_TOOLCHAINS="$work/htc" SH_EXEC="$work/hexec" SH_HOME="$work/hhome" \
    SH_EXEC_BIN="$work/hexec/bin" SH_EXEC_VIEWS="$work/hexec/views" \
    SH_HOME_TMP="$work/hhome/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
    SH_VIEW_MODE=copy \
    sh "$work/hash-ensure.sh" 2>&1)
t_contains "$hashed_out" 'STATUS=0' \
    'a toolchain whose name is a failing stub on PATH still verifies after install'
case "$hashed_out" in
    *'still does not run from the exec view'*)
        t_ok 1 'the stale hashed command is not used for the verification probe' ;;
    *)
        t_ok 0 'the stale hashed command is not used for the verification probe' ;;
esac

# THE GENERATED WRAPPER MUST BE VALID SHELL, AND MUST RUN. A printf format
# inside single quotes needs no escaping, so a `\"` written there lands
# literally in the wrapper and the first exec dies with "not found". The
# fixture wraps a logging payload and runs the result. The env write runs
# under `set -u` on the real paths (bin/sandhome sets it), so the fragment
# half of this runs in a `sh -u` driver: one bare `$` in a heredoc comment
# once aborted the whole write mid-fragment while every set-u-less test
# passed, and the fragment silently lost LD_LIBRARY_PATH and RUSTC.
. "$ROOT/tools/rust.sh"
mkdir -p "$work/wrap/home/bin" "$work/wrap/view/bin"
# No format substitution: a %s here would be eaten by the writing printf.
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" >> "$WRAP_LOG"' 'exit 0' > "$work/wrap/home/bin/rustc"
chmod 0755 "$work/wrap/home/bin/rustc"
printf '#!/bin/sh\nexit 0\n' > "$work/wrap/view/bin/rustc"
chmod 0755 "$work/wrap/view/bin/rustc"
if [ -x "$work/exec/bin/sandhome-memexec" ]; then
    SH_VIEW_MODE=launch
    export SH_VIEW_MODE
    if tc_rust_sysroot_wrapper "$work/wrap/view/bin/rustc" "$work/wrap/home/bin/rustc" \
        "$work/wrap/view" "$work/wrap/home/lib" >/dev/null 2>&1; then
        t_ok 0 'the sysroot wrapper is written in launch mode'
    else
        t_ok 1 'the sysroot wrapper is written in launch mode'
    fi
    # In dash a quoted backslash-quote pattern never matches (the backslash
    # pairing happens after quote removal), so the shape that actually fires
    # is an unquoted escaped backslash: any backslash at all in a generated
    # shell file is the defect, since printf formats here need no escaping.
    case "$(cat "$work/wrap/view/bin/rustc" 2>/dev/null)" in
        *\\*) t_ok 1 'the wrapper carries no backslash' ;;
        *) t_ok 0 'the wrapper carries no backslash' ;;
    esac
    sh -n "$work/wrap/view/bin/rustc" 2>/dev/null
    t_is "$?" 0 'the wrapper parses as shell'
    WRAP_LOG="$work/wrap.log"
    export WRAP_LOG
    SANDHOME_HOME="$work/home" SANDHOME_EXEC="$work/exec" \
        sh "$work/wrap/view/bin/rustc" --version >/dev/null 2>&1
    t_is "$?" 0 'the wrapper runs'
    sh_wr_log=$(cat "$work/wrap.log" 2>/dev/null)
    case "$sh_wr_log" in
        *--sysroot*)
            case "$sh_wr_log" in
                *"$work/wrap/view"*) t_ok 0 'the wrapper passes --sysroot' ;;
                *) t_ok 1 "the wrapper passes --sysroot (got: $sh_wr_log)" ;;
            esac ;;
        *) t_ok 1 "the wrapper passes --sysroot (got: $sh_wr_log)" ;;
    esac
    SH_VIEW_MODE=copy
    export SH_VIEW_MODE
else
    t_skip 'the helper did not build, so the wrapper clauses were skipped'
fi

# The env write under the dispatcher's shell flags. bin/sandhome runs the
# whole tree under `set -u`; an unquoted heredoc that expands a bare `$`
# aborts the function at that line, and on the repair path the abort is
# swallowed by `|| true`, so the fragment is left half-written with no
# signal. The driver below is the repair path in miniature, flags included.
cat > "$work/setu-driver.sh" <<'DRIVER'
set -u
for m in common detect space fetch env toolchain shim memexec; do
    . "$1/lib/$m.sh"
done
. "$1/tools/rust.sh"
SH_HOME=$2/home; SH_EXEC=$2/exec; SH_EXEC_BIN=$2/exec/bin
SH_EXEC_VIEWS=$2/exec/views; SH_HOME_TOOLCHAINS=$2/home/toolchains
SH_HOME_TMP=$2/home/tmp; SH_HOME_EXEC=no; SH_REPO_DIR=$1; SH_LIB_DIR=$1/lib
SH_VIEW_MODE=copy
SH_DRY_RUN=0; SH_SELF=test
# shellcheck disable=SC2086
tc_rust_ld_fragment "$2/frag.sh" ${3:-} || echo DRIVER-FAIL
DRIVER
mkdir -p "$work/setu"
sh -u "$work/setu-driver.sh" "$ROOT" "$work/setu" "/fake/toolchain/lib" > "$work/setu.out" 2>&1
t_is "$?" 0 'the LD fragment writes under set -u'
t_contains "$(cat "$work/setu/frag.sh" 2>/dev/null)" 'LD_LIBRARY_PATH="/fake/toolchain/lib' \
    'the fragment carries the toolchain lib on LD_LIBRARY_PATH'
case "$(cat "$work/setu.out" 2>/dev/null)" in
    *DRIVER-FAIL*) t_ok 1 'the fragment helper reports success' ;;
    *) t_ok 0 'the fragment helper reports success' ;;
esac

# THE REPORT RECOMPUTES THE MODE, IT DOES NOT REMEMBER IT. SH_VIEW_MODE
# lives only in the installing process; a fresh `sandhome report` that read
# it would always say copy. sh_report_view answers from the machine.
if [ -x "$work/exec/bin/sandhome-memexec" ] && sh_memexec_probe >/dev/null 2>&1; then
    SH_VIEW_MODE=''
    export SH_VIEW_MODE
    t_is "$(sh_report_view 2>/dev/null)" 'launch' \
        'a fresh shell reports launch mode when the helper probes here'
    SH_VIEW_MODE=copy
    export SH_VIEW_MODE
else
    t_skip 'the helper does not probe here, so the report-mode clause was skipped'
fi

# SANDHOME_VIEW_MODE OVERRIDES THE DECISION (issue #83). copy forces real
# copies without building; launch demands the helper with a copy fallback.
# SH_HOME_EXEC=no is already set above, so the machine would choose launch
# where the helper probes.
SANDHOME_VIEW_MODE=copy sh_memexec_ensure >/dev/null 2>&1
t_is "$SH_VIEW_MODE" 'copy' 'SANDHOME_VIEW_MODE=copy forces copy mode'
SH_VIEW_MODE=''
export SH_VIEW_MODE
unset SANDHOME_VIEW_MODE
# The per-toolchain mapping names how each entry runs: a home tree runs in
# the machine mode, an adopted copy runs direct. That mapping is what a
# /memfd:sandhome path in a trace is explained against.
mkdir -p "$work/home/toolchains/mxkind"
SH_VIEW_MODE=launch
SANDHOME_VIEW_MODE=''
export SH_VIEW_MODE SANDHOME_VIEW_MODE
t_is "$(sh_toolchain_view_kind mxkind)" 'launch' 'an installed tree runs in the machine mode'
t_is "$(sh_toolchain_view_kind nosuchtool)" 'direct' 'an adopted copy runs direct'

# THE VIEW KIND IS READ FROM THE FILE, NOT FROM THE PLAN (issue #113), AND
# DISAGREEING VIEWS ARE REPORTED AS SUCH. A tree repaired under an explicit
# copy mode is real bytes while the machine still probes launch; the report
# must name what runs rather than repeat what the plan would have done.
if [ -x "$work/exec/bin/sandhome-memexec" ] && sh_memexec_probe >/dev/null 2>&1; then
    mkdir -p "$work/home/toolchains.d" "$work/home/toolchains/mxcop/bin" \
             "$work/home/toolchains/mxlaunch/bin" "$work/exec/views/mxcop/bin" \
             "$work/exec/views/mxlaunch/bin"
    printf 'TC_mxcop_BINS="bin/mxcop"\n' > "$work/home/toolchains.d/mxcop.sh"
    printf 'TC_mxlaunch_BINS="bin/mxlaunch"\n' > "$work/home/toolchains.d/mxlaunch.sh"
    printf '#!/bin/sh\nexit 0\n' > "$work/home/toolchains/mxcop/bin/mxcop"
    printf '#!/bin/sh\nexit 0\n' > "$work/home/toolchains/mxlaunch/bin/mxlaunch"
    printf '#!/bin/sh\nexit 0\n' > "$work/exec/bin/mxcop"
    cp "$work/exec/bin/sandhome-memexec" "$work/exec/bin/mxlaunch"
    SH_VIEW_MODE=launch
    export SH_VIEW_MODE
    t_is "$(sh_toolchain_view_kind mxcop)" 'copy' 'a real view entry reports copy'
    t_is "$(sh_toolchain_view_kind mxlaunch)" 'launch' 'a launcher view entry reports launch'
    t_is "$(sh_view_kind_of "$work/exec/bin/nothere")" 'direct' 'a missing view entry reports direct'
    t_is "$(sh_report_view)" 'mixed' 'disagreeing views are reported as mixed'
    # A SYMLINK IS DIRECT, NOT COPY: an adopted toolchain resolves outside
    # the view, and calling it a copy claims mirrored bytes that were never
    # written. Exec perms differ by sandbox, so only a byte or size
    # comparison may answer launch or copy; a link never does.
    ln -sfn /usr/bin/sh "$work/exec/bin/mxlink" 2>/dev/null
    t_is "$(sh_view_kind_of "$work/exec/bin/mxlink")" 'direct' 'a symlinked view entry reports direct'
    rm -f "$work/exec/bin/mxlink" 2>/dev/null
    # A VIEW LINK POINTING INSIDE THE EXEC ROOT IS MEASURED, NOT DIRECT: the
    # framework links every view entry into the exec bin, so following the
    # link names the bytes that run. Only an outside link runs direct.
    ln -sfn "$work/exec/bin/mxcop" "$work/exec/bin/mxself" 2>/dev/null
    t_is "$(sh_view_kind_of "$work/exec/bin/mxself")" 'copy' 'an intra-view link reports its target kind'
    rm -f "$work/exec/bin/mxself" 2>/dev/null
else
    t_skip 'the helper does not probe here, so the measured-view clause was skipped'
fi

t_end
