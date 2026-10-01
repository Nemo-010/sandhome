# AGENTS.md

Orientation for an agent working ON this repository. It routes; it does not
teach. Everything below is a pointer, and every pointer is checked by
`tests/docs.sh` so it cannot rot.

**If you are a CONSUMER and not a maintainer, you do not need this file.** The
entry point is:

```
https://raw.githubusercontent.com/talaria0101/sandhome/main/ROUTE.md
```

That one file tells an agent how to set up, check, get to work, and diagnose
a failure, without reading anything else. The skill at
`skills/sandhome/SKILL.md` carries the same fast path for harnesses that
discover skills from a `skills/` directory.

## What this repository is

A portable home for agents that run inside a sealed sandbox. One bootstrap, one
environment, POSIX `sh` throughout, and a hard rule that is worth reading once:

> A writable mount can still refuse `execve`. Data and executables may need
> different roots, and only running a file tells you which is which.

## The map

| path | what it is | read it when |
| --- | --- | --- |
| `AGENTS.md` | this router | you are working on the repository |
| `skills/sandhome/SKILL.md` | **the consumer entry point** | you want to set up a sandbox |
| `skills/errandsh/SKILL.md` | a pty-less line discipline | a remote shell has no echo |
| `skills/sealed-sandbox/SKILL.md` | operating inside a cage | something is denied |
| `docs/guide.md` | the long form: every option, every variable, every failure mode | you need detail the skill does not carry |
| `docs/architecture.md` | the two roots, the mirror rules, the toolchain contract | you are changing a lib file or adding a toolchain |
| `docs/decisions/` | settled shapes and the measurement behind each | before changing an interface one describes |
| `docs/reference.md` | **generated**: every command, flag and variable, extracted from the code | never read by hand; regenerate it |

## Working rules

1. **Measure, do not assume.** A mount can be `rw` with no `noexec` in its
   options and still refuse `execve`. `sh_exec_probe` runs a real file for
   exactly this reason. Every report in this tree is read from the machine;
   keep it that way in anything you add.
2. **The suite is the gate.** `sh tests/run.sh`. `passed`, `skipped` and
   `failed` are three different claims and only `failed` turns it red.
3. **Every new claim gets a clause.** A defect is not fixed until a test fails
   against the code as it was and passes after. This is the whole standard the
   tree is held to.
4. **POSIX `sh`, and the dependency set is a decision.** No `local`, no arrays,
   no `[[`, no `$'...'`. The library may not use `awk`, `sed`, `grep`, `tr`,
   `find`, `install` or `dirname`: a bootstrap whose job is installing the
   missing tools cannot require them first. `uname` and `id` are the exceptions
   POSIX guarantees.
5. **No recursion in shell functions.** POSIX `sh` has no locals, so a
   recursive function overwrites its caller's variables. Every walk here is a
   queue. `sh_promote_tree` was recursive and it silently mirrored 32 files to
   the wrong paths.
6. **Nothing runs at shell start that can fail.** The profile fragment fetches
   nothing, defines no alias and no prompt, and returns early for a
   non-interactive shell.

## Changing something

| to change | edit | then run |
| --- | --- | --- |
| a command or a flag | `bin/sandhome` or `bootstrap.sh`, and the `usage` text in the same file | `sh tests/docs.sh && sh tests/unit.sh` |
| the environment `env.sh` writes | `lib/env.sh` (`sh_env_body`) | `sh tests/unit.sh` |
| the two-root plan | `lib/space.sh` | `sh tests/space.sh` |
| a toolchain | `tools/<name>.sh` | `sandhome selftest && sh tests/toolchain.sh` |
| the mirror | `sh_promote_tree` in `lib/space.sh` | `sh tests/space.sh` |
| a shim | `shims/*.c` | `sh tests/shims.sh` |
| the line discipline | `shell/errandsh` | `bash tests/errandsh-posix.sh` |
| any of the above, docs too | | `sh tests/run.sh` |

`docs/reference.md` is generated from the code by `sh tests/docs.sh`, which also
checks every flag and variable the docs name against the code that implements
it. Run it after any change to a command, a flag or a variable. It fails rather
than warning: a document that names a flag the code does not have is the exact
failure this rule exists to prevent.

## Adding a toolchain

Drop `tools/<name>.sh`:

```sh
TC_<name>_DESC='one line for sandhome toolchains'
TC_<name>_BINS='bin/tool'          # every executable that must be on PATH
TC_<name>_REQUIRES='other'         # optional; ensured first
TC_<name>_EXEC_MB=32               # fresh-install exec need in MB, for the feas plan
tc_<name>_probe()   { ...; }       # 0 when a working copy is already here
tc_<name>_install() { ...; }       # install into $(sh_toolchain_root <name>)
tc_<name>_env()     { ...; }       # write the env fragment (optional)
tc_<name>_version() { ...; }       # print a version (optional)
tc_<name>_adopted() { ...; }       # where the working copy is, when adopted
```

The contract and the reasoning behind each rule are in
`docs/decisions/toolchain-contract.md`; the short version is in
`docs/architecture.md` section 5. A module that installs into its own location,
declares nothing in `_BINS`, or tests a binary by its home path is wrong, and
each of those was a measured defect rather than a style opinion.

## Before you push

```sh
sh tests/run.sh        # 200+ clauses; only `failed` is a non-zero status
sh tests/docs.sh       # the docs name only flags that exist
```

Plain ASCII throughout, including comments. A non-ASCII byte in a shell file is
a portability question and the answer is no.
