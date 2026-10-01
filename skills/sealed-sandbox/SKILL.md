---
name: sealed-sandbox
description: Operate and diagnose a sealed agent sandbox - no bind, no pty, no /etc/passwd, egress only through a proxy, and mounts that refuse exec. Use when a cage denies bind or chroot, when an ssh server will not start, when a login is refused with publickey, when a program needs a terminal that does not exist, or when a binary is present but will not execute.
---

# Working inside a sealed sandbox

A sealed cage typically has: no `bind(2)`, no `/dev/ptmx`, no `/etc/passwd`, no
`/var`, no UDP, possibly no resolver, and an egress that reaches only a proxy
or a whitelisted rendezvous. Each has a named workaround here.

`docs/reference.md` carries every command and every variable, generated from
the code. After a network-only setup the docs also live under
`$SANDHOME_HOME/repo/docs/`; without any docs on disk use `sandhome help` and
`sandhome <cmd> --help`, which print the same contract. `docs/architecture.md`
section 6 and `skills/sealed-sandbox/SKILL.md` carry the measurements.
This page is the map.

## First, measure

```sh
sandhome space --probe   # which roots run a binary
sandhome report          # os, kernel, arch, libc, privilege, provider, pty, passwd
sandhome doctor          # one line per invariant, ending in doctor_failures=N
```

`report` and `doctor` read the machine. Do not infer a capability from a
package list, from a mount option, or from what a previous run reported: a
mount can be `rw` with no `noexec` in its options and still refuse `execve`.

## No exec on the data root

The most common shape, and the reason this repository exists. `sandhome`
detects it by running a file, splits the roots, mirrors executables onto the
exec root and symlinks shared objects back. See `docs/architecture.md` section 1.

If a tool "installed" and is not found, or a binary is `Permission denied`:
`sandhome repair <name>`. `repair` rebuilds the exec view and downloads nothing,
so it cannot make a working install worse; `install` is the command that adopts
and downloads, and on an adopted toolchain that is what broke the view in the
first place.

Two failures here read as something else and are worth naming. A **language
runtime** (`node`, `deno`, `bun`) cannot be a launch-mode view at all: every
worker and download helper the runtime spawns reads `process.execPath`, and an
anonymous memfd path is gone by the time they do, so a browser or bundler dies
with `spawn /memfd:sandhome (deleted) ENOENT` while `node --version` answers.
`sandhome doctor` reports `toolchain_node_spawn` when that is true. And a
**rustup proxy** resolves the toolchain under `$RUSTUP_HOME`, which on a split
root is the mount that refuses `execve`, so `cargo` can answer
`Permission denied (os error 13)` from a fresh shell while working in any
sourced one; `sandhome repair rust` points the view at the real binaries.

## No bind

Both ends must dial out: no TCP listener starts here, and nothing needs one.
A sandbox that cannot `bind(2)` a TCP socket can still `connect(2)`, so any
transport where both peers initiate is available and any where one side
listens on TCP is not. Measured refinement (issue #97): `AF_UNIX` stream and
dgram binds succeed where `AF_INET` is refused (`sandhome report` says
`bind=unix` then), so local sockets in the X11/Wayland style can bind while
TCP cannot. A rendezvous relay
that both peers dial is the shape that works; a public one is perishable, so
re-measure latency and failure modes rather than trusting a recorded table.

This repository does not carry a transport. What it does carry is the tooling
that makes a transport work in a cage: `sandhome shell` for the session,
`SANDHOME_PASSWD_USERS` for the account, and the shims for a program that
refuses to start without a terminal or a passwd entry.

## No pty

Use `errandsh` (`skills/errandsh/SKILL.md`): `sandhome shell`. For a program
that needs `isatty(2)` to be true, build and load the interposer:

```sh
sandhome shims
SANDHOME_SHIMS=1 . "$SANDHOME_HOME/env.sh"
```

**Opt-in, but changes are scoped**: `env.sh` exports the session descriptors'
readlink identity, so `fakepty` fakes THOSE and leaves a pipe opened later a
pipe; a pipeline is no longer colourised. Turn it on for the shell that needs a
terminal, `sandhome pty CMD` for a single command, or `sandhome shell` for an
interactive line discipline.

Full-screen programs DO work: `shims/fakepty.c` is a userspace pty, because the
kernel offers none, and `sandhome pty nano file` runs it. The only thing it
cannot reach is a STATICALLY LINKED program, which carries its own libc.

## No listen

A process that creates its **own TCP listener** cannot start here: `bind(2)` on
`AF_INET` is refused (`EACCES`). Do not retry TCP bind variants. Either dial out
to a relay both ends connect to (per the no-bind row above) or emit static
output instead of serving it.

**A program that can adopt an already-listening descriptor can serve.** `AF_UNIX`
bind succeeds here (see the no-bind row), so bind an `AF_UNIX` socket outside the
program, hand it the descriptor, and let it listen on that. Worked example,
measured on workerd (the Cloudflare Workers runtime):

```sh
# bind-then-exec: the descriptor must land on a chosen fd and survive exec,
# and the launcher must EXEC, not spawn. node:child_process cannot pass a
# chosen descriptor (a listener that was fd 18 in the parent arrives as fd 3),
# and without clearing FD_CLOEXEC the kernel closes it at exec, which workerd
# reports as an unbound socket rather than a descriptor error.
./prebind ./entry.sock 4 workerd serve --experimental --socket-fd=http=4 minimal.capnp &
curl -sS --unix-socket ./entry.sock http://x/
```

Three levers are in `workerd serve --help` and `workerd.capnp`: a `unix:/path`
address in the config (workerd binds a filesystem socket), `-S/--socket-fd
<name>=<fd>` (adopt an inherited listener when the config's address is TCP and
cannot be edited), and `-e/--external-addr <name>=<addr>` (repoint an external
service at a unix path). Two constraints are workerd's own error text: the
fd must already be **listening** (`--socket-fd=entry=3: Socket for entry is not
listening.`), and a socket must not be given both `--socket-addr` and
`--socket-fd`, so a launcher has to **replace** the generated `--socket-addr`.
Also: `node_modules/.bin/workerd` is a Node wrapper that drops descriptors; use
the native binary at
`node_modules/@cloudflare/workerd-linux-64/bin/workerd`.

A bound `AF_UNIX` socket file **outlives the process that made it**: the kernel
never unlinks it, so the next run at the same path fails `EADDRINUSE`
with nothing listening. Always `rm -f "$SOCK"` before binding. `ss`/`lsof` show
nothing bound. And killed processes linger as unreapable `<defunct>` zombies
here (there is no init to reap them), so `pgrep`/`pkill` matching a zombie is
**not** evidence that something is running. `sandhome gc` does not remove
socket inodes a crash left; only `rm -f` makes the path bindable again.

The launcher that makes the listener, in full:

```c
/* prebind.c: prebind SOCK FD CMD... - bind an AF_UNIX listener on FD and exec CMD.
 * cc -O2 -o prebind prebind.c */
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: prebind SOCK FD CMD...\n"); return 2; }
    if (strlen(argv[1]) >= sizeof((struct sockaddr_un *)0)->sun_path) {
        fprintf(stderr, "prebind: socket path too long\n"); return 2;
    }
    unlink(argv[1]);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_un a; memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX; strncpy(a.sun_path, argv[1], sizeof a.sun_path - 1);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { perror("bind"); return 1; }
    if (listen(fd, 511) < 0) { perror("listen"); return 1; }
    int slot = atoi(argv[2]);
    if (fd != slot) { dup2(fd, slot); close(fd); }
    fcntl(slot, F_SETFD, fcntl(slot, F_GETFD) & ~FD_CLOEXEC);
    execvp(argv[3], &argv[3]);
    perror("execvp");
    return 1;
}
```

Scope, stated honestly: this runs **workerd itself** over a unix socket.
`wrangler dev` does not work, because miniflare hard-codes TCP in many places;
reaching it needs a `--socket-fd`/`--external-addr` seam or running the generated
config directly the way `prebind` does. A raw-TCP client still needs a path, not
a port: `net.connect({ path })` and `curl --unix-socket` work, a client that only
speaks TCP port numbers does not, on both ends, without a relay.

## No /etc/passwd

`fakepwd.so` answers `getpwnam`/`getpwuid` from `$SANDHOME_PASSWD`, which
`env.sh` exports when the shims are loaded. Add login names with
`SANDHOME_PASSWD_USERS=agent,deploy` and rebuild:

```sh
SANDHOME_PASSWD_USERS=agent,deploy sandhome shims
```

An ssh server refuses an unknown account with `Permission denied (publickey)`,
which reads as a key problem and is not one. The synthetic database is written
by `sandhome shims` and is readable at `doctor_failures` time: `shim_report`
prints its path.

**Build the server dynamically.** A statically linked binary carries its own
libc, so `LD_PRELOAD` cannot reach it. A static `dropbear` also cannot see a
synthetic passwd entry and logs `Login attempt for nonexistent user` for a user
that is there. `shims/fakepwd.c` is the reference implementation.

## No chroot, and sshd will not start

`sshd -i -t` exiting 0 is not evidence that `sshd -i` runs. A modern OpenSSH
needs a privilege-separation user and a chroot directory that a cage denies:

1. `sshd -i -t -f <config>` exits 0
2. `sshd -i` gives `Privilege separation user nobody does not exist`
3. with a `nobody` entry, `Missing privilege separation directory: /var/chroot/ssh`
4. moving `ChrootDirectory` has no effect; a different path is hardcoded
5. `UsePrivilegeSeparation no` is deprecated and ignored since OpenSSH 8.4

No configuration fixes it. The working shape is a dynamically built `dropbear`
that tolerates a denied `setgroups(2)` and a denied `ENOTSOCK` on
`socket(AF_INET, SOCK_STREAM)` from a pipe-carried session. Both changes are
small and both belong to whichever build produces that server; nothing in this
repository needs them.

## The map

| the cage denies | the answer |
| --- | --- |
| `execve` on a writable mount | `sandhome space --probe`, then `sandhome install <name>` |
| `bind(2)` | any transport where both ends dial out; a listener can also be bound here as `AF_UNIX` and handed to the program by descriptor (see the no-listen row) |
| `/dev/ptmx` | `sandhome shell`, and `SANDHOME_SHIMS=1` for non-shells |
| `/etc/passwd` | `sandhome shims` with `SANDHOME_PASSWD_USERS` |
| `chroot` and a privilege-separation user | a dynamic `dropbear` that tolerates a denied `setgroups(2)` |
| `/var` | the exec root is `$HOME`, `/tmp` or `/dev/shm`; `--exec DIR` names one |
