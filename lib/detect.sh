#!/bin/sh
# detect.sh - what machine is this, and what may it do. Sourced by bootstrap.sh
# and by bin/sandhome. Every answer is read off the machine rather than assumed,
# and the answers are exported with a SH_ prefix.

# NOTE: THE KERNEL DECIDES THE FAMILY, then the family decides what to look for. A
# bare search for `pkg` on PATH is wrong in both directions: pkgsrc puts one on
# some Linux machines, and a FreeBSD jail can carry a Linux emulation layer.
SH_PROVIDERS='apk apt dnf emerge pacman pkg pkg_add pkgin tdnf xbps yum zypper'

sh_detect_provider() {
    case "$(uname -s)" in
        FreeBSD|DragonFly)
            if sh_have pkg; then printf 'pkg'; return 0; fi
            printf ''
            return 0
            ;;
        NetBSD)
            # pkgin first and pkg_add second: both are real and one installs the
            # other, and a stock NetBSD base carries pkg_add and not pkgin.
            if sh_have pkgin; then printf 'pkgin'; return 0; fi
            if sh_have pkg_add; then printf 'pkg_add'; return 0; fi
            printf ''
            return 0
            ;;
        OpenBSD)
            if sh_have pkg_add; then printf 'pkg_add'; return 0; fi
            printf ''
            return 0
            ;;
    esac
    # Not alphabetical. A distribution can carry more than one; Fedora keeps a
    # `yum` that forwards to `dnf`, so the native one is tried first.
    if sh_have apk;          then printf 'apk';     return 0; fi
    if sh_have pacman;       then printf 'pacman';  return 0; fi
    if sh_have apt-get;      then printf 'apt';     return 0; fi
    if sh_have zypper;       then printf 'zypper';  return 0; fi
    if sh_have dnf;          then printf 'dnf';     return 0; fi
    if sh_have tdnf;         then printf 'tdnf';    return 0; fi
    if sh_have yum;          then printf 'yum';     return 0; fi
    if sh_have xbps-install; then printf 'xbps';    return 0; fi
    if sh_have emerge;       then printf 'emerge';  return 0; fi
    printf ''
}

# OpenBSD, NetBSD and MidnightBSD have no /etc/os-release; the kernel fallback
# is what keeps their `os:` rows from being dead.
#
# # STOP: BOTH LOCATIONS ARE READ, AND /usr/lib IS NOT AN AFTERTHOUGHT. The
# os-release specification names /etc/os-release as a symlink INTO /usr/lib on
# every merged-/usr distribution, and /usr/lib/os-release as the real file. The
# old code read /etc only, so on any image that ships the file WITHOUT the
# symlink - a container that bind-mounts it, a minimal rootfs, a foreign
# distribution - `os_id` answered `unknown`, and the first line of every report
# and every bootstrap was wrong on a machine that had already told us exactly
# what it was. Measured on the machine these fixes were made on, whose
# /etc/os-release does not exist and whose /usr/lib/os-release reads ID="void":
#   sh -c '. ./lib/common.sh; . ./lib/detect.sh; sh_detect_os_id'   ->  unknown
# /etc is still tried FIRST, because a distribution that overrides the file
# there is overriding it deliberately.
#
# The file is NOT SOURCED. A distribution's os-release is data, and it may
# carry PATH= or LD_PRELOAD=; sourcing it into the caller's shell would let a
# file that was only read as a document rewrite the process that read it. Only
# the one ID= line is extracted, and the quotes come off with parameter
# expansion rather than with sed, because this tree does not depend on sed for a
# transformation the shell already does.
sh_detect_os_id() {
    for sh_do_file in /etc/os-release /usr/lib/os-release; do
        [ -r "$sh_do_file" ] || continue
        sh_do_id=$(sh_do_read_id "$sh_do_file")
        [ -n "$sh_do_id" ] || continue
        printf '%s' "$sh_do_id"
        return 0
    done
    case "$(uname -s)" in
        FreeBSD)   printf 'freebsd' ;;
        NetBSD)    printf 'netbsd' ;;
        OpenBSD)   printf 'openbsd' ;;
        DragonFly) printf 'dragonfly' ;;
        Darwin)    printf 'darwin' ;;
        *)         printf 'unknown' ;;
    esac
}

# sh_do_read_id FILE -> the value of ID= in FILE, or nothing. grep is used when
# it is present and the line is read with the shell when it is not, because
# this file is loaded on userlands that carry no grep at all.
sh_do_read_id() {
    sh_dri_line=''
    if sh_have grep; then
        sh_dri_line=$(grep -m1 '^ID=' "$1" 2>/dev/null) || sh_dri_line=''
    fi
    if [ -z "$sh_dri_line" ] && [ -r "$1" ]; then
        while IFS= read -r sh_dri_raw || [ -n "$sh_dri_raw" ]; do
            case "$sh_dri_raw" in
                ID=*) sh_dri_line=$sh_dri_raw; break ;;
            esac
        done < "$1"
    fi
    case "$sh_dri_line" in
        ID=\"*\")
            sh_dri_val=${sh_dri_line#ID=\"}
            printf '%s' "${sh_dri_val%\"}"
            ;;
        ID=*)  printf '%s' "${sh_dri_line#ID=}" ;;
        *)     printf '' ;;
    esac
}

# NOTE: `ldd --version` writes to stdout on glibc, to stderr on musl, and exits 1 on
# musl while doing it. Looking for the loader is the answer that does not depend
# on which one is there. The multiarch glob is not optional: Debian and Ubuntu
# keep libc at /lib/x86_64-linux-gnu/libc.so.6 and nothing at the four obvious
# paths.
sh_detect_libc() {
    case "$(uname -s)" in
        Linux) ;;
        *) printf 'libc'; return 0 ;;
    esac
    for sh_dl_candidate in /lib/ld-musl-* /usr/lib/ld-musl-*; do
        if [ -e "$sh_dl_candidate" ]; then
            printf 'musl'
            return 0
        fi
    done
    for sh_dl_candidate in \
        /lib/libc.so.6 /lib64/libc.so.6 /usr/lib/libc.so.6 /usr/lib64/libc.so.6 \
        /lib/*-linux-gnu/libc.so.6 /usr/lib/*-linux-gnu/libc.so.6; do
        if [ -e "$sh_dl_candidate" ]; then
            printf 'glibc'
            return 0
        fi
    done
    printf 'unknown'
}

sh_detect_wsl() {
    if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSLENV:-}" ]; then
        printf 'yes'
        return 0
    fi
    if [ -r /proc/sys/kernel/osrelease ]; then
        sh_dw_release=''
        read -r sh_dw_release < /proc/sys/kernel/osrelease || sh_dw_release=''
        case "$sh_dw_release" in
            *[Mm]icrosoft*) printf 'yes'; return 0 ;;
        esac
    fi
    printf 'no'
}

# NOTE: THE PRIVILEGE ANSWER IS THREE-VALUED, and collapsing it to a boolean is what
# makes a bootstrap hang. `sudo` without -n waits on a terminal an unattended run
# does not have, so a password-requiring sudo is reported as no privilege rather
# than tried.
sh_detect_privilege() {
    if [ "$(id -u)" = 0 ]; then
        printf 'root'
        return 0
    fi
    if sh_have sudo && sudo -n true 2>/dev/null; then
        printf 'sudo'
        return 0
    fi
    printf 'none'
}

# sh_as_root COMMAND... -> run as the detected privilege, or fail.
sh_as_root() {
    case "${SH_PRIVILEGE:-none}" in
        root) "$@" ;;
        sudo) sudo -n "$@" ;;
        *)    return 1 ;;
    esac
}

# sh_detect_pty -> yes when a kernel pty can be opened. A cage without /dev/ptmx
# and without devpts gets no, and that is exactly the case errandsh and fakepty
# exist for.
sh_detect_pty() {
    if [ -e /dev/ptmx ]; then
        printf 'yes'
        return 0
    fi
    printf 'no'
}

# sh_detect_passwd -> yes when a passwd database answers. `getent` is absent on
# some cages; reading /etc/passwd is the fallback. A cage with neither gets no,
# which is the case fakepwd exists for.
sh_detect_passwd() {
    if [ -r /etc/passwd ]; then
        printf 'yes'
        return 0
    fi
    if sh_have getent; then
        if getent passwd "$(id -un 2>/dev/null)" >/dev/null 2>&1; then
            printf 'yes'
            return 0
        fi
    fi
    printf 'no'
}

# sh_detect_ptrace -> yes when the ptrace syscall class works here, no when it is
# denied, unknown when it cannot be probed.
#
# # WHY A BOGUS REQUEST IS SENT TOO. A blanket EPERM from ptrace is answered by
# several different things, and they mean different things for a tracee:
#   - a seccomp filter refuses the whole syscall class BEFORE the kernel looks at
#     the request, so even a request number that does not exist answers EPERM;
#   - YAMA and an LSM answer AFTER argument validation, so a bogus request gets
#     EIO/ESRCH instead.
# The distinction decides which shim answers it: a filter cannot be interposed
# into at all (it runs before libc), but a program that only SELF-CHECKS with
# PTRACE_TRACEME can still be satisfied by shims/antiptrace.so. Sending the bogus
# request is what tells the two apart. The method is the one strace-appimage's
# experiments/10-probe-host.sh uses; this is the same measurement, in the shape
# sandhome needs it (no compiler on the host, so python3 spawns a child that
# stops itself).
sh_detect_ptrace() {
    if sh_have python3; then
        _sh_dp=$(python3 -c 'import os,ctypes,signal,errno
libc = ctypes.CDLL("libc.so.6", use_errno=True)
pid = os.fork()
if pid == 0:
    os.kill(os.getpid(), signal.SIGSTOP)
    os._exit(0)
os.waitpid(pid, os.WUNTRACED)
results = []
for req in (0, 16, 0x4206, 0x9999):
    ctypes.set_errno(0)
    target = 0 if req == 0 else pid
    libc.ptrace(req, target, 0, 0)
    results.append(ctypes.get_errno())
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
if all(e == 0 for e in results):
    print("yes")
elif all(e == errno.EPERM for e in results):
    print("no")
else:
    print("partial")
' 2>/dev/null)
        case "$_sh_dp" in
            yes|no|partial) printf '%s' "$_sh_dp"; return 0 ;;
        esac
    fi
    # FALLBACK: no python3, but a C compiler answers the same question with
    # the same rule. The child stops itself; the parent sends TRACEME (request
    # 0), a real attach (16) and the bogus request (0x9999), and reports
    # yes/no/partial off errno exactly like the python probe above. A host
    # with neither gets unknown, and says so rather than guessing.
    if sh_have cc || sh_have gcc; then
        _sh_dp_cc=cc
        sh_have cc || _sh_dp_cc=gcc
        _sh_dp_dir=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
        _sh_dp_src="$_sh_dp_dir/.ptrace-probe.$$.c"
        _sh_dp_bin="$_sh_dp_dir/.ptrace-probe.$$"
        if cat > "$_sh_dp_src" 2>/dev/null <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
int main(void){
    pid_t pid = fork();
    int st, e0, e1, e2;
    if (pid < 0) return 2;
    if (pid == 0) { kill(getpid(), SIGSTOP); _exit(0); }
    if (waitpid(pid, &st, WUNTRACED) < 0) return 2;
    errno = 0; ptrace((enum __ptrace_request)0, 0, 0, 0); e0 = errno;
    errno = 0; ptrace((enum __ptrace_request)16, pid, 0, 0); e1 = errno;
    errno = 0; ptrace((enum __ptrace_request)0x9999, pid, 0, 0); e2 = errno;
    kill(pid, SIGKILL);
    waitpid(pid, &st, 0);
    if (e0 == 0 && e1 == 0 && e2 == 0) puts("yes");
    else if (e0 == EPERM && e1 == EPERM && e2 == EPERM) puts("no");
    else puts("partial");
    return 0;
}
EOF
        then
            _sh_dp=$( ("$_sh_dp_cc" -O2 -o "$_sh_dp_bin" "$_sh_dp_src" 2>/dev/null && "$_sh_dp_bin" 2>/dev/null) )
            rm -f "$_sh_dp_src" "$_sh_dp_bin" 2>/dev/null
            case "$_sh_dp" in
                yes|no|partial) printf '%s' "$_sh_dp"; return 0 ;;
            esac
            return 1
        fi
        rm -f "$_sh_dp_src" "$_sh_dp_bin" 2>/dev/null
    fi
    printf 'unknown'
}

# sh_detect_bind -> yes when a socket can be bound at all. A seccomp profile can
# deny bind(2) while allowing connect(2), which is the whole reason podssh dials
# out and never listens.
#
# # STOP: TCP IS THE WRONG PROBE, AND IT ANSWERED `no` ON A MACHINE THAT CAN
# BIND. This asked for AF_INET on 127.0.0.1 and nothing else. Measured here: that
# bind is refused (EACCES) while AF_UNIX stream and dgram binds both succeed, and
# AF_UNIX is the transport X11, Wayland, sshd, a dev server and every local
# socket in the Electrosphere actually use. A `no` from that probe was then read
# as "nothing here listens", which is false. The probe now reports WHAT binds, so
# a caller can tell "no sockets at all" from "only TCP is denied".
sh_detect_bind() {
    if sh_have python3; then
        _sh_db=$(python3 -c 'import socket,errno,os,tempfile
def probe(fam, typ, addr, alt=None):
    try:
        s = socket.socket(fam, typ)
    except OSError:
        return "nosock"
    try:
        s.bind(addr)
        return "yes"
    except OSError as e:
        if alt is not None and e.errno not in (errno.EACCES, errno.EPERM):
            try:
                s.close()
                s = socket.socket(fam, typ)
                s.bind(alt)
                try: os.unlink(alt)
                except OSError: pass
                return "yes"
            except OSError as e2:
                try: os.unlink(alt)
                except OSError: pass
                return "denied" if e2.errno in (errno.EACCES, errno.EPERM) else "error"
        return "denied" if e.errno in (errno.EACCES, errno.EPERM) else "error"
    finally:
        s.close()
tmp = tempfile.gettempdir()
unix = probe(socket.AF_UNIX, socket.SOCK_STREAM, "\0sandhome-detect-bind", os.path.join(tmp, "sandhome-bind-probe"))
unixd = probe(socket.AF_UNIX, socket.SOCK_DGRAM, "\0sandhome-detect-bind-d")
tcp = probe(socket.AF_INET, socket.SOCK_STREAM, ("127.0.0.1", 0))
if unix == "yes" or unixd == "yes":
    print("unix" if tcp != "yes" else "yes")
elif tcp == "yes":
    print("tcp")
else:
    print("no")
' 2>/dev/null)
        case "$_sh_db" in
            yes|unix|tcp) printf '%s' "$_sh_db"; return 0 ;;
            no)           printf 'no'; return 0 ;;
        esac
        printf 'unknown'
        return 0
    fi
    printf 'unknown'
}

# sh_detect_all -> read every answer and export it. One place, so a script added
# later reads the same answer as every other.
sh_detect_all() {
    SH_OS_ID=$(sh_detect_os_id)
    SH_KERNEL=$(uname -s 2>/dev/null) || SH_KERNEL=unknown
    SH_ARCH=$(uname -m 2>/dev/null) || SH_ARCH=unknown
    SH_LIBC=$(sh_detect_libc)
    SH_WSL=$(sh_detect_wsl)
    SH_PRIVILEGE=$(sh_detect_privilege)
    SH_PROVIDER=$(sh_detect_provider)
    SH_PTY=$(sh_detect_pty)
    SH_PASSWD=$(sh_detect_passwd)
    SH_PTRACE=$(sh_detect_ptrace)
    SH_BIND=$(sh_detect_bind)
    export SH_OS_ID SH_KERNEL SH_ARCH SH_LIBC SH_WSL SH_PRIVILEGE SH_PROVIDER
    export SH_PTY SH_PASSWD SH_PTRACE SH_BIND
}

# sh_arch_go -> the GOARCH spelling of this machine.
sh_arch_go() {
    case "${SH_ARCH:-unknown}" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv6l) printf 'armv6l' ;;
        i386|i686)     printf '386' ;;
        *)             printf '%s' "${SH_ARCH:-unknown}" ;;
    esac
}

# sh_arch_node -> the nodejs.org spelling.
sh_arch_node() {
    case "${SH_ARCH:-unknown}" in
        x86_64|amd64)  printf 'x64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l)        printf 'armv7l' ;;
        *)             printf '%s' "${SH_ARCH:-unknown}" ;;
    esac
}

# sh_arch_rust -> the rustup target-triple spelling for this libc and kernel.
sh_arch_rust() {
    case "${SH_KERNEL:-unknown}" in
        Linux)
            case "${SH_LIBC:-unknown}" in
                musl) printf '%s-unknown-linux-musl' "${SH_ARCH:-unknown}" ;;
                *)    printf '%s-unknown-linux-gnu' "${SH_ARCH:-unknown}" ;;
            esac
            ;;
        Darwin) printf '%s-apple-darwin' "${SH_ARCH:-unknown}" ;;
        *)      printf '%s-unknown-unknown' "${SH_ARCH:-unknown}" ;;
    esac
}
