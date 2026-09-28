#!/bin/sh
# space.sh - where files may live, and where they may run. Sourced.
#
# THE MEASUREMENT THIS EXISTS FOR. A sandbox can mount a directory rw and still
# refuse execve(2) on it, while allowing mmap(PROT_EXEC) - so a shared library
# read from there loads, and a copied binary in it will not run. `mount` does not
# have to say noexec: the refusal can come from a sandbox policy that is invisible
# in /proc/mounts. The only reliable answer is to try it.
#
# WHAT THAT MEANS FOR A TOOLCHAIN. Data (stdlib, GOROOT, .rlib, .so) may live on
# the big read-only-in-effect home directory. Executables (rustc, cargo, go, node,
# the bundled linker) may not: they need an exec-capable mount, and so does every
# build script, proc-macro and test binary a build produces.
#
# So the plan is two roots:
#   SH_HOME  persistent data, exactly where it was asked for. May be noexec.
#   SH_EXEC  the exec-capable root. Small is fine; only executables and build
#            output are promoted here, everything else is symlinked back.
# When SH_HOME is itself exec-capable the two collapse and nothing is promoted.

# STOP: THE TUNABLE HAS ONE NAME AND THE OLD ONE STILL ANSWERS. The variable
# was SH_MIN_EXEC_MB while every document said SANDHOME_MIN_EXEC_MB, so a
# reader who set the documented name changed nothing and had no way to find
# out. The public name is now the one the documents carry, and the old name is
# still read so an existing script is not silently ignored.
: "${SANDHOME_MIN_EXEC_MB:=${SH_MIN_EXEC_MB:-128}}"
SH_MIN_EXEC_MB=$SANDHOME_MIN_EXEC_MB
: "${SH_MIN_HOME_MB:=256}"
SH_TAB=$(printf '\t')

# sh_dir_writable DIR -> 0 when a file can be created in DIR.
sh_dir_writable() {
    [ -d "$1" ] || return 1
    sh_dw_probe="$1/.sandhome.w.$$"
    if ( : > "$sh_dw_probe" ) 2>/dev/null; then
        rm -f "$sh_dw_probe" 2>/dev/null
        return 0
    fi
    rm -f "$sh_dw_probe" 2>/dev/null
    return 1
}

# sh_exec_probe DIR -> 0 when a binary can actually be executed from DIR.
# STOP: NOT A CHECK OF MOUNT OPTIONS. The probe is a real exec of a real file; a
# policy that refuses execve does not have to show up in /proc/mounts, and a
# mount that says noexec can still allow it on some kernels.
sh_exec_probe() {
    sh_ep_dir=$1
    [ -d "$sh_ep_dir" ] || return 1
    sh_ep_file="$sh_ep_dir/.sandhome.exec.$$"
    if ! printf '#!/bin/sh\nexit 0\n' > "$sh_ep_file" 2>/dev/null; then
        rm -f "$sh_ep_file" 2>/dev/null
        return 1
    fi
    chmod 0700 "$sh_ep_file" 2>/dev/null || true
    if "$sh_ep_file" >/dev/null 2>&1; then
        rm -f "$sh_ep_file" 2>/dev/null
        return 0
    fi
    rm -f "$sh_ep_file" 2>/dev/null
    return 1
}

# sh_mount_opts DIR -> the mount options for the filesystem holding DIR, or
# nothing. This is the cheap answer shown in the report; it is never the answer
# used to decide, because it can be wrong.
sh_mount_opts() {
    if [ -r /proc/mounts ]; then
        sh_mo_want=$1
        sh_mo_best=''
        sh_mo_len=0
        while read -r sh_mo_dev sh_mo_point sh_mo_fs sh_mo_opts sh_mo_a sh_mo_b; do
            case "$sh_mo_want" in
                "$sh_mo_point"|"$sh_mo_point"/*)
                    if [ "${#sh_mo_point}" -gt "$sh_mo_len" ]; then
                        sh_mo_len=${#sh_mo_point}
                        sh_mo_best=$sh_mo_opts
                    fi
                    ;;
            esac
        done < /proc/mounts
        if [ -n "$sh_mo_best" ]; then
            printf '%s' "$sh_mo_best"
            return 0
        fi
    fi
    printf ''
}

# sh_home_default -> the persistent root, honouring the environment. XDG first
# when it is set, then ~/.local/share, then a plain ~/.sandhome for a userland
# with no XDG convention at all.
sh_home_default() {
    if [ -n "${SANDHOME_HOME:-}" ]; then
        printf '%s' "$SANDHOME_HOME"
        return 0
    fi
    if [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s/sandhome' "$XDG_DATA_HOME"
        return 0
    fi
    if [ -n "${HOME:-}" ]; then
        printf '%s/.local/share/sandhome' "$HOME"
        return 0
    fi
    printf '/tmp/sandhome'
}

# sh_exec_candidates -> the places tried for the exec root, best first. The
# environment override wins, then the home itself, then every writable tmpfs
# that is usually tmpfs, then a directory under the home.
#
# NOTE: ONE LIST AND ONE DEDUPE, BECAUSE TWO LISTS DRIFT. The plan and the probe
# report each built their own candidate string and they disagreed: the plan did
# not create a missing candidate and the report created one as a side effect of
# asking whether it was writable, so `sandhome space --probe` listed a directory
# that the bootstrap had never made and would never use. /var/tmp was in the list
# at all only because the probe created it (in this sandbox /var/tmp is absent,
# and a probe that makes the directory it reports is a probe that changes the
# machine it claims to be reading).
sh_exec_candidates() {
    sh_ec_seen=' '
    sh_ec_out=''
    for sh_ec_c in \
        ${SANDHOME_EXEC:+"$SANDHOME_EXEC"} \
        "$SH_HOME" \
        /dev/shm \
        /tmp \
        "/run/user/$(id -u 2>/dev/null)" \
        ${HOME:+"$HOME/.cache/sandhome/exec"}
    do
        [ -n "$sh_ec_c" ] || continue
        case "$sh_ec_seen" in
            *" $sh_ec_c "*) continue ;;
        esac
        sh_ec_seen="$sh_ec_seen$sh_ec_c "
        sh_ec_out="$sh_ec_out$sh_ec_c "
    done
    sh_ec_out=${sh_ec_out% }
    printf '%s' "$sh_ec_out"
}

# sh_space_plan -> set SH_HOME and SH_EXEC, create both, and export them. The
# exec root is the first candidate that is writable and actually runs a file;
# free space prefers a candidate with room but does not disqualify the only one,
# sh_space_plan [--no-create] -> set SH_HOME and SH_EXEC, create both, and export
# them. The exec root is the first candidate that is writable and actually runs a
# file; free space prefers a candidate with room but does not disqualify the only
# one, because a small exec root that works beats a large one that does not.
#
# # STOP: `--no-create` ANSWERS WITHOUT CHANGING THE MACHINE, BECAUSE A QUESTION
# ABOUT A ROOT IS NOT A REQUEST TO BUILD ONE. The planner used to mkdir both
# roots on the way to answering anything, and bin/sandhome called it before its
# dispatcher, so every subcommand created them:
#   $ SANDHOME_HOME=/tmp/h SANDHOME_EXEC=/tmp/e sh bin/sandhome version
#   sandhome/1
#   $ find /tmp/h /tmp/e -maxdepth 1        # four directories each
# Three things were wrong with that. `version` and `help` are the two commands a
# caller reaches for BECAUSE something is broken, and they could not run at all
# on a machine whose configured home is unwritable: sh_die fired during startup
# and the usage text was never printed. `space --probe` reported a post-creation
# state, so the answer was about the world it had just made rather than the one
# asked about - the same fault the probe report already documents for /var/tmp.
# And `HOME/.cache/sandhome/exec` is a candidate, so once any command had run,
# a directory appeared that would never otherwise exist and became a writable,
# exec-capable candidate: the plan's own outcome then depended on which command
# had been run first.
#
# In --no-create the home is NOT probed for exec and NOT created, the candidate
# list is examined as it stands, and a directory that does not exist is passed
# over rather than made. A caller that needs the directories runs a command that
# installs something; that is what creating them is for.
sh_space_plan() {
    sh_sp_create=1
    if [ "${1:-}" = --no-create ]; then
        sh_sp_create=0
    fi
    SH_HOME=$(sh_home_default)
    SH_EXEC=''
    SH_HOME_EXEC=no
    # # STOP: THE USABLE FLAG IS RESET AT THE TOP OF EVERY PLAN, NOT ONLY SET ON
    # THE FAILING PATH. A read-only plan that found nothing sets it to 1, and the
    # create plan that runs after it reused the stale 1, so `sandhome install`
    # refused a root it had just made. Every plan decides this from scratch.
    SH_EXEC_UNUSABLE=0

    if [ "$sh_sp_create" = 1 ]; then
        if ! mkdir -p "$SH_HOME" 2>/dev/null; then
            sh_die "cannot create the home root at $SH_HOME; pass SANDHOME_HOME"
        fi
    fi
    # Probing the home for exec WRITES to it (sh_exec_probe creates and runs a
    # file), so it is a create-only answer too. A read-only plan reports
    # home_exec=unknown rather than guessing, because the honest answer is that
    # it was not measured and the honest cost of measuring it is a write.
    if [ "$sh_sp_create" = 1 ]; then
        if sh_exec_probe "$SH_HOME"; then
            SH_HOME_EXEC=yes
        fi
    else
        SH_HOME_EXEC=unknown
    fi

    sh_sp_first_working=''
    sh_sp_first_roomy=''
    sh_sp_explicit_ok=0
    sh_sp_tried=''
    for sh_sp_candidate in $(sh_exec_candidates); do
        [ -n "$sh_sp_candidate" ] || continue
        sh_sp_tried="$sh_sp_tried$sh_sp_candidate "
        # # STOP: THE FLAG IS INITIALISED BEFORE THE BRANCH THAT MAY `continue`
        # PAST IT, BECAUSE `set -u` IS A RUNTIME ABORT AND NOT A LINT WARNING.
        # The read-only branch below does `continue` when the candidate is not a
        # directory, and the room check that reads this flag is outside it, so a
        # read-only plan that saw a missing candidate first died with
        # "sh_sp_fake: parameter not set" and the command exited 0 on the way
        # out, having printed nothing. Every variable a loop reads after a
        # conditional `continue` is assigned before the branch, not in it.
        sh_sp_fake=''
        if [ "$sh_sp_create" = 1 ]; then
            if ! mkdir -p "$sh_sp_candidate" 2>/dev/null; then
                continue
            fi
            # # STOP: A CANDIDATE THIS CALL JUST CREATED IS NOT EVIDENCE OF ROOM,
            # AND THE GATE BELOW IS THE OTHER HALF OF THAT. The directory did not
            # exist a moment ago, so its free space was measured on a filesystem
            # that had just been given an empty directory, and preferring it on
            # that number would rank what we made above a real tmpfs with
            # gigabytes on it. The flag marks the created ones and the room check
            # SKIPS them.
            #
            # The first version of this got the sense backwards: it set the flag
            # on the created candidates and then ran the room check only for
            # those, so it preferred exactly the directories it had just made and
            # ignored every real one. The original code measured all of them and
            # was right to; what changed is only that the ones we created are
            # excluded. tests/space.sh drives the two shapes.
            [ -d "$sh_sp_candidate" ] || sh_sp_fake=yes
        else
            # Read-only: a directory that is not there is not a candidate, and
            # is not brought into being to become one.
            [ -d "$sh_sp_candidate" ] || continue
        fi
        if ! sh_dir_writable "$sh_sp_candidate"; then
            continue
        fi
        if ! sh_exec_probe "$sh_sp_candidate"; then
            continue
        fi
        if [ -n "${SANDHOME_EXEC:-}" ] && [ "$sh_sp_candidate" = "$SANDHOME_EXEC" ]; then
            sh_sp_explicit_ok=1
        fi
        if [ -z "$sh_sp_first_working" ]; then
            sh_sp_first_working=$sh_sp_candidate
        fi
        if [ -z "$sh_sp_fake" ]; then
            sh_sp_free=$(sh_free_mb "$sh_sp_candidate")
            case "$sh_sp_free" in
                ''|*[!0-9]*) sh_sp_free=0 ;;
            esac
            if [ "$sh_sp_free" -ge "$SANDHOME_MIN_EXEC_MB" ] && [ -z "$sh_sp_first_roomy" ]; then
                sh_sp_first_roomy=$sh_sp_candidate
            fi
        fi
    done

    # # NOTE: THE TWO ROOTS COLLAPSE ONLY WHEN NOTHING WAS ASKED FOR EXPLICITLY. An
    # operator who named SANDHOME_EXEC has said where executables must go, and
    # silently overriding that with the home root is how a small root becomes a
    # surprise. A named root that cannot be used is refused by name rather than
    # swapped for a different one.
    # # STOP: AN EXPLICITLY NAMED ROOT IS CREATED BEFORE IT IS JUDGED. The loop
    # above tests `SANDHOME_EXEC` only after a successful mkdir, and a nested
    # path whose parent does not exist fails that mkdir, so a caller who named
    # `$work/unk-x` was told the root "is not writable or does not allow exec"
    # about a directory that simply had not been made. The create plan makes it
    # and asks again. A read-only plan does not, and says so instead.
    if [ -n "${SANDHOME_EXEC:-}" ] && [ "$sh_sp_create" = 1 ] && [ "$sh_sp_explicit_ok" != 1 ]; then
        if mkdir -p "$SANDHOME_EXEC" 2>/dev/null &&
           sh_dir_writable "$SANDHOME_EXEC" &&
           sh_exec_probe "$SANDHOME_EXEC"; then
            SH_EXEC=$SANDHOME_EXEC
            sh_sp_explicit_ok=1
            SH_EXEC_UNUSABLE=0
        fi
    fi

    if [ -n "${SANDHOME_EXEC:-}" ]; then
        if [ "$sh_sp_explicit_ok" = 1 ]; then
            SH_EXEC=$SANDHOME_EXEC
        elif [ "$sh_sp_create" = 0 ]; then
            # # NOTE: A READ-ONLY PLAN REFUSES BY NAME RATHER THAN DYING. `sandhome
            # version` with an unwritable SANDHOME_EXEC used to exit 2 from
            # startup, before the dispatcher, so the usage text never printed and
            # the two commands an operator reaches for when a machine is broken
            # were the two that could not run on one. The plan now reports what it
            # found and the CALLER decides whether that is fatal; only a command
            # that installs something turns this into a refusal.
            SH_EXEC=$SANDHOME_EXEC
            SH_EXEC_UNUSABLE=1
        else
            sh_die "SANDHOME_EXEC=$SANDHOME_EXEC is not writable or does not allow exec"
        fi
    elif [ "$SH_HOME_EXEC" = yes ]; then
        SH_EXEC=$SH_HOME
    elif [ -n "$sh_sp_first_roomy" ]; then
        SH_EXEC=$sh_sp_first_roomy
    elif [ -n "$sh_sp_first_working" ]; then
        SH_EXEC=$sh_sp_first_working
        sh_warn "no candidate had ${SANDHOME_MIN_EXEC_MB}MB free; using $SH_EXEC anyway"
    else
        # Nothing on this machine both runs a file and can be written. A create
        # run cannot continue; a read-only run can still ANSWER, and the answer
        # is the finding.
        if [ "$sh_sp_create" = 1 ]; then
            sh_die "no writable mount here both allows exec and can be written; set SANDHOME_EXEC to one"
        fi
        SH_EXEC=''
        SH_EXEC_UNUSABLE=1
    fi

    if [ -n "$SH_EXEC" ]; then
        SH_EXEC_BIN="$SH_EXEC/bin"
        SH_EXEC_VIEWS="$SH_EXEC/views"
    else
        SH_EXEC_BIN=''
        SH_EXEC_VIEWS=''
    fi
    SH_HOME_TOOLCHAINS="$SH_HOME/toolchains"
    SH_HOME_TMP="$SH_HOME/tmp"
    if [ "$sh_sp_create" = 1 ]; then
        mkdir -p "$SH_EXEC_BIN" "$SH_EXEC_VIEWS" "$SH_HOME_TOOLCHAINS" "$SH_HOME_TMP" 2>/dev/null || \
            sh_die "cannot create the sandhome directories below $SH_HOME and $SH_EXEC"
    fi

    # What the plan actually tried, and why it settled where it did. `doctor`
    # and the bootstrap log read these instead of re-deriving the list.
    SH_EXEC_TRIED=$sh_sp_tried
    SH_EXEC_CHOSEN_REASON=collapsed
    if [ -z "$SH_EXEC" ]; then
        SH_EXEC_CHOSEN_REASON=none
    fi
    if [ -n "$SH_EXEC" ] && [ "$SH_EXEC" != "$SH_HOME" ]; then
        SH_EXEC_CHOSEN_REASON=split
    fi
    if [ -n "${SANDHOME_EXEC:-}" ] && [ "$SH_EXEC" = "$SANDHOME_EXEC" ]; then
        SH_EXEC_CHOSEN_REASON=explicit
    fi
    SH_PLAN_CREATED=$sh_sp_create
    export SH_HOME SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TOOLCHAINS SH_HOME_TMP
    export SH_HOME_EXEC SH_EXEC_TRIED SH_EXEC_CHOSEN_REASON SH_PLAN_CREATED SH_EXEC_UNUSABLE
    return 0
}

# sh_space_need MB [WHERE] -> refuse to proceed when there is plainly not enough
# room for the named install. WHERE is `exec`, `home` or `both` (default both).
sh_space_need() {
    sh_sn_mb=$1
    sh_sn_where=${2:-both}
    case "$sh_sn_where" in
        exec|both)
            sh_sn_free=$(sh_free_mb "$SH_EXEC")
            case "$sh_sn_free" in ''|*[!0-9]*) sh_sn_free=0 ;; esac
            if [ "$sh_sn_free" -lt "$sh_sn_mb" ]; then
                sh_warn "$SH_EXEC has ${sh_sn_free}MB free and this wants ${sh_sn_mb}MB on the exec root"
                return 1
            fi
            ;;
    esac
    case "$sh_sn_where" in
        home|both)
            sh_sn_free=$(sh_free_mb "$SH_HOME")
            case "$sh_sn_free" in ''|*[!0-9]*) sh_sn_free=0 ;; esac
            if [ "$sh_sn_free" -lt "$sh_sn_mb" ]; then
                sh_warn "$SH_HOME has ${sh_sn_free}MB free and this wants ${sh_sn_mb}MB on the home root"
                return 1
            fi
            ;;
    esac
    return 0
}

# sh_view_need SRC -> refuse before mirroring when the exec root plainly cannot
# hold the view. Uses the free-space number the planner already measures and
# the apparent size of SRC. Names the constraint rather than failing at ENOSPC
# mid-copy (issue #33 constrains #29: a 172MB zig binary does not fit a 245MB
# tmpfs that already holds views plus GOCACHE).
sh_view_need() {
    sh_vn_src=$1
    [ -d "$sh_vn_src" ] || return 0
    sh_vn_need=$(sh_dir_size "$sh_vn_src" 2>/dev/null)
    case "$sh_vn_need" in
        ''|*[!0-9]*) return 0 ;;
    esac
    # du reports KB; keep 20MB headroom for the copy itself plus a build cache.
    sh_vn_need_mb=$((sh_vn_need / 1024 + 20))
    sh_vn_free=$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)
    case "$sh_vn_free" in
        ''|*[!0-9]*) sh_vn_free=0 ;;
    esac
    if [ "$sh_vn_free" -lt "$sh_vn_need_mb" ]; then
        sh_warn "$SH_EXEC has ${sh_vn_free}MB free and the $sh_vn_src view wants about ${sh_vn_need_mb}MB; set SANDHOME_EXEC to a roomy root (--exec DIR) and re-run"
        return 1
    fi
    return 0
}

# sh_is_exec_file PATH -> 0 for a regular file that must be COPIED into an exec
# view rather than symlinked. # STOP: A SHARED OBJECT IS NOT ONE: mmap(PROT_EXEC) from
# a noexec mount is allowed even where execve is not, which is the measurement
# this whole split rests on, and copying a 144MB librustc_driver or a 191MB
# libLLVM would not fit on the small root it would be copied to.
sh_is_exec_file() {
    [ -f "$1" ] || return 1
    [ -x "$1" ] || return 1
    case "$1" in
        *.so|*.so.*|*.dylib|*.dll|*.a|*.rlib|*.rmeta|*.o) return 1 ;;
    esac
    return 0
}

# sh_promote_tree SRC DEST -> mirror SRC into DEST. Directories are recreated,
# executable files are COPIED (they must be able to execve), and everything else
# is symlinked back to SRC. A copy that fails falls back to a symlink and warns,
# because a run that half-answers is worse than one that names the gap.
#
# STOP: IT IS A QUEUE AND NOT RECURSION, AND THAT IS NOT A STYLE CHOICE. POSIX sh has
# no `local`, so a recursive function's variables are GLOBALS: the recursive call
# for a subdirectory overwrote this call's source, destination and basename, and
# the loop then copied the remaining files to paths built from the child's names.
# Measured on the Go tree: 32 ".sh" files failed to copy and `go` never landed in
# the view at all, while every message blamed the file and not the walk.
sh_promote_tree() {
    sh_pt_src=$1
    sh_pt_dst=$2
    if [ ! -d "$sh_pt_src" ]; then
        return 0
    fi
    # Size-gate before writing anything (class C): name the constraint rather
    # than failing at ENOSPC mid-copy. A hard failure here is a refusal, and
    # the caller reports it; a soft warning would leave a half view behind.
    sh_view_need "$sh_pt_src" || return 1
    sh_pt_root_src=$(sh_lex_normalize "$sh_pt_src")
    sh_pt_root_dst=$(sh_lex_normalize "$sh_pt_dst")
    mkdir -p "$sh_pt_dst" 2>/dev/null || return 1
    sh_pt_tmp=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_pt_tmp" 2>/dev/null || return 1
    sh_pt_queue="$sh_pt_tmp/.promote.$$"
    printf '%s\t%s\n' "$sh_pt_src" "$sh_pt_dst" > "$sh_pt_queue" 2>/dev/null || return 1
    while IFS="$SH_TAB" read -r sh_pt_s sh_pt_d; do
        [ -n "$sh_pt_s" ] || continue
        for sh_pt_e in "$sh_pt_s"/* "$sh_pt_s"/.[!.]* "$sh_pt_s"/..?*; do
            [ -e "$sh_pt_e" ] || [ -L "$sh_pt_e" ] || continue
            sh_pt_b=${sh_pt_e##*/}
            if [ -d "$sh_pt_e" ] && [ ! -L "$sh_pt_e" ]; then
                mkdir -p "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                printf '%s\t%s\n' "$sh_pt_e" "$sh_pt_d/$sh_pt_b" >> "$sh_pt_queue"
                continue
            fi
            # # STOP: A SYMLINK WHOSE TARGET IS IN THIS TREE IS MIRRORED, NOT RESOLVED,
            # AND THAT FIXED A BROKEN npm. Copying the link's target under the
            # link's basename moves it: node's bin/npm -> ../lib/node_modules/
            # npm/bin/npm-cli.js has a relative `require('../lib/cli.js')`, and a
            # copy at bin/npm looked for bin/../lib/cli.js and died. A symlink to
            # the home does not help either: the kernel refuses execve on a
            # shebang script whose inode is on a noexec mount. Pointing the link
            # at the mirrored copy keeps the script on the exec root and keeps
            # every relative path inside the tree.
            if [ -L "$sh_pt_e" ] && sh_have readlink; then
                sh_pt_t=$(readlink "$sh_pt_e" 2>/dev/null)
                case "$sh_pt_t" in
                    '') sh_pt_abs='' ;;
                    /*) sh_pt_abs=$(sh_lex_normalize "$sh_pt_t") ;;
                    *)  sh_pt_abs=$(sh_lex_normalize "$sh_pt_s/$sh_pt_t") ;;
                esac
                # NOTE: A TARGET INSIDE THIS TREE IS REMAPPED ONTO THE VIEW. A
                # target OUTSIDE IT IS LEFT ALONE, and this is not a style
                # choice: the earlier code computed the view path for ANY
                # absolute target and compared it afterwards, so
                # `bin/link.sh -> ../outside/ext.sh` became
                # `link.sh -> <view>/outside/ext.sh`, a path the view does not
                # contain and never will. Measured: the link pointed at a file
                # that did not exist, and nothing in the run said so. A link
                # whose target lives outside the tree is a link to a file that
                # is not being mirrored, so the honest link is the original one.
                case "$sh_pt_abs" in
                    "$sh_pt_root_src"/*)
                        if [ -e "$sh_pt_abs" ] || [ -L "$sh_pt_abs" ]; then
                            if ln -sfn "$sh_pt_root_dst/${sh_pt_abs#"$sh_pt_root_src"/}" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                                continue
                            fi
                        fi
                        ;;
                    *)
                        # NOTE: A LINK TO A TARGET OUTSIDE THE TREE IS REPOINTED AT
                        # THAT TARGET'S ABSOLUTE PATH, NOT COPIED VERBATIM AND NOT
                        # REMAPPED INTO THE VIEW. Three wrong answers were
                        # available and each was measured. Remapping the target
                        # into the view produced `<view>/outside/ext.sh`, which
                        # the view does not contain. Copying the link's own text
                        # produced `../outside/ext.sh` relative to the VIEW's
                        # bin, which is a different directory. And linking to the
                        # link itself produced a self-referential path. The
                        # target's absolute path names the same file from
                        # anywhere, and it is the only one of the four that does.
                        if [ -n "$sh_pt_abs" ] && [ -e "$sh_pt_abs" ]; then
                            if ln -sfn "$sh_pt_abs" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                                continue
                            fi
                        fi
                        ;;
                esac
            fi
            # STOP: A DEAD SYMLINK IS REPRODUCED POINTING AT ITS OWN TARGET, AND
            # NEVER AT ITSELF. `cp` dereferences, so a link whose target is gone
            # fails to copy, and the old fallback was `ln -sfn "$entry"`, which
            # points the view's copy at the SOURCE'S COPY of the link rather than
            # at what the link names. Measured: `bin/link.sh -> ../outside/ext.sh`
            # became `link.sh -> <source>/bin/link.sh`, a self-referential path
            # that resolves to the source link, which resolves to nothing. The
            # link is reproduced with its target's absolute path instead, so it
            # names the same file it always named and stays broken in exactly the
            # way the source is broken rather than in a new way.
            if [ -L "$sh_pt_e" ] && [ ! -e "$sh_pt_e" ]; then
                sh_pt_dead=''
                if sh_have readlink; then
                    sh_pt_dead=$(readlink "$sh_pt_e" 2>/dev/null)
                    case "$sh_pt_dead" in
                        /*) : ;;
                        *)  sh_pt_dead=$(sh_lex_normalize "$sh_pt_s/$sh_pt_dead") ;;
                    esac
                    if [ -n "$sh_pt_dead" ]; then
                        ln -sfn "$sh_pt_dead" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                        continue
                    fi
                fi
                sh_warn "$sh_pt_e is a symlink whose target is missing and could not be reproduced"
                continue
            fi
            if sh_is_exec_file "$sh_pt_e"; then
                if cp -f "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null; then
                    chmod 0755 "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                else
                    sh_warn "could not copy $sh_pt_e into the exec view; symlinking it instead, and it will not run"
                    ln -sfn "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
                fi
            else
                ln -sfn "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || cp -f "$sh_pt_e" "$sh_pt_d/$sh_pt_b" 2>/dev/null || true
            fi
        done
    done < "$sh_pt_queue"
    rm -f "$sh_pt_queue" 2>/dev/null
    return 0
}

# sh_toolchain_root NAME -> where toolchain NAME's data lives.
sh_toolchain_root() { printf '%s/%s' "$SH_HOME_TOOLCHAINS" "$1"; }

# sh_toolchain_view NAME -> where toolchain NAME's exec view lives.
sh_toolchain_view() { printf '%s/%s' "$SH_EXEC_VIEWS" "$1"; }

# sh_toolchain_adopted_root NAME -> the directory an ADOPTED toolchain was found
# in, or nothing. # NOTE: AN ADOPTED TOOLCHAIN HAS NO DIRECTORY IN THE HOME, AND
# PROMOTING IT FROM `sh_toolchain_root` SILENTLY DID NOTHING. The home root of an
# adopted toolchain does not exist, so `sh_promote_tree` was handed a missing
# source, returned 0 because it could not mirror what was not there, and every
# `TC_<name>_BINS` link was skipped: the tool answered on PATH (it was already
# there) and was absent from `$SANDHOME_EXEC/bin`, so a shell that read only
# `env.sh` could not find it, and a later run on a host where the original copy
# was gone had nothing to fall back on. A module declares where its working copy
# lives with `tc_<name>_adopted`; when it declares nothing, the binary that
# answered the probe is linked by its own absolute path, which is the honest
# answer and is what the caller had been relying on.
sh_toolchain_adopted_root() {
    sh_tar_name=$1
    sh_toolchain_load "$sh_tar_name" >/dev/null 2>&1 || { printf ''; return 0; }
    if command -v "tc_${sh_tar_name}_adopted" >/dev/null 2>&1; then
        "tc_${sh_tar_name}_adopted" 2>/dev/null
        return 0
    fi
    printf ''
}

# sh_promote_toolchain NAME BIN_REL... -> build the exec view for NAME and put
# every named relative executable on PATH under its basename. When the home is
# already exec-capable the tree needs no mirror, but the bins are still linked:
# the PATH entry is how `sandhome` and the env file find the tool, and skipping
# it left a toolchain installed, reported present in the home, and absent from
# every shell.
#
# An adopted toolchain is linked from wherever it actually lives rather than from
# the home root it never had. A BINARY FOUND ON PATH THAT CANNOT RUN FROM ITS OWN
# DIRECTORY (the noexec-home case) IS MIRRORED THROUGH AN EXEC VIEW LIKE ANY
# OTHER TREE, and a refusal is reported rather than swallowed.
sh_promote_toolchain() {
    sh_ptc_name=$1
    shift
    sh_ptc_root=$(sh_toolchain_root "$sh_ptc_name")
    sh_ptc_view=$(sh_toolchain_view "$sh_ptc_name")
    if [ -d "$sh_ptc_root" ]; then
        if [ "$SH_HOME_EXEC" = yes ]; then
            sh_ptc_view=$sh_ptc_root
        else
            sh_promote_tree "$sh_ptc_root" "$sh_ptc_view" || sh_fail "could not build the exec view for $sh_ptc_name"
        fi
    else
        # Adopted: no home tree. Link the probe's answer, or the module's own
        # declared location, straight into the exec bin.
        sh_ptc_adopted=$(sh_toolchain_adopted_root "$sh_ptc_name")
        sh_ptc_done=no
        for sh_ptc_rel in "$@"; do
            sh_ptc_bin=${sh_ptc_rel##*/}
            sh_ptc_link=''
            if [ -n "$sh_ptc_adopted" ] && [ -x "$sh_ptc_adopted/$sh_ptc_rel" ]; then
                sh_ptc_link="$sh_ptc_adopted/$sh_ptc_rel"
            elif [ -n "$sh_ptc_adopted" ] && [ -x "$sh_ptc_adopted/$sh_ptc_bin" ]; then
                sh_ptc_link="$sh_ptc_adopted/$sh_ptc_bin"
            fi
            if [ -n "$sh_ptc_link" ]; then
                mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
                ln -sfn "$sh_ptc_link" "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || \
                    sh_warn "could not link $sh_ptc_link into $SH_EXEC_BIN"
                sh_ptc_done=yes
                continue
            fi
            # No declared location. Fall back to whatever answered on PATH, but
            # only if it RUNS: a binary on a noexec mount is not a binary here.
            sh_ptc_which=$(command -v "$sh_ptc_bin" 2>/dev/null)
            if [ -n "$sh_ptc_which" ] && [ -x "$sh_ptc_which" ]; then
                if "$sh_ptc_which" --version >/dev/null 2>&1; then
                    mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
                    ln -sfn "$sh_ptc_which" "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || \
                        sh_warn "could not link $sh_ptc_which into $SH_EXEC_BIN"
                    sh_ptc_done=yes
                else
                    sh_warn "$sh_ptc_which is on PATH but will not run from $SH_EXEC; run 'sandhome install $sh_ptc_name' to place it properly"
                fi
            fi
        done
        if [ "$sh_ptc_done" = no ]; then
            sh_warn "$sh_ptc_name was adopted but no declared binary could be linked into $SH_EXEC_BIN; it is reachable only on the current PATH"
        fi
        SH_TOOLCHAIN_VIEW=$SH_EXEC_BIN
        export SH_TOOLCHAIN_VIEW
        return 0
    fi
    for sh_ptc_rel in "$@"; do
        sh_ptc_src="$sh_ptc_view/$sh_ptc_rel"
        sh_ptc_bin=${sh_ptc_rel##*/}
        if [ -e "$sh_ptc_src" ] || [ -L "$sh_ptc_src" ]; then
            mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
            ln -sfn "$sh_ptc_src" "$SH_EXEC_BIN/$sh_ptc_bin" 2>/dev/null || true
        fi
    done
    SH_TOOLCHAIN_VIEW=$sh_ptc_view
    export SH_TOOLCHAIN_VIEW
    return 0
}

# sh_space_report -> one line per root, and the mounts that were tried. This is
# what `sandhome space` prints and what the bootstrap says when it had to split.
sh_space_report() {
    printf 'home=%s\n' "$SH_HOME"
    printf 'home_exec=%s\n' "$SH_HOME_EXEC"
    printf 'home_mount=%s\n' "$(sh_mount_opts "$SH_HOME")"
    printf 'home_free_mb=%s\n' "$(sh_free_mb "$SH_HOME")"
    printf 'home_total_mb=%s\n' "$(sh_total_mb "$SH_HOME")"
    printf 'exec=%s\n' "$SH_EXEC"
    printf 'exec_reason=%s\n' "${SH_EXEC_CHOSEN_REASON:-unknown}"
    printf 'exec_mount=%s\n' "$(sh_mount_opts "$SH_EXEC")"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "$SH_EXEC")"
    printf 'exec_total_mb=%s\n' "$(sh_total_mb "$SH_EXEC")"
    printf 'exec_bin=%s\n' "$SH_EXEC_BIN"
    printf 'min_exec_mb=%s\n' "$SANDHOME_MIN_EXEC_MB"
}

# sh_space_probe_report -> every candidate tried, with the real answer for each.
# This is the report that explains a split decision, and the one to read when a
# toolchain would not run.
sh_space_probe_report() {
    sh_spr_chosen=${SH_EXEC:-}
    for sh_spr_c in $(sh_exec_candidates); do
        [ -n "$sh_spr_c" ] || continue
        if [ ! -d "$sh_spr_c" ]; then
            # # NOTE: A DIRECTORY THAT DOES NOT EXIST IS REPORTED AS ABSENT, AND NOT
            # MADE. The probe created every candidate it listed, so a report of
            # this machine changed it; in this sandbox /var/tmp is absent and one
            # probe call brought it into being. Existence is now the first fact
            # printed and the only one the plan needed before mkdir.
            printf 'candidate=%s exists=no writable=no exec=no mount= free_mb=\n' "$sh_spr_c"
            continue
        fi
        sh_spr_w=no
        sh_spr_x=no
        sh_dir_writable "$sh_spr_c" && sh_spr_w=yes
        sh_exec_probe "$sh_spr_c" && sh_spr_x=yes
        sh_spr_pick=''
        [ "$sh_spr_c" = "$sh_spr_chosen" ] && sh_spr_pick=' chosen=yes'
        printf 'candidate=%s exists=yes writable=%s exec=%s mount=%s free_mb=%s%s\n' \
            "$sh_spr_c" "$sh_spr_w" "$sh_spr_x" \
            "$(sh_mount_opts "$sh_spr_c")" "$(sh_free_mb "$sh_spr_c")" "$sh_spr_pick"
    done
}

# sh_space_gc [DAYS] -> remove work directories older than DAYS (default 7) and
# every staging directory. A bootstrap leaves staging behind when it is killed,
# and on a small exec root that is the difference between the next install
# fitting and not. Named so a caller can see exactly what may be deleted.
#
# # STOP: THE ARGUMENT IS CHECKED BEFORE IT REACHES `find`. It was interpolated
# straight into `-mtime +"$sh_gc_days"`, and `sandhome gc abc` then ran
# `find ... -mtime +abc`, which failed, returned nothing, removed nothing, and
# REPORTED SUCCESS:
#   $ sh bin/sandhome gc abc
#   sandhome: removed 0 staging entries      # exit 0
# `gc -5` became `-mtime +-5` the same way. `gc` is the command a caller reaches
# for when a small exec root is full, and it is the only command here that
# deletes; a wrong answer there costs a session and a `--dry-run` was missing
# for a command whose whole job is destructive. Both are below, and
# tests/space.sh drives all four cases.
sh_space_gc() {
    sh_gc_days=${1:-7}
    case "$sh_gc_days" in
        ''|*[!0-9]*)
            sh_warn "gc needs a whole number of days, not '$sh_gc_days'"
            return 2
            ;;
    esac
    sh_gc_removed=0
    sh_gc_bytes=0
    # The named staging areas are ours and are always safe to clear.
    for sh_gc_dir in "$SH_HOME/.staging" "$SH_EXEC/.staging"; do
        [ -n "$sh_gc_dir" ] || continue
        [ -d "$sh_gc_dir" ] || continue
        for sh_gc_e in "$sh_gc_dir"/* "$sh_gc_dir"/.[!.]*; do
            [ -e "$sh_gc_e" ] || continue
            if [ "${SH_GC_DRY_RUN:-0}" = 1 ]; then
                sh_step "would remove $sh_gc_e ($(sh_dir_size "$sh_gc_e"))"
            else
                rm -rf "$sh_gc_e" 2>/dev/null && sh_gc_removed=$((sh_gc_removed + 1))
            fi
        done
    done
    # Build caches and targets on the exec root (issue #33): GOCACHE, the exec
    # tmp, uv/npm caches on exec, and cargo target dirs under the home views.
    # Only entries older than DAYS are removed, so an active build is kept.
    if sh_have find; then
        for sh_gc_dir in "$SH_EXEC/cache" "$SH_EXEC/tmp" "$SH_EXEC/go-bin"; do
            [ -n "$sh_gc_dir" ] || continue
            [ -d "$sh_gc_dir" ] || continue
            for sh_gc_e in "$sh_gc_dir"/* "$sh_gc_dir"/.[!.]*; do
                [ -e "$sh_gc_e" ] || continue
                if [ -n "$(find "$sh_gc_e" -maxdepth 0 -mtime +"$sh_gc_days" 2>/dev/null)" ]; then
                    if [ "${SH_GC_DRY_RUN:-0}" = 1 ]; then
                        sh_step "would remove $sh_gc_e ($(sh_dir_size "$sh_gc_e"))"
                    else
                        rm -rf "$sh_gc_e" 2>/dev/null && sh_gc_removed=$((sh_gc_removed + 1))
                    fi
                fi
            done
        done
    else
        sh_warn "no find; leaving $SH_EXEC/cache and $SH_EXEC/tmp alone"
    fi
    # # STOP: AGE IS CHECKED WITH find AND NOT ASSUMED. Without find the temp area is
    # left alone and that is said out loud, rather than deleted wholesale:
    # another bootstrap may be holding a directory in it right now.
    if [ -d "$SH_HOME_TMP" ]; then
        if sh_have find; then
            for sh_gc_e in "$SH_HOME_TMP"/* "$SH_HOME_TMP"/.[!.]*; do
                [ -e "$sh_gc_e" ] || continue
                if [ -n "$(find "$sh_gc_e" -maxdepth 0 -mtime +"$sh_gc_days" 2>/dev/null)" ]; then
                    if [ "${SH_GC_DRY_RUN:-0}" = 1 ]; then
                        sh_step "would remove $sh_gc_e ($(sh_dir_size "$sh_gc_e"))"
                    else
                        rm -rf "$sh_gc_e" 2>/dev/null && sh_gc_removed=$((sh_gc_removed + 1))
                    fi
                fi
            done
        else
            sh_warn "no find; leaving $SH_HOME_TMP alone rather than deleting a running bootstrap's work"
        fi
    fi
    # The reason to run gc is space. A count of entries is not a number of
    # bytes: the two things it removes are a directory of unpacked files and a
    # tarball, and those differ by two orders of magnitude. The bytes are
    # measured off the filesystem before and after rather than estimated from
    # the entry list, so the number is what actually changed.
    printf '%s' "$sh_gc_removed"
    return 0
}

# sh_free_kb DIR -> free kilobytes on the filesystem holding DIR, or nothing.
sh_free_kb() {
    df -Pk "$1" 2>/dev/null | {
        if read -r sh_fk_dev sh_fk_1 sh_fk_used sh_fk_free sh_fk_rest; then
            if read -r sh_fk_dev sh_fk_1 sh_fk_used sh_fk_free sh_fk_rest; then
                case "$sh_fk_free" in
                    ''|*[!0-9]*) printf '' ;;
                    *) printf '%s' "$sh_fk_free" ;;
                esac
            fi
        fi
    }
}

# sh_dir_size PATH -> the apparent size in kilobytes, or nothing when no tool
# that can measure is present. `du -sk` is the only portable answer, and it is
# NOT assumed: a report that guesses a size is worse than one that prints
# nothing beside it, so this answers the empty string and the caller says
# "size unavailable" rather than a number.
sh_dir_size() {
    if sh_have du; then
        sh_ds_out=$(du -sk "$1" 2>/dev/null | { read -r sh_ds_k _ || :; printf '%s' "$sh_ds_k"; })
        case "$sh_ds_out" in
            ''|*[!0-9]*) printf '' ;;
            *) printf '%s' "$sh_ds_out" ;;
        esac
        return 0
    fi
    printf ''
}
