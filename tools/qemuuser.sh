#!/bin/sh
# qemu-user - the user-mode emulators (qemu-x86_64, qemu-aarch64, ...) from the
# static Zig build. Not a machine emulator: qemu-system-* boots guests, this runs
# a single ELF, which gives it two properties this sandbox needs.
#
# 1. IT EXECUTES A BINARY FROM A NOEXEC TREE. The home often refuses execve, and
#    the whole view/promote machinery exists for that. A static qemu-user reads
#    the binary itself and re-executes its instructions, so a binary left in
#    place on a noexec root runs:
#      $ /state/home/probe            -> Permission denied
#      $ qemu-x86_64 /state/home/probe -> runs
#    This is not a replacement for the view (a guest that spawns children, uses
#    shared libraries or checks /proc/self/exe still wants a real view); it is
#    the cheap path for a STATIC single binary and the only path when the binary
#    cannot be copied.
#
# 2. IT IS A SYSCALL TRACER THAT DOES NOT NEED ptrace. `qemu-x86_64 -strace`
#    prints the guest's syscalls from inside the emulator. On a host whose seccomp
#    profile denies the ptrace syscall class this is a tracing path that needs no
#    capability, no filter of its own and no ptrace at all.
#
# COST. ~2x native for x86_64-on-x86_64 (measured 0.421s -> 0.845s on a 300M
# iteration loop, identical checksum), against ~21x for qemu-system TCG. User
# mode has no machine, no devices and no boot.
#
# SOURCE. codeberg.org/ziglang/qemu-static; 33 emulators, static-pie, ~280MB
# extracted, 8.2MB for qemu-x86_64 alone. The Forgejo API resolves the newest tag
# and the asset is fetched direct first, through the pkgforge mirror second;
# both want a curl-like user agent (a browser UA is answered 420).
TC_qemuuser_DESC='qemu-user, the static user-mode emulators (run a guest ELF, trace its syscalls without ptrace)'
# The HOST emulator is always promoted; extra guest architectures are opt-in
# through SANDHOME_QEMUUSER_EXTRA, because all 33 emulators are ~280MB of exec
# view and most sessions need one. Naming a guest arch here is what makes
# `zig cc --target=aarch64-linux-musl ... && qemu-aarch64 ./out` work, which is
# the whole cross-architecture story on a host with no cross toolchain.
TC_qemuuser_BINS='bin/qemu-x86_64'
TC_qemuuser_EXEC_MB=12

# tc_qemuuser_root -> the payload dir, or nothing. sh_toolchain_root lives in
# lib/toolchain.sh, which the isolated probe (sh_run_isolated sources only
# common.sh plus this module) does NOT have: calling it there answers empty
# and the disk scan below then read `/bin` -- the whole system -- found the
# system qemu-aarch64, and reported a requested guest present when it was
# not (measured: isolated probe 0 beside direct probe 1 for the same
# EXTRA=aarch64). Every disk read here goes through this guard, with the
# derived fallbacks the framework itself uses, and system prefixes refuse.
tc_qemuuser_root() {
    sh_qr_root=''
    if command -v sh_toolchain_root >/dev/null 2>&1; then
        sh_qr_root=$(sh_toolchain_root qemuuser 2>/dev/null)
    elif [ -n "${SH_HOME_TOOLCHAINS:-}" ]; then
        sh_qr_root=$SH_HOME_TOOLCHAINS/qemuuser
    elif [ -n "${SH_HOME:-}" ]; then
        sh_qr_root=$SH_HOME/toolchains/qemuuser
    fi
    case "$sh_qr_root" in
        ''|/bin|/usr/bin|/sbin|/|/bin/*|/usr/bin/*|/sbin/*) printf ''; return 0 ;;
    esac
    printf '%s' "$sh_qr_root"
    return 0
}

# tc_qemuuser_bins_from_disk -> BINS listing what is actually in the bin
# directory, host emulator first. Called at load time as well as after an
# install, because the install function does NOT run on the "payload already
# present, rebuild the view" path: without this, an opt-in guest whose payload
# is already on disk was dropped from BINS on every re-run, so the view lost a
# launcher that the payload still backed (and `command -v` then found nothing).
# Reading the directory is also the honest answer -- it names what exists, not
# what was once requested.
tc_qemuuser_bins_from_disk() {
    sh_qbd_root=$(tc_qemuuser_root 2>/dev/null)
    [ -n "$sh_qbd_root" ] || return 0
    [ -d "$sh_qbd_root/bin" ] || return 0
    for sh_qbd_e in "$sh_qbd_root/bin/"*; do
        [ -f "$sh_qbd_e" ] || continue
        sh_qbd_b=${sh_qbd_e##*/}
        case " $TC_qemuuser_BINS " in
            *" bin/$sh_qbd_b "*) ;;
            *) TC_qemuuser_BINS="$TC_qemuuser_BINS bin/$sh_qbd_b" ;;
        esac
    done
}

# STOP: LOADING IS SILENT, BECAUSE EVERY COMMAND LOADS. The earlier shape
# warned at source time when SANDHOME_QEMUUSER_EXTRA named a guest that was
# not on disk, so `sandhome help`, `sandhome version` and every other command
# printed a warning about a toolchain nobody asked it about. The missing
# guests are computed fresh in the probe, not at source time: `install
# qemuuser --extra aarch64` sets the variable AFTER every module is sourced,
# so a source-time snapshot never sees the flag and the install wrongly
# adopts (issue #117). The probe is the path that actually answers about
# this toolchain, and it re-reads the disk first so a payload already
# present is never mistaken for a missing guest.
SH_QEMUUSER_MISSING_EXTRA=''
SH_QEMUUSER_WARNED=0
tc_qemuuser_bins_from_disk

tc_qemuuser_probe() {
    # A guest that is requested but absent is a FAILED probe, not a warning
    # beside a pass. The old shape warned and then answered present when the
    # host emulator ran, so `sandhome install qemuuser --extra aarch64` on a
    # tree that already held the host saw "present", skipped the install,
    # and left `qemu-aarch64` missing with only a warning to explain it
    # (issue #117). Failing here makes ensure fetch the guest whether or not
    # --force was passed, and makes doctor name the unfulfilled request.
    # The warning fires once per process because the probe runs on every
    # ensure; the failure fires every time because the guest is still missing.
    # The missing set is computed HERE, not at source time, so a flag parsed
    # after the modules loaded (`install qemuuser --extra X`) is still seen.
    tc_qemuuser_bins_from_disk >/dev/null 2>&1 || true
    SH_QEMUUSER_MISSING_EXTRA=''
    if [ -n "${SANDHOME_QEMUUSER_EXTRA:-}" ]; then
        for sh_qbd_x in ${SANDHOME_QEMUUSER_EXTRA:-}; do
            case "$sh_qbd_x" in qemu-*) sh_qbd_n=$sh_qbd_x ;; *) sh_qbd_n=qemu-$sh_qbd_x ;; esac
            case " $TC_qemuuser_BINS " in
                *" bin/$sh_qbd_n "*) ;;
                *) SH_QEMUUSER_MISSING_EXTRA="$SH_QEMUUSER_MISSING_EXTRA $sh_qbd_x" ;;
            esac
        done
        SH_QEMUUSER_MISSING_EXTRA=${SH_QEMUUSER_MISSING_EXTRA# }
    fi
    if [ -n "$SH_QEMUUSER_MISSING_EXTRA" ]; then
        if [ "$SH_QEMUUSER_WARNED" = 0 ]; then
            SH_QEMUUSER_WARNED=1
            sh_warn "SANDHOME_QEMUUSER_EXTRA names$SH_QEMUUSER_MISSING_EXTRA, but it is not installed; run 'sandhome install qemuuser --extra $SH_QEMUUSER_MISSING_EXTRA' to fetch it"
        fi
        return 1
    fi
    sh_have qemu-x86_64 && qemu-x86_64 --version >/dev/null 2>&1
}

# tc_qemuuser_payload_satisfies -> 1 when the on-disk payload is missing a
# guest the current request names. sh_toolchain_ensure asks this BEFORE taking
# the "payload already present; rebuilding the view without downloading" path,
# because that message is only true when the payload can answer the request.
# The probe cannot be used here: it needs the promoted view, and the whole
# question is whether to build that view without a download (issue #146).
tc_qemuuser_payload_satisfies() {
    [ -n "${SANDHOME_QEMUUSER_EXTRA:-}" ] || return 0
    tc_qemuuser_bins_from_disk >/dev/null 2>&1 || true
    for sh_qps_x in ${SANDHOME_QEMUUSER_EXTRA:-}; do
        case "$sh_qps_x" in qemu-*) sh_qps_n=$sh_qps_x ;; *) sh_qps_n=qemu-$sh_qps_x ;; esac
        case " $TC_qemuuser_BINS " in
            *" bin/$sh_qps_n "*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# tc_qemuuser_guests -> the guest arches present on disk (aarch64, arm, ...),
# one per line, or nothing. The host emulator is excluded: it is always
# present when the probe passes, and listing it as a guest would read as
# "no further work needed" on a tree that holds only the host (issue #117).
tc_qemuuser_guests() {
    sh_qg_root=$(tc_qemuuser_root 2>/dev/null)
    [ -n "$sh_qg_root" ] || return 0
    [ -d "$sh_qg_root/bin" ] || return 0
    sh_qg_host=''
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) sh_qg_host=qemu-x86_64 ;;
        aarch64|arm64) sh_qg_host=qemu-aarch64 ;;
    esac
    for sh_qg_e in "$sh_qg_root"/bin/qemu-*; do
        [ -f "$sh_qg_e" ] || continue
        sh_qg_b=${sh_qg_e##*/}
        [ "$sh_qg_b" = "$sh_qg_host" ] && continue
        printf '%s\n' "${sh_qg_b#qemu-}"
    done
    return 0
}

# tc_qemuuser_asset -> the archive asset name for this machine, or nothing when
# upstream publishes no build for it. The Zig build names its archives by the
# HOST triple it runs on; a missing arm returns non-zero so the install refuses
# by name.
tc_qemuuser_asset() {
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   printf 'qemu-linux-x86_64' ;;
        Linux:aarch64|Linux:arm64)  printf 'qemu-linux-aarch64' ;;
        *) return 1 ;;
    esac
}

# tc_qemuuser_tag_from_body BODY -> the tag_name value, or nothing. The Forgejo
# answer is one JSON object; the tag is the first "tag_name":"..." pair in it.
# Read with the shell rather than sed so the resolve works on a userland whose
# own bootstrap has not installed anything yet.
tc_qemuuser_tag_from_body() {
    sh_qt_rest=${1:-}
    case "$sh_qt_rest" in
        *'"tag_name"'*)
            sh_qt_rest=${sh_qt_rest#*'"tag_name"'}
            sh_qt_rest=${sh_qt_rest#*'"'}
            sh_qt_tag=${sh_qt_rest%%'"'*}
            case "$sh_qt_tag" in
                ''|*'{'*|*'}'*|*' '*|*'"'*) printf '' ;;
                *) printf '%s' "$sh_qt_tag" ;;
            esac
            ;;
        *) printf '' ;;
    esac
}

# tc_qemuuser_tag -> the newest qemu-static tag, or nothing. curl first, wget
# second, because a bootstrap whose job is fetching toolchains cannot require
# one particular fetcher to resolve what to fetch. Both send a curl-like agent:
# the mirror answers anything else with 420.
tc_qemuuser_tag() {
    sh_qt_api="https://api.cb.pkgforge.dev/api/v1/repos/ziglang/qemu-static/releases/latest"
    sh_qt_body=''
    if sh_have curl; then
        sh_qt_body=$(curl -fsSL -A 'curl/sandhome' "$sh_qt_api" 2>/dev/null)
    fi
    if [ -z "$sh_qt_body" ] && sh_have wget; then
        sh_qt_body=$(wget -qO- --header='User-Agent: curl/sandhome' "$sh_qt_api" 2>/dev/null)
    fi
    [ -n "$sh_qt_body" ] || return 1
    sh_qt_tag=$(tc_qemuuser_tag_from_body "$sh_qt_body")
    [ -n "$sh_qt_tag" ] || return 1
    printf '%s' "$sh_qt_tag"
}

# tc_qemuuser_extract ARCHIVE DEST -> unpack the xz archive. tar owns the .xz
# suffix only when it was built with liblzma; otherwise the stream is decoded
# first with unxz or xz and tar reads stdin. Three spellings for one archive,
# because the host this module installs onto is the host whose tar is unknown.
# Every spelling goes through sh_tar, which drops archive ownership first:
# a uid-0 sandbox without CAP_CHOWN refuses tar's chown and exits 2.
tc_qemuuser_extract() {
    if sh_tar -xJf "$1" -C "$2" 2>/dev/null; then
        return 0
    fi
    if sh_have unxz; then
        if unxz -c "$1" 2>/dev/null | sh_tar -xf - -C "$2" 2>/dev/null; then
            return 0
        fi
    fi
    if sh_have xz; then
        if xz -dc "$1" 2>/dev/null | sh_tar -xf - -C "$2" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

tc_qemuuser_install() {
    sh_qu_root=$(sh_toolchain_root qemuuser)
    # # STOP: SH_ARCH IS NOT RELIABLE HERE, SO THE ARCH IS MEASURED. The first
    # version built the copy glob from ${SH_ARCH%%_*}, and in the install path
    # that variable can be unset, so the glob became `qemu-*` and matched
    # nothing -- the install downloaded 63MB, extracted it, then refused with
    # "the archive did not contain the expected emulator". uname answers the
    # same question and is always there.
    sh_qu_mach=$(uname -m 2>/dev/null) || sh_qu_mach=${SH_ARCH:-unknown}
    tc_qemuuser_asset >/dev/null 2>&1 || {
        sh_warn "no qemu-static build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"
        return 1
    }
    sh_qu_asset=$(tc_qemuuser_asset)

    # # STOP: RESOLVE THE TAG, DO NOT PIN IT IN THE MODULE. A hardcoded tag is the
    # shape that rots: the version literal goes stale while the module still
    # says it is current. The Forgejo API answers the newest tag, and only
    # the RESULT needs to be pinned -- the digest of the bytes we fetch.
    if ! sh_qu_tag=$(tc_qemuuser_tag); then
        sh_warn 'could not resolve the newest qemu-static tag from the Forgejo API'
        return 1
    fi
    sh_qu_rel="ziglang/qemu-static/releases/download/$sh_qu_tag/$sh_qu_asset-$sh_qu_tag.tar.xz"
    sh_qu_pin=$(sh_pin_for "https://codeberg.org/$sh_qu_rel" qemuuser)

    mkdir -p "$sh_qu_root" 2>/dev/null || return 1
    # # STOP: A KEPT ARCHIVE IS REUSED BEFORE THE NETWORK IS TOUCHED. Adding a
    # guest to an existing payload (`install qemuuser --extra aarch64`) used to
    # re-download the same 63MB archive, because the install deleted it after
    # the first extraction: the run printed "rebuilding the view without
    # downloading" for a view that could not serve the guest, then "downloading
    # a fresh copy" (issue #146). The archive holds every guest, so keeping it
    # costs one file on the home side and makes the second run a local extract.
    # It is verified against the same pin before reuse, so a truncated or
    # altered file is discarded and fetched again.
    if [ -f "$sh_qu_root/qu.tar.xz" ]; then
        sh_qu_kept=$(sh_sha256 "$sh_qu_root/qu.tar.xz" 2>/dev/null)
        if [ -n "$sh_qu_kept" ] && sh_digest_matches "$sh_qu_kept" "$sh_qu_pin"; then
            sh_say "reusing the kept qemu-static archive at $sh_qu_root/qu.tar.xz"
        else
            rm -f "$sh_qu_root/qu.tar.xz" 2>/dev/null || true
        fi
    fi
    if [ ! -f "$sh_qu_root/qu.tar.xz" ]; then
        # Direct first, mirror second: either serves identical bytes, and the
        # pin below holds whichever answered, so a fallback never weakens the
        # check.
        if ! sh_fetch_verified "https://codeberg.org/$sh_qu_rel" "$sh_qu_root/qu.tar.xz" "$sh_qu_pin"; then
            if ! sh_fetch_verified "https://api.rv.pkgforge.dev/https://codeberg.org/$sh_qu_rel" "$sh_qu_root/qu.tar.xz" "$sh_qu_pin"; then
                return 1
            fi
        fi
    fi
    if ! tc_qemuuser_extract "$sh_qu_root/qu.tar.xz" "$sh_qu_root"; then
        sh_warn "could not unpack the qemu-static archive (no working tar+lzma path here)"
        return 1
    fi
    # The top entry without find: the archive holds one qemu-linux-* directory.
    sh_qu_dir=''
    for sh_qu_e in "$sh_qu_root"/qemu-linux-*; do
        [ -d "$sh_qu_e" ] || continue
        sh_qu_dir=$sh_qu_e
        break
    done
    [ -n "$sh_qu_dir" ] || { sh_warn "the qemu-static archive had no top-level directory"; return 1; }
    # START FROM A CLEAN BIN: without this, a re-install that asks for different
    # guests leaves the previous guests on disk, and the BINS loop below would
    # promise them on PATH even though this install did not decide to keep them.
    rm -rf "$sh_qu_root/bin" 2>/dev/null || true
    mkdir -p "$sh_qu_root/bin" 2>/dev/null || return 1
    # The host emulator always; the guest set on request. Promoting all 33
    # unconditionally is ~280MB of view for a machine that will run one or two,
    # and the exec root is the constrained side of the split -- this is the
    # same mistake the archive invites, avoided once here.
    case "$sh_qu_mach" in
        x86_64|amd64)
            sh_qu_host=qemu-x86_64 ;;
        aarch64|arm64)
            sh_qu_host=qemu-aarch64 ;;
        *)
            sh_qu_host='' ;;
    esac
    if [ -n "$sh_qu_host" ]; then
        cp "$sh_qu_dir/bin/$sh_qu_host" "$sh_qu_root/bin/" 2>/dev/null || true
    fi
    for sh_qu_extra in ${SANDHOME_QEMUUSER_EXTRA:-}; do
        # A name is accepted as either `aarch64` or `qemu-aarch64`.
        case "$sh_qu_extra" in
            qemu-*) sh_qu_name=$sh_qu_extra ;;
            *)      sh_qu_name=qemu-$sh_qu_extra ;;
        esac
        if [ -f "$sh_qu_dir/bin/$sh_qu_name" ]; then
            cp "$sh_qu_dir/bin/$sh_qu_name" "$sh_qu_root/bin/" 2>/dev/null || true
        else
            sh_warn "SANDHOME_QEMUUSER_EXTRA names $sh_qu_extra, but the archive has no bin/$sh_qu_name"
        fi
    done
    # BINS is read as a plain variable by the promote step, so the set that
    # actually reached disk is what it must list. The same helper the module
    # uses at load time does this, so the two cannot disagree about what exists.
    tc_qemuuser_bins_from_disk
    export TC_qemuuser_BINS
    # The host emulator is the one this module promises. Checking for it by name
    # after the copies means an archive that did not contain it is caught here
    # rather than at first use; on a host whose name we do not know, the case
    # above left sh_qu_host empty and there is nothing to assert.
    if [ -n "$sh_qu_host" ]; then
        [ -x "$sh_qu_root/bin/$sh_qu_host" ] || {
            sh_warn "the archive did not contain bin/$sh_qu_host"
            return 1
        }
    fi
    chmod 0755 "$sh_qu_root/bin/"* 2>/dev/null || true
    # The extracted tree is 280MB and is dropped; qu.tar.xz (63MB) is kept so
    # the next `--extra` is a local extract rather than a second download.
    rm -rf "$sh_qu_dir"
    return 0
}

tc_qemuuser_env() { return 0; }

tc_qemuuser_version() {
    sh_have qemu-x86_64 && sh_first_line qemu-x86_64 --version 2>/dev/null
}
