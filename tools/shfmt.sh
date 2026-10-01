#!/bin/sh
# shfmt - the shell formatter, from the official mvdan/sh release binary.
TC_shfmt_DESC='shfmt, a shell script formatter (single static binary)'
TC_shfmt_BINS='bin/shfmt'
TC_shfmt_EXEC_MB=8

tc_shfmt_probe() {
    sh_have shfmt && shfmt --version >/dev/null 2>&1
}

tc_shfmt_install() {
    sh_sf_root=$(sh_toolchain_root shfmt)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_sf_plat=linux_amd64 ;;
        Linux:aarch64|Linux:arm64)  sh_sf_plat=linux_arm64 ;;
        Darwin:x86_64)              sh_sf_plat=darwin_amd64 ;;
        Darwin:arm64)               sh_sf_plat=darwin_arm64 ;;
        *) sh_warn "no shfmt build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    # The tag is resolved, not typed: the asset name carries the version, so
    # a literal here is the shape that rots (issue #105).
    sh_sf_tag=${SANDHOME_SHFMT_VERSION:-$(sh_github_latest_tag mvdan/sh)}
    case "$sh_sf_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current shfmt release'; return 1 ;;
    esac
    sh_sf_asset="shfmt_${sh_sf_tag}_${sh_sf_plat}"
    sh_sf_url="https://github.com/mvdan/sh/releases/download/${sh_sf_tag}/${sh_sf_asset}"
    sh_space_need 16 home || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_sf_url into $sh_sf_root"
        return 0
    fi
    rm -rf "$sh_sf_root" 2>/dev/null
    mkdir -p "$sh_sf_root/bin" 2>/dev/null || return 1
    if ! sh_fetch_verified "$sh_sf_url" "$sh_sf_root/bin/shfmt" "$(sh_pin_for "$sh_sf_url" shfmt)"; then
        return 1
    fi
    chmod 0755 "$sh_sf_root/bin/shfmt" 2>/dev/null || true
    if [ ! -x "$sh_sf_root/bin/shfmt" ]; then
        sh_warn "the shfmt release did not put shfmt at $sh_sf_root/bin/shfmt"
        return 1
    fi
    return 0
}

tc_shfmt_env() {
    # Nothing beyond PATH: BINS put the exec-view binary on it.
    return 0
}

tc_shfmt_version() {
    sh_have shfmt && sh_first_line shfmt --version 2>/dev/null
}

# tc_shfmt_adopted -> the directory the working copy was found in when this
# toolchain is ADOPTED rather than installed. sh_path_where, not command -v
# (issue #43).
tc_shfmt_adopted() {
    sh_sf_which=$(sh_path_where shfmt)
    [ -n "$sh_sf_which" ] || return 0
    sh_sf_dir=${sh_sf_which%/*}
    [ -n "$sh_sf_dir" ] || sh_sf_dir=.
    ( CDPATH='' cd -- "$sh_sf_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_sf_dir"
}
