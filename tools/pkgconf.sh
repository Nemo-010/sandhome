#!/bin/sh
# pkgconf, the pkg-config implementation a ./configure needs. On most bases
# pkg-config or pkgconf already answers; this module adopts that copy so a
# project toolset has a name for it instead of relying on the base image.
# When neither answers it installs the portable pkgconf release tarball, so a
# minimal base that lacks both still configures (issue #123: both were adopted
# with no catalog name, so a base without them failed with no install path).
TC_pkgconf_DESC='pkgconf, the pkg-config implementation for ./configure builds'
TC_pkgconf_BINS='bin/pkgconf bin/pkg-config'
TC_pkgconf_EXEC_MB=8

tc_pkgconf_exec_mb() {
    printf '8'
}

tc_pkgconf_probe() {
    # Either spelling counts: a base that ships pkg-config answers the same
    # queries pkgconf does, and adopting it avoids a from-source build.
    (sh_have pkgconf && pkgconf --version >/dev/null 2>&1) || \
    (sh_have pkg-config && pkg-config --version >/dev/null 2>&1)
}

tc_pkgconf_install() {
    sh_pc_root=$(sh_toolchain_root pkgconf)
    # Adopted first is handled by the framework; reaching here means no working
    # copy answered. Try the portable release before failing loudly.
    sh_pc_tag=${SANDHOME_PKGCONF_VERSION:-$(sh_github_latest_tag pkgconf/pkgconf)}
    case "$sh_pc_tag" in
        v[0-9]*|pkgconf-[0-9]*) ;;
        *) sh_pc_tag='' ;;
    esac
    # Without a resolvable tag there is nothing to fetch: name the gap rather
    # than failing in silence, because ./configure names pkg-config and the
    # caller needs the next command.
    if [ -z "$sh_pc_tag" ]; then
        sh_warn 'no working pkg-config/pkgconf here and the release tag did not resolve; install pkgconf from your base image'
        return 1
    fi
    sh_pc_ver=${sh_pc_tag#v}
    sh_pc_ver=${sh_pc_ver#pkgconf-}
    sh_pc_url="https://github.com/pkgconf/pkgconf/releases/download/$sh_pc_tag/pkgconf-$sh_pc_ver.tar.xz"
    sh_pc_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_pc_stage" 2>/dev/null || return 1
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_pc_url into $sh_pc_root"
        return 0
    fi
    rm -rf "$sh_pc_root" 2>/dev/null
    mkdir -p "$sh_pc_root" 2>/dev/null || return 1
    if ! sh_fetch_verified "$sh_pc_url" "$sh_pc_stage/.pkgconf.$$.tar.xz" "$(sh_pin_for "$sh_pc_url" pkgconf)"; then
        sh_warn 'the pkgconf tarball did not fetch; install pkgconf from your base image'
        return 1
    fi
    if ! sh_tar -xf "$sh_pc_stage/.pkgconf.$$.tar.xz" -C "$sh_pc_stage" 2>/dev/null; then
        sh_warn 'could not unpack the pkgconf archive'
        rm -f "$sh_pc_stage/.pkgconf.$$.tar.xz" 2>/dev/null
        return 1
    fi
    rm -f "$sh_pc_stage/.pkgconf.$$.tar.xz" 2>/dev/null
    sh_pc_src=''
    for sh_pc_try in "$sh_pc_stage"/pkgconf-"$sh_pc_ver"; do
        [ -d "$sh_pc_try" ] || continue
        sh_pc_src=$sh_pc_try
        break
    done
    [ -n "$sh_pc_src" ] || { sh_warn 'the pkgconf archive did not contain its tree'; return 1; }
    # A from-source build needs a compiler; without one adopt is the only path
    # and this leg says so rather than failing mid-configure.
    if ! sh_have cc && ! sh_have gcc && ! sh_have clang; then
        sh_warn 'pkgconf needs a compiler to build and none answers; install pkgconf from your base image'
        return 1
    fi
    sh_pc_cwd=$PWD
    cd "$sh_pc_src" 2>/dev/null || return 1
    if ./configure --prefix="$sh_pc_root" >/dev/null 2>&1 && make >/dev/null 2>&1 && make install >/dev/null 2>&1; then
        cd "$sh_pc_cwd" 2>/dev/null || true
        mkdir -p "$sh_pc_root/bin" 2>/dev/null || true
        # pkg-config is the name ./configure asks for; pkgconf is the binary.
        if [ -x "$sh_pc_root/bin/pkgconf" ] && [ ! -e "$sh_pc_root/bin/pkg-config" ]; then
            ln -sf pkgconf "$sh_pc_root/bin/pkg-config" 2>/dev/null || cp -f "$sh_pc_root/bin/pkgconf" "$sh_pc_root/bin/pkg-config" 2>/dev/null || true
        fi
        return 0
    fi
    cd "$sh_pc_cwd" 2>/dev/null || true
    sh_warn 'the pkgconf build failed; install pkgconf from your base image'
    return 1
}

tc_pkgconf_env() {
    return 0
}

tc_pkgconf_version() {
    if sh_have pkgconf; then
        sh_first_line pkgconf --version 2>/dev/null
    elif sh_have pkg-config; then
        sh_first_line pkg-config --version 2>/dev/null
    fi
}

# tc_pkgconf_adopted -> where the working copy lives. Either spelling counts:
# a base that ships pkg-config answers the same queries a pkgconf does, and
# the probe accepts both so adoption does too.
tc_pkgconf_adopted() {
    sh_pc_which=$(sh_path_where pkgconf)
    [ -n "$sh_pc_which" ] || sh_pc_which=$(sh_path_where pkg-config)
    [ -n "$sh_pc_which" ] || return 0
    printf '%s' "${sh_pc_which%/*}"
}
