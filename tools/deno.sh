#!/bin/sh
# deno - the Deno runtime, from the official denoland/deno release zip.
TC_deno_DESC='Deno, a TypeScript/JavaScript runtime (single binary, from GitHub)'
TC_deno_BINS='deno'
TC_deno_EXEC_MB=150
# Deno fetches after install: remote imports, `deno upgrade` and JSR/npm fetches
# all reach the network at run time. Declared for the same reason as bun
# (issue #125).
TC_deno_DYNAMIC='remote imports and self-upgrade (deno upgrade) at run time'

# # STOP: THE RUNTIME IS A REAL COPY, NOT A LAUNCHER. deno run, deno test and
# every worker deno spawns re-execute the runtime through its own path, and a
# launcher makes that path `/memfd:sandhome (deleted)`; every spawn then dies
# with ENOENT while `deno --version` still answers (issue #139). A launcher is
# right for a compiler invoked once; it is wrong for an interpreter designed to
# fork itself thousands of times.
tc_deno_copy_bins() { printf 'deno'; }

# tc_deno_exec_mb -> the fresh-install exec need in MB. deno is on the copy
# list, so launch mode already pays for the real binary, and the price is the
# declared one in both modes: the linux-x64 release is a 150MB binary and the
# view cannot be smaller than the file it holds, so under-pricing it would
# refuse nothing and then run out of room mid-copy. Read by the install gate
# below and the feasibility plan so the two never disagree (issue #92).
tc_deno_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '150'
    else
        printf '150'
    fi
}

# tc_deno_doctor -> the same self-exec check node gets, for the same reason: a
# runtime that can answer --version and not spawn itself is the failure mode
# issue #139 is about, and the readiness gate is where it has to be visible.
tc_deno_doctor() {
    sh_dd_bin=''
    if [ -n "${SH_EXEC_VIEWS:-}" ] && [ -x "$SH_EXEC_VIEWS/deno/deno" ]; then
        sh_dd_bin="$SH_EXEC_VIEWS/deno/deno"
    elif [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/views/deno/deno" ]; then
        sh_dd_bin="$SANDHOME_EXEC/views/deno/deno"
    elif sh_have deno; then
        sh_dd_bin=deno
    fi
    [ -n "$sh_dd_bin" ] || return 1
    # Deno.Command has outputSync()/output()/spawn(); there is no spawnSync, so
    # the old check threw a TypeError and reported a deno that re-executes fine
    # as broken (issue #151). Run the child and propagate its own exit code.
    # REDUNDANCY: TWO SPELLINGS OF THE SAME RE-EXEC, NOT A LOWER BAR. The
    # re-exec through Deno.execPath is what workers do, so both probes prove
    # it: outputSync first, async spawn second. A --version fallback is
    # deliberately absent: answering --version proves the binary starts, not
    # that it can re-execute itself, and the gate is named for the spawn.
    # One renamed API (the spawnSync defect) cannot red the toolchain again,
    # and one working spelling cannot be mistaken for a working runtime.
    if "$sh_dd_bin" eval 'const r = new Deno.Command(Deno.execPath(), {args:["eval","0"]}); Deno.exit(r.outputSync().code);' >/dev/null 2>&1; then
        return 0
    fi
    if "$sh_dd_bin" eval 'const c = new Deno.Command(Deno.execPath(), {args:["eval","0"]}).spawn(); const s = await c.status; Deno.exit(s.code);' >/dev/null 2>&1; then
        return 0
    fi
    return 1
    "$sh_dd_bin" --version >/dev/null 2>&1
}

tc_deno_probe() {
    sh_have deno && deno --version >/dev/null 2>&1
}

tc_deno_install() {
    sh_di_root=$(sh_toolchain_root deno)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_di_triple=x86_64-unknown-linux-gnu ;;
        Linux:aarch64|Linux:arm64)  sh_di_triple=aarch64-unknown-linux-gnu ;;
        Darwin:x86_64)              sh_di_triple=x86_64-apple-darwin ;;
        Darwin:arm64)               sh_di_triple=aarch64-apple-darwin ;;
        *) sh_warn "no deno build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_di_tag=$(sh_github_latest_tag denoland/deno)
    case "$sh_di_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current deno release'; return 1 ;;
    esac
    sh_di_name="deno-${sh_di_triple}"
    sh_di_base="https://github.com/denoland/deno/releases/download/${sh_di_tag}"
    sh_di_url="${sh_di_base}/${sh_di_name}.zip"
    sh_di_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_di_stage" 2>/dev/null || return 1
    sh_space_need 300 home || return 1
    sh_space_need "$(tc_deno_exec_mb)" exec || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_di_url into $sh_di_root"
        return 0
    fi
    # The release publishes a .sha256sum sidecar next to each asset, so the
    # download is held to the publisher's digest as well as to any caller pin.
    sh_di_sha=''
    sh_di_sum="$sh_di_stage/deno-sum.$$"
    if sh_fetch "${sh_di_base}/${sh_di_name}.zip.sha256sum" "$sh_di_sum"; then
        read -r sh_di_sha _ < "$sh_di_sum" || :
        sh_is_hex64 "$sh_di_sha" || sh_di_sha=''
        rm -f "$sh_di_sum" 2>/dev/null
    fi
    rm -rf "$sh_di_root" 2>/dev/null
    mkdir -p "$sh_di_root" 2>/dev/null || return 1
    if ! sh_fetch_unpack "$sh_di_url" "$sh_di_root" "$sh_di_sha" deno; then
        return 1
    fi
    if [ ! -x "$sh_di_root/deno" ]; then
        sh_warn "the deno archive did not put deno at $sh_di_root/deno"
        return 1
    fi
    return 0
}

tc_deno_version() {
    sh_have deno && sh_first_line deno --version 2>/dev/null
}
