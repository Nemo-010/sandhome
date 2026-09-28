#!/bin/sh
# ripgrep - the search tool agents reach for first. A single musl binary.
TC_ripgrep_DESC='ripgrep (rg), the fast recursive search tool'
TC_ripgrep_BINS='bin/rg'

tc_ripgrep_probe() {
    sh_have rg && rg --version >/dev/null 2>&1
}

tc_ripgrep_install() {
    sh_rg_root=$(sh_toolchain_root ripgrep)
    sh_rg_tag=$(sh_github_latest_tag BurntSushi/ripgrep)
    case "$sh_rg_tag" in
        ''|*[!0-9.]*) sh_warn 'could not resolve the current ripgrep release tag'; return 1 ;;
    esac
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_rg_triple='x86_64-unknown-linux-musl' ;;
        Linux:aarch64|Linux:arm64) sh_rg_triple='aarch64-unknown-linux-gnu' ;;
        Darwin:x86_64)             sh_rg_triple='x86_64-apple-darwin' ;;
        Darwin:arm64)              sh_rg_triple='aarch64-apple-darwin' ;;
        *) sh_warn "no ripgrep release for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_rg_name="ripgrep-${sh_rg_tag}-${sh_rg_triple}"
    sh_rg_url="https://github.com/BurntSushi/ripgrep/releases/download/${sh_rg_tag}/${sh_rg_name}.tar.gz"
    sh_space_need 32 home || return 1
    rm -rf "$sh_rg_root" 2>/dev/null
    if ! sh_fetch_unpack "$sh_rg_url" "$sh_rg_root/stage"; then
        sh_warn 'could not fetch or unpack ripgrep'
        return 1
    fi
    mkdir -p "$sh_rg_root/bin" 2>/dev/null || return 1
    if [ -f "$sh_rg_root/stage/rg" ]; then
        mv "$sh_rg_root/stage/rg" "$sh_rg_root/bin/rg" 2>/dev/null || true
    fi
    rm -rf "$sh_rg_root/stage" 2>/dev/null
    [ -f "$sh_rg_root/bin/rg" ] || { sh_warn 'the ripgrep archive had no rg binary'; return 1; }
    return 0
}

tc_ripgrep_env() { return 0; }

tc_ripgrep_version() {
    sh_have rg && sh_first_line rg --version 2>/dev/null
}

# tc_ripgrep_adopted -> the directory the working copy was found in when this
# toolchain is ADOPTED rather than installed. There is no home tree in that case,
# so this is what `$SANDHOME_EXEC/bin` links against, and what the promote step
# mirrors through an exec view when the copy cannot run from where it sits.
#
# # STOP: `command -v rg`, NOT `command -v ripgrep`, AND THE BINARY NAME IS THE
# MODULE'S OWN. `TC_ripgrep_BINS='bin/rg'` and the probe asks for `rg`; this
# function asked for `ripgrep`, which no ripgrep release has ever installed, so
# it answered nothing on every machine. The answer was empty rather than wrong,
# which is why it was dormant: sh_promote_toolchain fell through to its own
# `command -v "$bin"` fallback and found the binary by luck. The cost of the
# luck is that this function - the declared way for a module to say where its
# working copy lives - was never exercised at all, and the same shape in another
# module would have pointed the view at a different program than the one
# TC_<name>_BINS names. Measured with a working rg on PATH as `rg`:
#   which rg=[/tmp/fb/rg]   adopted=[]
# It now answers /tmp/fb. The general guard is in tests/unit.sh, which requires
# every module's tc_<name>_adopted to name the directory its own _BINS binary
# was found in, so the next module that copies this shape is caught.
tc_ripgrep_adopted() {
    sh_rg_which=$(command -v rg 2>/dev/null)
    [ -n "$sh_rg_which" ] || return 0
    sh_rg_dir=${sh_rg_which%/*}
    [ -n "$sh_rg_dir" ] || sh_rg_dir=.
    ( CDPATH='' cd -- "$sh_rg_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_rg_dir"
}
