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
    if ! sh_fetch_verified "$sh_cm_url" "$sh_cm_stage/.cmake.$$.tar.gz" "$(sh_pin_for "$sh_cm_url" cmake)"; then
        return 1
    fi
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
tc_cmake_adopted() {
    sh_cm_which=$(sh_path_where cmake)
    [ -n "$sh_cm_which" ] || return 0
    sh_cm_dir=${sh_cm_which%/*}
    [ -d "$sh_cm_dir/../share/cmake-4.4" ] || [ -d "$sh_cm_dir/../share" ] || return 0
    printf '%s' "${sh_cm_dir%/*}"
}
