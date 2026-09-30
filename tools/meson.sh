#!/bin/sh
# Meson, the build system for C/C++/Rust/Vala projects, installed through the
# python toolchain's uv. Meson is a Python package with no single binary, so it
# is not fetched as a tarball: uv builds it an isolated environment on the exec
# root and links the `meson` console script next to the toolchain's own
# binaries. REQUIRES python so the closure installs uv first (issue #123).
#
# The exec-root paths are the load-bearing part: `uv tool install` writes the
# launcher and the environment under UV_TOOL_BIN_DIR/UV_TOOL_DIR, and both
# point at $SANDHOME_EXEC (issue #82, fixed), so the console script is
# executable. Without them the install succeeds and the script dies with
# "bad interpreter: Permission denied" on the noexec home.
TC_meson_DESC='Meson, the build system for C/C++/Rust/Vala projects'
TC_meson_BINS='bin/meson'
TC_meson_REQUIRES='python'
TC_meson_EXEC_MB=32

# tc_meson_exec_mb -> the fresh-install exec need in MB. The environment is
# ~30MB and runs from a launcher in launch mode, so the view costs kilobytes;
# the figure below is the copy-mode price.
tc_meson_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '8'
    else
        printf '32'
    fi
}

tc_meson_probe() {
    sh_have meson && meson --version >/dev/null 2>&1
}

tc_meson_install() {
    sh_me_root=$(sh_toolchain_root meson)
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install meson with uv into $sh_me_root"
        return 0
    fi
    # uv must be reachable. The python toolchain owns it and leaves it on PATH
    # (TC_python_DESC says so); the closure guarantees python is installed
    # first, but a hand-run `install meson` may reach here with no PATH, so
    # four locations are tried before giving up. The brittle single fallback
    # (`UV_TOOL_BIN_DIR` with a fixed `views/python` suffix) missed the real
    # layout on a split root, so the exec views, the home toolchains and the
    # repo-adjacent python are all tried: every one is still a file that must
    # exist and run, never a guessed PATH.
    sh_me_uv=''
    if sh_have uv; then
        sh_me_uv=uv
    elif [ -n "${UV_TOOL_BIN_DIR:-}" ] && [ -x "$UV_TOOL_BIN_DIR/uv" ]; then
        sh_me_uv="$UV_TOOL_BIN_DIR/uv"
    elif [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/views/python/bin/uv" ]; then
        sh_me_uv="$SANDHOME_EXEC/views/python/bin/uv"
    elif [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/bin/uv" ]; then
        sh_me_uv="$SANDHOME_EXEC/bin/uv"
    elif [ -n "${SH_HOME:-}" ]; then
        for sh_me_try in "$SH_HOME"/toolchains/python/*/bin/uv "$SH_HOME"/toolchains/python/bin/uv; do
            # shellcheck disable=SC2086
            for sh_me_hit in $sh_me_try; do
                [ -x "$sh_me_hit" ] || continue
                sh_me_uv=$sh_me_hit
                break
            done
            [ -n "$sh_me_uv" ] && break
        done
    fi
    [ -n "$sh_me_uv" ] || { sh_warn 'meson needs uv (install the python toolchain first)'; return 1; }
    rm -rf "$sh_me_root" 2>/dev/null
    mkdir -p "$sh_me_root/bin" 2>/dev/null || return 1
    # --force replaces an environment this toolchain owns, so a reinstall is
    # deterministic rather than "already installed" into someone else's dir.
    sh_me_out=$("$sh_me_uv" tool install --force meson 2>&1)
    case "$sh_me_out" in
        *meson*) : ;;
        *) sh_warn "uv could not install meson: $(printf '%s' "$sh_me_out" | sh_first_line)"; return 1 ;;
    esac
    # uv links the console script where UV_TOOL_BIN_DIR points. Copy it into the
    # toolchain's own bin so this module owns a file, exactly as the other
    # modules do, and so repair can rebuild the view from the payload. Three
    # locations are tried because the launcher may live under a hashed env dir
    # while only the stable link is on PATH.
    sh_me_src=''
    if [ -n "${UV_TOOL_BIN_DIR:-}" ] && [ -e "$UV_TOOL_BIN_DIR/meson" ]; then
        sh_me_src=$UV_TOOL_BIN_DIR/meson
    elif [ -n "${SANDHOME_EXEC:-}" ] && [ -e "$SANDHOME_EXEC/uv-bin/meson" ]; then
        sh_me_src="$SANDHOME_EXEC/uv-bin/meson"
    elif sh_have meson; then
        sh_me_src=$(sh_path_where meson)
    fi
    [ -n "$sh_me_src" ] || { sh_warn 'uv installed meson but no meson launcher was found'; return 1; }
    cp -f "$sh_me_src" "$sh_me_root/bin/meson" 2>/dev/null || return 1
    chmod 0755 "$sh_me_root/bin/meson" 2>/dev/null || true
    if [ ! -x "$sh_me_root/bin/meson" ]; then
        sh_warn "meson did not land at $sh_me_root/bin/meson"
        return 1
    fi
    return 0
}

tc_meson_env() {
    # Nothing beyond PATH: BINS put the exec-view launcher on it, and meson
    # finds its own environment through the launcher it was built with.
    return 0
}

tc_meson_version() {
    sh_have meson && sh_first_line meson --version 2>/dev/null
}

# tc_meson_adopted -> the directory a working meson was found in when this
# toolchain is ADOPTED rather than installed. sh_path_where, not command -v,
# for the same reason as everywhere else (issue #43).
tc_meson_adopted() {
    sh_me_which=$(sh_path_where meson)
    [ -n "$sh_me_which" ] || return 0
    printf '%s' "${sh_me_which%/*}"
}
