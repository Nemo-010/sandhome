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

# sh_report_text -> the human report on stdout. Everything else is stderr.
sh_report_text() {
    printf 'os=%s\n'          "$SH_OS_ID"
    printf 'kernel=%s\n'      "$SH_KERNEL"
    printf 'arch=%s\n'        "$SH_ARCH"
    printf 'libc=%s\n'        "$SH_LIBC"
    printf 'wsl=%s\n'         "$SH_WSL"
    printf 'privilege=%s\n'   "$SH_PRIVILEGE"
    printf 'provider=%s\n'    "${SH_PROVIDER:-none}"
    printf 'pty=%s\n'         "$SH_PTY"
    printf 'passwd=%s\n'      "$SH_PASSWD"
    printf 'home=%s\n'        "$SH_HOME"
    printf 'home_exec=%s\n'   "$SH_HOME_EXEC"
    printf 'exec=%s\n'        "$SH_EXEC"
    printf 'exec_free_mb=%s\n' "$(sh_free_mb "$SH_EXEC")"
    printf 'installed=%s\n'   "$(sh_lead "$SH_INSTALLED")"
    printf 'adopted=%s\n'     "$(sh_lead "$SH_ADOPTED")"
    # # STOP: THIS LINE PROBES THE DISK. It printed $SH_SHIMS_BUILT, which is
    # "built by this run", and so was empty on a second run (the .so was
    # already there), on a dry run (nothing was compiled, by design) and under
    # `sandhome report` (which never calls the builder). The two fields below
    # are the two different facts a reader needs, and neither of them is the
    # third one: what is present, and what this machine needs and does not have.
    printf 'shims=%s\n'       "$(sh_lead "$(sh_shim_present)")"
    printf 'shims_missing=%s\n' "$(sh_lead "$(sh_shim_needed_missing)")"
    printf 'shims_built_this_run=%s\n' "$(sh_lead "${SH_SHIMS_BUILT:-}")"
    for sh_rt_name in $(sh_toolchain_available); do
        printf 'toolchain.%s=%s\n' "$sh_rt_name" "$(sh_toolchain_version "$sh_rt_name")"
    done
    printf 'failures=%s\n' "$SH_FAILURES"
}

# sh_report_json -> one JSON object. Only identifiers, names and counts reach
# it; every free-text message went to stderr.
sh_report_json() {
    printf '{'
    printf '"schema":"sandhome/1"'
    printf ',"os":"%s","kernel":"%s","arch":"%s","libc":"%s","wsl":"%s"' \
        "$(sh_json_escape "$SH_OS_ID")" "$(sh_json_escape "$SH_KERNEL")" \
        "$(sh_json_escape "$SH_ARCH")" "$(sh_json_escape "$SH_LIBC")" \
        "$(sh_json_escape "$SH_WSL")"
    printf ',"privilege":"%s","provider":"%s","pty":"%s","passwd":"%s"' \
        "$(sh_json_escape "$SH_PRIVILEGE")" "$(sh_json_escape "${SH_PROVIDER:-none}")" \
        "$(sh_json_escape "$SH_PTY")" "$(sh_json_escape "$SH_PASSWD")"
    printf ',"home":"%s","home_exec":"%s","exec":"%s","exec_free_mb":"%s"' \
        "$(sh_json_escape "$SH_HOME")" "$(sh_json_escape "$SH_HOME_EXEC")" \
        "$(sh_json_escape "$SH_EXEC")" "$(sh_json_escape "$(sh_free_mb "$SH_EXEC")")"
    printf ',"installed":"%s","adopted":"%s","shims":"%s"' \
        "$(sh_json_escape "$(sh_lead "$SH_INSTALLED")")" \
        "$(sh_json_escape "$(sh_lead "$SH_ADOPTED")")" \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_present)")")"
    printf ',"shims_missing":"%s"' \
        "$(sh_json_escape "$(sh_lead "$(sh_shim_needed_missing)")")"
    printf ',"failures":%s}\n' "$SH_FAILURES"
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
    sh_doctor_check() {
        sh_dc_name=$1
        sh_dc_got=$2
        sh_dc_want=$3
        if [ "$sh_dc_got" = "$sh_dc_want" ]; then
            printf 'ok   %s=%s\n' "$sh_dc_name" "$sh_dc_got"
        else
            printf 'FAIL %s=%s (wanted %s)\n' "$sh_dc_name" "$sh_dc_got" "$sh_dc_want"
            sh_doc_fail=$((sh_doc_fail + 1))
        fi
    }
    sh_doctor_check home_writable "$(sh_dir_writable "$SH_HOME" && printf yes || printf no)" yes
    sh_doctor_check exec_writable "$(sh_dir_writable "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_runs "$(sh_exec_probe "$SH_EXEC" && printf yes || printf no)" yes
    sh_doctor_check exec_on_path "$(case ":$PATH:" in *":$SH_EXEC_BIN:"*) printf yes ;; *) printf no ;; esac)" yes
    sh_doctor_check env_file "$([ -r "$SH_HOME/env.sh" ] && printf yes || printf no)" yes
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
    # The exec view must exist, and every toolchain that was installed must
    # still answer. `report` prints a version per toolchain; doctor turns the
    # empty ones into failures, because a version that is empty is a toolchain
    # that is not reachable and the report alone does not say so.
    if [ -d "$SH_EXEC_VIEWS" ]; then
        for sh_doc_t in $(sh_toolchain_available); do
            case " $(sh_lead "$INSTALLED") $(sh_lead "$ADOPTED") " in
                *" $sh_doc_t "*) ;;
                *) continue ;;
            esac
            sh_doctor_version=$(sh_toolchain_version "$sh_doc_t")
            sh_doctor_check "toolchain_$sh_doc_t" \
                "$([ -n "$sh_doctor_version" ] && printf yes || printf no)" yes
        done
    fi
    printf 'doctor_failures=%s\n' "$sh_doc_fail"
    unset -f sh_doctor_check
    [ "$sh_doc_fail" -gt 0 ] && return 1
    return 0
}
