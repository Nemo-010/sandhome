---
name: errandsh
description: Drive an interactive shell over a pty-less SSH session with errandsh - echo, line editing, history, tab completion and Ctrl-R where there is no /dev/ptmx. Use when a remote shell has no echo or line editing, when ssh -t degrades to a dumb pipe, or when testing a pty-less session.
---

# errandsh

`errandsh` is a line discipline for a session that has no pty. A sealed cage has
no `/dev/ptmx` and no devpts, so a remote shell arrives with no echo, no line
editing and no signals. `errandsh` provides those in POSIX `sh`.

## Run it

```sh
sandhome shell                 # interactive
sandhome shell -c 'make test'  # exec channel, no line discipline
sh shell/errandsh              # from the checkout
```

`sandhome shell` runs the copy on the exec root when a bootstrap placed one
there, and the checkout's copy otherwise, so it works from any shell that has
read `$SANDHOME_HOME/env.sh`.

As a remote login shell, set it on the server side and connect with plain
`ssh`. The transport is whatever the operator already has: this repository
carries the line discipline, not a client, and a transport where both peers
dial out is the one that works in a cage that cannot `bind(2)`.

## Environment

| variable | meaning | default |
| --- | --- | --- |
| `ERRANDSH_NAME` | the name in the prompt | the hostname up to its first dot, cut to 24 characters |
| `ERRANDSH_HISTORY` | the history file | `$HOME/.errandsh-history` |
| `ERRANDSH_SHELL` | the shell commands run in | `/bin/sh` |
| `ERRANDSH_MAXHIST` | history lines kept in the session | 500 |
| `NO_COLOR` | set to anything to drop colour | unset |

## What it does and does not do

It gives echo, a prompt carrying the last exit code, history with Up/Down,
Left/Right/Home/End/Delete, `Ctrl-A E B F K U W`, `Ctrl-R` reverse search, tab
completion, and bracketed paste.

It cannot run a full-screen TUI: nothing in userspace can create `/dev/ptmx`.
While a command runs the session is not reading keys, so `Ctrl-C` is delivered
by the operator's own client and type-ahead is read after the command finishes.

## Test it

```sh
bash tests/errandsh-posix.sh
```

The test drives it over pipes, not a pty, under every shell the host has, and
asserts the recalled text and the cursor-walk escape, because a cursor movement
on a short line looks like no movement at all. It prints `N shell(s) passed,
0 failed` and exits non-zero on any clause that did not hold.
`sh tests/run.sh` includes it.

## The related shims

When a program other than an interactive shell needs to believe a pipe is a
terminal, `fakepty.so` is the `LD_PRELOAD` interposer:

```sh
sandhome shims                              # build what this machine needs
SANDHOME_SHIMS=1 . "$SANDHOME_HOME/env.sh"  # load them, for this shell
```

**It is off by default and must stay off**, because it makes every
terminal-aware program colourise a pipe, and that breaks `jq -r`, `git` and
`ls --color=auto`. Neither shim can reach a static binary. The same contract is
in `sandhome help`; the long form is `docs/architecture.md` section 6 with
`skills/sealed-sandbox/SKILL.md`.
