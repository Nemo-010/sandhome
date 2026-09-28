# ROUTE.md

**One paste, any sandbox.** Nothing to clone, nothing to fill in, no prompt
to pick. You are reading this because somebody pasted its URL into a session
and asked you to set up first and work second.

**This file is self-contained.** Fetch the rest only once you know which row
you are on.

Everything below is fetched from, and run against, this base:

```text
https://raw.githubusercontent.com/talaria0101/sandhome/main
```

The human paste that points here reads like this:

```text
Setup your env as per https://raw.githubusercontent.com/talaria0101/sandhome/main/ROUTE.md and then <the task>.
```

When you receive that, it means: follow this file through setup, confirm
the check at the end of step 2 exits 0, then do the task without reporting
back on setup at all.

---

## Before you copy any command

The bootstrap names its own downloader when one is chosen, so you do not
have to. A machine with none of curl, wget or fetch says so in one sentence
and names the install command. A scratch directory is whatever this host
actually has:

```sh
printf 'scratch: %s\n' "${TMPDIR:-/tmp}"
```

If this host has no POSIX shell at all, stop and say so. The whole tree is
POSIX sh and there is no other spelling of it.

---

## Two rules before you do anything

**1. When the check exits 0, the sandbox is ready. Start the task.**

Do not end your turn to report that setup worked. Do not ask about setup.
If the check fails, report its exact lines and hold. A finished turn is a
session the operator has to restart.

**2. Read only what the row names.**

This file routes. It restates nothing, so it cannot fork from the document
it points at. The link is the authority. Pages written for maintainers
(`AGENTS.md`, `docs/architecture.md`, `docs/decisions/`) are not for this
session. If the task is to change this repository itself, stop here and read
`AGENTS.md` instead.

---

## Step 1. Look at the machine. Do not ask yet.

```sh
command -v sandhome
```

```sh
sandhome doctor
```

```sh
sandhome space --probe
```

That answers most of it:

| what you see | the state is |
| --- | --- |
| no `sandhome` on PATH and no `env.sh` under the data root | fresh sandbox, go to step 2 |
| the checkout is here (`bootstrap.sh` and `bin/sandhome` beside you) and the task changes this repository | maintainer session, read `AGENTS.md` and put this file away |
| the check at the end of step 2 exits 0 | ready, do the task |
| the check fails | find the symptom in step 3 and follow that row |

Do not infer a capability from a package list or a mount option. A mount
can be writable, show no refusal flag anywhere, and still refuse to run a
file. The probe above runs a real file for exactly this reason.

---

## Step 2. Set up, in four commands.

From nothing but a network:

```sh
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/bootstrap.sh | sh -s -- --toolset developer
```

```sh
. "$HOME/.local/share/sandhome/env.sh"
```

```sh
sandhome doctor
```

```sh
sandhome toolchains
```

From a clone, the first command is instead:

```sh
sh bootstrap.sh --toolset developer
```

The run detects the machine, plans the two roots, adopts each toolchain
that already answers and installs the ones that do not, builds the shims
this machine actually needs, writes `env.sh`, and prints a report read from
the machine. The third command exits 0 only when every invariant holds.
The fourth names what is here and how each tool reaches PATH.

Toolsets: `minimal` (jq), `cli` (plus ripgrep and fd), `developer` (plus
python and node, the default), `languages` and `agent` (both plus rust and
go). Add one with `--with rust`, drop one with `--without node`. Both flags
repeat and both take a comma list. Exit `0` done, `1` something asked for
could not be done, `2` could not run at all. Every flag, variable and
command is specified in `docs/reference.md`, which is generated from the
code, so it overrules any other page that disagrees with it.

### The skills, where the harness finds them.

A harness discovers skills from `~/.agents/skills/` (Pi also reads
`~/.pi/agent/skills/`). Without a clone, fetch each one by URL:

```sh
mkdir -p "$HOME/.agents/skills/sandhome" "$HOME/.agents/skills/errandsh" "$HOME/.agents/skills/sealed-sandbox"
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills/sandhome/SKILL.md -o "$HOME/.agents/skills/sandhome/SKILL.md"
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills/errandsh/SKILL.md -o "$HOME/.agents/skills/errandsh/SKILL.md"
curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills/sealed-sandbox/SKILL.md -o "$HOME/.agents/skills/sealed-sandbox/SKILL.md"
```

From a clone, link instead of copying, so later pulls update them:

```sh
ln -s "$PWD/skills" "$HOME/.agents/skills/sandhome"
```

Confirm all three landed, then read them in this session. A new session
picks them up on start. There is no reload command.

```sh
ls "$HOME/.agents/skills/sandhome/SKILL.md" "$HOME/.agents/skills/errandsh/SKILL.md" "$HOME/.agents/skills/sealed-sandbox/SKILL.md"
```

---

## Step 3. One table. The symptom decides the row.

More than one row can apply and then both are read.

| the symptom or the ask | read, in full |
| --- | --- |
| install or adopt another toolchain later, or list what is here and how it reaches PATH | `skills/sandhome/SKILL.md` |
| a tool installed and is not found, or a binary answers Permission denied | `skills/sandhome/SKILL.md` diagnose part, then `docs/guide.md` section 7 |
| a Go program compiles and then fails to run with a permission error | `docs/guide.md` section 4 |
| a remote shell has no echo, no line editing, no signals | `skills/errandsh/SKILL.md` |
| an ssh login is refused, a program needs a passwd entry or a terminal, bind is denied, there is no pty | `skills/sealed-sandbox/SKILL.md` |
| the exec root is full | `docs/guide.md` section 7, which carries the `gc` row |
| the exact spelling of a flag, a variable or a command | `docs/reference.md` and nothing else |
| change this repository: a lib file, a toolchain, a shim, the line discipline | `AGENTS.md`, which is the maintainer router |

A row you cannot match is not a row that does not exist. Say what the
symptom was, name the closest two rows, and read both. Do not invent a
procedure because the table did not name one.

---

## Step 4. Whatever the row said, these hold

A toolchain already on PATH is adopted, not downloaded. The report says
which. Adoption is the common case on a long lived base.

The shims are opt in and stay opt in. Build them with the `shims`
subcommand and load them for one shell with `SANDHOME_SHIMS` set to 1.
The default is off for a measured reason: the terminal interposer makes
every terminal aware program colourise a pipe, which breaks clean output
from tools like jq and git.

The environment file is the single source of truth, and sourcing it is a per-session cost, not a setup step. Every new shell, including every non-login tool shell, must load it again before `sandhome` or any toolchain is on PATH. In a shell that sources files, source it. Where sourcing is not possible, load it through eval, which survives `sh -c`:

```sh
eval "$(sandhome env)"
```

```sh
sh -c 'eval "$(sandhome env)"; sandhome doctor'
```

A toolchain that installed without an error and still does not answer is
reported as a failure. Run the `install` subcommand for that name again:
it rebuilds the exec view and probes the tool afterwards, on the adopt
path as well as the install path.

---

## Step 5. Before acting on required reading, print the receipt

Whichever row you took names files to read in full. For each one report
its line count and the heading of its last section:

```sh
wc -l FILE && grep '^#' FILE | tail -1
```

A line count alone is available from a listing. The last heading is not.
Reaching it means reaching the end of the file, which is the part a skim
drops. A receipt for a file you did not read is a fabricated measurement,
which is worse than saying you skipped it.

---

## What this file is not

Not a substitute for the file it routes you to. Reading this row is not
reading that document.

Not a procedure. It ends the moment setup checks out or the symptom finds
its row.

Not permission to change this repository. Rows that touch the tree stop
for the maintainer router first.

Not a list of everything this repository can do. The generated reference
is the full map of commands, and a session whose symptom matches no row
should say so rather than improvise.
