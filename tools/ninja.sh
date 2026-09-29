#!/bin/sh
# ninja - the small build system, from the official ninja-build/ninja release zip.
TC_ninja_DESC='ninja, a small build system (single static binary)'
TC_ninja_BINS='ninja'
TC_ninja_EXEC_MB=8

tc_ninja_probe() {
    sh_have ninja && ninja --version >/dev/null 2>&1
}

tc_ninja_install() {
    sh_nj_root=$(sh_toolchain_root ninja)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64|Linux:aarch64|Linux:arm64) sh_nj_asset='ninja-linux.zip' ;;
        Darwin:*) sh_nj_asset='ninja-mac.zip' ;;
        *) sh_warn "no ninja build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    # The asset name carries no version, so latest/download serves whatever is
    # current with no tag to resolve and nothing to go stale.
    sh_nj_url="https://github.com/ninja-build/ninja/releases/latest/download/$sh_nj_asset"
    sh_space_need 16 home || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_nj_url into $sh_nj_root"
        return 0
    fi
    rm -rf "$sh_nj_root" 2>/dev/null
    mkdir -p "$sh_nj_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_nj_url" "$sh_nj_root" '' ninja; then
        return 1
    fi
    if [ ! -x "$sh_nj_root/ninja" ]; then
        sh_warn "the ninja archive did not put ninja at $sh_nj_root/ninja"
        return 1
    fi
    chmod 0755 "$sh_nj_root/ninja" 2>/dev/null || true
    return 0
}

tc_ninja_env() {
    # Nothing beyond PATH: BINS put the exec-view binary on it.
    return 0
}

tc_ninja_version() {
    sh_have ninja && sh_first_line ninja --version 2>/dev/null
}

# tc_ninja_adopted -> the directory the working copy was found in when this
# toolchain is ADOPTED rather than installed. sh_path_where, not command -v
# (issue #43).
tc_ninja_adopted() {
    sh_nj_which=$(sh_path_where ninja)
    [ -n "$sh_nj_which" ] || return 0
    sh_nj_dir=${sh_nj_which%/*}
    [ -n "$sh_nj_dir" ] || sh_nj_dir=.
    ( CDPATH='' cd -- "$sh_nj_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_nj_dir"
}
