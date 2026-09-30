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

- **A login shell file alone.** A non-login, non-interactive shell reads none,
  which is the only shell a harness uses. The profile fragment now loads the
  environment for every login shell as well (issue #131: a non-interactive
  `bash -lc` got the exec bin on `PATH` from `~/.profile` but never the roots,
  so every launch-mode copy in it died), but that covers only shells that read
  a login file at all, so it cannot be the answer on its own.
- **`BASH_ENV`/`ENV`.** Unset, and setting them is the caller's business, not
  the installer's.
- **Writing a wrapper into `$HOME/bin` and adding it to `PATH`.** `$HOME` is
  the noexec root, so the wrapper answers `command -v` and then fails with
  `Permission denied`.
- **A new directory on `PATH` only for login shells.** The profile fragment
  already on the home has this limit; it is not read by the shells that matter.

## Three things the hook has to do, and each was a measured failure

The first version installed the hook and exposed the exec view. Consuming it as
a user found three gaps, each of which is now part of the decision.

**1. A view name whose only `PATH` hit is inside this tree must still be
exposed (issue #132).** `env.sh` puts `views/<name>/bin` and the toolchain
prefixes on `PATH`, so asking "does `PATH` already find this name?" answered
yes for tools that only a shell which has *already read the environment* can
find - which is the shell the hook exists to make unnecessary. `npm` and `npx`
were the two names lost this way, because they are the only symlinks in the view
that point at a script, so a filter looking for scripts-to-wrappers caught them
and the ELF names slipped through. The test is the exec **root**, not the view
bin: a hit under `$SH_EXEC` does not count; a hit outside it is a real host
copy and is still filtered.

**2. A directory this tree creates to hold executables is never a hook
directory (issue #138).** `npm install -g cowsay` writes
`bin/cowsay -> ../lib/node_modules/cowsay/cli.js`, a **relative** link the
kernel resolves against the link's *real* directory. While `bin` was a symlink
to `$SH_EXEC/global`, that resolved under `$SH_EXEC` instead of the prefix and
every `npm i -g` CLI was dangling while npm reported success. The refusal is by
**exact path** against one list (`sh_global_sandbox_dirs`), because a prefix
match would also refuse `npm-global/lib`, which is the directory those relative
links resolve *into*. An older hook already sitting in one of those
directories is repaired rather than merely refused in future: our own link is
removed, the directory is restored, and the stranded relative links are moved
back.

**3. The CLIs installed afterwards have to be on the `PATH` a fresh shell
searches (issue #138 again).** Restoring the prefix directory makes `npm i -g`
write a good link, and the CLI is then reachable from a sourced shell and from
any tool the hook starts - but a shell that has not run a hooked command and is
not a login shell still does not search the prefix, and a fresh shell is
exactly the case this whole decision is about. Two things close it, and neither
is enough alone: the dispatcher prepends the sandbox bin directories to the
`PATH` of the tools it starts, in `env.sh`'s order so the result is identical;
and the hook's name list reads those directories **from disk** rather than from
a record, because they change every time an operator installs something and a
recorded list would be stale the moment it was written. A login shell is covered
separately by the profile fragment, and a shell with no `PATH` at all by
`entry.sh`.

## The decision

Install a **global hook**: every directory already on `PATH` that is writable
and runs binaries, holding one dispatcher that reads the environment and starts
the real tool. `sh_global_install` in `lib/env.sh` classifies each `PATH`
entry in two passes:

1. A `PATH` entry that is writable **and** runs binaries. The dispatcher is
   written there in place, so nothing about the host's layout changes.
2. A `PATH` entry that is absent, empty, or already a symlink, on a writable
   root that refuses `execve`. The entry is replaced by a symlink into
   `$SANDHOME_EXEC/global`.

Case 1 is tried first so a working directory is never replaced by a symlink.

Every qualifying entry is taken, not only the first, up to `SH_GI_MAX_DIRS`
(6). Different shells inherit different `PATH`s: a harness that rebuilds
`PATH`, an `env -i` shell with a subset, and a login shell with a wider one do
not agree on entry zero, so a hook that lives in one directory only is a hook
some of those shells cannot see. Any one of them being correct is enough, which
is the redundancy the design is buying. The install plan is the current
candidates plus every recorded directory: a refresh repairs an entry that
dropped off this shell's `PATH` instead of forgetting it, and an entry is
looked up by its path in the record, never by its position, because `PATH`
order moves between runs.

The dispatcher is one file keyed on `$0`. Its shape, abbreviated (the real
one also carries the prefixed-bin loop, the `env -i` probe marker and a
last-resort search of the prefix):

```sh
_sandhome_name=${0##*/}
. "$_sandhome_home/env.sh"
for _sandhome_sb in "$SANDHOME_EXEC/npm-global/bin" "$SANDHOME_EXEC/uv-bin"; do
    [ -d "$_sandhome_sb" ] || continue
    case ":$PATH:" in *":$_sandhome_sb:"*) continue ;; esac
    PATH="$_sandhome_sb:$PATH"
done
export PATH
exec "$SANDHOME_EXEC/bin/$_sandhome_name" "$@"
```

The directory list is generated from `sh_global_sandbox_dirs` so the dispatcher's
`PATH` and the refusal in point 2 above cannot name different directories.

Every exposed name is a symlink to that one file, so a toolchain added later
needs a symlink, not a new script, and the environment has one place to live.

Case 2 is the reason this works in a cage at all. `execve` on the looked-up
path is refused, but the kernel resolves the symlink before the mount's exec
policy is consulted, and the policy applies to the **resolved** root, which
does allow `execve`. The noexec home is therefore not a wall; it is a path that
has to be redirected. This is the same asymmetry exploited by
[`exec-split.md`](exec-split.md), used in the other direction.

## Failure is not fatal, staleness is not

A host may have no writable, exec-capable `PATH` directory. Then the hook is
not installed, the report prints `global=none`, and the stable fallback is
`$SANDHOME_HOME/entry.sh`, sourced once per shell. The install itself still
succeeds: `sh_global_install` returns 0 when it has nowhere to write, and
`doctor` does not fail on `global=none`. A host's layout is not an install
error, and a test suite that runs on such a host must not go red over it.

A recorded directory that stops answering is a different thing, and it is the
#127 failure returning. The install therefore verifies its own result: after
the commit, every recorded directory is run under a fresh `env -i` shell with
a bounded timeout (`SH_PROBE_TIMEOUT_SECS`, so a wedged dispatcher reads as
not-answering rather than hanging a doctor run), and the dispatcher has to
print `sandhome-dispatch loaded=yes exec=<root>` back. `sh_global_report` and
`doctor` read that probe rather than the install's own claim, so:

- `global=on:<dir>`: a recorded directory answered a fresh shell.
- `global=stale:<dir>`: recorded, and no longer answering. `doctor` fails and
  its `wanted` text names `sandhome global` as the repair. A partially
  degraded record (one entry stale, another serving) still reads `on:` from
  the first directory that answers, because the gate is "can a fresh shell
  work"; `global --status` names the stale entry and its state per directory.
- `global=none`: nothing was recorded. It passes.

## Safety

- `sh_global_remove` restores what the install recorded finding, per
  directory: an empty directory comes back as a directory, a dangling symlink
  comes back as that symlink, an absent entry stays absent. It deletes only
  names and dispatchers the install created, and only when they are still
  what it created; a directory it shares with the host is left otherwise
  untouched. Install may take an entry the host was not using, but it has to
  put the entry back the way it was.
- Case 2 replaces an entry only when it is absent, empty, already a symlink,
  or a dangling link. A non-empty directory that is not the hook is not
  overwritten; a host file that already answers a view name is never
  shadowed, it is counted as a clash and named by `global --status`, and the
  scan keeps the entry it was given.
- Installation records the directory, whether it is a symlink, what was
  there before (the original state, so remove can restore it), whether the
  `sandhome` command was copied (it is not copied over a foreign file), and
  the names. `sandhome global --status` reads the record back, one `hook=`
  line per directory with its state; `sandhome report` prints the one line.
- The hook is skipped entirely by `--no-global` or `SANDHOME_GLOBAL=0`, which
  is what the test suite uses so it never writes into a PATH directory the
  machine owns. The switch is honored in `sh_global_install` itself, not only
  in the bootstrap, because `sandhome install` and `sandhome repair` call it
  directly; a suite that exported the switch still had the hook written into
  the machine's real `PATH` by those two commands until it was moved there
  (issue #127).
- A view entry that is a symlink to a `#!` wrapper script which `PATH` already
  finds is not exposed by the hook. The dispatcher execs the view entry, so a
  wrapper that re-resolves its own name (errand's `gh`) would find the hook
  link and exec itself forever; an ELF binary cannot, so only the symlinked
  script is filtered and `PATH` keeps serving it.

## The measurement

On the sandbox this was built in, `HOME=/state/home` is noexec and
`/state/home/.pi/agent/bin` is on `PATH` but holds nothing. After
`sh_global_install`, a shell started with `env -i` and a `PATH` of only the
hook directory ran both a toolchain and `sandhome` by name, and the tool's
output contained a variable that exists only in `env.sh`, which proves the
dispatcher read it rather than merely being found. `tests/global.sh` reproduces
both cases, including the noexec symlink, and asserts the fallback, the
not-installed `127`, and that a foreign file survives a remove.

A consumer-shaped run of the same thing (two qualifying directories: a
writable exec-capable one, and an absent entry under the noexec home, so one
dispatcher is written in place and one is a symlink into the exec root)
measured, on 20 runs of one command each on this host: hook 49 ms, bare PATH
58 ms, per-command `. env.sh` 154 ms, so the hook is inside the noise of
running the tool at all and about three times cheaper than the incantation it
replaces. Every recorded directory then served a fresh shell on its own, a
shell with no `PATH` entry in common with the record still found `sandhome`
through the surviving directory, and after the exec root was deleted,
`doctor` failed with the three wanted toolchains named, `sandhome resume`
rebuilt the views, re-verified the hook, and exited `doctor_failures=0`.
The run is `consumer-proof/run-proof.sh` and its log is kept beside it.
