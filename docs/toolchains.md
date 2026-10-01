# Adding a toolchain

Two ways to add a tool, depending on how much of it there is.

## The common case: `sandhome add`

One static asset, one name on `PATH`, an optional digest:

```sh
sandhome add NAME --url URL [--sha256 DIGEST] [--bin PATH] [--desc TEXT]
```

`sandhome add` writes a module into the durable local directory
(`$SANDHOME_HOME/toolchains.d/`, see below) and installs it, so
`doctor`, `toolchains` and `repair` treat it like any shipped toolchain.
`--bin` names the executable inside the asset, relative to the toolchain
root (`bin/tool`); without it the asset's own basename is exposed. A `.tar.*`,
`.tgz` or `.zip` asset is unpacked first, anything else is placed as one
binary. `--sha256` pins the download; without it the digest is taken and
printed, held to nothing.

```sh
sandhome add shfmt --url https://github.com/mvdan/sh/releases/latest/download/shfmt_v3.12.0_linux_amd64
sandhome add yq --url https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 --sha256 <digest>
```

`sandhome add NAME --scaffold` writes the same module without installing it,
for the cases below: edit the install function, then `sandhome install NAME`.

## The bespoke case: write a module

A module is one file, `tools/<name>.sh` in a clone or
`$SANDHOME_HOME/toolchains.d/<name>.sh` on a setup, declaring:

```sh
TC_<name>_DESC='one line for sandhome toolchains'
TC_<name>_BINS='bin/tool'          # relative executables to expose
TC_<name>_REQUIRES='other'         # optional; ensured first
TC_<name>_EXEC_MB=32               # fresh-install exec need in MB

tc_<name>_probe()   { ...; }       # 0 when a working copy is already here
tc_<name>_install() { ...; }       # install into $(sh_toolchain_root <name>)
tc_<name>_env()     { ...; }       # write the env fragment (optional)
tc_<name>_version() { ...; }       # print a version (optional)
tc_<name>_exec_mb() { ...; }       # computed exec need when it depends on
                                   # the view mode (optional)
tc_<name>_copy_bins() { ...; }     # executables that stay real copies in
                                   # launch mode (optional)
tc_<name>_pin URL   { ...; }       # digest for this download (optional)
```

The framework adopts when `tc_<name>_probe` succeeds and installs otherwise,
promotes `TC_<name>_BINS` into the exec view, writes the env fragment, and
probes again: a toolchain that installed "without an error" and still does not
run fails loudly. The full contract, with the reasoning behind each rule, is
`docs/decisions/toolchain-contract.md`; start from `sandhome add NAME
--scaffold` rather than a blank file, because the generated module carries the
rules as comments.

Three rules decide most designs:

- Install into `sh_toolchain_root <name>` and promote only what must execute.
  Never test a binary by its home path; the home may refuse exec.
- Put exec-only caches on `SANDHOME_EXEC`. Downloads and module caches are
  data and stay in the home.
- Resolve versions, do not type them: read `releases/latest`, `index.json`
  or `VERSION?m=text`, and pin the fetched bytes instead of the name.

A module's digest lives with the module: `tc_<name>_pin` answers it, or the
operator sets `SANDHOME_SHA256_<NAME>`. The operator's pin wins; the module's
ranks above the publisher sidecar and the bare default. Either way an outsider
module is verified like a shipped one.

## Where local modules live

`$SANDHOME_HOME/toolchains.d/` is scanned ahead of the shipped `tools/`, so a
local module survives every reinstall and sync and wins a name clash visibly:
`sandhome toolchains` marks each module `local` or shipped (and `--json`
carries an `origin` field). The directory does not exist until something is
added; nothing in the shipped tree reads it until then.
