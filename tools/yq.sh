#!/bin/sh
# yq - the YAML/TOML/XML processor, from the official mikefarah/yq release binary.
TC_yq_DESC='yq, a YAML/TOML/XML command-line processor (single binary)'
TC_yq_BINS='bin/yq'
TC_yq_EXEC_MB=8

tc_yq_probe() {
    sh_have yq && yq --version >/dev/null 2>&1
}

tc_yq_install() {
    sh_yq_root=$(sh_toolchain_root yq)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_yq_plat=linux_amd64 ;;
        Linux:aarch64|Linux:arm64)  sh_yq_plat=linux_arm64 ;;
        Darwin:x86_64)              sh_yq_plat=darwin_amd64 ;;
        Darwin:arm64)               sh_yq_plat=darwin_arm64 ;;
        *) sh_warn "no yq build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    # The asset name carries no version, so latest/download serves whatever is
    # current with no tag to resolve and nothing to go stale.
    sh_yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_${sh_yq_plat}"
    sh_space_need 32 home || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_yq_url into $sh_yq_root"
        return 0
    fi
    rm -rf "$sh_yq_root" 2>/dev/null
    mkdir -p "$sh_yq_root/bin" 2>/dev/null || return 1
    if ! sh_fetch_verified "$sh_yq_url" "$sh_yq_root/bin/yq" "$(sh_pin_for "$sh_yq_url" yq)"; then
        return 1
    fi
    chmod 0755 "$sh_yq_root/bin/yq" 2>/dev/null || true
    if [ ! -x "$sh_yq_root/bin/yq" ]; then
        sh_warn "the yq release did not put yq at $sh_yq_root/bin/yq"
        return 1
    fi
    return 0
}

tc_yq_env() {
    # Nothing beyond PATH: BINS put the exec-view binary on it.
    return 0
}

tc_yq_version() {
    sh_have yq && sh_first_line yq --version 2>/dev/null
}

# tc_yq_adopted -> the directory the working copy was found in when this
# toolchain is ADOPTED rather than installed. sh_path_where, not command -v
# (issue #43).
tc_yq_adopted() {
    sh_yq_which=$(sh_path_where yq)
    [ -n "$sh_yq_which" ] || return 0
    sh_yq_dir=${sh_yq_which%/*}
    [ -n "$sh_yq_dir" ] || sh_yq_dir=.
    ( CDPATH='' cd -- "$sh_yq_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_yq_dir"
}
