#!/bin/sh
# rust - the Rust toolchain through rustup, into the sandhome root.
TC_rust_DESC='Rust via rustup (rustc, cargo, rustup; minimal profile)'
TC_rust_BINS='cargo/bin/rustup cargo/bin/cargo'

tc_rust_probe() {
    sh_have rustc && rustc --version >/dev/null 2>&1
}

# tc_rust_behavioural -> 0 when a trivial native binary links and runs.
# This is the probe that catches the noexec sysroot: `rustc --version`
# runs from the view while `collect2` spawns `ld.lld` from the noexec home.
tc_rust_behavioural() {
    sh_rb_tmp=${SH_EXEC:-${TMPDIR:-/tmp}}/rust-probe.$$
    mkdir -p "$sh_rb_tmp" 2>/dev/null || return 1
    printf 'fn main(){println!("ok");}\n' > "$sh_rb_tmp/hello.rs" 2>/dev/null || {
        rm -rf "$sh_rb_tmp" 2>/dev/null
        return 1
    }
    if rustc "$sh_rb_tmp/hello.rs" -o "$sh_rb_tmp/hello" >/dev/null 2>&1; then
        if "$sh_rb_tmp/hello" >/dev/null 2>&1; then
            rm -rf "$sh_rb_tmp" 2>/dev/null
            return 0
        fi
    fi
    rm -rf "$sh_rb_tmp" 2>/dev/null
    return 1
}

tc_rust_install() {
    : "${SH_RUST_TARGETS:=${SANDHOME_RUST_TARGETS:-}}"
    sh_ri_root=$(sh_toolchain_root rust)
    sh_ri_rustup="$sh_ri_root/rustup"
    sh_ri_cargo="$sh_ri_root/cargo"

    # # NOTE: AN EXISTING WORKING RUSTUP IS THE FASTEST INSTALL. If the machine already
    # has rustup, it is asked to place the toolchain under this root rather than a
    # second copy of the installer being fetched.
    if sh_have rustup; then
        if RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
           rustup toolchain install stable --profile minimal \
           -c rustfmt -c clippy --no-self-update >/dev/null 2>&1; then
            sh_step 'installed the stable toolchain with the rustup already here'
            # Extra targets requested via SANDHOME_RUST_TARGETS or --target.
            if [ -n "${SH_RUST_TARGETS:-}" ]; then
                for sh_ri_t in $(sh_split_on ',' "$SH_RUST_TARGETS"); do
                    [ -n "$sh_ri_t" ] || continue
                    RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
                        rustup target add --toolchain stable "$sh_ri_t" >/dev/null 2>&1 || \
                        sh_warn "rustup could not add target $sh_ri_t"
                done
            fi
            return 0
        fi
        sh_warn 'the rustup on PATH could not install into the sandhome root; falling back to rustup-init'
    fi

    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)
            if [ "${SH_LIBC:-unknown}" = musl ]; then
                sh_ri_triple='x86_64-unknown-linux-musl'
            else
                sh_ri_triple='x86_64-unknown-linux-gnu'
            fi ;;
        Linux:aarch64|Linux:arm64)
            if [ "${SH_LIBC:-unknown}" = musl ]; then
                sh_ri_triple='aarch64-unknown-linux-musl'
            else
                sh_ri_triple='aarch64-unknown-linux-gnu'
            fi ;;
        Linux:i386|Linux:i686) sh_ri_triple='i686-unknown-linux-gnu' ;;
        Darwin:x86_64)         sh_ri_triple='x86_64-apple-darwin' ;;
        Darwin:arm64)          sh_ri_triple='aarch64-apple-darwin' ;;
        *) sh_warn "no rustup-init for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_space_need 900 home || return 1
    sh_space_need 400 exec || {
        sh_warn "no exec root with 400MB free for the rust view; set SANDHOME_EXEC to a roomy root"
        return 1
    }
    mkdir -p "$sh_ri_rustup" "$sh_ri_cargo" 2>/dev/null || return 1
    sh_ri_url="https://static.rust-lang.org/rustup/dist/${sh_ri_triple}/rustup-init"
    sh_ri_init="$SH_HOME_TMP/rustup-init.$$"
    if ! sh_fetch_verified "$sh_ri_url" "$sh_ri_init" "$(sh_pin_for "$sh_ri_url" rust)"; then
        return 1
    fi
    chmod 0755 "$sh_ri_init" 2>/dev/null || true
    if ! RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
         "$sh_ri_init" -y --no-modify-path --profile minimal \
         --default-toolchain stable -c rustfmt -c clippy >/dev/null 2>&1; then
        sh_warn 'rustup-init could not install the toolchain'
        rm -f "$sh_ri_init" 2>/dev/null
        return 1
    fi
    rm -f "$sh_ri_init" 2>/dev/null
    if [ -n "${SH_RUST_TARGETS:-}" ]; then
        for sh_ri_t in $(sh_split_on ',' "$SH_RUST_TARGETS"); do
            [ -n "$sh_ri_t" ] || continue
            RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
                "$sh_ri_cargo/bin/rustup" target add --toolchain stable "$sh_ri_t" >/dev/null 2>&1 || \
                sh_warn "rustup could not add target $sh_ri_t"
        done
    fi
    return 0
}

# STOP: THE TOOLCHAIN BIN DIRECTORY IS ON PATH DIRECTLY, NOT BY BASENAME. rustc
# resolves its sysroot from the directory it is run from: a copy of the binary at
# the exec view's root, without the mirrored `lib/` beside it, reports the wrong
# sysroot and cannot find its own standard library. The mirrored tree keeps the
# executable at the same depth, so the sysroot resolves.
tc_rust_env() {
    : "${SH_RUST_TARGETS:=${SANDHOME_RUST_TARGETS:-}}"
    sh_re_root=$(sh_toolchain_root rust)
    sh_re_rustup="$sh_re_root/rustup"
    sh_re_cargo="$sh_re_root/cargo"
    # Adopted system rustc: still write a fragment when the home is split, so
    # the linker workaround and rustup exposure apply. The toolchain bin that
    # answered the probe keeps winning on PATH; this only adds what was missing.
    sh_re_installed=no
    if [ -d "$sh_re_rustup/toolchains" ] || [ -d "$sh_re_cargo/bin" ]; then
        sh_re_installed=yes
    fi
    if [ "$sh_re_installed" = no ] && tc_rust_probe; then
        # Pure adoption: no sandhome tree. Expose rustup/cargo when they exist
        # beside the answering rustc, and set the split-root linker flag.
        sh_re_which=$(command -v rustc 2>/dev/null)
        sh_re_dir=${sh_re_which%/*}
        sh_env_write_fragment rust <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
case ":\$PATH:" in
  *":$sh_re_dir:"*) ;;
  *) PATH="$sh_re_dir:\$PATH" ;;
esac
export PATH
EOF
        if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
            cat >> "$(sh_env_fragment rust)" <<EOF
# Split root: the sysroot linker lives on a noexec mount, so force the
# system bfd linker which runs from the exec-capable root.
RUSTFLAGS="\${RUSTFLAGS:-} -C link-arg=-fuse-ld=bfd"
export RUSTFLAGS
EOF
        fi
        if ! tc_rust_behavioural >/dev/null 2>&1; then
            sh_warn "rustc answers --version but cannot link on this split root ($SH_HOME noexec); RUSTFLAGS forces bfd, retry the build"
        fi
        return 0
    fi
    sh_promote_toolchain rust cargo/bin/rustup cargo/bin/cargo >/dev/null 2>&1
    sh_re_view=$(sh_toolchain_view rust)
    sh_re_bin=''
    for sh_re_d in "$sh_re_view"/rustup/toolchains/*/bin "$sh_re_root"/rustup/toolchains/*/bin; do
        if [ -x "$sh_re_d/rustc" ]; then
            sh_re_bin=$sh_re_d
            break
        fi
    done
    if [ -z "$sh_re_bin" ]; then
        sh_warn 'no rustc was found under the rustup root after install'
        return 1
    fi
    # Promote the bundled linker out of the noexec sysroot when split, so the
    # view copy runs. Failures fall back to the bfd flag below.
    if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
        for sh_re_ld in "$sh_re_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/ld.lld; do
            [ -x "$sh_re_ld" ] || continue
            sh_re_ld_dir=${sh_re_ld%/*}
            sh_re_ld_rel=${sh_re_ld#"$sh_re_root"/}
            mkdir -p "$sh_re_view/${sh_re_ld_rel%/*}" 2>/dev/null || true
            cp -f "$sh_re_ld" "$sh_re_view/$sh_re_ld_rel" 2>/dev/null || true
            chmod 0755 "$sh_re_view/$sh_re_ld_rel" 2>/dev/null || true
        done
    fi
    sh_env_write_fragment rust <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
RUSTUP_HOME="$sh_re_root/rustup"
CARGO_HOME="$sh_re_root/cargo"
CARGO_INSTALL_ROOT="\$SANDHOME_EXEC/cargo-install"
export RUSTUP_HOME CARGO_HOME CARGO_INSTALL_ROOT
case ":\$PATH:" in
  *":$sh_re_bin:"*) ;;
  *) PATH="$sh_re_bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/cargo-install/bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/cargo-install/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_re_root/cargo/bin:"*) ;;
  *) PATH="$sh_re_root/cargo/bin:\$PATH" ;;
esac
export PATH
EOF
    if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
        cat >> "$(sh_env_fragment rust)" <<EOF
# Split root (issue #19): rustc resolves its sysroot to the noexec home and
# passes -B<sysroot>/.../gcc-ld, so collect2 spawns ld.lld from a path that
# refuses execve. Force the system bfd linker until a zig-cc wrapper is set
# (see tools/zig.sh and CARGO_TARGET_*_LINKER below).
RUSTFLAGS="\${RUSTFLAGS:-} -C link-arg=-fuse-ld=bfd"
export RUSTFLAGS
EOF
    fi
    # Zig cross wrappers, one per requested target, placed on the exec view.
    if sh_have zig 2>/dev/null || [ -x "$SH_EXEC_BIN/zig" ]; then
        for sh_re_t in $(sh_split_on ',' "${SH_RUST_TARGETS:-}"); do
            [ -n "$sh_re_t" ] || continue
            sh_re_wrap="$SH_EXEC_BIN/rust-link-$sh_re_t"
            cat > "$sh_re_wrap" 2>/dev/null <<WRAP
#!/bin/sh
exec zig cc -target $sh_re_t "\$@"
WRAP
            chmod 0755 "$sh_re_wrap" 2>/dev/null || true
            sh_re_upper=$(sh_upper "$sh_re_t")
            # CARGO_TARGET_<TRIPLE>_LINKER with - and . as _
            sh_re_var=$(printf '%s' "$sh_re_upper" | {
                sh_re_o=''
                sh_re_r=$sh_re_upper
                while [ -n "$sh_re_r" ]; do
                    sh_re_c=${sh_re_r%"${sh_re_r#?}"}
                    sh_re_r=${sh_re_r#?}
                    case "$sh_re_c" in
                        -|.) sh_re_o="${sh_re_o}_" ;;
                        *) sh_re_o="${sh_re_o}$sh_re_c" ;;
                    esac
                done
                printf '%s' "$sh_re_o"
            })
            cat >> "$(sh_env_fragment rust)" <<EOF
CARGO_TARGET_${sh_re_var}_LINKER="$sh_re_wrap"
export CARGO_TARGET_${sh_re_var}_LINKER
EOF
        done
    fi
    if ! tc_rust_behavioural >/dev/null 2>&1; then
        sh_warn "rustc installed without an error and still does not link from the exec view (home $SH_HOME is noexec); see RUSTFLAGS in $(sh_env_fragment rust)"
    fi
    return 0
}

tc_rust_version() {
    sh_have rustc && sh_first_line rustc --version 2>/dev/null
}

# tc_rust_adopted -> directory of the answering rustc when adopted.
tc_rust_adopted() {
    sh_ra_which=$(command -v rustc 2>/dev/null)
    [ -n "$sh_ra_which" ] || return 0
    sh_ra_dir=${sh_ra_which%/*}
    [ -n "$sh_ra_dir" ] || sh_ra_dir=.
    ( CDPATH='' cd -- "$sh_ra_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_ra_dir"
}
