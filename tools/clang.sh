#!/bin/sh
# clang - Clang/LLVM, from the official LLVM release tarball.
#
# NOTE: THIS IS THE >1GB TOOLCHAIN, AND IT IS WHY THE FETCH PATH SHARDS. The
# x86_64 tarball is about 1.9GB, well past the 1GB RLIMIT_FSIZE measured on a
# sandbox and past every single-file limit a process can raise. The install goes
# through sh_fetch_unpack, which fetches ranges into parts under the limit and
# unpacks from the concatenated stream, so no file bigger than the limit is ever
# written.
#
# # STOP: ONLY clang AND clang++ ARE COPIED INTO THE EXEC VIEW. The LLVM release
# ships dozens of executables (llvm-ar, llvm-objdump, the -XX variants, lld,
# llvm-config, ...) and promoting the whole tree copied every one of them, so a
# small exec root had to hold the entire bin/ - hundreds of MB - for a consumer
# who only ever starts `clang`. TC_clang_VIEW_BINS_ONLY tells the promote step to
# copy the named bins and symlink the rest back to the home, which is enough
# because the driver re-execs only itself for -cc1, reads its resource headers
# and libLLVM through symlinks (mmap(PROT_EXEC) is allowed on a noexec mount),
# and hands the final link to the system linker. The exec root then holds the
# ~150MB clang binary instead of the whole toolchain.
TC_clang_DESC='Clang/LLVM, from the official LLVM release tarball (a >1GB download)'
TC_clang_BINS='bin/clang bin/clang++'
TC_clang_VIEW_BINS_ONLY=1

tc_clang_probe() {
    sh_have clang && clang --version >/dev/null 2>&1
}

tc_clang_adopted() {
    sh_ca_which=$(command -v clang 2>/dev/null)
    [ -n "$sh_ca_which" ] || return 0
    sh_ca_dir=${sh_ca_which%/*}
    [ -n "$sh_ca_dir" ] || sh_ca_dir=.
    ( CDPATH='' cd -- "$sh_ca_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_ca_dir"
}

tc_clang_install() {
    sh_ci_root=$(sh_toolchain_root clang)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_ci_arch=X64 ;;
        Linux:aarch64|Linux:arm64) sh_ci_arch=ARM64 ;;
        *) sh_warn "no LLVM release tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_ci_tag=${SANDHOME_LLVM_TAG:-$(sh_github_latest_tag llvm/llvm-project)}
    case "$sh_ci_tag" in
        llvmorg-[0-9]*) ;;
        *) sh_warn 'could not resolve the current LLVM release'; return 1 ;;
    esac
    sh_ci_ver=${sh_ci_tag#llvmorg-}
    # # STOP: THE zst ASSET IS PREFERRED WHERE ZSTD EXISTS. It is 1.18GB against
    # 2.01GB for the xz, and zstd decompresses several times faster, which is the
    # difference between an LLVM install that is worth attempting on a sandbox
    # and one that is not. The xz stays the fallback for a host without zstd.
    if command -v zstd >/dev/null 2>&1 || command -v unzstd >/dev/null 2>&1; then
        sh_ci_asset="LLVM-${sh_ci_ver}-Linux-${sh_ci_arch}.tar.zst"
    else
        sh_ci_asset="LLVM-${sh_ci_ver}-Linux-${sh_ci_arch}.tar.xz"
    fi
    sh_ci_url="https://github.com/llvm/llvm-project/releases/download/${sh_ci_tag}/${sh_ci_asset}"
    # The x86_64 tree extracted to ~12GB here, plus ~1.9GB of parts held at the
    # same time. The home is named because that is where the tree goes; the exec
    # root is not given a static number, because only TC_clang_BINS is copied and
    # sh_view_need measures that copy before writing it.
    sh_space_need 16000 home || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_ci_url into $sh_ci_root"
        return 0
    fi
    rm -rf "$sh_ci_root" 2>/dev/null
    mkdir -p "$sh_ci_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_ci_url" "$sh_ci_root" '' clang; then
        return 1
    fi
    if [ ! -x "$sh_ci_root/bin/clang" ] && [ ! -x "$sh_ci_root/bin/clang++" ]; then
        sh_warn "the LLVM archive did not put clang under $sh_ci_root/bin"
        return 1
    fi
    return 0
}

tc_clang_version() {
    sh_have clang && sh_first_line clang --version 2>/dev/null
}
