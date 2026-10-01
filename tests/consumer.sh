#!/bin/sh
# tests/consumer.sh - the ROUTE.md journey, end to end, as a consumer with
# nothing pre-sourced: one bootstrap, then every later command in a FRESH
# `env -i` shell, a wipe of the exec root, and a resume. This is the guard
# for issue #127 (a fresh shell must find the environment with nothing in
# front of the command) and for the resume round trip a tmpfs restart needs.
#
# Nothing here exports SANDHOME_* for the consumer steps: only HOME and PATH
# are given, because that is what a fresh shell actually has. The dispatch
# cost numbers and the shell-diversity matrix live in the session proof
# (consumer-proof/proof.log); this test asserts the properties, not the
# timings, so it can run on any host the suite runs on.

. "$(dirname -- "$0")/lib.sh"

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

t_begin 'consumer'
command -v jq >/dev/null 2>&1 || { t_skip 'this host has no jq on PATH, so the minimal toolset cannot be adopted offline'; t_end; }

# A home root that refuses execve, the shape this project exists for. Probed,
# never assumed; when the host has no such mount the journey still runs and
# the symlink assertions below still hold, because the hook entry itself is
# absent rather than a directory in either case.
noexec_base=''
for c in /tmp /dev/shm /state/home "${TMPDIR:-}"; do
    [ -n "$c" ] && [ -d "$c" ] || continue
    printf '#!/bin/sh\nexit 0\n' > "$c/.sandhome.ncprobe.$$" 2>/dev/null || continue
    chmod 0700 "$c/.sandhome.ncprobe.$$" 2>/dev/null
    if "$c/.sandhome.ncprobe.$$" >/dev/null 2>&1; then
        rm -f "$c/.sandhome.ncprobe.$$" 2>/dev/null
        continue
    fi
    rm -f "$c/.sandhome.ncprobe.$$" 2>/dev/null
    [ -z "$noexec_base" ] && noexec_base=$c
done
[ -n "$noexec_base" ] || noexec_base=$(t_exec_tmpdir sandhome-home-base)

home=$noexec_base/.sandhome-consumer.$$
wsbin=$(t_exec_tmpdir sandhome-consumer-wsbin) || exit 1
exec_root=$(t_exec_tmpdir sandhome-consumer-exec) || exit 1
wsbin=$wsbin/wsbin
exec_root=$exec_root/exec
mkdir -p "$home" "$wsbin"
homebin=$home/bin
cpath="$homebin:$wsbin:/usr/bin:/bin"
rm -rf "$exec_root"
fresh() { # fresh SHELL-PROG ARGS... : env -i with only HOME and PATH
    fc_p=$1; shift
    env -i HOME="$home" PATH="$cpath" "$fc_p" "$@" </dev/null
}

# ------------------------------------------------- failing before ----------
# NOTE: dash's `command -v` exits 127 for a missing command (other shells use
# 1), so the contract asserted here is presence/absence, not an exit code.
c_out=$(fresh sh -c 'command -v sandhome >/dev/null 2>&1; [ $? -ne 0 ] && printf absent || printf found')
t_is "$c_out" 'absent' 'before setup, a fresh shell has no sandhome'
t_is "$([ -r "$home/.local/share/sandhome/env.sh" ] && printf yes || printf no)" 'no' \
     'before setup, there is no environment file'

# ------------------------------------------------- the one setup -----------
c_out=$(
    cd "$ROOT" || exit 1
    env -i HOME="$home" PATH="$cpath" TMPDIR="${TMPDIR:-/tmp}" \
        sh bootstrap.sh --toolset minimal --exec "$exec_root" 2>&1
)
c_rc=$?
t_is "$c_rc" '0' 'the bootstrap exits 0 (ROUTE step 2)'
t_contains "$c_out" 'global hook' 'the bootstrap says it installed the global hook'

# ------------------------------------------------- fresh shells ------------
c_out=$(fresh sh -c 'command -v sandhome; printf "rc=%s\n" "$?"')
t_contains "$c_out" "$homebin/sandhome" 'a fresh shell finds sandhome through the hook'
c_out=$(fresh sh -c 'sandhome doctor; printf "doctor rc=%s\n" "$?"')
t_contains "$c_out" 'doctor_failures=0' 'doctor is green in a fresh shell with nothing sourced'
t_contains "$c_out" 'doctor rc=0' 'doctor exits 0 in a fresh shell'
c_out=$(fresh sh -c 'sandhome status')
t_contains "$c_out" 'ready=yes' 'status reports ready in a fresh shell'

# The no-source proof, two halves. The SHELL started with env -i and read no
# file, so it sees no environment; a TOOL run by name goes through the hook,
# and jq prints the environment IT inherited. jq is the witness because the
# dispatcher must have sourced env.sh for the path to be there at all.
c_out=$(fresh sh -c 'printf "shell=[%s] " "${SANDHOME_EXEC:-unset}"; jq -n "\$ENV.SANDHOME_EXEC"')
t_contains "$c_out" 'shell=[unset]' 'the shell itself still has no environment'
t_contains "$c_out" "$exec_root" 'the dispatched tool carries the environment'

# Every recorded directory serves a fresh shell on its own: any one of them
# being correct is the redundancy the hook buys.
c_status=$(fresh sh -c 'sandhome global --status')
t_contains "$c_status" 'global_dirs=2' 'both qualifying PATH entries were hooked'
t_contains "$c_status" 'global_ok=2' 'both entries answer the fresh-shell probe'
for c_d in $(printf '%s\n' "$c_status" | sed -n 's/^hook=\([^ ]*\).*/\1/p'); do
    c_out=$(env -i HOME="$home" PATH="$c_d:/usr/bin:/bin" \
                sh -c 'command -v sandhome >/dev/null && jq -n "\$ENV.SANDHOME_EXEC"' </dev/null 2>&1)
    t_contains "$c_out" "$exec_root" "a fresh shell through $c_d alone runs with the environment"
done
# A tool the view does not name still falls through to PATH.
c_out=$(fresh sh -c 'git --version')
t_contains "$c_out" 'git version' 'a host tool the hook does not name still runs'

# --------------------------------------------- wipe, gate, resume ----------
fresh sh -c 'jq --version' >/dev/null 2>&1
t_ok $? 'the tool runs before the wipe'
rm -rf "$exec_root"
fresh sh -c 'jq --version' >/dev/null 2>&1
if [ $? -ne 0 ]; then
    t_ok 0 'the tool is broken after the wipe, as a tmpfs restart would leave it'
else
    t_ok 1 'the tool is broken after the wipe, as a tmpfs restart would leave it'
fi
c_out=$(fresh sh -c 'sandhome doctor' 2>&1; printf 'rc=%s' "$?")
t_contains "$c_out" 'FAIL' 'doctor fails while the exec root is gone'
c_out=$(fresh sh -c 'sandhome resume; printf "resume rc=%s\n" "$?"' 2>&1)
t_contains "$c_out" 'resume rc=0' 'resume exits 0 and rebuilds without fetching'
c_out=$(fresh sh -c 'sandhome doctor; printf "doctor rc=%s\n" "$?"')
t_contains "$c_out" 'doctor_failures=0' 'doctor is green again after resume'
# The witness, not just the version: a version can come from a host tool on
# PATH, but $ENV.SANDHOME_EXEC can only be printed by a jq that went through
# the hook and inherited the environment. Without this, a resume that rebuilt
# nothing would still pass the version check by falling through to /usr/bin.
c_out=$(fresh sh -c 'jq -n "\$ENV.SANDHOME_EXEC"')
t_contains "$c_out" "$exec_root" 'after resume, the dispatched jq carries the environment again'
# The symlinked entry under the home dangled with the exec root; resume's
# repair path re-plans the recorded directories, so both entries must serve.
c_status=$(fresh sh -c 'sandhome global --status')
t_contains "$c_status" 'global_ok=2' 'resume re-verifies both hook directories'
if fresh sh -c 'jq --version' >/dev/null 2>&1; then
    t_ok 0 'the tool runs again after resume'
else
    t_ok 1 'the tool runs again after resume'
fi

# ------------------------------------------------- shells the harness uses --
for c_shell in sh dash bash; do
    command -v "$c_shell" >/dev/null 2>&1 || continue
    if env -i HOME="$home" PATH="$cpath" "$c_shell" -c \
            'command -v sandhome >/dev/null && jq -n 1 >/dev/null' </dev/null 2>&1; then
        t_ok 0 "$c_shell -c finds the hook and runs a toolchain"
    else
        t_ok 1 "$c_shell -c finds the hook and runs a toolchain"
    fi
done

# ------------------------------------- remove, and the cold-path recovery ---
fresh sh -c 'sandhome global --remove' >/dev/null 2>&1
c_out=$(fresh sh -c 'command -v sandhome >/dev/null 2>&1; [ $? -ne 0 ] && printf absent || printf found')
t_is "$c_out" 'absent' 'remove takes the hook out of the PATH entries'
c_out=$(fresh sh -c \
    '. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh" >/dev/null 2>&1 && sandhome global && printf recovered' \
    2>&1)
t_contains "$c_out" 'recovered' 'entry.sh, the route for a shell with no hook, reinstalls it'
c_out=$(fresh sh -c 'command -v sandhome >/dev/null && jq -n "\$ENV.SANDHOME_EXEC"')
t_contains "$c_out" "$exec_root" 'the hook is back and serving after the entry-point recovery'

rm -rf "$home" "$(dirname -- "$wsbin")" "$(dirname -- "$exec_root")" 2>/dev/null
t_end
