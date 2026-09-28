#!/bin/sh
# shim.sh - build and install the two LD_PRELOAD interposers. Sourced.
#
# fakepty makes a pipe-backed shell believe fds 0-2 are a terminal, so readline
# and echo work where there is no /dev/ptmx. fakepwd answers getpwnam/getpwuid
# from a synthetic passwd database for a cage with no /etc/passwd.
#
# STOP: NEITHER CAN REACH A STATICALLY LINKED BINARY. A static binary carries its own
# libc, so LD_PRELOAD has nothing to interpose into. That is a measurement, not a
# caveat: it is why the ssh server sandhome builds must be dynamically linked.

sh_shims_dir() { printf '%s/shims' "$SH_HOME"; }

# sh_shim_need NAME -> yes when the machine lacks what the shim supplies.
sh_shim_need() {
    case "$1" in
        fakepty) [ "${SH_PTY:-unknown}" = no ] && printf 'yes' || printf 'no' ;;
        fakepwd) [ "${SH_PASSWD:-unknown}" = no ] && printf 'yes' || printf 'no' ;;
        *)       printf 'no' ;;
    esac
}

# sh_shim_build NAME SRC -> compile SRC into $SH_HOME/shims/NAME.so.
sh_shim_build() {
    sh_sb_name=$1
    sh_sb_src=$2
    sh_sb_out="$(sh_shims_dir)/$sh_sb_name.so"
    if [ ! -f "$sh_sb_src" ]; then
        sh_warn "no source at $sh_sb_src"
        return 1
    fi
    if ! sh_have cc && ! sh_have gcc; then
        sh_warn "no C compiler is present, so $sh_sb_name cannot be built"
        return 1
    fi
    sh_sb_cc=cc
    sh_have cc || sh_sb_cc=gcc
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would compile $sh_sb_src into $sh_sb_out"
        return 0
    fi
    mkdir -p "$(sh_shims_dir)" 2>/dev/null || return 1
    # # NOTE: THE COMPILER'S OWN ERROR IS SHOWN, NOT SWALLOWED. The build discarded
    # stderr, so a failure reported only "cc could not build fakepty" and the
    # operator was left to guess. Measured on a machine where `cc` is present
    # and every compile of the same source succeeds by hand: `cc` was reached
    # through a PATH that carried the compiler but not its assembler or linker,
    # and the message said nothing about either. The real answer was three lines
    # of `as`/`ld` not found that the build had thrown away. It is now captured
    # and printed, and a build that failed for a reason outside this tree says so
    # rather than naming this tree.
    sh_sb_err=${SH_HOME_TMP:-$SH_HOME/tmp}/.shim-build.$$
    # No dirname: the library may not require it (issue #16); sh_dirname is
    # the shell-only equivalent with dirname semantics for bare names.
    mkdir -p "$(sh_dirname "$sh_sb_err")" 2>/dev/null || true
    if "$sh_sb_cc" -shared -fPIC -O2 -o "$sh_sb_out" "$sh_sb_src" 2>"$sh_sb_err"; then
        rm -f "$sh_sb_err" 2>/dev/null
        sh_step "built $sh_sb_out"
        return 0
    fi
    if [ -s "$sh_sb_err" ]; then
        while IFS= read -r sh_sb_line || [ -n "$sh_sb_line" ]; do
            sh_warn "$sh_sb_cc: $sh_sb_line"
        done < "$sh_sb_err"
    else
        sh_warn "$sh_sb_cc could not build $sh_sb_name and said nothing about why"
    fi
    rm -f "$sh_sb_err" 2>/dev/null
    return 1
}

# sh_shim_build_all SRC_DIR -> build whichever shims are needed here. A shim the
# machine does not need is not built, so a normal host gets nothing.
#
# # STOP: A NEEDED SHIM THAT IS NOT THERE AFTERWARDS IS A FAILURE, AND THE
# FUNCTION IS WHERE THAT IS DECIDED. It used to append a name only when
# `sh_shim_build` returned 0 and then `return 0` regardless, so a machine that
# needed fakepty, had no C compiler, and therefore had no fakepty.so finished
# the whole bootstrap with `failures=0` and exit 0. The only trace was one
# `[!]` line on stderr, which is exactly what the `shims=` report field was
# supposed to surface and could not. Measured, with PATH holding no compiler:
#   bootstrap: [!] no C compiler is present, so fakepty cannot be built
#   bootstrap: [!] no C compiler is present, so fakepwd cannot be built
#   failures=0
#   $? = 0
# sh_doctor already treated a needed-but-absent shim as a hard invariant, so
# the rule existed in two places and only one of them held. It lives here now,
# which is the one place both the bootstrap and `sandhome shims` go through.
# `--require-shims` used to be the only way to learn this; it still narrows the
# check to a STALE shim, which is a different defect.
sh_shim_build_all() {
    sh_sba_dir=$1
    sh_sba_built=''
    sh_sba_failed=''
    for sh_sba_name in fakepty fakepwd; do
        sh_sba_need=$(sh_shim_need "$sh_sba_name")
        sh_sba_out="$(sh_shims_dir)/$sh_sba_name.so"
        if [ "$sh_sba_need" != yes ]; then
            sh_step "$sh_sba_name: this machine has $(sh_sba_what "$sh_sba_name"); not needed"
            continue
        fi
        if [ "$SH_DRY_RUN" = 1 ]; then
            sh_shim_build "$sh_sba_name" "$sh_sba_dir/$sh_sba_name.c" || true
            continue
        fi
        if sh_shim_build "$sh_sba_name" "$sh_sba_dir/$sh_sba_name.c"; then
            sh_sba_built="$sh_sba_built $sh_sba_name"
        fi
        # The build's exit status is not the question. The question is whether
        # the machine now has the file, and a build can return 0 without
        # writing one.
        if [ ! -f "$sh_sba_out" ]; then
            sh_fail "the $sh_sba_name shim is needed on this machine and is not at $sh_sba_out; install a C compiler (cc or gcc) and run this again"
            sh_sba_failed="$sh_sba_failed $sh_sba_name"
        fi
    done
    # WHAT WAS BUILT BY THIS RUN, which is a different fact from what is
    # present, and the report prints the second one (sh_shim_report). This
    # value is what the `[!]` guard on a stale build reads.
    SH_SHIMS_BUILT=${sh_sba_built# }
    export SH_SHIMS_BUILT
    return 0
}

sh_sba_what() {
    case "$1" in
        fakepty) printf 'a pty' ;;
        fakepwd) printf 'a passwd database' ;;
        *)       printf 'what it needs' ;;
    esac
}

# sh_shim_write_passwd -> the synthetic passwd file fakepwd reads, built from the
# account that is running. SANDHOME_PASSWD is the variable fakepwd reads and
# env.sh exports when the shim is loaded; the shim still answers to the older
# SANDSSH_PASSWD for a machine configured before it moved here.
#
# STOP: `id -un` CAN FAIL, AND WHEN IT DOES IT PRINTS TO STDERR AND NOTHING TO
# STDOUT. A cage with no /etc/passwd answers exactly that, and naming the entry
# `root` with uid 966 then reads as a passwd file that lies. The name is derived
# from the uid instead, and the uid is what the shim is asked for.
sh_shim_write_passwd() {
    sh_swp_file="$(sh_shims_dir)/passwd"
    sh_swp_uid=$(id -u 2>/dev/null) || sh_swp_uid=0
    sh_swp_gid=$(id -g 2>/dev/null) || sh_swp_gid=0
    sh_swp_user=$(id -un 2>/dev/null) || sh_swp_user=''
    if [ -z "$sh_swp_user" ]; then
        sh_swp_user="user$sh_swp_uid"
    fi
    sh_swp_home=${HOME:-/root}
    sh_swp_shell=${SHELL:-/bin/sh}
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would write $sh_swp_file for $sh_swp_user"
        return 0
    fi
    mkdir -p "$(sh_shims_dir)" 2>/dev/null || return 1
    {
        printf 'root:x:0:0:root:/root:/bin/sh\n'
        if [ "$sh_swp_uid" != 0 ]; then
            printf '%s:x:%s:%s:%s:%s:%s\n' \
                "$sh_swp_user" "$sh_swp_uid" "$sh_swp_gid" "$sh_swp_user" "$sh_swp_home" "$sh_swp_shell"
        fi
        # # NOTE: ANY LOGIN NAME A CALLER NAMES IS ADDED TOO. A cage's ssh server looks
        # the login name up before it checks the key, and an account that is not
        # there is refused with "Permission denied (publickey)", which reads as a
        # key problem and is not one. SANDHOME_PASSWD_USERS=agent,deploy adds the
        # names a later session will actually log in as.
        sh_swp_n=1000
        for sh_swp_extra in $(sh_split_on ', ' "${SANDHOME_PASSWD_USERS:-}"); do
            [ -n "$sh_swp_extra" ] || continue
            if [ "$sh_swp_extra" = root ] || [ "$sh_swp_extra" = "$sh_swp_user" ]; then
                continue
            fi
            printf '%s:x:%s:%s:%s:%s:%s\n' \
                "$sh_swp_extra" "$sh_swp_n" "$sh_swp_n" "$sh_swp_extra" "/home/$sh_swp_extra" "$sh_swp_shell"
            mkdir -p "/home/$sh_swp_extra" 2>/dev/null || true
            sh_swp_n=$((sh_swp_n + 1))
        done
    } > "$sh_swp_file"
    SH_PASSWD_FILE=$sh_swp_file
    export SH_PASSWD_FILE
    # # STOP: THE HOME MUST EXIST OR A SSH SERVER THAT CHDIRS TO IT FAILS, and the
    # failure reads as an auth problem rather than a missing directory.
    [ -d "$sh_swp_home" ] || mkdir -p "$sh_swp_home" 2>/dev/null || true
    return 0
}

# sh_shim_report -> what was needed, what is present, and where. Every value is
# read from the machine: a shim is named as built only when its object exists.
#
# # STOP: THIS READS THE OBJECTS AND NOT $SH_SHIMS_BUILT, AND THE REPORT FIELD
# PRINTS WHAT IS HERE. `SH_SHIMS_BUILT` means "built by this run", and the
# report line read it, which made `shims=` empty on every path that reaches it:
#   - a second run finds the .so already there, so sh_shim_build returns 0 and
#     nothing is appended;
#   - `--dry-run` compiled nothing, so nothing was appended by design;
#   - `sandhome report` never calls the builder at all, so it was unset;
# and on the one case that did populate it, a dry run on a home where the shims
# were already built printed an empty field while the files sat right there.
# A report that answers "none of the shims this machine needs are present" when
# both of them are is the exact class of claim this tree exists to refuse, and
# it is the one the report's own NOTE disclaims. tests/shims.sh and
# tests/unit.sh now assert both directions.
sh_shim_report() {
    sh_sr_dir=$(sh_shims_dir)
    sh_sr_pty=no;  sh_sr_fakepwd=no
    [ -f "$sh_sr_dir/fakepty.so" ] && sh_sr_pty=yes
    [ -f "$sh_sr_dir/fakepwd.so" ] && sh_sr_fakepwd=yes
    printf 'pty=%s fakepty_built=%s passwd=%s fakepwd_built=%s passwd_file=%s dir=%s preload=%s\n' \
        "${SH_PTY:-unknown}" "$sh_sr_pty" \
        "${SH_PASSWD:-unknown}" "$sh_sr_fakepwd" \
        "$([ -r "$sh_sr_dir/passwd" ] && printf '%s' "$sh_sr_dir/passwd" || printf none)" \
        "$sh_sr_dir" \
        "${SANDHOME_SHIMS:+on}${SANDHOME_SHIMS:-off}"
}

# sh_shim_present -> the shims that are present in $SH_HOME/shims, space
# separated, read off the disk. This is the value the `shims=` report field
# prints; it is a probe, like every other line in the report, and it answers
# about a home no run of this command has touched.
sh_shim_present() {
    sh_sp_present=''
    for sh_sp_name in fakepty fakepwd; do
        if [ -f "$(sh_shims_dir)/$sh_sp_name.so" ]; then
            sh_sp_present="$sh_sp_present $sh_sp_name"
        fi
    done
    printf '%s' "${sh_sp_present# }"
}

# sh_shim_needed_missing -> the shims this machine needs and does not have,
# space separated. Empty is the good answer, and it is a DIFFERENT answer from
# `sh_shim_present` being empty: that is a machine with a pty and a passwd
# database, which needs nothing. The report prints both so neither is read as
# the other.
sh_shim_needed_missing() {
    sh_snm_missing=''
    for sh_snm_name in fakepty fakepwd; do
        if [ "$(sh_shim_need "$sh_snm_name")" = yes ] && \
           [ ! -f "$(sh_shims_dir)/$sh_snm_name.so" ]; then
            sh_snm_missing="$sh_snm_missing $sh_snm_name"
        fi
    done
    printf '%s' "${sh_snm_missing# }"
}
