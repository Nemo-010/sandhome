#!/bin/sh
# bun - the Bun JavaScript/TypeScript runtime, from the official oven-sh/bun zip.
TC_bun_DESC='Bun, a JavaScript/TypeScript runtime and toolkit (single binary)'
TC_bun_BINS='bun'
TC_bun_EXEC_MB=200
# Bun fetches after install: `bun install` reaches the npm registry and the shim
# itself is only a launcher for whatever the network serves at run time. Declared
# so `sandhome toolchains` and the report name it instead of leaving the caller to
# discover it when the network is gone (issue #125).
TC_bun_DYNAMIC='registry installs (bun install) at run time'

# # STOP: THE RUNTIME IS A REAL COPY, NOT A LAUNCHER. `bun run`, `bun test`
# and every worker bun spawns re-execute the runtime through its own path, and a
# launcher makes that path `/memfd:sandhome (deleted)`; every spawn then dies
# with ENOENT while `bun --version` still answers (issue #139).
tc_bun_copy_bins() { printf 'bun'; }

# tc_bun_exec_mb -> the fresh-install exec need in MB. bun is on the copy list,
# so launch mode already pays for the real binary: 38MB measured for the
# linux-x64 build this tree was measured on (the declared 200 is the price the
# copy-mode gate reads, and it is kept above the measurement so a launch
# install is never the one that is refused), and 200 in copy mode
# (issue #92).
tc_bun_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '200'
    else
        printf '200'
    fi
}

# tc_bun_doctor -> the same self-exec check node gets, for the same reason: a
# runtime that can answer --version and not spawn itself is the failure mode
# issue #139 is about, and the readiness gate is where it has to be visible.
tc_bun_doctor() {
    sh_bd_bin=''
    if [ -n "${SH_EXEC_VIEWS:-}" ] && [ -x "$SH_EXEC_VIEWS/bun/bun" ]; then
        sh_bd_bin="$SH_EXEC_VIEWS/bun/bun"
    elif [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/views/bun/bun" ]; then
        sh_bd_bin="$SANDHOME_EXEC/views/bun/bun"
    elif sh_have bun; then
        sh_bd_bin=bun
    fi
    [ -n "$sh_bd_bin" ] || return 1
    "$sh_bd_bin" -e 'const r = Bun.spawnSync([process.execPath, "-e", "0"]); process.exit(r.exitCode === 0 ? 0 : 1)' >/dev/null 2>&1
}

tc_bun_probe() {
    sh_have bun && bun --version >/dev/null 2>&1
}

tc_bun_install() {
    sh_bi_root=$(sh_toolchain_root bun)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_bi_arch=x64 ;;
        Linux:aarch64|Linux:arm64) sh_bi_arch=aarch64 ;;
        *) sh_warn "no bun build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_bi_extra=''
    [ "${SH_LIBC:-unknown}" = musl ] && sh_bi_extra='-musl'
    sh_bi_tag=$(sh_github_latest_tag oven-sh/bun)
    case "$sh_bi_tag" in
        bun-v*) ;;
        *) sh_warn 'could not resolve the current bun release'; return 1 ;;
    esac
    sh_bi_url="https://github.com/oven-sh/bun/releases/download/${sh_bi_tag}/bun-linux-${sh_bi_arch}${sh_bi_extra}.zip"
    sh_space_need 400 home || return 1
    sh_space_need "$(tc_bun_exec_mb)" exec || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_bi_url into $sh_bi_root"
        return 0
    fi
    rm -rf "$sh_bi_root" 2>/dev/null
    mkdir -p "$sh_bi_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_bi_url" "$sh_bi_root" '' bun; then
        return 1
    fi
    if [ ! -x "$sh_bi_root/bun" ]; then
        sh_warn "the bun archive did not put bun at $sh_bi_root/bun"
        return 1
    fi
    return 0
}

tc_bun_version() {
    sh_have bun && sh_first_line bun --version 2>/dev/null
}
