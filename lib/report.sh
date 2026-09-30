#!/bin/sh
# report.sh - the report read from the machine, in text and in JSON. Sourced.
#
# NOTE: THE REPORT IS READ FROM THE MACHINE, NOT FROM WHAT WAS ASKED FOR. A line
# claiming a tool is present because an install command exited 0 is the class of
# claim this tree keeps finding to be false. Every line below probes.

SH_INSTALLED=''
SH_ADOPTED=''

sh_lead() { printf '%s' "${1# }"; }

# sh_toolchain_status NAME -> present|absent
sh_toolchain_status() {
    if sh_toolchain_probe "$1"; then
        printf 'present'
    else
        printf 'absent'
    fi
}

# sh_report_view -> launch, copy or mixed for this machine, read-only. The
# mode is a fact about the machine (split home plus a helper that probes
# here), not a memory of what installed it: SH_VIEW_MODE lives only in the
# installing process, so a fresh report would otherwise always say copy.
# sh_memexec_mode never builds, so the report changes nothing by asking.
#
# STOP: THE VIEWS ON DISK OUTRANK THE MACHINE MODE. A tree repaired under an
# explicit SANDHOME_VIEW_MODE=copy is real bytes while the machine still
# probes launch; saying `launch` there described the plan, not the tree
# (issue #113). Every installed tree whose bins are already linked is
# measured, and disagreement is reported as `mixed` rather than papered over.
sh_report_view() {
    sh_rv_mode=''
    if command -v sh_memexec_mode >/dev/null 2>&1; then
        sh_rv_mode=$(sh_memexec_mode 2>/dev/null) || sh_rv_mode=''
    fi
    [ -n "$sh_rv_mode" ] || sh_rv_mode=${SH_VIEW_MODE:-copy}
    if command -v sh_toolchain_view_measured >/dev/null 2>&1; then
        sh_rv_seen=''
        for sh_rv_t in $(sh_toolchain_available 2>/dev/null); do
            sh_rv_k=$(sh_toolchain_view_measured "$sh_rv_t" 2>/dev/null)
            case "$sh_rv_k" in
                mixed)
                    printf 'mixed'
                    return 0 ;;
                launch|copy)
                    if [ -z "$sh_rv_seen" ]; then
                        sh_rv_seen=$sh_rv_k
                    elif [ "$sh_rv_seen" != "$sh_rv_k" ]; then
                        printf 'mixed'
                        return 0
                    fi ;;
            esac
        done
        if [ -n "$sh_rv_seen" ]; then
            printf '%s' "$sh_rv_seen"
            return 0
        fi
    fi
    printf '%s' "$sh_rv_mode"
}

# sh_report_views_json -> a JSON object mapping each installed toolchain to
# its measured view kind (launch/copy/mixed/direct), or {} when nothing is
# installed. The global `view` field stays the summary for old readers; this
# is the breakdown the summary folds (issue #113). Only identifiers reach
# the object, so no escaping beyond the names themselves is needed.
sh_report_views_json() {
    sh_rvj_first=1
    printf '{'
    if command -v sh_toolchain_view_measured >/dev/null 2>&1; then
        for sh_rvj_t in $(sh_toolchain_available 2>/dev/null); do
            [ -d "$(sh_toolchain_root "$sh_rvj_t" 2>/dev/null)" ] || continue
            sh_rvj_k=$(sh_toolchain_view_measured "$sh_rvj_t" 2>/dev/null)
            [ -n "$sh_rvj_k" ] || continue
            if [ "$sh_rvj_first" = 1 ]; then
                sh_rvj_first=0
            else
                printf ','
            fi
            printf '"%s":"%s"' "$(sh_json_escape "$sh_rvj_t")" "$(sh_json_escape "$sh_rvj_k")"
        done
    fi
    printf '}'
}

# sh_report_memexec -> the one line sh_memexec_report prints, or `unknown`
# when the module is not loaded. Same guard as sh_report_view: drivers that
# source the report without memexec get a word, not a raw shell error.
sh_report_memexec() {
    if command -v sh_memexec_report >/dev/null 2>&1; then
        sh_memexec_report 2>/dev/null
    else
        printf 'unknown'
    fi
}

# sh_report_text -> the human report on stdout. Everything else is stderr.
#
# STOP: EVERY PROBE-DERIVED FIELD DEFAULTS BEFORE IT IS FORMATTED (issue #8).
# A probe that fails answers nothing, and an empty expansion under `set -u`
# aborts the report mid-object: the yabs defects behind this were an empty
# score producing malformed JSON and a parser error interleaved into a human
# table. Nothing here reads an unset variable, nothing interleaves a parser
# diagnostic into the value (those go to stderr), and the failures count is
# numeric or zero, so the object always parses.
sh_report_text() {
    printf 'os=%s\n'          "${SH_OS_ID:-unknown}"
    printf 'kernel=%s\n'      "${SH_KERNEL:-unknown}"
    printf 'arch=%s\n'        "${SH_ARCH:-unknown}"
    printf 'libc=%s\n'        "${SH_LIBC:-unknown}"
    printf 'wsl=%s\n'         "${SH_WSL:-unknown}"
    printf 'privilege=%s\n'   "${SH_PRIVILEGE:-none}"
    printf 'provider=%s\n'    "${SH_PROVIDER:-none}"
    printf 'pty=%s\n'         "${SH_PTY:-unknown}"
    printf 'passwd=%s\n'      "${SH_PASSWD:-unknown}"
    printf 'ptrace=%s\n'      "${SH_PTRACE:-unknown}"
    printf 'bind=%s\n'        "${SH_BIND:-unknown}"
    printf 'home=%s\n'        "${SH_HOME:-unknown}"
    printf 'home_exec=%s\n'   "${SH_HOME_EXEC:-unknown}"
    printf 'exec=%s\n'        "${SH_EXEC:-unknown}"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)"
    # The judgement, not just the number. `exec_free_mb=36` is a fact an agent
    # has to interpret; `exec_space=low` is the conclusion, and a report whose
    # whole job is to be read at a glance should carry it.
    printf 'exec_space=%s\n' "$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)"
    printf 'max_exec_free_mb=%s\n' "$(sh_space_max_exec_free 2>/dev/null)"
    printf 'exec_ceiling=%s\n' "$(sh_space_ceiling 2>/dev/null)"
    # The invoking shell, measured so a harness that spawns a non-login shell
    # per tool call sees what it needs: whether this shell is a login shell,
    # whether env.sh is already on this shell's PATH, and the exact one-liner
    # to load it. The operator otherwise discovers the asymmetry themselves
    # (issue #122). `login_shell` reads `shopt -q login_shell` under bash and
    # falls back to "unknown" elsewhere, because POSIX sh has no portable
    # login test and guessing would be the wrong answer.
    sh_rt_login=unknown
    if [ -n "${BASH_VERSION:-}" ]; then
        if shopt -q login_shell 2>/dev/null; then sh_rt_login=yes; else sh_rt_login=no; fi
    elif [ -n "${ZSH_VERSION:-}" ]; then
        case "${options[login]:-}" in on) sh_rt_login=yes ;; off) sh_rt_login=no ;; esac
    fi
    sh_rt_onpath=no
    case ":${PATH:-}:" in *":${SH_EXEC_BIN:-}:") sh_rt_onpath=yes ;; esac
    printf 'login_shell=%s\n' "$sh_rt_login"
    printf 'env_on_path=%s\n' "$sh_rt_onpath"
    printf 'entry=%s\n' "${SH_HOME:-unknown}/entry.sh"
    # The global hook: whether a fresh shell finds the environment with no
    # sourcing. Read from disk, so a report run after the exec root moved says
    # `stale:` rather than repeating what an install once claimed (issue #127).
    printf 'global=%s\n' "$(sh_global_report 2>/dev/null)"
    printf 'installed=%s\n'   "$(sh_lead "${SH_INSTALLED:-}")"
    printf 'adopted=%s\n'     "$(sh_lead "${SH_ADOPTED:-}")"
    # # STOP: THIS LINE PROBES THE DISK. It printed $SH_SHIMS_BUILT, which is
    # "built by this run", and so was empty on a second run (the .so was
    # already there), on a dry run (nothing was compiled, by design) and under
    # `sandhome report` (which never calls the builder). The two fields below
    # are the two different facts a reader needs, and neither of them is the
    # third one: what is present, and what this machine needs and does not have.
    printf 'shims=%s\n'       "$(sh_lead "$(sh_shim_present 2>/dev/null)")"
    printf 'shims_missing=%s\n' "$(sh_lead "$(sh_shim_needed_missing 2>/dev/null)")"
    printf 'shims_built_this_run=%s\n' "$(sh_lead "${SH_SHIMS_BUILT:-}")"
    printf 'view=%s\n' "$(sh_report_view 2>/dev/null)"
    printf 'memexec=%s\n' "$(sh_report_memexec 2>/dev/null)"
    # Per-toolchain measured views: the breakdown the global `view` folds.
    # A mixed tree names which entries are which without a second command.
    if command -v sh_toolchain_view_measured >/dev/null 2>&1; then
        for sh_rt_vt in $(sh_toolchain_available 2>/dev/null); do
            [ -d "$(sh_toolchain_root "$sh_rt_vt" 2>/dev/null)" ] || continue
            sh_rt_vk=$(sh_toolchain_view_measured "$sh_rt_vt" 2>/dev/null)
            [ -n "$sh_rt_vk" ] || continue
            printf 'view.%s=%s\n' "$sh_rt_vt" "$sh_rt_vk"
        done
    fi
    for sh_rt_name in $(sh_toolchain_available 2>/dev/null); do
        # TEXT ONLY, on purpose (judge finding 8-A): the JSON object carries no
        # toolchain map. A version is free text from the tool itself, and this
        # report is a key=value line format, so a hostile version can at worst
        # add lines here; the JSON side only ever carries escaped identifiers
        # and counts, so it deliberately excludes the one field that cannot be
        # constrained. A consumer who wants versions reads the text report or
        # runs `sandhome toolchains`.
        printf 'toolchain.%s=%s\n' "$sh_rt_name" "$(sh_toolchain_version "$sh_rt_name" 2>/dev/null)"
    done
    sh_rt_fail=${SH_FAILURES:-0}
    case "$sh_rt_fail" in
        ''|*[!0-9]*) sh_rt_fail=0 ;;
    esac
    printf 'failures=%s\n' "$sh_rt_fail"
}

# sh_report_json -> one JSON object. Only identifiers, names and counts reach
# it; every free-text message went to stderr.
sh_report_json() {
    sh_rj_fail=${SH_FAILURES:-0}
    case "$sh_rj_fail" in
        ''|*[!0-9]*) sh_rj_fail=0 ;;
    esac
    printf '{'
    printf '"schema":"sandhome/1"'
    printf ',"os":"%s","kernel":"%s","arch":"%s","libc":"%s","wsl":"%s"' \
        "$(sh_json_escape "${SH_OS_ID:-unknown}")" "$(sh_json_escape "${SH_KERNEL:-unknown}")" \
        "$(sh_json_escape "${SH_ARCH:-unknown}")" "$(sh_json_escape "${SH_LIBC:-unknown}")" \
        "$(sh_json_escape "${SH_WSL:-unknown}")"
    printf ',"privilege":"%s","provider":"%s","pty":"%s","passwd":"%s","ptrace":"%s","bind":"%s"' \
        "$(sh_json_escape "${SH_PRIVILEGE:-none}")" "$(sh_json_escape "${SH_PROVIDER:-none}")" \
        "$(sh_json_escape "${SH_PTY:-unknown}")" "$(sh_json_escape "${SH_PASSWD:-unknown}")" \
        "$(sh_json_escape "${SH_PTRACE:-unknown}")" "$(sh_json_escape "${SH_BIND:-unknown}")"
    printf ',"home":"%s","home_exec":"%s","exec":"%s","exec_free_mb":"%s","exec_space":"%s","max_exec_free_mb":"%s","exec_ceiling":"%s"' \
        "$(sh_json_escape "${SH_HOME:-unknown}")" "$(sh_json_escape "${SH_HOME_EXEC:-unknown}")" \
        "$(sh_json_escape "${SH_EXEC:-unknown}")" "$(sh_json_escape "$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_space_max_exec_free 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_space_ceiling 2>/dev/null)")"
    printf ',"installed":"%s","adopted":"%s","shims":"%s"' \
        "$(sh_json_escape "$(sh_lead "${SH_INSTALLED:-}")")" \
        "$(sh_json_escape "$(sh_lead "${SH_ADOPTED:-}")")" \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_present 2>/dev/null)")")"
    sh_rj_login=unknown
    if [ -n "${BASH_VERSION:-}" ]; then
        if shopt -q login_shell 2>/dev/null; then sh_rj_login=yes; else sh_rj_login=no; fi
    fi
    sh_rj_onpath=no
    case ":${PATH:-}:" in *":${SH_EXEC_BIN:-}:") sh_rj_onpath=yes ;; esac
    printf ',"login_shell":"%s","env_on_path":"%s","entry":"%s","global":"%s"' \
        "$(sh_json_escape "$sh_rj_login")" "$(sh_json_escape "$sh_rj_onpath")" \
        "$(sh_json_escape "${SH_HOME:-unknown}/entry.sh")" \
        "$(sh_json_escape "$(sh_global_report 2>/dev/null)")"
    printf ',"shims_missing":"%s","view":"%s","memexec":"%s"' \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_needed_missing 2>/dev/null)")")" \
        "$(sh_json_escape "$(sh_report_view 2>/dev/null)")" \
        "$(sh_json_escape "$(sh_report_memexec 2>/dev/null)")"
    # The per-toolchain breakdown beside the summary: old readers keep
    # reading `view`, new readers read `views` to see which entry is which.
    if command -v sh_report_views_json >/dev/null 2>&1; then
        printf ',"views":%s' "$(sh_report_views_json 2>/dev/null || printf '{}')"
    fi
    # The fields an agent needs before writing its first file (issue #88):
    # whether the current directory runs binaries, where build output must
    # go, and what to do next. next_action reads the exec-space state only;
    # readiness itself is doctor's job, not the report's.
    sh_rj_wd=${PWD:-.}
    sh_rj_wd_noexec=no
    sh_exec_probe "$sh_rj_wd" 2>/dev/null || sh_rj_wd_noexec=yes
    sh_rj_space=$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)
    case "$sh_rj_space" in
        ok) sh_rj_next="build under ${SH_EXEC:-.}" ;;
        unknown) sh_rj_next="run 'sandhome space --probe': the exec root cannot be measured" ;;
        *) sh_rj_next="run 'sandhome gc', then re-run the setup with '--exec DIR' on a roomy exec-capable path" ;;
    esac
    printf ',"workdir":"%s","workdir_noexec":"%s","build_root":"%s","next_action":"%s"' \
        "$(sh_json_escape "$sh_rj_wd")" "$sh_rj_wd_noexec" \
        "$(sh_json_escape "${SH_EXEC:-unknown}")" "$(sh_json_escape "$sh_rj_next")"
    printf ',"failures":%s}\n' "$sh_rj_fail"
}

# sh_doctor -> probe the things a working sandhome must have and report. It
# never repairs; the bootstrap does that. It prints one line per invariant and
# ends with `doctor_failures=N`, and it EXITS NON-ZERO when N is not zero. It
# does not exit with N: an exit status is one byte, and a value above 125
# truncates, so a machine with 130 broken invariants would answer 5 and a caller
# that read the status as the count would under-report. The count is printed and
# the status is 0 or 1.
#
# NOTE: EVERY INVARIANT IS CHECKED, INCLUDING THE ONES THAT ARE OFF BY DEFAULT.
# The shim checks were guarded by `if [ "$SH_PTY" = no ]`: on a machine with a
# pty they are simply absent, which is right, but the check for a machine with
# a pty and no shim directory was never made, and the shim is only built when it
# is needed. A machine where the shim WAS needed and the build failed therefore
# showed a clean report. Every needed shim is now a hard invariant, and a
# shim that is present but was built for the wrong libc is named.
sh_doctor() {
    sh_doc_fail=0
    # SH_DOCTOR_JSON=1 collects machine-readable members instead of prose:
    # each check appends "name":"got" to SH_DOCTOR_MEMBERS and each miss
    # appends its name to SH_DOCTOR_FAILED; the tail wraps the object.
    # Prose notes (workdir hints, restart hints) are human text: in JSON mode
    # they go to stderr, and their facts live in report --json fields instead.
    if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
        SH_DOCTOR_MEMBERS=''
        SH_DOCTOR_FAILED=''
        export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
    fi
    sh_doctor_check() {
        sh_dc_name=$1
        sh_dc_got=$2
        sh_dc_want=$3
        if [ "$sh_dc_got" = "$sh_dc_want" ]; then
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"$sh_dc_name\":\"$(sh_json_escape "$sh_dc_got")\""
                export SH_DOCTOR_MEMBERS
            else
                printf 'ok   %s=%s\n' "$sh_dc_name" "$sh_dc_got"
            fi
        else
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"$sh_dc_name\":\"$(sh_json_escape "$sh_dc_got")\""
                SH_DOCTOR_FAILED="$SH_DOCTOR_FAILED,\"$sh_dc_name\""
                export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
            else
                printf 'FAIL %s=%s (wanted %s)\n' "$sh_dc_name" "$sh_dc_got" "$sh_dc_want"
            fi
            sh_doc_fail=$((sh_doc_fail + 1))
        fi
    }
    sh_doctor_check home_writable "$(sh_dir_writable "$SH_HOME" && printf yes || printf no)" yes
    sh_doctor_check exec_writable "$(sh_dir_writable "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_runs "$(sh_exec_probe "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_on_path "$(case ":$PATH:" in *":$SH_EXEC_BIN:"*) printf yes ;; *) printf no ;; esac)" yes
    sh_doctor_check env_file "$([ -r "$SH_HOME/env.sh" ] && printf yes || printf no)" yes
    # The working tree may itself be noexec (issue #24): build output there
    # fails at run time with Permission denied, which reads as an install bug.
    # This is informational, never a failure: the fix is to build under
    # SANDHOME_EXEC, not to move the project.
    #
    # The note names the two shapes that read as a BROKEN INSTALL rather than a
    # noexec mount, because neither is obvious and both were measured (issue #42).
    # A per-project venv half-works: bin/python is a symlink to an exec-capable
    # system python, so `.venv/bin/python -m x` runs, while every console script
    # has an absolute shebang into the noexec tree and dies with
    #   .venv/bin/cowsay: .venv/bin/python: bad interpreter: Permission denied
    # The same for node: `npm install` exits 0, and ./node_modules/.bin/CLI dies
    # the same way while `node node_modules/CLI/index.js` works. The remedy is
    # one command, not two incantations: `sandhome project` puts the project
    # on the exec root with its venv inside it (where its shebangs resolve)
    # and links ./NAME back to it.
    sh_doc_cwd=${PWD:-.}
    # Notes stay prose-only: in JSON mode they are skipped, and their facts
    # (workdir noexec, cleared exec root) live in report --json fields.
    if [ "${SH_DOCTOR_JSON:-0}" != 1 ] && ! sh_exec_probe "$sh_doc_cwd" 2>/dev/null; then
        printf 'note   workdir=%s is noexec; build and run output under %s\n' "$sh_doc_cwd" "${SH_EXEC:-.}"
        printf 'note   a .venv or node_modules here half-works: python -m runs, but every\n'
        printf 'note     console script has a shebang into this tree and exits "bad\n'
        printf 'note     interpreter: Permission denied". One command does the dance:\n'
        printf 'note     sandhome project NAME [--python|--node]\n'
    fi
    # A cleared tmpfs exec root (container restart) leaves a valid env.sh with
    # no sandhome on it. Name the state rather than failing silently.
    # STOP: THE SECOND COMMAND IS REPAIR-IF-STILL-BROKEN, NEVER INSTALL (issue
    # #62). Re-running the setup rebuilds the view on its own (measured: 5s,
    # doctor 0, no follow-up), and `install <name>` re-runs the adopt path that
    # broke 8 views in 8 rounds (#49, #43).
    if [ "${SH_DOCTOR_JSON:-0}" != 1 ] && [ ! -x "$SH_EXEC_BIN/sandhome" ] && [ -r "$SH_HOME/repo/bin/sandhome" ]; then
        printf 'note   exec root was cleared (tmpfs restart); re-run the setup, then run sandhome repair only if doctor still fails\n'
    fi
    # The work tree names its own missing build tool, with the exact next
    # command, so a `cmake: command not found` after a green doctor never needs
    # knowing that `sandhome add --url` exists (issue #123). These are notes,
    # never failures: doctor gates what the setup asked for, and the work tree
    # is what the caller pasted after it. Each marker is checked against the
    # probe, not against the wanted list, because a `--toolset developer` run
    # in a CMake checkout wants cmake even though it never named it.
    if [ "${SH_DOCTOR_JSON:-0}" != 1 ]; then
        sh_doc_wd=${PWD:-.}
        if [ -e "$sh_doc_wd/CMakeLists.txt" ] || [ -e "$sh_doc_wd/CMakePresets.json" ]; then
            if ! sh_have cmake; then
                printf 'note   CMakeLists.txt here but cmake is not on PATH; run: sandhome install cmake\n'
            fi
        fi
        if [ -e "$sh_doc_wd/meson.build" ]; then
            if ! sh_have meson; then
                printf 'note   meson.build here but meson is not on PATH; run: sandhome install meson\n'
            fi
        fi
        if [ -e "$sh_doc_wd/configure.ac" ]; then
            if ! sh_have pkgconf && ! sh_have pkg-config; then
                printf 'note   configure.ac here but neither pkgconf nor pkg-config is on PATH; run: sandhome install pkgconf\n'
            fi
            if ! sh_have perl; then
                printf 'note   configure.ac here but perl is not on PATH; run: sandhome install perl\n'
            fi
        fi
        if [ -e "$sh_doc_wd/Makefile" ] || [ -e "$sh_doc_wd/makefile" ] || [ -e "$sh_doc_wd/GNUmakefile" ]; then
            if ! sh_have cmake && ([ -e "$sh_doc_wd/CMakeLists.txt" ] || [ -e "$sh_doc_wd/CMakePresets.json" ]); then
                printf 'note   build files here but cmake is not on PATH; run: sandhome install cmake\n'
            fi
        fi
    fi
    # A needed shim that is not there is a failure even when the machine looks
    # like it does not need it, because a shim built by an earlier run and a
    # shim needed by this run are the same directory.
    sh_doc_shim_dir=$(sh_shims_dir)
    if [ "${SH_PTY:-unknown}" = no ] || [ -f "$sh_doc_shim_dir/fakepty.so" ]; then
        sh_doctor_check fakepty_built \
            "$([ -f "$sh_doc_shim_dir/fakepty.so" ] && printf yes || printf no)" yes
    fi
    if [ "${SH_PASSWD:-unknown}" = no ] || [ -f "$sh_doc_shim_dir/fakepwd.so" ]; then
        sh_doctor_check fakepwd_built \
            "$([ -f "$sh_doc_shim_dir/fakepwd.so" ] && printf yes || printf no)" yes
        sh_doctor_check fakepwd_database \
            "$([ -r "$sh_doc_shim_dir/passwd" ] && printf yes || printf no)" yes
    fi
    # antiptrace is doctor-checked the same way: present when the machine denies
    # ptrace (wholly or partly), or when an earlier run built it here and the
    # file is the same one a program will load.
    if [ "${SH_PTRACE:-unknown}" = no ] || [ "${SH_PTRACE:-unknown}" = partial ] || [ -f "$sh_doc_shim_dir/antiptrace.so" ]; then
        sh_doctor_check antiptrace_built \
            "$([ -f "$sh_doc_shim_dir/antiptrace.so" ] && printf yes || printf no)" yes
    fi
    # The headless shims share one rule instead of four blocks: needed here,
    # or built by an earlier run, means present is required.
    for sh_doc_shim in fakedrm fakeinput fakexenv fakedisplay; do
        if [ "$(sh_shim_need "$sh_doc_shim")" = yes ] || [ -f "$sh_doc_shim_dir/$sh_doc_shim.so" ]; then
            sh_doctor_check "${sh_doc_shim}_built" \
                "$([ -f "$sh_doc_shim_dir/$sh_doc_shim.so" ] && printf yes || printf no)" yes
        fi
    done
    # The exec view must exist, and every toolchain that was installed must
    # still answer. `report` prints a version per toolchain; doctor turns the
    # empty ones into failures, because a version that is empty is a toolchain
    # that is not reachable and the report alone does not say so.
    if [ -d "$SH_EXEC_VIEWS" ]; then
        # # STOP: THE REQUESTED LIST IS READ FROM env.sh, NOT FROM THE
        # ENVIRONMENT. `sh_env_load` sources prefs.sh and env.d/ but not env.sh
        # - deliberately, because env.sh rewrites PATH and SANDHOME_* and
        # loading it from inside a command is how a value gets set twice. So a
        # fresh `sandhome doctor` has SANDHOME_WANTED_TOOLCHAINS unset even
        # though the file records it, and reading the variable was reading
        # nothing. It is read here with the shell's own read, the way
        # sh_space_recorded_exec reads the exec root, because the library may not
        # use grep and this is the same question: what does the file say.
        sh_doc_wanted_all=''
        sh_doc_cr=$(printf '\r')
        if [ -r "$SH_HOME/env.sh" ]; then
            while IFS= read -r sh_doc_wl; do
                sh_doc_wl=${sh_doc_wl%"$sh_doc_cr"}
                case "$sh_doc_wl" in
                    SANDHOME_WANTED_TOOLCHAINS=*)
                        sh_doc_wanted_all=${sh_doc_wl#SANDHOME_WANTED_TOOLCHAINS=}
                        sh_doc_wanted_all=${sh_doc_wanted_all#\'}
                        sh_doc_wanted_all=${sh_doc_wanted_all%\'}
                        sh_doc_wanted_all=${sh_doc_wanted_all#\"}
                        sh_doc_wanted_all=${sh_doc_wanted_all%\"}
                        ;;
                esac
            done < "$SH_HOME/env.sh"
        fi
        for sh_doc_t in $(sh_toolchain_available); do
            sh_doc_wanted=no
            case " $sh_doc_wanted_all " in
                *" $sh_doc_t "*) sh_doc_wanted=yes ;;
            esac
            case " $(sh_lead "$INSTALLED") $(sh_lead "$ADOPTED") " in
                *" $sh_doc_t "*) sh_doc_wanted=yes ;;
            esac
            # A toolchain the setup ASKED FOR is checked even when neither
            # INSTALLED nor ADOPTED names it. Those two are this run's variables
            # and are empty in a fresh process, so the loop used to skip every
            # toolchain and report a green readiness gate over a setup that had
            # just said it could not install five of eleven (issue #38). A name
            # in neither list is still skipped, because `languages` being
            # installed says nothing about whether a consumer who never asked
            # for it wants clang.
            [ "$sh_doc_wanted" = yes ] || continue
            sh_doc_version=$(sh_toolchain_version "$sh_doc_t")
            sh_doctor_check "toolchain_$sh_doc_t" \
                "$([ -n "$sh_doc_version" ] && printf yes || printf no)" yes
        done
    fi
    # # STOP: EVERY BINARY THE REPORT ADVERTISES MUST BE THERE AND MUST RUN.
    # `doctor` is the readiness gate ROUTE.md step 2 tells a session to trust
    # ("when the check at the end of this step exits 0, the sandbox is ready:
    # do the task"), and it was answering that question about the two roots and
    # the shims only. On a host where the toolset was adopted it exited 0 while
    # GOBIN, GOCACHE, CARGO_INSTALL_ROOT and NPM_CONFIG_PREFIX were unset and
    # `go install` produced a binary that neither ran nor reached PATH, and it
    # stayed green while jq, rg and fd were self-symlinks in the exec view and
    # every one of them exited 126 (issues #43, #45, #47).
    #
    # The two loops below close both gaps. The first is the exec view: a link
    # that does not resolve, or resolves to itself, is a tool that is not there
    # however green the root checks are. The second is the env file: a variable
    # ROUTE.md step 4 says "already point[s] there" and does not is a promise
    # the consumer is told to rely on.
    if [ -d "$SH_EXEC_BIN" ]; then
        for sh_doc_link in "$SH_EXEC_BIN"/*; do
            [ -e "$sh_doc_link" ] || [ -L "$sh_doc_link" ] || continue
            sh_doc_name=${sh_doc_link##*/}
            sh_doc_real=$(sh_dirname "$sh_doc_link")
            sh_doc_target=$(readlink "$sh_doc_link" 2>/dev/null || printf '')
            # A symlink whose target is its own path is the defect in #43 and it
            # is invisible to [ -e ] on a shell that follows the link silently.
            if [ -n "$sh_doc_target" ] && [ "$sh_doc_target" = "$sh_doc_link" ]; then
                printf 'FAIL exec_link_%s=broken (links to itself)\n' "$sh_doc_name"
                sh_doc_fail=$((sh_doc_fail + 1))
                continue
            fi
            if [ ! -x "$sh_doc_link" ]; then
                printf 'FAIL exec_link_%s=broken (not executable)\n' "$sh_doc_name"
                sh_doc_fail=$((sh_doc_fail + 1))
            fi
        done
    fi
    for sh_doc_var in GOBIN GOCACHE CARGO_INSTALL_ROOT NPM_CONFIG_PREFIX; do
        sh_doc_want_exec=''
        case " $(sh_lead "$ADOPTED") $(sh_lead "$INSTALLED") " in
            *" go "*)      sh_doc_want_exec=yes ;;
            *" rust "*)    sh_doc_want_exec=yes ;;
            *" node "*)    sh_doc_want_exec=yes ;;
        esac
        [ -n "$sh_doc_want_exec" ] || continue
        sh_doc_got=$(eval "printf '%s' \"\${$sh_doc_var:-}\"")
        case "$sh_doc_got" in
            "$SH_EXEC"/*) : ;;
            *)
                printf 'FAIL %s=unset (expected under %s; run sandhome install --force <name>)\n' \
                    "$sh_doc_var" "$SH_EXEC"
                sh_doc_fail=$((sh_doc_fail + 1)) ;;
        esac
    done
    # # STOP: A ROOT THAT IS DRAINING IS A FAILURE, AND IT IS NAMED IN WORDS.
    # `doctor` is the command ROUTE.md step 2 makes a session run to decide
    # whether the sandbox is ready, so it is the only place an agent is
    # guaranteed to look. It printed exec_free_mb and said nothing about it, and
    # on this host at 86% full it printed `doctor_failures=0`:
    #   df: /dev/shm 245MB total, 36MB free
    #   go build -o $SANDHOME_EXEC/x .  ->  no space left on device, exit 0
    # The failure is not hypothetical and it is not rare: the exec root holds
    # GOCACHE, GOBIN, CARGO_*, NPM_* and every build artifact, so it is the
    # first thing a real project fills.
    #
    # low is a FAILURE too, not a note. A low root still works, and the point of
    # hearing about it is that it works NOW and does not after the next install.
    # A note is read and dismissed; a non-zero exit is read.
    sh_doc_space=$(sh_space_status "${SH_EXEC:-/tmp}" 2>/dev/null)
    case "$sh_doc_space" in
        ok) ;;
        unknown)
            # # STOP: AN UNREADABLE ROOT IS A FINDING, NOT A PASS. `df` failing on
            # the exec root means nothing can be measured about the one place
            # every build artifact has to land, and the tree's own rule is that a
            # question the machine will not answer is reported rather than
            # assumed ("a read-only plan refuses by name rather than dying",
            # "an empty answer rather than a wrong one"). Treating it as ok is the
            # exact shape of the defect this change exists to remove: a silent
            # pass on the thing that was not measured.
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"exec_space\":\"unknown\""
                SH_DOCTOR_FAILED="$SH_DOCTOR_FAILED,\"exec_space\""
                export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
            else
                printf 'FAIL exec_space=unknown (df could not measure %s; builds may fail with "no space left on device". Run "sandhome space --probe" to see the candidates)\n' "${SH_EXEC:-/tmp}"
            fi
            sh_doc_fail=$((sh_doc_fail + 1)) ;;
        *)
            sh_doc_free=$(sh_free_mb "${SH_EXEC:-/tmp}" 2>/dev/null)
            case "$sh_doc_free" in ''|*[!0-9]*) sh_doc_free='?' ;; esac
            # `du` before `gc`, for the reason the adviser carries: on a root
            # full of build output `gc` reclaims nothing, and it was measured
            # that way here. The one line names the biggest thing on the root
            # and the space it is worth.
            if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
                SH_DOCTOR_MEMBERS="$SH_DOCTOR_MEMBERS,\"exec_space\":\"$sh_doc_space\""
                SH_DOCTOR_FAILED="$SH_DOCTOR_FAILED,\"exec_space\""
                export SH_DOCTOR_MEMBERS SH_DOCTOR_FAILED
            else
                printf 'FAIL exec_space=%s (%sMB free; builds and installs will fail. "du -sh %s/* | sort -h | tail" names what holds it, "sandhome gc" reclaims the caches sandhome owns, and re-running setup with --exec DIR moves everything. See "sandhome space --probe" for candidates)\n' \
                    "$sh_doc_space" "$sh_doc_free" "${SH_EXEC:-/tmp}"
            fi
            sh_doc_fail=$((sh_doc_fail + 1)) ;;
    esac
    if [ "${SH_DOCTOR_JSON:-0}" = 1 ]; then
        printf '{"failures":%s,"failed":[%s],"checks":{%s}}\n' \
            "$sh_doc_fail" "${SH_DOCTOR_FAILED#,}" "${SH_DOCTOR_MEMBERS#,}"
    else
        printf 'doctor_failures=%s\n' "$sh_doc_fail"
    fi
    unset -f sh_doctor_check
    [ "$sh_doc_fail" -gt 0 ] && return 1
    return 0
}
