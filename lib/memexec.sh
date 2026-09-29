#!/bin/sh
# memexec.sh - run executables from memory instead of copying them. Sourced.
#
# THE MEASUREMENT THIS EXISTS FOR. On a split root (home noexec, small exec)
# the old answer copied every executable regular file into the exec view:
# ~100MB for rust, ~270MB for clang. A memfd plus exec-from-fd runs the same
# bytes with no exec-root space at all: the view holds 20KB launcher copies
# of one helper plus symlinks, and the payloads stay on the home. Measured on
# a noexec $HOME: direct exec fails EACCES, ELF / dynamic ELF / #! scripts
# all run from the memfd, rust links (with the --sysroot wrapper rust still
# needs), clang compiles (resource detection follows the view path).
#
# The helper is shims/memexec.c, written from scratch for this tree; the
# mechanism (memfd_create plus exec through a fd) is transcribed from the
# description in hackerschoice/memexec, studied as reference only.
#
# SH_VIEW_MODE is launch when the helper is built and passes its probe here,
# copy otherwise. Copy is the old behavior and the fallback, not a defect:
# a machine without a C compiler, without memfd, or with an exec-capable
# home never needs the helper.

# sh_memexec_bin -> the helper path, or nothing when it is absent.
sh_memexec_bin() { printf '%s/sandhome-memexec' "${SH_EXEC_BIN:-}"; }

# sh_memexec_src -> the C source in the checkout.
sh_memexec_src() { printf '%s/shims/memexec.c' "${SH_REPO_DIR:-.}"; }

# sh_memexec_built -> 0 when the helper binary exists.
sh_memexec_built() {
    [ -n "${SH_EXEC_BIN:-}" ] || return 1
    [ -x "$(sh_memexec_bin)" ] || return 1
    return 0
}

# sh_memexec_build -> compile the helper onto the exec bin. Best effort: a
# failure is reported and the caller falls back to copy mode, because the
# helper is an optimization and refusing the install over it would trade a
# working slow path for a failed fast one.
sh_memexec_build() {
    sh_mb_out=$(sh_memexec_bin)
    [ -n "$sh_mb_out" ] || return 1
    if [ ! -f "$(sh_memexec_src)" ]; then
        sh_warn 'no memexec source beside the library; views fall back to copies'
        return 1
    fi
    if ! sh_have cc && ! sh_have gcc; then
        sh_warn 'no C compiler is present, so sandhome-memexec cannot be built; views fall back to copies'
        return 1
    fi
    sh_mb_cc=cc
    sh_have cc || sh_mb_cc=gcc
    if [ "${SH_DRY_RUN:-0}" = 1 ]; then
        sh_step "would compile $(sh_memexec_src) into $sh_mb_out"
        return 0
    fi
    mkdir -p "$SH_EXEC_BIN" 2>/dev/null || return 1
    sh_mb_err=${SH_HOME_TMP:-${TMPDIR:-/tmp}}/.memexec-build.$$
    mkdir -p "$(sh_dirname "$sh_mb_err")" 2>/dev/null || true
    if "$sh_mb_cc" -O2 -o "$sh_mb_out" "$(sh_memexec_src)" 2>"$sh_mb_err"; then
        rm -f "$sh_mb_err" 2>/dev/null
        chmod 0755 "$sh_mb_out" 2>/dev/null || true
        sh_step "built $sh_mb_out"
        return 0
    fi
    if [ -s "$sh_mb_err" ]; then
        while IFS= read -r sh_mb_line || [ -n "$sh_mb_line" ]; do
            sh_warn "$sh_mb_cc: $sh_mb_line"
        done < "$sh_mb_err"
    else
        sh_warn "$sh_mb_cc could not build sandhome-memexec and said nothing about why"
    fi
    rm -f "$sh_mb_err" "$sh_mb_out" 2>/dev/null
    return 1
}

# sh_memexec_probe -> 0 when the helper runs a file its own mount refuses.
# This is the whole question: a binary that builds but cannot memfd-exec
# (seccomp, no memfd, hidden /proc with no fexecve) must read as absent, or
# every view built on it is a view of binaries that do not run. The probe
# file goes on the HOME, because that is the root the payloads live on: on
# an exec-capable home the direct execve answers and the memfd path is
# untested, which is honest, since the helper is only load-bearing where
# the home refuses.
sh_memexec_probe() {
    sh_mp_help=$(sh_memexec_bin)
    [ -n "$sh_mp_help" ] || return 1
    [ -x "$sh_mp_help" ] || return 1
    sh_mp_dir=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_mp_dir" 2>/dev/null || return 1
    sh_mp_f="$sh_mp_dir/.memexec-probe.$$"
    printf '#!/bin/sh\nexit 0\n' > "$sh_mp_f" 2>/dev/null || return 1
    chmod 0755 "$sh_mp_f" 2>/dev/null || true
    # When the probe file itself runs, the answer is about nothing: the home
    # executes files and the helper is unneeded. That is still a pass for the
    # helper as a binary, and the mode decision below is what keeps the copy.
    if "$sh_mp_f" >/dev/null 2>&1; then
        # The home runs files, so the helper is unneeded here; what is
        # probed is that the helper binary itself runs. The memfd path is
        # probed on the noexec branch below, the only place it matters.
        if "$sh_mp_help" "$sh_mp_f" >/dev/null 2>&1; then
            rm -f "$sh_mp_f" 2>/dev/null
            return 0
        fi
        rm -f "$sh_mp_f" 2>/dev/null
        return 1
    fi
    # The home refuses: the helper must run it from memory or it is useless.
    if "$sh_mp_help" "$sh_mp_f" >/dev/null 2>&1; then
        rm -f "$sh_mp_f" 2>/dev/null
        return 0
    fi
    rm -f "$sh_mp_f" 2>/dev/null
    return 1
}

# sh_view_kind_of FILE -> launch when FILE is a launcher copy, copy when it is
# a real file, direct when it is not there. THIS READS THE DISK, AND IT HAS TO:
# sh_memexec_mode answers what the machine WOULD do, and a single view built
# under an explicit SANDHOME_VIEW_MODE=copy is real bytes while the machine
# still probes launch. A report that echoed the plan named the wrong thing for
# exactly the tree a caller had just asked to change (issue #113).
sh_view_kind_of() {
    sh_vko_f=$1
    if [ -z "$sh_vko_f" ] || [ ! -e "$sh_vko_f" ]; then
        printf 'direct'
        return 0
    fi
    # Without cmp the launcher cannot be told from a real file, and answering
    # `copy` would make a launch host look like a copy host. Say nothing and let
    # the caller fall back to the machine mode.
    if sh_memexec_built && sh_have cmp; then
        if cmp -s "$sh_vko_f" "$(sh_memexec_bin)" 2>/dev/null; then
            printf 'launch'
        else
            printf 'copy'
        fi
        return 0
    fi
    printf ''
    return 0
}

# sh_memexec_mode -> launch or copy, read-only. The mode is a fact about the
# machine (split home plus a helper that probes here), not a memory of what
# installed it: a fresh `sandhome report` must answer the same mode the
# install used, and it cannot run the build to find out. sh_memexec_ensure
# builds first and then asks this; the report only asks.
sh_memexec_mode() {
    if [ "${SH_HOME_EXEC:-unknown}" = yes ]; then
        printf 'copy'
        return 0
    fi
    if sh_memexec_built && sh_memexec_probe 2>/dev/null; then
        printf 'launch'
    else
        printf 'copy'
    fi
    return 0
}

# sh_memexec_ensure -> build and probe the helper when this machine can use
# it, and set SH_VIEW_MODE to launch or copy. Idempotent: a helper already
# there is probed, not rebuilt. Never fatal: copy mode is the fallback.
#
# STOP: ON A COLLAPSED HOME THE ANSWER IS COPY, AND NOTHING IS BUILT. The two
# roots are one directory that runs its own files, so no view is ever
# mirrored and a helper would sit unused. Building one anyway costs a compile
# and prints a step about a binary nothing will call.
#
# SANDHOME_VIEW_MODE overrides the decision (issue #83): `copy` forces real
# copies, which keeps `/proc/self/exe` a real path at the price of exec-root
# room; `launch` demands the helper and falls back to copy with a warning
# when it does not probe here; empty or anything else decides per machine.
# A launcher runs from an anonymous memfd, so exe-relative tools that must
# see their own path (zig's install dir, node-gyp's process.execPath, crash
# traces) either land on the per-module copy list or need copy mode: the
# choice is visible in `sandhome report` (`view=`) instead of silent.
sh_memexec_ensure() {
    if [ "${SH_HOME_EXEC:-unknown}" = yes ]; then
        if [ "${SANDHOME_VIEW_MODE:-auto}" = launch ]; then
            sh_warn 'SANDHOME_VIEW_MODE=launch was asked but the home runs its own files; views stay copies'
        fi
        SH_VIEW_MODE=copy
        export SH_VIEW_MODE
        return 0
    fi
    if [ "${SANDHOME_VIEW_MODE:-auto}" = copy ]; then
        SH_VIEW_MODE=copy
        export SH_VIEW_MODE
        return 0
    fi
    if ! sh_memexec_built; then
        sh_memexec_build || true
    fi
    SH_VIEW_MODE=$(sh_memexec_mode)
    if [ "${SANDHOME_VIEW_MODE:-auto}" = launch ] && [ "$SH_VIEW_MODE" != launch ]; then
        sh_warn 'SANDHOME_VIEW_MODE=launch was asked and the helper does not probe here; views fall back to copies'
        SH_VIEW_MODE=copy
    fi
    export SH_VIEW_MODE
    return 0
}

# sh_memexec_stamp SRC DST -> place one launcher copy for SRC at DST. The
# copy maps itself back at runtime (views/<name> to toolchains/<name>), so
# stamping is a cp, not a compile: the one binary serves every entry.
#
# STOP: THE DESTINATION IS REMOVED FIRST, BECAUSE IT MAY BE A SYMLINK FROM
# AN EARLIER VIEW. A path that an older mirror left as a link to the source
# makes cp compare the two and refuse with "are the same file", and the
# entry stays a symlink to the noexec home and cannot run. Measured twice:
# once here, once in the split-root change this replaces.
sh_memexec_stamp() {
    sh_ms_out=$(sh_memexec_bin)
    [ -n "$sh_ms_out" ] || return 1
    rm -f "$2" 2>/dev/null
    if cp -f "$sh_ms_out" "$2" 2>/dev/null; then
        chmod 0755 "$2" 2>/dev/null || true
        return 0
    fi
    return 1
}

# sh_memexec_template_kb -> the helper size in KB, or 32 when unknown. The
# size gate prices launch-mode views off this, not off the payloads.
sh_memexec_template_kb() {
    sh_mt_out=$(sh_memexec_bin)
    if [ -n "$sh_mt_out" ] && [ -f "$sh_mt_out" ] && sh_have du; then
        sh_mt_k=$(du -sk "$sh_mt_out" 2>/dev/null | { read -r sh_mt_kb _ || :; printf '%s' "$sh_mt_kb"; })
        case "$sh_mt_k" in
            ''|*[!0-9]*) printf '32' ;;
            *) printf '%s' "$sh_mt_k" ;;
        esac
        return 0
    fi
    printf '32'
}

# sh_memexec_report -> the one line the report prints.
sh_memexec_report() {
    if [ "${SH_HOME_EXEC:-unknown}" = yes ]; then
        printf 'unneeded (the home runs its own files)'
        return 0
    fi
    if sh_memexec_built && sh_memexec_probe 2>/dev/null; then
        printf 'yes (%s)' "$(sh_memexec_bin)"
        return 0
    fi
    if sh_memexec_built; then
        printf 'built but the probe fails here; views fall back to copies'
        return 0
    fi
    printf 'no; views fall back to copies'
}
