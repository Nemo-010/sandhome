#!/bin/sh
# jq - the JSON filter. A single static binary, which makes it the smallest
# complete test of the install -> promote -> exec path.
TC_jq_DESC='jq, the command-line JSON processor (single static binary)'
TC_jq_BINS='bin/jq'
TC_jq_EXEC_MB=8

tc_jq_probe() {
    sh_have jq && jq --version >/dev/null 2>&1
}

tc_jq_install() {
    sh_ji_root=$(sh_toolchain_root jq)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64) sh_ji_asset='jq-linux-amd64' ;;
        Linux:aarch64|Linux:arm64) sh_ji_asset='jq-linux-arm64' ;;
        Linux:i386|Linux:i686) sh_ji_asset='jq-linux-i386' ;;
        Darwin:*) sh_ji_asset='jq-macos-amd64' ;;
        *) sh_warn "no jq build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_space_need 16 home || return 1
    mkdir -p "$sh_ji_root/bin" 2>/dev/null || return 1
    sh_ji_url="https://github.com/jqlang/jq/releases/latest/download/$sh_ji_asset"
    if ! sh_fetch_verified "$sh_ji_url" "$sh_ji_root/bin/jq" "$(sh_pin_for "$sh_ji_url" jq)"; then
        return 1
    fi
    chmod 0755 "$sh_ji_root/bin/jq" 2>/dev/null || true
    return 0
}

tc_jq_env() {
    # Nothing beyond PATH: BINS put the exec-view binary on it.
    return 0
}

tc_jq_version() {
    sh_have jq && jq --version 2>/dev/null
}

# tc_jq_adopted -> the directory the working copy was found in when this
# toolchain is ADOPTED rather than installed. There is no home tree in that case,
# so this is what `$SANDHOME_EXEC/bin` links against, and what the promote step
# mirrors through an exec view when the copy cannot run from where it sits.
tc_jq_adopted() {
    # sh_path_where, not command -v: the exec view is on PATH by the time an
    # install runs, so command -v answers with the view this tool is being
    # linked INTO and the promote step then links the view onto itself (issue
    # #43). The exec view is not a working copy and is not consulted.
    sh_jq_which=$(sh_path_where jq)
    [ -n "$sh_jq_which" ] || return 0
    sh_jq_dir=${sh_jq_which%/*}
    [ -n "$sh_jq_dir" ] || sh_jq_dir=.
    ( CDPATH='' cd -- "$sh_jq_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_jq_dir"
}
