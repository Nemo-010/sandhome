# Decision: the environment is installed once, not sourced per command

Date: 2026-09-29. Status: settled. Supersedes the per-call sourcing the docs
carried before it (ROUTE.md step 4, and `entry.sh` from #122).

## The problem

A harness that runs one tool call per process gives each call a fresh
non-login shell. That shell reads no startup file: `bash -c` sources `BASH_ENV`
only when the variable is set, `sh -c` sources `ENV` only when it is set, and
inside errand neither is set. Environment variables do not survive between
calls. So an install that writes `$SANDHOME_HOME/env.sh` is invisible to the
next command, and the first working answer was to put the file in front of
every command:

```
bash . "$HOME/.local/share/sandhome/env.sh" <some_cmd>
```

That answer is correct and hostile. Every command carries an incantation, and
a reader who omits it once sees `command not found` and concludes the setup
failed. Issue #127 is exactly that report. The fix has to make a fresh shell
find the environment with nothing in front of the command.

## What does not work

- **A login shell file.** A non-login, non-interactive shell does not read one,
  which is the only shell a harness uses.
- **`BASH_ENV`/`ENV`.** Unset, and setting them is the caller's business, not
  the installer's.
- **Writing a wrapper into `$HOME/bin` and adding it to `PATH`.** `$HOME` is
  the noexec root, so the wrapper answers `command -v` and then fails with
  `Permission denied`.
- **A new directory on `PATH` only for login shells.** The profile fragment
  already on the home has this limit; it is not read by the shells that matter.

## The decision

Install a **global hook**: a directory already on `PATH` that the shell
searches for every command, whose contents read the environment and start the
real tool. `sh_global_install` in `lib/env.sh` picks the directory in two
passes:

1. A `PATH` entry that is writable **and** runs binaries. The dispatcher is
   written there in place, so nothing about the host's layout changes.
2. A `PATH` entry that is absent, empty, or already a symlink, on a writable
   root that refuses `execve`. The entry is replaced by a symlink into
   `$SANDHOME_EXEC/global`.

Case 1 is tried first so a working directory is never replaced by a symlink.

The dispatcher is one file keyed on `$0`:

```sh
_sandhome_name=${0##*/}
. "$_sandhome_home/env.sh"
exec "$SANDHOME_EXEC/bin/$_sandhome_name" "$@"
```

Every exposed name is a symlink to that one file, so a toolchain added later
needs a symlink, not a new script, and the environment has one place to live.

Case 2 is the reason this works in a cage at all. `execve` on the looked-up
path is refused, but the kernel resolves the symlink before the mount's exec
policy is consulted, and the policy applies to the **resolved** root, which
does allow `execve`. The noexec home is therefore not a wall; it is a path that
has to be redirected. This is the same asymmetry exploited by
[`exec-split.md`](exec-split.md), used in the other direction.

## Failure is not fatal

A host may have no writable, exec-capable `PATH` directory. Then the hook is
not installed, the report prints `global=none`, and the stable fallback is
`$SANDHOME_HOME/entry.sh`, sourced once per shell. The install itself still
succeeds: `sh_global_install` returns 0 when it has nowhere to write, and
`doctor` does not fail on `global=none`. A host's layout is not an install
error, and a test suite that runs on such a host must not go red over it.

## Safety

- `sh_global_remove` deletes only the names and the dispatcher recorded at
  install time, and only when they are still the files it created. A directory
  it shares with the host is left otherwise untouched.
- Case 2 replaces an entry only when it is absent, empty, or already a symlink.
  A non-empty directory that is not the hook is not overwritten; the scan moves
  to the next candidate.
- Installation records the directory, whether it is a symlink, whether the
  `sandhome` command was copied (it is not copied over a foreign file), and the
  names. `sandhome global --status` reads the record; `sandhome report` prints
  the one line.
- The hook is skipped entirely by `--no-global` or `SANDHOME_GLOBAL=0`, which
  is what the test suite uses so it never writes into a PATH directory the
  machine owns.

## The measurement

On the sandbox this was built in, `HOME=/state/home` is noexec and
`/state/home/.pi/agent/bin` is on `PATH` but holds nothing. After
`sh_global_install`, a shell started with `env -i` and a `PATH` of only the
hook directory ran both a toolchain and `sandhome` by name, and the tool's
output contained a variable that exists only in `env.sh`, which proves the
dispatcher read it rather than merely being found. `tests/global.sh` reproduces
both cases, including the noexec symlink, and asserts the fallback, the
not-installed `127`, and that a foreign file survives a remove.
