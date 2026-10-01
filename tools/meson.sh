#!/bin/sh
# Meson, the build system for C/C++/Rust/Vala projects, installed through the
# python toolchain's uv. Meson is pure Python, so its payload does NOT need the
# exec root: `uv pip install --target` puts the package under the toolchain root
# on the persistent home, and a tiny launcher runs it with the exec-view python.
# REQUIRES python so the closure installs uv first (issue #123).
#
# STOP: THE PAYLOAD LIVES ON THE HOME, NOT UNDER `uv tool install`. The first
# cut used `uv tool install`, which puts the venv under UV_TOOL_DIR on the exec
# root and keeps only the console shim on the home. A tmpfs restart clears the
# exec root, so after `sandhome resume` the kept meson shim died with
#   cannot execute .../toolchains/meson/bin/meson from memory: No such file or directory
# and `doctor` stayed green when meson was not in the recorded request, leaving
# a broken name on PATH (issue #172). A pure-Python package unpacked onto the
# home survives the restart, because only the interpreter must exec and that is
# the exec-view python the tree already mirrors.
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
    sh_me_lib="$sh_me_root/lib"
    mkdir -p "$sh_me_root/bin" "$sh_me_lib" 2>/dev/null || return 1
    # --target, not `tool install`: the package lands on the persistent home
    # and no venv is created on the exec root, so a restart cannot strand it
    # (issue #172). --upgrade makes a reinstall deterministic.
    sh_me_out=$("$sh_me_uv" pip install --target "$sh_me_lib" --upgrade meson 2>&1)
    if [ ! -d "$sh_me_lib/mesonbuild" ]; then
        sh_warn "uv could not install meson: $(printf '%s' "$sh_me_out" | sh_first_line)"
        return 1
    fi
    # The launcher runs the exec-view python with the home lib on sys.path. It
    # does not read $0 (the launch-mode view runs it from a memfd), so it is
    # safe as a launcher copy, and it survives a restart with the payload it
    # names. The path is single-quoted by sh_sq_quote so a home with a quote or
    # a space still produces a runnable script.
    sh_me_launcher="$sh_me_root/bin/meson"
    # The launcher runs the exec-view python with the home lib on sys.path. It
    # does not read $0 (the launch-mode view runs it from a memfd), so it is
    # safe as a launcher copy, and it survives a restart with the payload it
    # names. The lib directory is SINGLE-QUOTED through a shell variable, so the
    # printf that writes the assignment is not itself a format string, and the
    # line is a plain `SANDHOME_MESON_LIB=<default>` the reference generator can
    # read (docs/reference.md is GENERATED; a bare literal default of $ERB
    # there is the docs test's business, not this file's).
    sh_me_lib_q=$(sh_sq_quote "$sh_me_lib")
    {
        printf '#!/bin/sh\n'
        printf '# written by sandhome: run meson from the exec-view python.\n'
        printf 'SANDHOME_MESON_LIB=%s\n' "$sh_me_lib_q"
        printf 'export SANDHOME_MESON_LIB\n'
        printf 'exec python3 -c %s "$@"\n' "$(sh_sq_quote 'import os, sys; sys.path.insert(0, os.environ["SANDHOME_MESON_LIB"]); from mesonbuild.mesonmain import main; sys.exit(main())')"
    } > "$sh_me_launcher" 2>/dev/null || return 1
    chmod 0755 "$sh_me_launcher" 2>/dev/null || true
    if [ ! -x "$sh_me_launcher" ]; then
        sh_warn "meson did not land at $sh_me_launcher"
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
