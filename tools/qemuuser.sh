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
# and the asset is fetched through the arbitrary-URL passthrough; both want a
# curl-like user agent (a browser UA is answered 420).
TC_qemuuser_DESC='qemu-user, the static user-mode emulators (run a guest ELF, trace its syscalls without ptrace)'
# The HOST emulator is always promoted; extra guest architectures are opt-in
# through SANDHOME_QEMUUSER_EXTRA, because all 33 emulators are ~280MB of exec
# view and most sessions need one. Naming a guest arch here is what makes
# `zig cc --target=aarch64-linux-musl ... && qemu-aarch64 ./out` work, which is
# the whole cross-architecture story on a host with no cross toolchain.
TC_qemuuser_BINS='bin/qemu-x86_64'
TC_qemuuser_EXEC_MB=12

# tc_qemuuser_bins_from_disk -> BINS listing what is actually in the bin
# directory, host emulator first. Called at load time as well as after an
# install, because the install function does NOT run on the "payload already
# present, rebuild the view" path: without this, an opt-in guest whose payload
# is already on disk was dropped from BINS on every re-run, so the view lost a
# launcher that the payload still backed (and `command -v` then found nothing).
# Reading the directory is also the honest answer -- it names what exists, not
# what was once requested.
tc_qemuuser_bins_from_disk() {
    sh_qbd_root=$(sh_toolchain_root qemuuser 2>/dev/null)
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

# Honour the requested extras even when the payload is already here. A guest
# that is requested but absent cannot be copied on this path (the archive is
# gone), so it is named rather than silently ignored: `install --force` is the
# only way to add one, and saying so is the difference between a warning and a
# mystery.
tc_qemuuser_bins_from_disk
if [ -n "${SANDHOME_QEMUUSER_EXTRA:-}" ]; then
    for sh_qbd_x in ${SANDHOME_QEMUUSER_EXTRA}; do
        case "$sh_qbd_x" in qemu-*) sh_qbd_n=$sh_qbd_x ;; *) sh_qbd_n=qemu-$sh_qbd_x ;; esac
        case " $TC_qemuuser_BINS " in
            *" bin/$sh_qbd_n "*) ;;
            *) sh_warn "SANDHOME_QEMUUSER_EXTRA names $sh_qbd_x, but it is not installed; run 'sandhome install --force qemuuser' to fetch it" ;;
        esac
    done
fi

tc_qemuuser_probe() {
    sh_have qemu-x86_64 && qemu-x86_64 --version >/dev/null 2>&1
}

# tc_qemuuser_asset -> the archive asset name for this machine, or nothing when
# upstream publishes no build for it. The Zig build names its archives by the
# HOST triple it runs on, which is what sh_arch_go-style mapping is for; a
# missing arm returns non-zero so the install refuses by name.
tc_qemuuser_asset() {
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   printf 'qemu-linux-x86_64' ;;
        Linux:aarch64|Linux:arm64)  printf 'qemu-linux-aarch64' ;;
        *) return 1 ;;
    esac
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
    # shape that rots (#105): the version literal goes stale while the module
    # still says it is current. The Forgejo API answers the newest tag, and only
    # the RESULT needs to be pinned -- the digest of the bytes we fetch.
    sh_qu_api="https://api.cb.pkgforge.dev/api/v1/repos/ziglang/qemu-static/releases/latest"
    sh_qu_tag=
    if sh_have curl; then
        # The proxy wants a curl-like agent; without one it answers 420.
        sh_qu_tag=$(curl -fsSL -A 'curl/sandhome' "$sh_qu_api" 2>/dev/null | \
            sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    if [ -z "$sh_qu_tag" ]; then
        sh_warn "could not resolve the newest qemu-static tag from $sh_qu_api"
        return 1
    fi
    sh_qu_url="https://codeberg.org/ziglang/qemu-static/releases/download/$sh_qu_tag/$sh_qu_asset-$sh_qu_tag.tar.xz"

    mkdir -p "$sh_qu_root" 2>/dev/null || return 1
    # The asset is fetched through the arbitrary-URL passthrough, which preserves
    # the digest byte for byte, so a pin still holds when the mirror serves it.
    if ! sh_fetch_verified "https://api.rv.pkgforge.dev/$sh_qu_url" "$sh_qu_root/qu.tar.xz" "$(sh_pin_for "$sh_qu_url" qemuuser)"; then
        return 1
    fi
    tar -xJf "$sh_qu_root/qu.tar.xz" -C "$sh_qu_root" 2>/dev/null || return 1
    sh_qu_dir=$(find "$sh_qu_root" -maxdepth 1 -type d -name "qemu-linux-*" | head -1)
    [ -n "$sh_qu_dir" ] || { sh_warn "the qemu-static archive had no top-level directory"; return 1; }
    mkdir -p "$sh_qu_root/bin" 2>/dev/null || return 1
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
    rm -rf "$sh_qu_dir" "$sh_qu_root/qu.tar.xz"
    return 0
}

tc_qemuuser_env() { return 0; }


tc_qemuuser_version() {
    sh_have qemu-x86_64 && qemu-x86_64 --version 2>/dev/null | sed -n '1s/.*version //p'
}
