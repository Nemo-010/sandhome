# Architecture

How the pieces fit, and why they are shaped this way. For how to *use* it, read
`skills/sandhome/SKILL.md`. For every flag and variable, read
`docs/reference.md`, which is generated from the code.

## 1. The two roots

`SANDHOME_HOME` holds data. `SANDHOME_EXEC` holds executables. The split exists
because of one measured asymmetry:

> A mount can be writable and refuse `execve`, while allowing
> `mmap(PROT_EXEC)`. A shared library read from that mount loads; a binary in it
> does not run. `mount` does not have to say `noexec` - the refusal can come
> from a policy invisible in `/proc/mounts`.

So `sh_exec_probe` writes a `#!/bin/sh` file, chmods it, and **runs it**. Every
decision about a root comes from that, never from parsing mount options.

When the home runs binaries, the two roots collapse and nothing is copied. When
it does not, each toolchain installs into the home and an exec view is mirrored
onto the exec root.

### The mirror's three rules

`sh_promote_tree` in `lib/space.sh` decides per entry, and each rule is a
measured fix rather than a preference:

| entry | what the view gets | why |
| --- | --- | --- |
| a regular executable | **copied** | it must `execve`, and a symlink into a noexec mount is refused |
| a symlink whose target is **inside** the tree | **remapped** onto the view | `bin/npm -> ../lib/node_modules/npm/bin/npm-cli.js` reads `../lib/cli.js` relative to itself; copied to `bin/npm` it looked for `bin/../lib/cli.js` and died |
| a symlink whose target is **outside** the tree | **repointed at the target's absolute path** | the view cannot mirror what it does not contain, and a relative link resolves against a different directory there |
| a symlink whose target is **missing** | **reproduced naming that same missing path** | `cp` dereferences, so the copy fails; the old fallback linked the entry to itself |
| everything else, including `.so` | **symlinked back** to the home | `mmap(PROT_EXEC)` is allowed where `execve` is not, and copying a 191MB `libLLVM.so` onto a 250MB root does not fit |

### Launch mode: run from memory instead of copying

Copying every executable costs real room on the exec root (rust's declared
copy figure is 150MB, clang's 3000MB). Where the machine allows it the view
holds 20KB launcher
copies of one helper instead: `shims/memexec.c` (`sandhome-memexec` on the
exec bin) copies the payload bytes into an anonymous `memfd` and executes
them from the file descriptor, falling back to `fexecve` where `/proc` is
absent. The mechanism (memfd plus exec-from-fd) is transcribed from the
description in `hackerschoice/memexec`, studied as reference only; what runs
here is written from scratch for this tree. Measured on a noexec home:
direct exec fails `EACCES`, ELF, dynamic ELF and `#!` scripts all run from
the fd, and the rust view shrinks from ~100MB of copies to ~17MB (launchers
plus the few real copies below).

### What a view costs, per toolchain and mode

This table owns the figures; prose elsewhere links here instead of quoting
its own. `copy` is the module's declared `TC_<name>_EXEC_MB`, the price the
install gate and the feasibility plan actually read; `launch` is the
`tc_<name>_exec_mb` figure where the module computes one, else the same
declared number. A guarded check in `tests/docs.sh` requires every declared
number to appear in its row, so the table and the modules cannot drift.

| toolchain | copy view, MB | launch view, MB |
| --- | --- | --- |
| bun | 200 | 12 |
| clang | 3000 | 32 |
| cmake | 64 | 16 |
| deno | 150 | 8 |
| fd | 16 | 16 |
| gh | 16 | 16 |
| go | 150 | 12 |
| jq | 8 | 8 |
| meson | 32 | 8 |
| perl | 8 | 8 |
| pkgconf | 8 | 8 |
| mold | 60 | 8 |
| ninja | 8 | 8 |
| node | 200 | 16 |
| python | 30 | 30 (launch unmeasured; priced as copy until it is) |
| qemuuser | 12 | 12 |
| ripgrep | 32 | 32 |
| rust | 150 | 25 |
| shellcheck | 8 | 8 |
| shfmt | 8 | 8 |
| yq | 8 | 8 |
| zig | 200 | 200 (a real copy: its install-dir lookup fails from a memfd) |

A launcher copy maps itself back to its home payload at runtime (the
`views/<name>` to `toolchains/<name>` convention, argv unchanged), so
exe-relative tools keep working: clang finds its resource dir and re-execs
`-cc1` through the view path. Three shapes cannot run from a memfd image and
stay real copies, named per module by `tc_<name>_copy_bins`: a binary that
is *spawned by path and locates its siblings exe-relative* (gcc's `ld.lld`
wrapping, `cargo-clippy` finding `clippy-driver`), zig, which locates its
install dir through `/proc/self/exe` that a memfd image hides, and the sysroot rustc
reports, which still needs the `--sysroot` wrapper because the driver loads
from the home path in every mode. `SH_VIEW_MODE` is `launch` when the helper
is built and passes its probe here, `copy` otherwise; `copy` is the old
behavior and the fallback, and the report prints which (`view=`). A usable
host copy is still adopted with no workaround at all; `SANDHOME_FORCE` (or
`install --force`) installs locally regardless.

**`/proc/self/exe` is the memfd in launch mode.** A launcher runs from an
anonymous file, so anything that reports its own path -- `process.execPath`,
`argv[0]`-vs-exe checks, crash traces, `node-gyp` error lines -- names
`/memfd:sandhome (deleted)`, a path that no longer exists by the time it is
read. That is inherent to running from memory, not a defect in one tool.
Three answers exist: the per-module copy list above (keep the tool real),
`SANDHOME_VIEW_MODE=copy` (keep every view real, at the price of exec-root
room), and the mapping itself -- `sandhome toolchains --json` carries a
`view` field per toolchain (`launch`, `copy`, `direct`), so a memfd path in
a trace is explainable instead of mysterious.

### Exec-only caches

A build cache is not data. `go run` and `go test` compile into `GOCACHE` and
then `execve` what they built, so `GOCACHE` and `GOTMPDIR` go on
`SANDHOME_EXEC` while `GOPATH` and the module cache stay in the home. Measured:
a cache on a noexec home makes every `go run` fail with
`fork/exec ... permission denied` after a compile that succeeded.

### Choosing the exec root

Candidates are tried in order: `$SANDHOME_EXEC`, the home, `/dev/shm`, `/tmp`,
`/run/user/<uid>`, `$HOME/.cache/sandhome/exec`. The first that is writable
*and runs a file* wins, and among those the first with at least
`SANDHOME_MIN_EXEC_MB` (128) free is preferred. Free space decides, because a
working 244MB `/dev/shm` fills up and a large one that cannot run a file is
worth nothing.

`SANDHOME_EXEC` set explicitly is honoured, and a named root that cannot run a
binary is **refused by name**, never silently replaced.

## 2. The layers

```
bootstrap.sh          the installer. Self-fetching when piped.
bin/sandhome          the command. Copied to $SANDHOME_EXEC/bin by a bootstrap.
  lib/common.sh       logging, shell-only helpers, the one file appender
  lib/detect.sh       what machine is this, read off the machine
  lib/space.sh        the two roots, the probes, the mirror, gc
  lib/fetch.sh        one download path, one digest path, one unpack path
  lib/env.sh          the environment, written once, read everywhere, and the
                      global hook that reads it for a fresh shell
  lib/toolchain.sh    the contract every tools/<name>.sh obeys
  lib/shim.sh         the three LD_PRELOAD interposers
  lib/report.sh       the report, read from probes
  lib/profile.sh      the login fragment (fetched never, aliased never)
  tools/<name>.sh     one module per toolchain
  shims/*.c           fakepty, fakepwd, antiptrace
  shell/errandsh      a line discipline for a session with no kernel pty
  shell/faketty       run one command under the userspace pty
```

**One fact has one home.** The environment is written once, to
`$SANDHOME_HOME/env.sh`, and every caller sources that file; `sandhome env`
prints the same bytes, so `eval "$(sandhome env)"` and the file cannot drift.
Each toolchain owns one fragment under `$SANDHOME_HOME/env.d/`, and `env.sh`
sources them all, so a second module cannot clobber the first.

The hook does not add a second source of truth: it is one dispatcher that reads
`env.sh` and `exec`s the view, so it cannot drift from the file. `sandhome
global --remove` deletes exactly what `sh_global_install` recorded writing,
which is what lets it share a directory with files it did not create.

**Every function is namespaced by its module**, because POSIX `sh` has no
namespaces and two modules defining `install` would shadow each other silently.

## 3. The toolchain lifecycle

1. Resolve the requirement closure with an iterative algorithm, not recursion,
   and refuse a cycle **by name**.
2. Load any existing environment fragment, then **adopt** if `tc_<name>_probe`
   answers, **install** otherwise. Adoption is the common case: a sandbox that
   already carries a toolchain should not download a second copy.
3. Promote: build the exec view and link every `TC_<name>_BINS` entry into
   `$SANDHOME_EXEC/bin`. This runs on **both** paths, because an adopted
   toolchain has no home tree to mirror and the link is all it needs.
4. Call `tc_<name>_env`, load the environment again.
5. **Probe once more.** A toolchain that installed "without an error" and does
   not answer is the exact claim this tree exists to refuse, and the split root
   is where it hides. The post-promote probe runs for an adoption too, because
   an adoption fails differently: a module that probes by its own home path is
   true on a collapsed home and false the moment the roots split.

## 4. POSIX sh, and the dependency set

`dash -n` and `bash --posix -n` on every file, in `tests/syntax.sh`. No `local`,
no arrays, no `[[`, no `$'...'`, no `a && b || c`.

The library may not use `awk`, `sed`, `grep`, `tr`, `find`, `install` or
`dirname`. Measured across minimal images: Photon carries neither `awk` nor
`tr`, openSUSE carries neither `awk` nor `find`, Void and Rocky 8 carry no
`find`. A bootstrap whose job is installing the missing tools cannot require
them first. `uname` and `id` are the exceptions POSIX guarantees.

**No recursion.** POSIX `sh` has no locals, so a function's variables are
globals and a recursive call overwrites its caller's. `sh_promote_tree` was
recursive: the nested call for one subdirectory overwrote the parent's source,
destination and basename, and the second sibling directory was mirrored under
the first. Measured on the Go tree: 32 files failed to copy and `go` never
landed in the view at all, while every message blamed the file. Every walk here
is a queue.

**`read` at EOF.** `read` returns non-zero on a last line with no newline and
still sets the variable. Testing its status threw the answer away, which broke
Go's version lookup; `sh_first_line` and `sh_first_word` use `read ... || :`,
and `sh_read_file` carries that last line out of the loop.

**Command substitution strips a trailing newline**, so `NL=$(printf '\n')` is
the empty string and a `case` arm built on it can never match. The JSON escaper
matches control characters with a bracket expression instead.

**Views are shared and gc never scans them.** `$SH_EXEC/views` belongs to every
session at once: concurrent repairs of one toolchain mirror the same payload
to the same directory, and the mirror only ever writes complete files (copies
then chmod, symlinks via rename-safe `ln -sfn`), so no session observes a
partial view. Measured clean at 8 concurrent repairs plus 100 executions
against the repair. `gc` scans staging, exec caches and home tmp only -- never
views -- because a view is toolchain data rebuilt by `repair`, not a cache;
a run that deleted views to reclaim space would break every toolchain to save
the root they run from. Both properties are load-bearing and both are
covered in `tests/space.sh`, so neither can be "fixed" away unnoticed.

## 5. The toolchain contract

One module per toolchain at `tools/<name>.sh`. The full contract is in
`docs/decisions/toolchain-contract.md`; the rules that exist because the
alternative was measured are:

1. **Install into `$(sh_toolchain_root <name>)`.** A module that picks its own
   location cannot be promoted, reported or collected.
2. **Declare every executable that must be on `PATH`** in `TC_<name>_BINS`. An
   undeclared binary is absent from every shell.
3. **Never test a binary by its home path.** The home may refuse `exec`. Let the
   framework's post-promote probe decide, by running the tool.
4. **Put exec-only caches on `SANDHOME_EXEC`.** Go is the example above.
5. **Declare `tc_<name>_adopted`** if the tool may be adopted. Without it an
   adopted toolchain is linked from wherever it happens to be on `PATH`, which
   is a guess.
6. **Refuse with a reason.** A missing asset, an unsupported kernel/arch pair or
   a failed digest is a warning plus a non-zero return, never a silent skip that
   later reads as a transport failure.

## 6. The shims, and why they are opt-in

`fakepty` is a **userspace pty**. It keeps a list of the session's own
`readlink()` descriptor identities (`SANDHOME_FAKEPTY_ID`, set by `shell/faketty`
from `/proc/$$/fd`) and answers `isatty`, `tcgetattr`, `ioctl(TIOCGWINSZ)` and
`open("/dev/tty")` as a terminal for THOSE, and for nothing else. A pipe a
program opens later is a new object; it is not in the list and stays a pipe, so
`jq -n 1 | cat` does not put ANSI codes into `cat`. Without the variable the
older fds 0-2 behaviour is kept, and that is what made the shim unsafe to turn
on: it reported every fd 1, including a pipeline's. `fakepwd` answers
`getpwnam`/`getpwuid` from a synthetic passwd database for a cage with no
`/etc/passwd`. Neither can reach a **statically linked** binary, because a
static binary carries its own libc and there is nothing to interpose into.

That limit is about interposition, not about terminals. A full-screen program
is a matter of what it is linked against: `less`, `nano`, `top` and python
curses are dynamically linked and run full-screen here, where the kernel offers
no pty at all. So the honest statement of the limit is that `sandhome pty`
cannot reach a statically linked binary, and not that a full-screen program is
the one thing it cannot do.

They are loaded only when `SANDHOME_SHIMS` is set to something other than `0`.
When they are, `env.sh` computes the same descriptor identities for the login
shell, so the session is scoped from the first command. `shell/faketty` is the
single-command path: it exports the shim and the identity and `exec`s, which is
why a subshell the command starts still has a terminal.

## 7. Digests

`sh_fetch_verified` fetches, digests, compares, refuses, and reports **which
tool took the digest and where the expected value came from**:

```
sha256 b1c22172...870f (taken with sha256sum; no digest to compare against)
sha256 matches the value from SANDHOME_SHA256 (pinned by the caller) (taken with sha256sum)
... does not match the expected sha256 (got b1c... with sha256sum, wanted 0000...)
```

A digest fetched from the same release as the bytes proves **transport, not
authorship**: whoever could replace one could replace the other. It catches a
mirror that truncates a download, which is the common failure.
`SANDHOME_SHA256` is the stronger check, and `SANDHOME_REQUIRE_DIGEST=1` turns
a missing digest tool into a refusal rather than a warning.

Two toolchains fetch from a source that publishes a digest beside the archive:
Go from `dl/?mode=json`, found by matching the archive's own `filename` because
**there is no `.sha256` sidecar** (that URL is an HTML redirect page and yields
`<!DOCTYPE` as a digest), and Node from `SHASUMS256.txt`. Both parsers are
formatting-independent and are tested offline through a `SANDHOME_*_URL`
override, because a parser that only works against one rendering of a document
silently returns nothing and the download then goes unchecked.

## 8. What runs at shell start

The profile fragment: nothing that can fail. It fetches nothing, defines no
alias and no prompt, returns early for a non-interactive shell (`$-` containing
`i`), de-duplicates `PATH` and drops empty elements, gives history a home that
survives the session, and in WSL moves an interactive shell off a mounted
Windows drive. One switch, `SANDHOME_NO_PROFILE=1`, turns all of it off.

## 9. The global hook: setup once, no per-command sourcing

A non-login `bash -c` shell reads no startup file, and `BASH_ENV`/`ENV` are
usually unset, so a harness that spawns one shell per tool call has no way to
inherit an environment. The first answer was "source `env.sh` at the top of
every command" - `bash . "$HOME/.local/share/sandhome/env.sh" <cmd>` - which
is correct and hostile: every command carries the incantation, and one command
that forgets it looks like a failed setup.

`sh_global_install` in `lib/env.sh` removes the incantation by putting the
environment into a directory the shell already searches. Two cases, in order:

1. **A `PATH` entry that already runs binaries and is writable.** One dispatcher
   is written there, keyed on `$0`: `${0##*/}` names the tool, the dispatcher
   sources `env.sh`, and it `exec`s `"$SANDHOME_EXEC/bin/$name"`. One symlink per
   tool points at the single file.
2. **A `PATH` entry that is absent, empty, or already a symlink, on a writable
   root that refuses `execve`.** The entry is replaced by a symlink into
   `$SANDHOME_EXEC/global`, which holds the same dispatcher. The mount refuses
   `execve` on the name the shell looked up, but the kernel resolves the link
   first and the exec policy applies to the resolved root, so the dispatcher
   runs. This is the userspace route through a `noexec` home.

The candidate scan is two passes so case 1 wins: a directory that runs binaries
is never replaced by a symlink. `sh_global_remove` deletes only what the install
recorded writing, and never a file it did not create. `bootstrap.sh` installs
the hook after the environment is written; `SANDHOME_GLOBAL=0` (or `--no-global`)
keeps it out of a directory the caller does not own, which is what the test
suite does. `sandhome report` prints `global=<state>`, and `sandhome
global --status` reads the record back.

Measured on the sandbox this was built in, where `$HOME` is `/state/home` and
refuses `execve`: with the hook installed, a fresh `env -i` shell whose `PATH`
holds only the hook ran a toolchain **and** `sandhome` by name with nothing
sourced, and the tool's own output proved `env.sh` had been read on the way.
The case is exercised by `tests/global.sh`.
