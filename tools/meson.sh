#!/bin/sh
# Meson, the build system for C/C++/Rust/Vala projects, installed through the
# python toolchain's uv. Meson is pure Python, so its payload does not need the
# exec root at all and does not need a venv: `uv pip install --target` unpacks
# the package onto the PERSISTENT HOME and a small launcher runs it with the
# exec-view python. REQUIRES python so the closure installs uv first (issue
# #123).
#
# STOP: THE PAYLOAD LIVES ON THE HOME, NOT UNDER `uv tool install` (issue
# #172). The first shape here was `uv tool install`, which puts the venv under
# UV_TOOL_DIR - and env.d/python.sh points UV_TOOL_DIR and UV_TOOL_BIN_DIR at
# $SANDHOME_EXEC because they have to be executable on a noexec home. That is
# right for the interpreter and wrong for the PACKAGE: the exec root is the
# root a tmpfs restart clears. So after a restart `sandhome resume` rebuilt the
# views, downloaded nothing, and left a name on PATH that could not run:
#   $ sandhome exec meson --version
#   .../exec/bin/meson: cannot execute .../toolchains/meson/bin/meson from
#   memory: No such file or directory
# while `sandhome toolchains` said `meson absent` and doctor ended with
# doctor_failures=0, because doctor only gates the RECORDED wanted list and
# meson was not in it. A broken name reachable from every shell, behind a green
# gate. Splitting the two roles is the fix: the interpreter is exec'd, so it
# lives on the exec root; the package is only ever READ by that interpreter, so
# it lives on the home and survives the restart.
#
# This is the general rule the whole tree already follows in sh_is_exec_file:
# `mmap(PROT_EXEC)` from a noexec mount is allowed even where `execve` is not,
# so data does not need the exec root. A Python package is data to a process
# that has already been exec'd, and putting it on the exec root bought nothing.
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
        sh_step "would unpack meson with uv onto the home at $sh_me_root"
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
    sh_me_lib=$sh_me_root/lib
    mkdir -p "$sh_me_root/bin" "$sh_me_lib" 2>/dev/null || return 1
    # --target, not `tool install`: the package lands on the persistent home and
    # NO venv is created on the exec root, so a tmpfs restart cannot strand it
    # (issue #172). --upgrade makes a reinstall deterministic rather than
    # "already satisfied" against a directory this toolchain owns.
    #
    # The success test is the DIRECTORY, not uv's wording. The previous shape
    # matched its output against the substring `meson`, which passes on a
    # warning that mentions meson and fails on a success message that does not,
    # so it tested the wrong thing twice over. `[ -d lib/mesonbuild ]` is what
    # actually has to be true for the launcher to import anything.
    sh_me_out=$("$sh_me_uv" pip install --target "$sh_me_lib" --upgrade meson 2>&1)
    if [ ! -d "$sh_me_lib/mesonbuild" ]; then
        sh_warn "uv could not install meson: $(printf '%s' "$sh_me_out" | sh_first_line)"
        return 1
    fi
    # The launcher runs the exec-view python with the home lib on sys.path.
    #
    # IT DOES NOT READ $0, which is what makes it safe as a launcher copy: the
    # launch-mode view runs a script from a memfd, where $0 is /proc/self/fd/N
    # (issue #169's emcc failure). A launcher that names its own directory
    # cannot survive that, and this one names an ABSOLUTE path it was given at
    # install time instead. It also survives a restart, because the directory it
    # names is the one that persisted.
    #
    # The path goes through sh_sq_quote rather than into a printf format string,
    # so a home whose path carries a quote, a space or a `%` still produces a
    # runnable script instead of a broken one or a mangled assignment.
    sh_me_launcher=$sh_me_root/bin/meson
    sh_me_lib_q=$(sh_sq_quote "$sh_me_lib")
    {
        printf '#!/bin/sh\n'
        printf '# written by sandhome: run meson from the exec-view python.\n'
        printf 'SANDHOME_MESON_LIB=%s\n' "$sh_me_lib_q"
        printf 'export SANDHOME_MESON_LIB\n'
        printf 'exec python3 -c %s "$@"\n' "$(sh_sq_quote 'import os, sys
sys.path.insert(0, os.environ["SANDHOME_MESON_LIB"])
from mesonbuild.mesonmain import main
sys.exit(main())')"
    } > "$sh_me_launcher" 2>/dev/null || return 1
    chmod 0755 "$sh_me_launcher" 2>/dev/null || true
    if [ ! -x "$sh_me_launcher" ]; then
        sh_warn "meson did not land at $sh_me_launcher"
        return 1
    fi
    # The launcher is proven HERE rather than left to the caller's probe: a
    # launcher whose python cannot import the package it names is the same
    # broken-name-on-PATH state issue #172 is about, and finding it at install
    # time is the difference between a warning and a mystery in a build log.
    # STOP: THE LAUNCHER IS TESTED THROUGH `sh`, NOT BY EXEC'ING ITS HOME
    # PATH (issue #177). The home refuses execve on a split root, so
    # `"$sh_me_launcher" --version` failed with Permission denied and every
    # first `sandhome install meson` reported "unpacked but does not answer"
    # and needed the documented `repair` second command. `sh file` reads the
    # script and runs it, which is the contract's rule (never test a binary by
    # its home path) and the same test from a mount that runs the file.
    if ! sh "$sh_me_launcher" --version >/dev/null 2>&1; then
        sh_warn "meson was unpacked but $sh_me_launcher does not answer --version; re-run 'sandhome repair meson' after the python toolchain is present"
        return 1
    fi
    return 0
}

tc_meson_env() {
    # Nothing beyond PATH: BINS put the exec-view entry on it, and the launcher
    # carries the absolute lib path it was installed with, so there is no
    # UV_TOOL_DIR to find after a restart and nothing for the environment to
    # keep in sync (issue #172).
    return 0
}

tc_meson_version() {
    sh_have meson && sh_first_line meson --version 2>/dev/null
}

# tc_meson_adopted -> the directory a working meson was found in when this
# toolchain is ADOPTED rather than installed. sh_path_where, not command -v,
# for the same reason as everywhere else (issue #43).
#
# AN ADOPTED MESON IS NOT COPIED INTO THE HOME AND IS NOT RELOCATED. The
# launcher this module writes is only produced by tc_meson_install; an adopted
# meson is whatever was already answering, and it keeps working because it keeps
# being that. Treating the directory as a home root and mirroring it would move
# a venv that uv built with absolute paths inside it and break it.
tc_meson_adopted() {
    sh_me_which=$(sh_path_where meson)
    [ -n "$sh_me_which" ] || return 0
    printf '%s' "${sh_me_which%/*}"
}
