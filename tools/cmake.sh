#!/bin/sh
# CMake, the build system for C/C++/Fortran projects, from the official
# Kitware release tarball. The Linux asset is a relocatable tree whose top
# directory holds bin/, share/ and the modules CMake needs at configure time,
# so the toolchain root is that whole tree and the binaries are named inside
# it (issue #123: a real project's `cmake -S . -B build` failed with
# `command not found` because the catalog had no cmake).
TC_cmake_DESC='CMake, the build system for C/C++/Fortran projects'
TC_cmake_BINS='bin/cmake bin/ctest bin/cpack'
TC_cmake_EXEC_MB=64

# tc_cmake_exec_mb -> the fresh-install exec need in MB. The tree is ~60MB and
# runs from a launcher in launch mode, so the view costs kilobytes; the figure
# below is the copy-mode price. Read by the install gate and the feasibility
# plan so the two never disagree.
tc_cmake_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '16'
    else
        printf '64'
    fi
}

tc_cmake_probe() {
    sh_have cmake && cmake --version >/dev/null 2>&1
}

tc_cmake_install() {
    sh_cm_root=$(sh_toolchain_root cmake)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)  sh_cm_plat='linux-x86_64' ;;
        Linux:aarch64|Linux:arm64) sh_cm_plat='linux-aarch64' ;;
        Darwin:x86_64)             sh_cm_plat='macos-universal' ;;
        Darwin:arm64)              sh_cm_plat='macos-universal' ;;
        *) sh_warn "no cmake build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    # The tag is resolved, not typed: a literal version in the asset name is
    # the shape that rots (issue #105). The GitHub latest redirect answers the
    # current tag, and only the fetched bytes need a pin, not the name. macOS
    # assets carry no version in the filename, so they use a fixed name and
    # the tag only for the URL prefix.
    sh_cm_tag=${SANDHOME_CMAKE_VERSION:-$(sh_github_latest_tag Kitware/CMake)}
    case "$sh_cm_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current cmake release'; return 1 ;;
    esac
    sh_cm_ver=${sh_cm_tag#v}
    case "$sh_cm_plat" in
        macos-*) sh_cm_asset="cmake-$sh_cm_ver-$sh_cm_plat.tar.gz" ;;
        *)       sh_cm_asset="cmake-$sh_cm_ver-$sh_cm_plat.tar.gz" ;;
    esac
    sh_cm_dirname="cmake-$sh_cm_ver-$sh_cm_plat"
    sh_space_need 64 home || return 1
    sh_cm_url="https://github.com/Kitware/CMake/releases/download/$sh_cm_tag/$sh_cm_asset"
    sh_cm_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_cm_stage" 2>/dev/null || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_cm_url into $sh_cm_root"
        return 0
    fi
    rm -rf "$sh_cm_root" 2>/dev/null
    mkdir -p "$sh_cm_root" "$sh_cm_stage" 2>/dev/null || return 1
    if sh_fetch_verified "$sh_cm_url" "$sh_cm_stage/.cmake.$$.tar.gz" "$(sh_pin_for "$sh_cm_url" cmake)"; then
        sh_cm_have_tarball=yes
    else
        sh_cm_have_tarball=no
        sh_warn "the Kitware tarball did not fetch; trying pip as a fallback"
    fi
    if [ "$sh_cm_have_tarball" = yes ]; then
    # Every spelling goes through sh_tar, which drops archive ownership first:
    # a uid-0 sandbox without CAP_CHOWN refuses tar's chown and exits 2.
    if sh_tar -xzf "$sh_cm_stage/.cmake.$$.tar.gz" -C "$sh_cm_stage" 2>/dev/null; then
        :
    elif sh_have gzip && gzip -dc "$sh_cm_stage/.cmake.$$.tar.gz" 2>/dev/null | sh_tar -xf - -C "$sh_cm_stage" 2>/dev/null; then
        :
    else
        sh_warn 'could not unpack the cmake archive (no working tar+gzip path here)'
        rm -f "$sh_cm_stage/.cmake.$$.tar.gz" 2>/dev/null
        return 1
    fi
    rm -f "$sh_cm_stage/.cmake.$$.tar.gz" 2>/dev/null
    sh_cm_bin=''
    # Unquoted directory part: a quoted glob runs once and matches nothing;
    # the directory name is machine-generated above, never user input.
    # shellcheck disable=SC2086
    for sh_cm_e in "$sh_cm_stage"/$sh_cm_dirname/bin/cmake; do
        [ -f "$sh_cm_e" ] || continue
        sh_cm_bin=$sh_cm_e
        break
    done
    [ -n "$sh_cm_bin" ] || { sh_warn 'the cmake archive did not contain bin/cmake'; return 1; }
    # Move the whole relocatable tree into the toolchain root: CMake finds its
    # own share/cmake-*/Modules relative to the binary, so taking bin/ alone
    # would configure nothing.
    if ! mv "$sh_cm_stage/$sh_cm_dirname"/* "$sh_cm_root/" 2>/dev/null; then
        sh_warn 'could not move the cmake tree into its toolchain root'
        return 1
    fi
    rm -rf "$sh_cm_stage/$sh_cm_dirname" 2>/dev/null
    chmod 0755 "$sh_cm_root/bin/cmake" 2>/dev/null || true
    if [ ! -x "$sh_cm_root/bin/cmake" ]; then
        sh_warn "the cmake archive did not put cmake at $sh_cm_root/bin/cmake"
        return 1
    fi
    return 0
    fi
    # FALLBACK: A PIP WHEEL WHEN THE TARBALL WILL NOT FETCH. The Kitware asset
    # is 60MB and the fastest path, but a blocked github.com origin or a
    # missing tar+gzip leaves the setup with nothing. The cmake PyPI wheel
    # ships the same binaries and installs through the python toolchain the
    # setup already owns, onto the exec root so the launcher runs. Three uv
    # locations are tried because a hand-run `install cmake` may reach here
    # with no PATH and no UV_TOOL_BIN_DIR yet.
    sh_cm_uv=''
    if sh_have uv; then
        sh_cm_uv=uv
    elif [ -n "${UV_TOOL_BIN_DIR:-}" ] && [ -x "$UV_TOOL_BIN_DIR/uv" ]; then
        sh_cm_uv="$UV_TOOL_BIN_DIR/uv"
    elif [ -n "${SANDHOME_EXEC:-}" ] && [ -x "$SANDHOME_EXEC/views/python/bin/uv" ]; then
        sh_cm_uv="$SANDHOME_EXEC/views/python/bin/uv"
    fi
    if [ -z "$sh_cm_uv" ]; then
        sh_warn 'neither the Kitware tarball nor a pip fallback is reachable (no uv for the pip leg)'
        return 1
    fi
    mkdir -p "$sh_cm_root/bin" 2>/dev/null || return 1
    sh_cm_out=$("$sh_cm_uv" tool install --force cmake 2>&1)
    case "$sh_cm_out" in
        *cmake*) : ;;
        *) sh_warn "uv could not install cmake: $(printf '%s' "$sh_cm_out" | sh_first_line)"; return 1 ;;
    esac
    sh_cm_src=''
    if [ -n "${UV_TOOL_BIN_DIR:-}" ] && [ -e "$UV_TOOL_BIN_DIR/cmake" ]; then
        sh_cm_src=$UV_TOOL_BIN_DIR/cmake
    elif sh_have cmake; then
        sh_cm_src=$(sh_path_where cmake)
    fi
    [ -n "$sh_cm_src" ] || { sh_warn 'uv installed cmake but no cmake launcher was found'; return 1; }
    cp -f "$sh_cm_src" "$sh_cm_root/bin/cmake" 2>/dev/null || return 1
    chmod 0755 "$sh_cm_root/bin/cmake" 2>/dev/null || true
    # ctest and cpack ride with the wheel when it carries them; missing ones
    # are not fatal because the probe only needs cmake itself.
    for sh_cm_extra in ctest cpack; do
        if [ -n "${UV_TOOL_BIN_DIR:-}" ] && [ -e "$UV_TOOL_BIN_DIR/$sh_cm_extra" ]; then
            cp -f "$UV_TOOL_BIN_DIR/$sh_cm_extra" "$sh_cm_root/bin/$sh_cm_extra" 2>/dev/null || true
        fi
    done
    [ -x "$sh_cm_root/bin/cmake" ] || { sh_warn 'the pip fallback did not land cmake'; return 1; }
    return 0
}

tc_cmake_env() {
    # Nothing beyond PATH: BINS put the exec-view binaries on it.
    return 0
}

tc_cmake_version() {
    sh_have cmake && sh_first_line cmake --version 2>/dev/null
}

# tc_cmake_adopted -> the directory the working copy was found in when this
# toolchain is ADOPTED rather than installed. sh_path_where, not command -v:
# the exec view is on PATH by the time an install runs, so command -v answers
# with the view this tool is being linked INTO (issue #43).
# REDUNDANCY: VERSION-AGNOSTIC, BECAUSE A LITERAL ROTS. The first version tested
# for share/cmake-4.4, so the next Kitware minor made every adopt fail and the
# setup downloaded a 60MB tarball beside a working system cmake. Any share/cmake-*
# directory proves the tree is a full CMake install and not a lone binary.
tc_cmake_adopted() {
    sh_cm_which=$(sh_path_where cmake)
    [ -n "$sh_cm_which" ] || return 0
    sh_cm_dir=${sh_cm_which%/*}
    sh_cm_found=no
    for sh_cm_try in "$sh_cm_dir"/../share/cmake-* "$sh_cm_dir"/../share/cmake "$sh_cm_dir"/../share; do
        # The glob must expand: a quoted glob runs once and matches nothing.
        # shellcheck disable=SC2086
        for sh_cm_hit in $sh_cm_try; do
            [ -d "$sh_cm_hit" ] || [ -e "$sh_cm_hit" ] || continue
            sh_cm_found=yes
            break
        done
        [ "$sh_cm_found" = yes ] && break
    done
    [ "$sh_cm_found" = yes ] || return 0
    printf '%s' "${sh_cm_dir%/*}"
}
