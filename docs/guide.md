# The sandhome guide

This is the page to read before working in a sandbox this repository set up, and
the page to read before adding a toolchain to it.

## 1. The two roots

`sandhome` keeps two directories apart on purpose:

- **`SANDHOME_HOME`**  -  the persistent data root. Default
  `$XDG_DATA_HOME/sandhome`, else `$HOME/.local/share/sandhome`. It may be a
  mount that refuses `execve`; every read and write still works there.
- **`SANDHOME_EXEC`**  -  the root that runs binaries. Default: the home root when
  it runs binaries, otherwise the first candidate that both is writable and
  *actually runs a file*, preferring one with at least `SANDHOME_MIN_EXEC_MB`
  (128) megabytes free. Candidates are tried in the order
  `$SANDHOME_EXEC`, the home, `/dev/shm`, `/tmp`, `/run/user/<uid>`,
  `$HOME/.cache/sandhome/exec`. There is no `/var/tmp`: it was in an older list
  only because the probe report created it, and `/var` is precisely the
  directory a sealed cage tends not to have.

  **Free space decides between working candidates, and it is the decision that
  matters.** On this sandbox `/dev/shm` works and has 244MB while `/tmp` works
  and has 52GB; the default is `/tmp`, and installing `go` onto the other one
  fails for want of room. `SANDHOME_MIN_EXEC_MB` raises the bar; when no
  candidate clears it the first that works is used and a warning says so.

When the home runs binaries the two collapse and nothing is copied. When it does
not, a toolchain installs into the home and an **exec view** is mirrored onto the
exec root. The rule for each entry:

- a **regular executable** is copied, because it must `execve`;
- a **symlinked executable whose target is inside the same tree** is mirrored as a
  symlink to the target's own place in the view, so relative paths beside it keep
  working;
- everything else (`.so`, `.rlib`, data) is symlinked back to the home.

This works because `mmap(PROT_EXEC)` is allowed on a noexec mount even when
`execve` is not  -  so a shared library loads from the home while the binary that
needs it runs from the exec root.

> **A symlink to a script on a noexec mount still does not run.** The kernel
> checks the script's own inode, so `bin/npm -> ../lib/.../npm-cli.js` pointed at
> the home fails with `bad interpreter: Permission denied`. That is why a
> symlinked executable is mirrored *into* the view rather than left pointing at
> the home; `npm` is the measurement behind the rule.

`SANDHOME_EXEC` set explicitly is honoured, and a named root that cannot run a
binary is refused **by name** rather than silently replaced.

Read the plan with:

```sh
sandhome space          # the chosen roots and their free space
sandhome space --probe  # every candidate, with writable/exec/mount/free
```

## 2. Bootstrap

```sh
sh bootstrap.sh [options]
```

| option | meaning |
| --- | --- |
| `--toolset NAME` | `minimal`, `cli`, `developer`, `languages`, `agent` |
| `--with LIST` / `--without LIST` | add or drop toolchains by name |
| `--list-toolchains` | print the known names |
| `--home DIR` / `--exec DIR` | override the roots. An option beats the environment variable of the same name. |
| `--no-shims` / `--require-shims` | do not build, or refuse without, the shims |
| `--no-shell` | do not install `errandsh` |
| `--no-profile` / `--no-path-line` | leave the login files alone |
| `--dry-run` / `--json` | preview, or one JSON report |
| `--doh-url URL` | DNS-over-HTTPS resolver for a confirmed no-resolver cage (see `SANDHOME_DOH_URL` in the reference). Off unless set. |

The run: detects the machine, plans the roots, adopts or installs each toolchain,
builds the shims this machine actually needs, writes `$SANDHOME_HOME/env.sh`,
installs `$SANDHOME_HOME/profile.sh` and the one line a login file reads, and
prints a report **read from the machine**  -  never from what was requested.

Exit codes: `0` done, `1` something asked for could not be installed, `2` could
not run at all.

### From a pipe

`bootstrap.sh` run with `$0` as the interpreter has no `lib/` beside it, so it
fetches the branch named by `SANDHOME_REF` (default `main`) from
`SANDHOME_REPO` (default `talaria0101/sandhome`), unpacks it to a temp dir, and
re-execs itself there.
`SANDHOME_NO_REFETCH=1` turns that off.

## 3. The environment

`$SANDHOME_HOME/env.sh` is the single source of truth. It exports the roots, puts
the exec bin directory on `PATH`, and sources one fragment per toolchain from
`$SANDHOME_HOME/env.d/`. It also exports `SANDHOME_REPO_DIR`, which is how the
copy of `sandhome` the bootstrap placed in `$SANDHOME_EXEC/bin` finds its
library. That copy is a **copy, not a symlink**, because the checkout is
frequently on a root that refuses `execve`: a symlink into it answers
`command -v sandhome` and then fails with `Permission denied`.

```sh
. "$SANDHOME_HOME/env.sh"          # in a shell
eval "$(sandhome env)"             # without sourcing the file
sandhome env                       # to read it
```

The installed profile fragment de-duplicates `PATH`, gives history a home that
survives the session, and moves an interactive shell out of a mounted Windows
drive in WSL. It is `SANDHOME_NO_PROFILE=1`-off in one switch, fetches nothing,
and defines no alias or prompt. It runs only for an interactive shell (`$-`
contains `i`), so a tool that sends a command to a login shell does not have its
environment changed underneath it.

## 4. Adding a toolchain

Drop `tools/<name>.sh`. It declares:

```sh
TC_<name>_DESC='one line for sandhome toolchains'
TC_<name>_BINS='bin/tool'          # relative executables to expose
TC_<name>_REQUIRES='other'         # optional; ensured first

tc_<name>_probe()   { ...; }       # 0 when a working copy is already here
tc_<name>_install() { ...; }       # install into $(sh_toolchain_root <name>)
tc_<name>_env()     { ...; }       # write the env fragment (optional)
tc_<name>_version() { ...; }       # print a version (optional)
```

The framework, `lib/toolchain.sh`:

1. ensures `TC_<name>_REQUIRES` first, refusing a cycle by name;
2. loads any existing environment fragment, then **adopts** when
   `tc_<name>_probe` succeeds, **installs** otherwise;
3. promotes `TC_<name>_BINS` and builds the exec view;
4. calls `tc_<name>_env`, loads the environment, and **probes again**;
5. fails loudly when a toolchain installed "without an error" and still does not
   run from the exec view.

Three rules keep a module portable:

- Install into `sh_toolchain_root <name>` and promote only what must execute.
- **Never test a binary by its home path**  -  it may not run there. Declare it in
  `TC_<name>_BINS`, or expose it through the fragment and let the framework's
  post-promote probe decide.
- **Put exec-only caches on `SANDHOME_EXEC`.** Go is the example: `go run` and
  `go test` build an executable into `GOCACHE` and then `execve` it, so a cache on
  a noexec home fails with `fork/exec ... permission denied` after a successful
  compile. Downloads and module caches are data and stay in the home.

For a version or digest that is fetched, give the URL a `SANDHOME_*` override
(`SANDHOME_GO_VERSION_URL`, `SANDHOME_GO_DL_JSON_URL`, `SANDHOME_NODE_INDEX_URL`).
That lets the parser be tested against a local file, which is how both of the
version parsers here are covered offline. See
[`decisions/toolchain-contract.md`](decisions/toolchain-contract.md).

## 5. The shims

Two `LD_PRELOAD` interposers, built only when the machine needs them:

- **`fakepty`**  -  makes fds 0-2 look like a terminal to a pipe-backed shell, so
  readline and echo work where there is no `/dev/ptmx`.
- **`fakepwd`**  -  answers `getpwnam`/`getpwuid` from a synthetic database, for a
  cage with no `/etc/passwd`. It reads `$SANDHOME_PASSWD`; `env.sh` exports it.

Both are built into `$SANDHOME_HOME/shims/`. `env.sh` puts them in `LD_PRELOAD`
only when `SANDHOME_SHIMS` is set to something other than `0`, and **the default
is off, deliberately**: `fakepty` reports fds 0-2 as a terminal, so every
terminal-aware program then colourises a *pipe*, which breaks `jq -r`, `git` and
`ls --color=auto`. Measured:

```
$ LD_PRELOAD=fakepty.so jq -n '{ok:1}'
^[[1;39m{^[[0m
  ^[[1;34m"ok"^[[0m^[[1;39m:^[[0m ^[[0;39m1^[[0m
^[[1;39m}^[[0m
```

```sh
SANDHOME_SHIMS=1 . "$SANDHOME_HOME/env.sh"   # on, for this shell
SANDHOME_SHIMS=0 . "$SANDHOME_HOME/env.sh"   # off, for this shell
```

> **Neither can reach a statically linked binary.** A static binary carries its
> own libc, so there is nothing to interpose into. Build the ssh server, or any
> other program the shims must reach, dynamically.

`SANDHOME_PASSWD_USERS=agent,deploy` adds those login names to the synthetic
database  -  an ssh server refuses an unknown account with `Permission denied
(publickey)`, which reads as a key problem and is not one.

## 6. errandsh

`sandhome shell` runs `shell/errandsh`, a POSIX-sh line discipline that gives a
pty-less session echo, line editing, history, completion, bracketed paste and
real signal handling at the prompt. `sandhome shell -c 'cmd'` is an exec channel
with no discipline. It cannot run a full-screen TUI: nothing in userspace can
create `/dev/ptmx`. Its test is `tests/errandsh-posix.sh`, which drives it over
pipes under every shell the host has.

## 7. Troubleshooting

| symptom | first thing to read |
| --- | --- |
| a tool "installed" and is not found | `sandhome space --probe`; the toolchain may have landed on a root that does not run it |
| `Permission denied` running a binary | the home is noexec and the exec view was not built  -  rerun `sandhome install <name>`. It rebuilds the view and probes the tool afterwards, on the adopt path as well as the install path. |
| `fork/exec ... permission denied` after a successful `go build` | the Go build cache landed on a noexec root; re-run the install so `GOCACHE` is written to `SANDHOME_EXEC` |
| `go install` binary neither runs nor is on PATH | `GOBIN` now points at `$SANDHOME_EXEC/go-bin` and is on PATH; re-run `sandhome install go`, then `go install`. Build output in a noexec work tree still will not run: build under `$SANDHOME_EXEC` |
| `npm i -g` CLI not found or `bad interpreter` | the prefix now lives on `$SANDHOME_EXEC/npm-global` with `bin` on PATH; re-run `sandhome install node`. Project-local `.bin` on a noexec checkout has the same cause: run the project from `$SANDHOME_EXEC` |
| `collect2: posix_spawnp: Permission denied` linking rust | the sysroot linker is on the noexec home; `RUSTFLAGS` forces bfd (see the rust fragment), or `sandhome install zig` plus `sandhome install rust --target <triple>` for a zig-cc wrapper |
| the working tree itself is noexec | `sandhome doctor` prints a note naming `$SANDHOME_EXEC`; build and run output there, not in the checkout |
| no echo / no line editing over ssh | the shims are not loaded; `SANDHOME_SHIMS=1` and restart the shell |
| an ssh login is refused with `publickey` | the login name is absent from the synthetic passwd; set `SANDHOME_PASSWD_USERS` |
| a full-screen program fails | there is no pty; this is the one thing `errandsh` cannot fix |
| the exec root filled | `sandhome gc`; staging, exec caches (`cache/`, `tmp/`, `go-bin/` entries older than DAYS), and home tmp older than DAYS are removed, toolchain data stays. `GOCACHE`, `GOBIN`, `NPM_CONFIG_PREFIX`, `CARGO_INSTALL_ROOT`, `CARGO_TARGET_DIR`, and `target/` all land on the exec root: heavy and multi-target builds need a roomy `--exec DIR`. If no candidate fits, the install names the constraint before writing anything |
| the exec root was cleared by a restart | the tmpfs exec view is gone while `env.sh` persists; re-run the setup, then `sandhome install <name>` to rebuild the view |

## 8. The report

`sandhome report` prints one `key=value` per line, and `--json` one object. It is
read from probes: `pty`, `passwd`, `home_exec`, per-toolchain versions, and
`failures`. `sandhome doctor` is the pass/fail view of the invariants a working
home must satisfy.
