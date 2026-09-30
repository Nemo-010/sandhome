#!/bin/sh
# run-proof.sh - consume sandhome the way ROUTE.md tells a fresh sandbox to:
# one bootstrap, then every later command in a FRESH shell that sources
# nothing, on a host whose home root refuses execve (/tmp) with the exec root
# on a roomy mount (/workspace). Nothing here sets SANDHOME_* for the
# consumer steps; only HOME and PATH are given, because that is what a fresh
# shell actually has.
#
# Phases:
#   C0  failing-before: no sandhome, no env.sh, no hook
#   C1  ROUTE step 2: the bootstrap, defaults except --toolset cli
#   C2  ROUTE step 2 tail: fresh `env -i` shells, zero sourcing
#   C3  every recorded directory serves a fresh shell
#   C4  wipe the exec root (tmpfs-restart shape), then `sandhome resume`
#   C5  dispatch cost: hook vs per-command sourcing vs bare PATH
#   C6  shell diversity: sh, dash, bash, login and non-login
#   C7  global --status, --remove, and recovery through entry.sh
#
# Everything lives under /tmp/shc (noexec home root) and /workspace/shc-*
# (exec root and workspace bin). The live machine's HOME and PATH are never
# touched. Output is the log this script prints; run it again to re-derive.

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=${PROOF_REPO:-/workspace/sandhome}
LOG=$HERE/proof.log

# Consumer-shaped roots. HOME is under /tmp so the home root REFUSES execve
# on this host: the split is real, not assumed. HOME_BIN is the consumer's
# own bin directory on PATH (absent -> the symlink case), WS_BIN is a
# writable exec-capable directory (the in-place case).
HOME_DIR=/tmp/shc/home
HOME_BIN=$HOME_DIR/bin
WS_BIN=/workspace/shc-wsbin
EXEC_DIR=/workspace/shc-exec
CONSUMER_PATH="$HOME_BIN:$WS_BIN:/usr/bin:/bin"

say() { printf '\n=== %s ===\n' "$*" | tee -a "$LOG"; }
run() { printf '$ %s\n' "$*" | tee -a "$LOG"; "$@" >>"$LOG" 2>&1; printf 'rc=%s\n' "$?" | tee -a "$LOG"; }
fresh() { # fresh SHELL-PROG ARGS... in an env -i with only HOME and PATH
    sh_p=$1; shift
    env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" "$sh_p" "$@" </dev/null
}

: > "$LOG"
mkdir -p /tmp/shc 2>/dev/null
say "C0 failing-before: a fresh shell has no sandhome and no environment"
printf 'date(host): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" | tee -a "$LOG"
printf 'command -v sandhome: [%s]\n' "$(command -v sandhome 2>/dev/null || true)" | tee -a "$LOG"
printf 'home root runs binaries: '
if printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR.probe" 2>/dev/null && chmod 0700 "$HOME_DIR.probe" 2>/dev/null && "$HOME_DIR.probe" 2>/dev/null; then
    printf 'yes\n' | tee -a "$LOG"
else
    printf 'no (noexec, as on the target sandbox)\n' | tee -a "$LOG"
fi
rm -f "$HOME_DIR.probe" 2>/dev/null
rm -rf "$HOME_DIR" "$WS_BIN" "$EXEC_DIR" /workspace/shc-exec.d 2>/dev/null
mkdir -p "$HOME_DIR" "$WS_BIN" 2>/dev/null
printf 'env.sh present: '; [ -r "$HOME_DIR/.local/share/sandhome/env.sh" ] && printf 'yes\n' | tee -a "$LOG" || printf 'no\n' | tee -a "$LOG"

say "C1 ROUTE step 2: sh bootstrap.sh --toolset cli --exec DIR (only HOME and PATH given)"
(
    cd "$REPO" || exit 1
    env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" TMPDIR=/tmp \
        sh bootstrap.sh --toolset cli --exec "$EXEC_DIR"
) >>"$LOG" 2>&1
printf 'bootstrap rc=%s\n' "$?" | tee -a "$LOG"
# The route's check at the end of step 2.
fresh sh -c 'command -v sandhome; printf "command-v rc=%s\n" "$?"' | tee -a "$LOG"

say "C2 route step 2 tail: doctor and status, nothing sourced"
fresh sh -c 'sandhome doctor; printf "doctor rc=%s\n" "$?"' | tee -a "$LOG"
fresh sh -c 'sandhome status' | tee -a "$LOG"
# The no-source proof, two halves: the SHELL was started with `env -i` and
# read no file, so it sees no environment; a TOOL run by name goes through
# the hook, and jq prints the environment IT inherited. jq is the witness
# because the dispatcher must have sourced env.sh for it to be there.
fresh sh -c 'printf "shell sees SANDHOME_EXEC: [%s]\n" "${SANDHOME_EXEC:-unset}"; printf "dispatched jq sees:     [%s]\n" "$(jq -n "\$ENV.SANDHOME_EXEC")"; jq --version; rg --version | head -1; fd --version' | tee -a "$LOG"
fresh sh -c 'git --version' | tee -a "$LOG"

say "C3 every recorded directory serves a fresh shell on its own"
fresh sh -c 'sandhome global --status' | tee -a "$LOG"
for d in $(env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c 'sandhome global --status' 2>/dev/null | sed -n 's/^hook=\([^ ]*\).*/\1/p'); do
    printf 'fresh shell through %s: ' "$d" | tee -a "$LOG"
    env -i HOME="$HOME_DIR" PATH="$d:/usr/bin:/bin" sh -c \
        'command -v sandhome >/dev/null && jq -n 1 && printf "env=%s" "${SANDHOME_HOME:+loaded}"' \
        </dev/null >>"$LOG" 2>&1 && printf 'ok\n' | tee -a "$LOG" || printf 'FAILED\n' | tee -a "$LOG"
done

say "C4 wipe the exec root (tmpfs-restart shape), then resume"
printf 'before: ' | tee -a "$LOG"
fresh sh -c 'jq --version' >>"$LOG" 2>&1 && printf 'tool ok\n' | tee -a "$LOG" || printf 'tool FAILED\n' | tee -a "$LOG"
rm -rf "$EXEC_DIR" 2>/dev/null
printf 'after wipe: ' | tee -a "$LOG"
fresh sh -c 'command -v sandhome >/dev/null 2>&1; c=$?; jq --version >/dev/null 2>&1; printf "command-v rc=%s jq rc=%s\n" "$c" "$?"' >>"$LOG" 2>&1
printf 'recorded state with the exec root gone: ' | tee -a "$LOG"
env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c 'sandhome global --status' </dev/null | sed -n '1p;/^hook=/p;/^global_ok/p' | tee -a "$LOG"
printf 'doctor with the exec root gone:\n' | tee -a "$LOG"
env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c \
    'sandhome doctor >/dev/null 2>&1; printf "doctor rc=%s (a non-zero rc here is the gate catching the wiped root)\n" "$?"' \
    </dev/null | tee -a "$LOG"
env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c \
    'sandhome doctor 2>&1 | grep -E "^FAIL|^doctor_failures"' </dev/null | tee -a "$LOG"
fresh sh -c 'sandhome resume; printf "resume rc=%s\n" "$?"' | tee -a "$LOG"
printf 'after resume: ' | tee -a "$LOG"
fresh sh -c 'jq --version' >>"$LOG" 2>&1 && printf 'tool ok\n' | tee -a "$LOG" || printf 'tool FAILED\n' | tee -a "$LOG"

say "C5 dispatch cost, this machine, 20 runs each (ms total)"
bench() {
    b_n=0
    b_t0=$(date +%s%N 2>/dev/null || date +%s)
    while [ "$b_n" -lt 20 ]; do
        env -i HOME="$HOME_DIR" PATH="$1" sh -c "$2" </dev/null >/dev/null 2>&1
        b_n=$((b_n + 1))
    done
    b_t1=$(date +%s%N 2>/dev/null || date +%s)
    printf '%s' $(( (b_t1 - b_t0) / 1000000 ))
}
b_bare=$(bench "/usr/bin:/bin" 'jq --version')
b_hook=$(bench "$CONSUMER_PATH" 'jq --version')
b_src=$(bench "/usr/bin:/bin" ". $HOME_DIR/.local/share/sandhome/env.sh; jq --version")
b_bare_true=$(bench "/usr/bin:/bin" 'true')
b_hook_true=$(bench "$CONSUMER_PATH" 'true')
b_src_true=$(bench "/usr/bin:/bin" ". $HOME_DIR/.local/share/sandhome/env.sh; true")
printf 'bare PATH, jq:            %s ms\n' "$b_bare" | tee -a "$LOG"
printf 'hook, jq:                 %s ms\n' "$b_hook" | tee -a "$LOG"
printf 'per-command . env.sh, jq: %s ms\n' "$b_src" | tee -a "$LOG"
printf 'bare PATH, true:          %s ms\n' "$b_bare_true" | tee -a "$LOG"
printf 'hook, true:               %s ms\n' "$b_hook_true" | tee -a "$LOG"
printf 'per-command . env.sh, true: %s ms\n' "$b_src_true" | tee -a "$LOG"

say "C6 shell diversity: sh, dash, bash, login and non-login"
for s in sh dash bash; do
    printf '%s -c: ' "$s" | tee -a "$LOG"
    env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" "$s" -c \
        'command -v sandhome >/dev/null && jq -n 42 >/dev/null && echo ok' \
        </dev/null >>"$LOG" 2>&1 && printf 'ok\n' | tee -a "$LOG" || printf 'FAILED rc=%s\n' "$?" | tee -a "$LOG"
done
printf 'bash -lc (login): ' | tee -a "$LOG"
env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" bash -lc \
    'command -v sandhome >/dev/null && jq -n 42 >/dev/null && echo ok' \
    </dev/null >>"$LOG" 2>&1 && printf 'ok\n' | tee -a "$LOG" || printf 'FAILED rc=%s\n' "$?" | tee -a "$LOG"

say "C7 status, remove, and recovery through entry.sh"
env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c 'sandhome global --status' </dev/null | tee -a "$LOG"
env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c 'sandhome global --remove' </dev/null >>"$LOG" 2>&1
printf 'after remove, command -v sandhome: [%s]\n' \
    "$(env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c 'command -v sandhome' </dev/null 2>/dev/null || true)" | tee -a "$LOG"
# Recovery without PATH: the entry point beside the home, which the route
# names as the cold-shell path, reinstalls the hook.
env -i HOME="$HOME_DIR" PATH="$CONSUMER_PATH" sh -c \
    '. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh" && sandhome global && sandhome doctor; printf "entry rc=%s\n" "$?"' \
    </dev/null >>"$LOG" 2>&1
printf 'after entry.sh recovery: ' | tee -a "$LOG"
fresh sh -c 'command -v sandhome >/dev/null && jq -n 7 >/dev/null && printf "hook back, tool ok\n"' \
    >>"$LOG" 2>&1 && printf 'ok\n' | tee -a "$LOG" || printf 'FAILED\n' | tee -a "$LOG"
fresh sh -c 'sandhome global --status' | tee -a "$LOG"

say "done"
printf 'log: %s\n' "$LOG" | tee -a "$LOG"
