#!/bin/sh
# ShellCheck, the shell script linter, from the official koalaman/shellcheck
# release tarball. A single static binary; it is both a toolchain in its own
# right and the gate tests/syntax.sh runs over this tree when it is present.
TC_shellcheck_DESC='ShellCheck, the shell script linter (single static binary)'
TC_shellcheck_BINS='bin/shellcheck'
TC_shellcheck_EXEC_MB=8

# tc_shellcheck_exec_mb -> the fresh-install exec need in MB. The binary is
# ~3MB and runs from a launcher in launch mode, so the view costs kilobytes;
# the static figure below is the copy-mode price. Read by the install gate
# and the feasibility plan so the two never disagree.
tc_shellcheck_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '8'
    else
        printf '8'
    fi
}

tc_shellcheck_probe() {
    sh_have shellcheck && shellcheck --version >/dev/null 2>&1
}

tc_shellcheck_install() {
    sh_sc_root=$(sh_toolchain_root shellcheck)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_sc_plat='linux.x86_64' ;;
        Linux:aarch64|Linux:arm64)  sh_sc_plat='linux.aarch64' ;;
        Darwin:x86_64)              sh_sc_plat='darwin.x86_64' ;;
        Darwin:arm64)               sh_sc_plat='darwin.aarch64' ;;
        *) sh_warn "no shellcheck build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    # STOP: THE TAG IS RESOLVED, NOT TYPED. A literal version in the asset
    # name is the shape that rots (issue #105): the module keeps saying it
    # installs while upstream moves on. The GitHub latest redirect answers
    # the current tag, and only the fetched bytes need a pin, not the name.
    sh_sc_tag=${SANDHOME_SHELLCHECK_VERSION:-$(sh_github_latest_tag koalaman/shellcheck)}
    case "$sh_sc_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current shellcheck release'; return 1 ;;
    esac
    sh_sc_asset="shellcheck-$sh_sc_tag.$sh_sc_plat.tar.xz"
    sh_sc_dirname="shellcheck-$sh_sc_tag"
    sh_space_need 16 home || return 1
    sh_sc_url="https://github.com/koalaman/shellcheck/releases/download/$sh_sc_tag/$sh_sc_asset"
    sh_sc_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_sc_stage" 2>/dev/null || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_sc_url into $sh_sc_root"
        return 0
    fi
    rm -rf "$sh_sc_root" 2>/dev/null
    mkdir -p "$sh_sc_root/bin" "$sh_sc_stage" 2>/dev/null || return 1
    if ! sh_fetch_verified "$sh_sc_url" "$sh_sc_stage/.shellcheck.$$.tar.xz" "$(sh_pin_for "$sh_sc_url" shellcheck)"; then
        return 1
    fi
    # The tarball holds one top directory with the binary inside. tar owns
    # the .xz suffix only when built with liblzma; otherwise decode first.
    # Every spelling goes through sh_tar, which drops archive ownership first:
    # a uid-0 sandbox without CAP_CHOWN refuses tar's chown and exits 2.
    if sh_tar -xJf "$sh_sc_stage/.shellcheck.$$.tar.xz" -C "$sh_sc_stage" 2>/dev/null; then
        :
    elif sh_have unxz && unxz -c "$sh_sc_stage/.shellcheck.$$.tar.xz" 2>/dev/null | sh_tar -xf - -C "$sh_sc_stage" 2>/dev/null; then
        :
    elif sh_have xz && xz -dc "$sh_sc_stage/.shellcheck.$$.tar.xz" 2>/dev/null | sh_tar -xf - -C "$sh_sc_stage" 2>/dev/null; then
        :
    else
        sh_warn 'could not unpack the shellcheck archive (no working tar+lzma path here)'
        rm -f "$sh_sc_stage/.shellcheck.$$.tar.xz" 2>/dev/null
        return 1
    fi
    rm -f "$sh_sc_stage/.shellcheck.$$.tar.xz" 2>/dev/null
    sh_sc_bin=''
    for sh_sc_e in "$sh_sc_stage/$sh_sc_dirname/shellcheck"; do
        [ -x "$sh_sc_e" ] || [ -f "$sh_sc_e" ] || continue
        sh_sc_bin=$sh_sc_e
        break
    done
    [ -n "$sh_sc_bin" ] || { sh_warn 'the shellcheck archive did not contain the shellcheck binary'; return 1; }
    cp -f "$sh_sc_bin" "$sh_sc_root/bin/shellcheck" 2>/dev/null || return 1
    chmod 0755 "$sh_sc_root/bin/shellcheck" 2>/dev/null || true
    rm -rf "$sh_sc_stage/$sh_sc_dirname" 2>/dev/null
    if [ ! -x "$sh_sc_root/bin/shellcheck" ]; then
        sh_warn "the shellcheck archive did not put shellcheck at $sh_sc_root/bin/shellcheck"
        return 1
    fi
    return 0
}

tc_shellcheck_env() {
    # Nothing beyond PATH: BINS put the exec-view binary on it.
    return 0
}

tc_shellcheck_version() {
    sh_have shellcheck && sh_first_line shellcheck --version 2>/dev/null
}

# tc_shellcheck_adopted -> the directory the working copy was found in when
# this toolchain is ADOPTED rather than installed. sh_path_where, not
# command -v: the exec view is on PATH by the time an install runs, so
# command -v answers with the view this tool is being linked INTO (issue #43).
tc_shellcheck_adopted() {
    sh_sc_which=$(sh_path_where shellcheck)
    [ -n "$sh_sc_which" ] || return 0
    sh_sc_dir=${sh_sc_which%/*}
    [ -n "$sh_sc_dir" ] || sh_sc_dir=.
    ( CDPATH='' cd -- "$sh_sc_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_sc_dir"
}
