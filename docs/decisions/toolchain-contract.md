# Decision: the toolchain module contract

Date: 2026-09-27. Status: settled.

## The contract

One module per toolchain at `tools/<name>.sh`, declaring:

```
TC_<name>_DESC        one line for `sandhome toolchains`
TC_<name>_BINS        relative executables to expose on the exec bin
TC_<name>_REQUIRES    other toolchains to ensure first (optional)
TC_<name>_EXEC_MB     fresh-install exec need in MB (see below)
tc_<name>_probe       return 0 when a working copy is already here
tc_<name>_install     install into $(sh_toolchain_root <name>)
tc_<name>_env         write the env fragment (optional)
tc_<name>_version     print a version (optional)
tc_<name>_exec_mb     computed fresh-install exec need in MB (optional)
tc_<name>_copy_bins   executables that stay real copies in launch mode (optional)
tc_<name>_doctor      health check the readiness gate runs (optional)
tc_<name>_pin URL      digest for this download (optional): consulted after
                    operator-set pins and before the published/default arms,
                    so an outsider module is pinnable without editing
                    `lib/fetch.sh`
```

`TC_<name>_EXEC_MB` prices a fresh install for the up-front feasibility
plan (`feas` lines plus `total_exec_need_mb`), and the module's own install
gate reads the same number, so the two never disagree. A module whose need
depends on the view mode (rust: 25 launch, 150 copy) defines
`tc_<name>_exec_mb` instead. `tc_<name>_copy_bins` names the executables a
memfd image cannot run: anything spawned by path that locates its siblings
exe-relative (measured: gcc's `ld.lld` wrapper, `cargo-clippy`), anything that
reads its own install dir through `/proc/self/exe` (`zig`), and the language
runtimes that fork themselves (`node`, `deno`, `bun` - issue #139, where the
symptom was that every Playwright and webpack spawn died with ENOENT naming
`/memfd:sandhome (deleted)` while `node --version` answered and `doctor` was
green). `tc_<name>_doctor` is a check the readiness gate runs on the toolchain
itself, for a property a version string cannot show: that a runtime can
re-execute itself.

The `copy_bins` list is only useful if it **reaches the promote**, and that took
a fix of its own. `sh_promote_toolchain` read the list through
`sh_copy_only_set`, which asked `command -v tc_<name>_copy_bins` without ever
sourcing `tools/<name>.sh`, so the answer was no and `SH_COPY_ONLY` came back
empty for every module that declared one - measured on `main` for node, deno,
bun, zig and rust alike. `bin/node` was therefore stamped as a launcher in
launch mode, which is exactly what `tc_node_copy_bins` exists to prevent, and
rust's `ld.lld` wrappers and zig's install-dir lookup were stamped too. The
resolver loads the module itself now (`sh_toolchain_load` is idempotent, so
every path is safe), and `tests/space.sh` calls it with nothing pre-loaded so
the property cannot rot.

Functions are namespaced by name because POSIX sh has no namespaces and two
modules defining `install` would silently shadow each other.

## The rules behind it

- **Install into the root the framework names.** A module that picks its own
  location cannot be promoted, reported or garbage-collected.
- **Declare every executable that must be on `PATH`.** The framework links it
  into `$SANDHOME_EXEC/bin` and, when the home is noexec, copies it onto the exec
  root. A binary left undeclared is absent from every shell.
- **Never test a binary by its home path.** The home may refuse exec. Test the
  promoted path, or return and let the framework's post-promote probe decide.
- **Write environment to a fragment, not to `env.sh`.** Each module owns one
  file under `$SANDHOME_HOME/env.d/`; `env.sh` sources them in sorted order, so a
  second module cannot clobber the first.
- **Refuse with a reason.** A missing release asset, an unsupported kernel/arch
  pair, or a failed digest is `sh_warn` plus a non-zero return, never a silent
  skip that later reads as a transport failure.
- **Resolve versions, do not type them.** An asset name carrying a literal
  version is the shape that rots: the module keeps saying it installs while
  upstream moves on. Ask the upstream what is current (`releases/latest`,
  `index.json`, `VERSION?m=text`) and pin the fetched bytes instead of the
  name. A literal is legitimate only where a digest must be held across
  releases, and then it sits beside the pin that justifies it.
- **Price the view mode you install into.** A static `TC_<name>_EXEC_MB`
  prices copy mode; a module whose launch view costs less defines
  `tc_<name>_exec_mb` and both the gate and the plan read it. The figure is
  measured off a real view, with headroom, never guessed.
- **Name every executable a memfd image cannot run** in `tc_<name>_copy_bins`.
  The promote reads that list to decide what lands as real bytes and what lands
  as a 20KB launcher. Three reasons a binary cannot run from memory, all
  measured: it is *spawned by path* and locates its siblings exe-relative (gcc's
  `ld.lld` wrapper, `cargo-clippy`); it finds its own install dir through
  `/proc/self/exe`, which a memfd image hides (`zig`); or it is a **language
  runtime that forks itself**, so `process.execPath` is a path that no longer
  exists by the time a child reads it (`node`, `deno`, `bun` - the last is the
  parent of every worker and every download helper, so Playwright, Puppeteer,
  webpack, vite and jest all break while `node --version` still answers,
  issue #139). A launcher is right for a compiler you invoke once and wrong for
  an interpreter you invoke thousands of times.
- **A `tc_<name>_doctor` hook is where a toolchain's own health check goes.**
  `doctor` runs it and reports `toolchain_<name>_spawn`, so the readiness gate
  cannot be green over a toolchain that cannot do what a *user* does with it.
  Run the user's call, not a proxy for it: `node` spawning itself through
  `process.execPath` is the check, because that is what every UI tool does. Name
  the view copy explicitly rather than trusting the `PATH` the doctor run
  inherited, or it can check a different toolchain's bytes.

## The digest position

A distribution package arrives through a package manager that already checks a
signature over its own index. For a tarball from a release, `sh_fetch_verified`
compares the digest the release publishes when one is available, and
`SANDHOME_SHA256` pins one the caller holds. A run-time digest proves transport,
not authorship: whoever could replace the bytes could replace the digest beside
them.
