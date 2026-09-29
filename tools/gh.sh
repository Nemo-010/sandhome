#!/bin/sh
# gh - the GitHub CLI, from the official cli/cli release tarball.
TC_gh_DESC='gh, the GitHub command-line tool (single binary from its tarball)'
TC_gh_BINS='bin/gh'
TC_gh_EXEC_MB=16

tc_gh_probe() {
    sh_have gh && gh --version >/dev/null 2>&1
}

tc_gh_install() {
    sh_gh_root=$(sh_toolchain_root gh)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_gh_plat=linux_amd64; sh_gh_ext='tar.gz' ;;
        Linux:aarch64|Linux:arm64)  sh_gh_plat=linux_arm64; sh_gh_ext='tar.gz' ;;
        Darwin:x86_64)              sh_gh_plat=macOS_amd64; sh_gh_ext='zip' ;;
        Darwin:arm64)               sh_gh_plat=macOS_arm64; sh_gh_ext='zip' ;;
        *) sh_warn "no gh build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    # The tag is resolved, not typed: the asset name carries the version, so
    # a literal here is the shape that rots (issue #105).
    sh_gh_tag=${SANDHOME_GH_VERSION:-$(sh_github_latest_tag cli/cli)}
    case "$sh_gh_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current gh release'; return 1 ;;
    esac
    sh_gh_ver=${sh_gh_tag#v}
    sh_gh_url="https://github.com/cli/cli/releases/download/${sh_gh_tag}/gh_${sh_gh_ver}_${sh_gh_plat}.${sh_gh_ext}"
    sh_space_need 64 home || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_gh_url into $sh_gh_root"
        return 0
    fi
    rm -rf "$sh_gh_root" 2>/dev/null
    mkdir -p "$sh_gh_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_gh_url" "$sh_gh_root" '' gh; then
        return 1
    fi
    if [ ! -x "$sh_gh_root/bin/gh" ]; then
        sh_warn "the gh archive did not put gh at $sh_gh_root/bin/gh"
        return 1
    fi
    return 0
}

tc_gh_env() {
    # Nothing beyond PATH: BINS put the exec-view binary on it.
    return 0
}

tc_gh_version() {
    sh_have gh && sh_first_line gh --version 2>/dev/null
}

# tc_gh_adopted -> the directory the working copy was found in when this
# toolchain is ADOPTED rather than installed. sh_path_where, not command -v
# (issue #43).
tc_gh_adopted() {
    sh_gh_which=$(sh_path_where gh)
    [ -n "$sh_gh_which" ] || return 0
    sh_gh_dir=${sh_gh_which%/*}
    [ -n "$sh_gh_dir" ] || sh_gh_dir=.
    ( CDPATH='' cd -- "$sh_gh_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_gh_dir"
}
