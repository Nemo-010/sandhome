#!/bin/sh
# zig - zig cc as a portable cross linker, from the official tarball.
TC_zig_DESC='zig cc cross compiler (also links native rust when the sysroot is noexec)'
TC_zig_BINS='zig'

tc_zig_latest() {
    sh_zl_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_zl_stage" 2>/dev/null || { printf ''; return 0; }
    sh_zl_file="$sh_zl_stage/.zig-index.$$"
    if ! sh_fetch "${SANDHOME_ZIG_INDEX_URL:-https://ziglang.org/download/index.json}" "$sh_zl_file"; then
        printf ''
        return 0
    fi
    sh_zl_ver=''
    while IFS= read -r sh_zl_line || [ -n "$sh_zl_line" ]; do
        case "$sh_zl_line" in
            *version*)
                sh_zl_rest=${sh_zl_line#*version}
                sh_zl_rest=${sh_zl_rest#*:}
                sh_zl_rest=${sh_zl_rest#*\"}
                sh_zl_tmp=${sh_zl_rest%%\"*}
                case "$sh_zl_tmp" in
                    [0-9]*.[0-9]*.[0-9]*) sh_zl_ver=$sh_zl_tmp; break ;;
                esac
                ;;
        esac
    done < "$sh_zl_file"
    rm -f "$sh_zl_file" 2>/dev/null
    printf '%s' "$sh_zl_ver"
}

tc_zig_probe() {
    sh_have zig && zig version >/dev/null 2>&1
}

tc_zig_install() {
    sh_zi_root=$(sh_toolchain_root zig)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_zi_os=linux  sh_zi_arch=x86_64 ;;
        Linux:aarch64|Linux:arm64)  sh_zi_os=linux  sh_zi_arch=aarch64 ;;
        Darwin:x86_64)              sh_zi_os=macos  sh_zi_arch=x86_64 ;;
        Darwin:arm64)               sh_zi_os=macos  sh_zi_arch=aarch64 ;;
        *) sh_warn "no zig tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_zi_ver=${SANDHOME_ZIG_VERSION:-$(tc_zig_latest)}
    case "$sh_zi_ver" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) sh_warn 'could not resolve the current zig release'; return 1 ;;
    esac
    sh_zi_name="zig-${sh_zi_os}-${sh_zi_arch}-${sh_zi_ver}"
    sh_zi_url="https://ziglang.org/download/${sh_zi_ver}/${sh_zi_name}.tar.xz"
    sh_zi_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_zi_stage" 2>/dev/null || return 1
    # The zig binary alone is about 172MB; the extracted tree is larger.
    # Size-gate both roots before writing anything (class C).
    sh_space_need 400 home || return 1
    sh_space_need 200 exec || {
        sh_warn "no exec root with 200MB free for zig; set SANDHOME_EXEC to a roomy root (--exec DIR)"
        return 1
    }
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_zi_url into $sh_zi_root"
        return 0
    fi
    rm -rf "$sh_zi_root" 2>/dev/null
    mkdir -p "$sh_zi_root" 2>/dev/null || return 1
    sh_zi_tar="$sh_zi_stage/${sh_zi_name}.tar.xz"
    if ! sh_fetch_verified "$sh_zi_url" "$sh_zi_tar" "$(sh_pin_for "$sh_zi_url" zig)"; then
        return 1
    fi
    if ! sh_untar "$sh_zi_tar" "$sh_zi_root"; then
        sh_warn "could not unpack $sh_zi_tar"
        rm -f "$sh_zi_tar" 2>/dev/null
        return 1
    fi
    rm -f "$sh_zi_tar" 2>/dev/null
    if [ -d "$sh_zi_root/$sh_zi_name" ]; then
        sh_zi_inner="$sh_zi_root/$sh_zi_name"
        for sh_zi_e in "$sh_zi_inner"/* "$sh_zi_inner"/.[!.]*; do
            [ -e "$sh_zi_e" ] || continue
            mv "$sh_zi_e" "$sh_zi_root/" 2>/dev/null || true
        done
        rmdir "$sh_zi_inner" 2>/dev/null || true
    fi
    if [ ! -x "$sh_zi_root/zig" ]; then
        sh_warn "the zig archive did not put zig at $sh_zi_root/zig"
        return 1
    fi
    return 0
}

tc_zig_env() {
    return 0
}

tc_zig_version() {
    sh_have zig && sh_first_line zig version 2>/dev/null
}
