#!/bin/sh
# rust - the Rust toolchain through rustup, split across the two roots.
#
# THE SHAPE. The toolchain data (RUSTUP_HOME, CARGO_HOME) lives on the home,
# where there is room for ~900MB, and only executables are mirrored into the
# exec view. Shared objects stay home: mmap(PROT_EXEC) is allowed where
# execve is not, so librustc_driver and libLLVM load from the home while a
# copied binary in it would not run.
#
# THE VIEW MODE DECIDES WHAT "MIRRORED" COSTS. In launch mode each executable
# is a 20KB launcher copy that runs the home payload from memory, plus a few
# megabytes of real copies for spawn targets, so the view is ~17MB measured.
# In copy mode each executable is a full copy (~100MB). The mode is
# chosen by sh_memexec_ensure before any install; this module only prices its
# own gate off it and writes the wrappers both modes need.
TC_rust_DESC='Rust via rustup (rustc, cargo, rustup; minimal profile)'
TC_rust_BINS='cargo/bin/rustup cargo/bin/cargo'

# tc_rust_exec_mb -> the fresh-install exec need in MB: 25 in launch mode
# (launcher copies plus the few real spawn-target copies), 150 in copy mode
# (full ~100MB executable copies). The install gate below reads this, and so
# does the up-front feasibility plan, so the two never disagree.
tc_rust_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '25'
    else
        printf '150'
    fi
}

# tc_rust_probe -> 0 when a WORKING rustc is already here, which is the whole
# question. It used to be `sh_have rustc && rustc --version`, and that answers
# yes for a copy that cannot build: some sealed sandboxes ship a multi-arch rust
# as a shim that prints a version and refuses everything else. So the adopt path
# was taken, `sandhome install rust` exited 0 having printed "a working copy is
# already here; adopting it", `sandhome report` printed
#   toolchain.rust=rustc 1.99.0 (proxy build 2026-01-01)
# and the first build the consumer attempted died with "proxy rustc: refusing,
# not a compiler" (issue #53). Nothing in the setup said the toolchain was a
# placeholder, and there was no --force to skip the probe (that came with #45).
#
# The decision being made is "can this copy build", so it is answered by
# building. tc_rust_behavioural compiles and runs one trivial binary, which is
# the same measurement the noexec-sysroot repair already used, and it is
# reported when it fails rather than falling through silently, because a
# consumer whose rustc was rejected needs to know which one was thrown away.
#
# The cost is one compile of a four-line program, and it is only paid when a
# rustc is present: with none on PATH there is nothing to probe. A working host
# copy is adopted and no workaround runs at all; SANDHOME_FORCE (or install
# --force) skips the probe and installs under sandhome's own control.
tc_rust_probe() {
    sh_have rustc || return 1
    rustc --version >/dev/null 2>&1 || return 1
    if tc_rust_behavioural >/dev/null 2>&1; then
        return 0
    fi
    sh_warn "the rustc on PATH answers --version but does not compile here, so it is not a working copy; install a real toolchain instead of adopting it"
    return 1
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

# sh_toolchain_ensure_rust_exec -> install a rust toolchain and promote its
# executable view, 0 on success. Called from the adopt path when the borrowed
# rustc cannot link here (issue #52): the only repair that makes a link succeed
# is a toolchain whose sysroot runs what is in it, and a linker flag provably
# does not.
#
# It is deliberately not `tc_rust_install`, because that records the toolchain in
# INSTALLED and the caller is still inside the adopt branch, where the consumer
# was told the host copy was adopted. What is printed is the truth: a usable
# toolchain was added, and where it came from. The promote belongs here and not
# in tc_rust_env: the framework promoted the tree this was ADOPTED from before
# it called here, and the tree just installed replaces that view, so it has to
# be mirrored after the install. On the ordinary install path the framework's
# own promote has already run and a second mirror would only re-hit the size
# gate after its own copy had spent the free space.
sh_toolchain_ensure_rust_exec() {
    sh_ere_saved_installed=$INSTALLED
    sh_ere_saved_targets=${SH_RUST_TARGETS:-}
    SH_RUST_TARGETS=''
    export SH_RUST_TARGETS
    if tc_rust_install; then
        INSTALLED=$sh_ere_saved_installed
        [ -n "$sh_ere_saved_targets" ] && SH_RUST_TARGETS=$sh_ere_saved_targets
        export SH_RUST_TARGETS
        sh_promote_toolchain rust cargo/bin/rustup cargo/bin/cargo
        return 0
    fi
    INSTALLED=$sh_ere_saved_installed
    [ -n "$sh_ere_saved_targets" ] && SH_RUST_TARGETS=$sh_ere_saved_targets
    export SH_RUST_TARGETS
    return 1
}

# sh_toolchain_rust_proxies -> ensure CARGO_HOME/bin holds cargo and rustup.
# `rustup toolchain install --no-self-update` skips the proxy-writing step,
# so a clean shell has cargo only through the exec view and no rustup at all
# (measured: `command -v rustup` empty after install, while TC_rust_BINS
# promises it). cargo links to the toolchain's own real binary (globbed, so
# no triple is spelled); rustup links to the installer that just ran, which
# is what manages this RUSTUP_HOME. Missing targets are skipped, never
# invented: the install still succeeds and the probe still decides.
sh_toolchain_rust_proxies() {
    sh_rr_cargo=$1
    sh_rr_rustup=$2
    sh_rr_host=$3
    mkdir -p "$sh_rr_cargo/bin" 2>/dev/null || return 0
    if [ ! -x "$sh_rr_cargo/bin/cargo" ]; then
        for sh_rr_c in "$sh_rr_rustup"/toolchains/*/bin/cargo; do
            if [ -f "$sh_rr_c" ]; then
                ln -sfn "$sh_rr_c" "$sh_rr_cargo/bin/cargo" 2>/dev/null || \
                    cp -f "$sh_rr_c" "$sh_rr_cargo/bin/cargo" 2>/dev/null || true
                break
            fi
        done
    fi
    if [ ! -x "$sh_rr_cargo/bin/rustup" ] && [ -n "$sh_rr_host" ] && [ -x "$sh_rr_host" ]; then
        ln -sfn "$sh_rr_host" "$sh_rr_cargo/bin/rustup" 2>/dev/null || \
            cp -f "$sh_rr_host" "$sh_rr_cargo/bin/rustup" 2>/dev/null || true
    fi
    return 0
}

tc_rust_install() {
    : "${SH_RUST_TARGETS:=${SANDHOME_RUST_TARGETS:-}}"
    sh_ri_root=$(sh_toolchain_root rust)
    # THE TOOLCHAIN DATA GOES ON THE HOME, AND ONLY ITS EXECUTABLES ARE
    # MIRRORED TO THE EXEC ROOT. The x86_64 minimal stable toolchain is
    # ~600MB, of which ~500MB is librustc_driver.so, libLLVM.so and the
    # rustlib rlibs - none of which needs execve. They are read and
    # mmap(PROT_EXEC) from a noexec mount is allowed, so the home holds them
    # and the view mirrors only the executables. In launch mode that mirror
    # is launcher copies plus a few megabytes of real spawn-target copies;
    # in copy mode it is full copies (~100MB), and the gate below prices the
    # mode this run actually chose.
    sh_ri_rustup="$sh_ri_root/rustup"
    sh_ri_cargo="$sh_ri_root/cargo"
    sh_space_need 900 home || return 1
    sh_space_need "$(tc_rust_exec_mb)" exec || return 1
    mkdir -p "$sh_ri_rustup" "$sh_ri_cargo" 2>/dev/null || return 1

    # # NOTE: AN EXISTING WORKING RUSTUP IS THE FASTEST INSTALL. If the machine already
    # has rustup, it is asked to place the toolchain under this root rather than a
    # second copy of the installer being fetched.
    sh_ri_host_rustup=''
    if sh_have rustup; then
        sh_ri_host_rustup=$(command -v rustup 2>/dev/null)
    fi
    if [ -n "$sh_ri_host_rustup" ]; then
        if RUSTUP_HOME="$sh_ri_rustup" CARGO_HOME="$sh_ri_cargo" \
           rustup toolchain install stable --profile minimal \
           -c rustfmt -c clippy --no-self-update >/dev/null 2>&1; then
            sh_step "installed the stable toolchain into the home ($sh_ri_rustup); its executables mirror to the exec root"
            sh_toolchain_rust_proxies "$sh_ri_cargo" "$sh_ri_rustup" "$sh_ri_host_rustup"
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
        sh_warn 'the rustup on PATH could not install into the sandhome home root; falling back to rustup-init'
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
    sh_ri_url="https://static.rust-lang.org/rustup/dist/${sh_ri_triple}/rustup-init"
    # The installer is executed, so it is fetched onto the EXEC root and not into
    # SH_HOME_TMP: on a noexec home the download completes, chmod +x succeeds and
    # the execve that follows is refused, which reads as "rustup-init could not
    # install the toolchain" over a file that was never run.
    sh_ri_init="${SH_EXEC:-/tmp}/rustup-init.$$"
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
    # rustup-init writes its own proxies, but the ensure is cheap and keeps
    # both install paths under the same guarantee.
    sh_toolchain_rust_proxies "$sh_ri_cargo" "$sh_ri_rustup" "$sh_ri_host_rustup"
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

# tc_rust_sysroot_wrapper VIEW_BIN HOME_BIN SYSROOT LD_DIRS -> write the
# wrapper for one of rustc, rustdoc or clippy-driver into VIEW_BIN.
#
# A WRAPPER PASSES --sysroot, BECAUSE DETECTION CANNOT BE REDIRECTED. rustc
# derives its sysroot from the directory containing the librustc_driver.so it
# loaded, and in the view that file is a symlink back to the noexec home, so
# `rustc --print sysroot` answers with the home and the link then spawns
# <home>/.../gcc-ld/ld.lld, which cannot be exec'd:
#   collect2: fatal error: posix_spawnp: Permission denied
# No environment variable moves that sysroot (SYSROOT, RUSTC_SYSROOT and
# RUST_SYSROOT were all measured and ignored); --sysroot on the command line
# is the one spelling that works. The memfd runner does not change this: the
# driver still loads from the home path, so the wrapper is needed in launch
# mode and in copy mode alike.
#
# In launch mode the wrapper runs the home binary through sandhome-memexec;
# in copy mode it execs the real binary kept beside it as <name>.real.
tc_rust_sysroot_wrapper() {
    sh_rw_view=$1
    sh_rw_home=$2
    sh_rw_sysroot=$3
    sh_rw_ld=$4
    sh_rw_name=${sh_rw_view##*/}
    if [ "${SH_VIEW_MODE:-copy}" = launch ] && sh_memexec_built; then
        sh_rw_run="$(sh_memexec_bin)"
        sh_rw_target=$sh_rw_home
    else
        if [ ! -f "$sh_rw_view.real" ]; then
            mv -f "$sh_rw_view" "$sh_rw_view.real" 2>/dev/null || return 1
        fi
        sh_rw_run=''
        sh_rw_target="$sh_rw_view.real"
    fi
    if [ "$sh_rw_name" = clippy-driver ]; then
        # clippy IS DRIVEN THROUGH RUSTC_WORKSPACE_WRAPPER, WHICH CALLS
        # `clippy-driver <path-to-rustc> <rustc args>`. The rustc path is
        # argv[1] and has to stay first, so --sysroot goes after it. Putting
        # --sysroot first made the driver read the rustc path and then `-`
        # as two input files:
        #   error: multiple input filenames provided (first two filenames
        #   are .../bin/rustc and -)
        {
            printf '#!/bin/sh\n'
            printf '# sandhome: sysroot wrapper\n'
            if [ -n "$sh_rw_ld" ]; then
                printf 'LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$sh_rw_ld"
                printf 'export LD_LIBRARY_PATH\n'
            fi
            printf 'if [ -n "${1:-}" ] && [ -x "$1" ]; then\n'
            printf '    sh_rw_w="$1"; shift\n'
            if [ -n "$sh_rw_run" ]; then
                printf '    exec "%s" "%s" "$sh_rw_w" --sysroot "%s" "$@"\n' \
                    "$sh_rw_run" "$sh_rw_target" "$sh_rw_sysroot"
            else
                printf '    exec "%s" "$sh_rw_w" --sysroot "%s" "$@"\n' \
                    "$sh_rw_target" "$sh_rw_sysroot"
            fi
            printf 'fi\n'
            if [ -n "$sh_rw_run" ]; then
                printf 'exec "%s" "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_run" "$sh_rw_target" "$sh_rw_sysroot"
            else
                printf 'exec "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_target" "$sh_rw_sysroot"
            fi
        } > "$sh_rw_view" 2>/dev/null || return 1
    else
        {
            printf '#!/bin/sh\n'
            printf '# sandhome: sysroot wrapper\n'
            if [ -n "$sh_rw_ld" ]; then
                printf 'LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$sh_rw_ld"
                printf 'export LD_LIBRARY_PATH\n'
            fi
            if [ -n "$sh_rw_run" ]; then
                printf 'exec "%s" "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_run" "$sh_rw_target" "$sh_rw_sysroot"
            else
                printf 'exec "%s" --sysroot "%s" "$@"\n' \
                    "$sh_rw_target" "$sh_rw_sysroot"
            fi
        } > "$sh_rw_view" 2>/dev/null || return 1
    fi
    chmod 0755 "$sh_rw_view" 2>/dev/null || true
    return 0
}

# tc_rust_lib_dirs -> the toolchain lib directories that exist, colon
# separated, or nothing. A rustc run from memory cannot resolve its sibling
# librustc_driver through $ORIGIN (its exe is a memfd), so the loader needs
# these on LD_LIBRARY_PATH. Only directories under this toolchain are named:
# a global library path would leak this toolchain's libraries into every
# other tool's link.
tc_rust_lib_dirs() {
    sh_rld_root=$(sh_toolchain_root rust)
    sh_rld_out=''
    for sh_rld_d in "$sh_rld_root"/rustup/toolchains/*/lib; do
        [ -d "$sh_rld_d" ] || continue
        if [ -z "$sh_rld_out" ]; then
            sh_rld_out=$sh_rld_d
        else
            sh_rld_out="$sh_rld_out:$sh_rld_d"
        fi
    done
    printf '%s' "$sh_rld_out"
}

# tc_rust_copy_bins -> the executables that must be REAL copies in the view
# even in launch mode, space separated, relative to the toolchain root.
# rustc links by spawning <sysroot>/lib/rustlib/<host>/bin/gcc-ld/ld.lld
# through the system cc, and that wrapper locates its siblings exe-relative:
# a launcher copy runs from a memfd image with no stable directory and dies
# with `lld-wrapper: parent directory could not be determined`, while a real
# copy of the same file links fine. The same holds for cargo-clippy, which
# execs `clippy-driver` from beside its own executable: from a memfd image
# that dirname is empty and cargo dies with `` could not execute `/clippy-driver` ``.
# cargo-fmt fails the same way finding rustfmt (`Could not run rustfmt`).
# rust-lld is spawned the same way. The
# triple is globbed because it is only known once the toolchain is here.
# Measured: ~4MB (rust-lld plus the four gcc-ld wrappers).
tc_rust_copy_bins() {
    sh_rcb_root=$(sh_toolchain_root rust)
    for sh_rcb_b in "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/ld.lld \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/ld64.lld \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/lld-link \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/gcc-ld/wasm-ld \
                     "$sh_rcb_root"/rustup/toolchains/*/lib/rustlib/*/bin/rust-lld \
                     "$sh_rcb_root"/rustup/toolchains/*/bin/cargo-clippy \
                     "$sh_rcb_root"/rustup/toolchains/*/bin/cargo-fmt; do
        [ -f "$sh_rcb_b" ] || continue
        printf '%s ' "${sh_rcb_b#"$sh_rcb_root"/}"
    done
}

# tc_rust_ld_fragment FILE DIRS -> append the LD_LIBRARY_PATH block for DIRS
# to FILE. Split out so the heredoc is testable under `set -u`: an unquoted
# heredoc expands every `$`, and one bare `$ORIGIN` in a comment aborted the
# whole env write mid-fragment on the repair path (which runs under `set -u`)
# while every test passed (they run without it). The fragment then carried no
# LD_LIBRARY_PATH and no RUSTC, and every launcher died on its missing driver.
tc_rust_ld_fragment() {
    if [ -z "${2:-}" ]; then
        return 0
    fi
    cat >> "$1" <<EOF
# A rustc run from memory cannot resolve its sibling librustc_driver through
# \$ORIGIN (its exe is a memfd), so the toolchain lib rides LD_LIBRARY_PATH.
# Only this toolchain's own lib is named: nothing else's link may see it.
LD_LIBRARY_PATH="$2\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
EOF
}

tc_rust_env() {
    : "${SH_RUST_TARGETS:=${SANDHOME_RUST_TARGETS:-}}"
    sh_re_root=$(sh_toolchain_root rust)
    sh_re_rustup="$sh_re_root/rustup"
    sh_re_cargo="$sh_re_root/cargo"
    sh_re_view=$(sh_toolchain_view rust)
    # Adopted system rustc: still write a fragment when the home is split, so
    # the linker workaround and rustup exposure apply. The toolchain bin that
    # answered the probe keeps winning on PATH; this only adds what was missing.
    sh_re_installed=no
    if [ -d "$sh_re_rustup/toolchains" ] || [ -d "$sh_re_cargo/bin" ]; then
        sh_re_installed=yes
    fi
    if [ "$sh_re_installed" = no ] && tc_rust_probe; then
        # Pure adoption: no sandhome tree. The toolchain bin that answered the
        # probe keeps winning on PATH, and CARGO_INSTALL_ROOT still points at
        # the exec root so `cargo install` puts a runnable binary somewhere it
        # can be run from.
        sh_re_which=$(sh_path_where rustc)
        sh_re_dir=${sh_re_which%/*}
        sh_env_write_fragment rust <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
CARGO_INSTALL_ROOT="\$SANDHOME_EXEC/cargo-install"
export CARGO_INSTALL_ROOT
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/cargo-install/bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/cargo-install/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_re_dir:"*) ;;
  *) PATH="$sh_re_dir:\$PATH" ;;
esac
export PATH
EOF
        # # STOP: A BORROWED rustup IS USUALLY A SHIM, AND A SHIM NEEDS A
        # RUSTUP_HOME THAT HAS A DEFAULT TOOLCHAIN. A host that installs rust
        # through rustup has `rustc` as a symlink to the rustup binary, and that
        # binary resolves the toolchain through RUSTUP_HOME. With no such home, or
        # one whose settings.toml names no default, the shim answers:
        #   error: rustup could not choose a version of rustc to run, because one
        #   wasn't specified explicitly, and no default is configured.
        # which is a broken compiler wearing a working `rustc --version`.
        #
        # The question is NOT "is RUSTUP_HOME set". It was, in the run that found
        # this: the caller's environment exported it, so a guard on the variable
        # alone passed and nothing was written - and the consumer's shell, which
        # did not inherit it, got a shim with no toolchain. The question is
        # whether the home the shim will read has a default_toolchain in it, and
        # the answer is measured by looking, not by asking whether a name is set.
        # The list is the usual locations, plus the one already in the
        # environment, so a home elsewhere is not skipped.
        sh_re_rh_ok=no
        for sh_re_rh in ${RUSTUP_HOME:-} "$HOME/.rustup" "$HOME/.local/share/rustup" /usr/local/share/rustup; do
            [ -n "$sh_re_rh" ] || continue
            case "$(cat "$sh_re_rh/settings.toml" 2>/dev/null)" in
                *default_toolchain*) sh_re_rh_ok=$sh_re_rh; break ;;
            esac
        done
        if [ "$sh_re_rh_ok" = no ] && [ -x "$sh_re_dir/rustup" ]; then
            for sh_re_rh in "$HOME/.rustup" "$HOME/.local/share/rustup" /usr/local/share/rustup; do
                if [ -r "$sh_re_rh/settings.toml" ]; then
                    sh_re_rh_ok=$sh_re_rh
                    break
                fi
            done
        fi
        if [ "$sh_re_rh_ok" != no ]; then
            cat >> "$(sh_env_fragment rust)" <<SHIMEOF
# The rustc beside this rustup is a shim to it, and a shim needs a RUSTUP_HOME
# with a default toolchain: without one, "rustc --version" and a link both fail
# with "rustup could not choose a version of rustc to run".
export RUSTUP_HOME="$sh_re_rh_ok"
SHIMEOF
            sh_step "the adopted rustc is a rustup shim; RUSTUP_HOME=$sh_re_rh_ok"
        fi
        # # STOP: A BORROWED TOOLCHAIN THAT CANNOT LINK GETS A WORKING ONE
        # INSTALLED, NOT A LINKER FLAG. This branch used to write
        # RUSTFLAGS=-fuse-ld=bfd and return, and that cannot work: the sysroot of
        # a borrowed rustc is on the noexec home, the ld.lld inside it cannot be
        # exec'd, and rustc appends its own -fuse-ld=lld and -B<sysroot> after
        # any -C link-arg, so the flag is overridden and the noexec path returns
        # (issue #52). The repair that works is a toolchain whose sysroot is the
        # view, so that is what happens. A borrow that links fine is left alone,
        # so the common case costs one behavioural probe and no download.
        if [ "${SH_HOME_EXEC:-unknown}" != yes ] && ! tc_rust_behavioural >/dev/null 2>&1; then
            sh_warn "the rustc on PATH cannot link on this split root ($SH_HOME noexec); installing a toolchain on the home with an exec view instead of working around it"
            if sh_toolchain_ensure_rust_exec; then
                sh_re_installed=yes
            fi
        fi
        [ "$sh_re_installed" = yes ] || return 0
    fi
    # Proxies before the view search: a tree installed before they were
    # ensured has no CARGO_HOME/bin, and the framework's promote already ran
    # before this function, so newly created proxies are mirrored into the
    # view here, per the current mode, rather than a cycle late. This runs
    # only for an installed tree; pure adoption returns above and grows no
    # home directories.
    sh_re_host_rustup=''
    if sh_have rustup; then
        sh_re_host_rustup=$(command -v rustup 2>/dev/null)
    fi
    if [ ! -x "$sh_re_cargo/bin/cargo" ] || [ ! -x "$sh_re_cargo/bin/rustup" ]; then
        sh_toolchain_rust_proxies "$sh_re_cargo" "$sh_re_rustup" "$sh_re_host_rustup"
        if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
            for sh_re_p in cargo rustup; do
                [ -f "$sh_re_cargo/bin/$sh_re_p" ] || continue
                sh_re_pv="$sh_re_view/cargo/bin/$sh_re_p"
                if [ ! -e "$sh_re_pv" ]; then
                    mkdir -p "$sh_re_view/cargo/bin" 2>/dev/null || continue
                    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
                        sh_memexec_stamp "$sh_re_cargo/bin/$sh_re_p" "$sh_re_pv" || \
                            cp -f "$sh_re_cargo/bin/$sh_re_p" "$sh_re_pv" 2>/dev/null || true
                    else
                        rm -f "$sh_re_pv" 2>/dev/null
                        cp -f "$sh_re_cargo/bin/$sh_re_p" "$sh_re_pv" 2>/dev/null || true
                    fi
                    [ -e "$sh_re_pv" ] && chmod 0755 "$sh_re_pv" 2>/dev/null || true
                    # The framework's bin links ran inside the promote above,
                    # before these entries existed, so link them here too:
                    # without this a repair heals the view but leaves rustup
                    # off PATH until the next cycle.
                    if [ -e "$sh_re_pv" ]; then
                        mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
                        ln -sfn "$sh_re_pv" "$SH_EXEC_BIN/$sh_re_p" 2>/dev/null || true
                    fi
                fi
            done
        fi
    fi
    # The view bin is searched first: on a split root it is the only copy that
    # can execve, and it is where the copied gcc-ld/ld.lld sits, so its sysroot
    # is the one the wrapper must name. The home copy is the fallback for a home
    # that already runs binaries, where the view and the home are the same tree.
    sh_re_bin=''
    for sh_re_d in "$sh_re_view"/rustup/toolchains/*/bin \
                   "$sh_re_root"/rustup/toolchains/*/bin; do
        if [ -x "$sh_re_d/rustc" ]; then
            sh_re_bin=$sh_re_d
            break
        fi
    done
    if [ -z "$sh_re_bin" ]; then
        sh_warn 'no rustc was found under the rustup root after install'
        return 1
    fi
    sh_re_sysroot=${sh_re_bin%/bin}
    sh_re_home_bin=${sh_re_bin#"$sh_re_view"}
    case "$sh_re_home_bin" in
        "$sh_re_bin") sh_re_home_bin=$sh_re_bin ;;
        *) sh_re_home_bin="$sh_re_root$sh_re_home_bin" ;;
    esac
    sh_re_ld=$(tc_rust_lib_dirs)
    if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
        # On a split root the view's rustc becomes the --sysroot wrapper: the
        # sysroot it names is the view, so every binary rustc execve's at link
        # time lives on a mount that runs it.
        for sh_re_w in rustc rustdoc clippy-driver; do
            [ -f "$sh_re_bin/$sh_re_w" ] || continue
            case "$sh_re_w" in
                rustc) sh_re_hw="$sh_re_home_bin/rustc" ;;
                rustdoc) sh_re_hw="$sh_re_home_bin/rustdoc" ;;
                *) sh_re_hw="$sh_re_home_bin/clippy-driver" ;;
            esac
            tc_rust_sysroot_wrapper "$sh_re_bin/$sh_re_w" "$sh_re_hw" \
                "$sh_re_sysroot" "$sh_re_ld" || \
                sh_warn "could not wrap $sh_re_w with --sysroot"
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
# Listed least-wanted first: every block prepends, so the LAST block wins.
# The home cargo dir is the fallback (it cannot execve on a split root);
# the view toolchain bin wins outright.
case ":\$PATH:" in
  *":$sh_re_root/cargo/bin:"*) ;;
  *) PATH="$sh_re_root/cargo/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/cargo-install/bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/cargo-install/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_re_view/cargo/bin:"*) ;;
  *) PATH="$sh_re_view/cargo/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_re_bin:"*) ;;
  *) PATH="$sh_re_bin:\$PATH" ;;
esac
export PATH
EOF
    tc_rust_ld_fragment "$(sh_env_fragment rust)" "$sh_re_ld"
    if [ "${SH_HOME_EXEC:-unknown}" != yes ]; then
        # The wrapper above names this sysroot on its command line; RUSTC and
        # RUSTDOC name the wrappers so cargo never resolves the home paths,
        # which cannot execve here. Measured: without RUSTC, cargo drives the
        # toolchain's own bin/rustc and the link dies with
        #   collect2: fatal error: posix_spawnp: Permission denied
        # (issue #52).
        cat >> "$(sh_env_fragment rust)" <<EOF
export RUSTC="$sh_re_bin/rustc"
export RUSTDOC="$sh_re_bin/rustdoc"
EOF
    fi
    # Zig cross wrappers, one per requested target, placed on the exec view.
    if sh_have zig 2>/dev/null || [ -x "$SH_EXEC_BIN/zig" ]; then
        for sh_re_t in $(sh_split_on ',' "${SH_RUST_TARGETS:-}"); do
            [ -n "$sh_re_t" ] || continue
            sh_re_wrap="$SH_EXEC_BIN/rust-link-$sh_re_t"
            # # STOP: THE WRAPPER REWRITES THE TRIPLE AND DROPS RUSTC'S OWN
            # LINKER FLAGS. The previous one-line wrapper was
            #   exec zig cc -target $sh_re_t "$@"
            # and it failed on 6 of the 7 targets I tried, for four separate
            # reasons (issue #51):
            #   1. rustup spells <arch>-<vendor>-unknown-<os>; zig wants
            #      <arch>-<os>, so aarch64-unknown-linux-gnu is UnknownOperatingSystem
            #   2. 32-bit arch names are zig's to choose: x86 not i686, arm not
            #      armv7/thumb (zig 0.13 `zig targets` lists x86, x86_64, arm,
            #      armeb, thumb, thumbeb)
            #   3. rustc injects -m64, -B<sysroot>, -fuse-ld=lld and per-target
            #      -Wl, tuning flags such as --fix-cortex-a53-843419, which zig
            #      rejects ("unsupported linker arg")
            #   4. for a musl target rustc passes its own self-contained crt
            #      objects AND -nostartfiles while zig links its own musl, so
            #      _start and _init are defined twice
            # The -B<sysroot> drop matters twice over: it is the flag that put
            # the noexec sysroot back on a link that otherwise would have worked.
            cat > "$sh_re_wrap" 2>/dev/null <<WRAP || continue
#!/bin/sh
# written by sandhome: rustc passes no target triple to its linker (argv[1] is
# -m64 on x86_64), so the target is baked in here and every host-shaped flag
# rustc adds is dropped in favour of zig's linker and libc.
triple=\$(printf '%s' '$sh_re_t' | sed \\
  -e 's/-unknown-/-/' \\
  -e 's/^i[3-6]86-/x86-/' \\
  -e 's/^armv7[a-z0-9]*-/arm-/' \\
  -e 's/^thumb[a-z0-9]*-/arm-/')
case "\$1" in -m64|-m32) shift ;; esac
args=""
for a in "\$@"; do
  case "\$a" in
    -B*|-fuse-ld=*|-nodefaultlibs|-m64|-m32) continue ;;
    -Wl,--fix-cortex*|--fix-cortex*) continue ;;
    -nostartfiles) continue ;;
    *self-contained/crt*.o|*self-contained/rcrt*.o) continue ;;
  esac
  args="\$args \$a"
done
exec zig cc -target "\$triple" \$args
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
    # # STOP: NO BEHAVIOURAL CHECK HERE. It would run before sh_env_load, so the
    # shell still resolves `rustc` through the PATH it had before the wrapper
    # existed and the check reports a healthy install as broken:
    #   [!] rustc installed without an error and still does not link
    # on a toolchain that compiles two lines later in a fresh shell. The
    # framework owns the last word: it calls sh_env_load and only then runs
    # tc_rust_probe, which does the same compile with the fragment in effect.
    return 0
}

tc_rust_version() {
    sh_have rustc && sh_first_line rustc --version 2>/dev/null
}

# tc_rust_adopted -> directory of the answering rustc when adopted.
tc_rust_adopted() {
    # sh_path_where, not command -v: the exec view is on PATH by the time an
    # install runs, so command -v answers with the view this tool is being
    # linked INTO and the promote step then links the view onto itself (issue
    # #43). The exec view is not a working copy and is not consulted.
    sh_ra_which=$(sh_path_where rustc)
    [ -n "$sh_ra_which" ] || return 0
    sh_ra_dir=${sh_ra_which%/*}
    [ -n "$sh_ra_dir" ] || sh_ra_dir=.
    ( CDPATH='' cd -- "$sh_ra_dir" 2>/dev/null && pwd ) || printf '%s' "$sh_ra_dir"
}
