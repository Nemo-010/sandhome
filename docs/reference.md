# Reference

GENERATED. Do not edit. `sh docs/generate-reference.sh > docs/reference.md`
rewrites it, and `sh tests/docs.sh` fails when the two differ. Every line
below is extracted from the code that implements it.

## Commands

```
usage: sandhome COMMAND [args]

  doctor                 probe the environment and report what is missing
  env                    print the environment, for `eval "$(sandhome env)"`
  path                   print the exec-view bin directory
  space [--probe]        where the two roots are, and every candidate tried
  toolchains             name, one-line description, PATH binaries, versions
  install NAME...        adopt or install each toolchain, then write the env
  install rust --target T   add rust cross targets (comma list, repeatable)
  ensure NAME...         alias for install
  shims [build]          build the LD_PRELOAD shims this machine needs
  test                   run this checkout's whole test suite
  selftest               the checks that need this machine and no network
  selftest shims         build and exercise the LD_PRELOAD shims
  selftest exec          the noexec-home end-to-end: install, promote, run
  shell [args]           run errandsh, the pty-less line discipline
  exec CMD...            run CMD with the sandhome environment loaded
  report [--json]        the full report
  gc [DAYS] [--dry-run]   remove staging older than DAYS (default 7)
  version                print the schema version
  help                   this text

Environment:
  SANDHOME_HOME   the persistent data root (default $XDG_DATA_HOME/sandhome)
  SANDHOME_EXEC   the exec-capable root; detected when unset
  SANDHOME_REPO   the checkout that holds lib/, tools/ and shell/
  SANDHOME_SHIMS  set to 1 to put the shims in LD_PRELOAD
  SANDHOME_PASSWD_USERS   extra names for the synthetic passwd database
  SANDHOME_SHA256 a default digest for downloads with no pin of their own.
                  Prefer SANDHOME_SHA256_<NAME> (the toolchain, upper-cased)
                  or SANDHOME_SHA256_<ASSET> (the url's last path segment,
                  upper-cased, no extension, hyphens as underscores), which
                  apply to one download. Resolution order: <NAME>, <ASSET>,
                  a digest the publisher published, then this.
  SANDHOME_REF    branch or tag the pipe bootstrap fetches. Default main
  SANDHOME_REPO_DIR   the checkout the installed copy of this command reads.
                      Set by env.sh; read it, do not set it.
  SANDHOME_MIN_EXEC_MB  free megabytes an exec candidate must have to be
                      preferred. Default 128
  SANDHOME_REQUIRE_DIGEST  1 refuses a download when no sha256 tool exists
  SANDHOME_DOH_URL    DNS-over-HTTPS resolver, e.g. https://1.1.1.1/dns-query.
                      Unset, and the fallback is off until it is set. Used
                      only after curl answers exit 6 twice.
  SANDHOME_GO_VERSION_URL, SANDHOME_GO_DL_JSON_URL, SANDHOME_NODE_INDEX_URL
                      point a version or digest parser at a mirror, so the
                      parsers can be tested offline
  SANDHOME_RUST_TARGETS   comma list of rust cross targets to add on install
                      (same as install rust --target T)
  SANDHOME_ZIG_VERSION    pin the zig release (default latest from index)
  SANDHOME_ZIG_INDEX_URL  point the zig version parser at a mirror for tests
```

## bootstrap.sh flags

```
usage: sh bootstrap.sh [options]

  --toolset NAME      minimal | cli | developer | languages | agent.
                      Default developer.
  --with NAME         add a toolchain. Repeatable, and also takes a
                      comma-separated list.
  --without NAME      leave a toolchain out. Repeatable, and also takes a
                      comma-separated list.
  --list-toolchains   print the known names and exit
  --home DIR          persistent data root. Default $XDG_DATA_HOME/sandhome
  --exec DIR          exec-capable root. Default: detected (see sandhome space)
  --no-shims          do not build the LD_PRELOAD shims
  --require-shims     refuse to finish when a needed shim could not be built
  --no-shell          do not install errandsh
  --no-profile        do not install the profile fragment or touch login files
  --no-path-line      do not add the exec bin directory to the login files
  --dry-run           print what would be done and change nothing
  --json              print the report as one JSON object
  --doh-url URL       DNS-over-HTTPS resolver for a confirmed no-resolver
                      cage, e.g. https://1.1.1.1/dns-query. Off unless set;
                      used only after curl answers exit 6 twice (see
                      SANDHOME_DOH_URL below).
  --version           print the schema version (sandhome/1) and exit
  -h, --help          this text

  SANDHOME_REPO       owner/name to fetch when run from a pipe.
                      Default talaria0101/sandhome.
  SANDHOME_REF        branch or tag to fetch. Default main
  SANDHOME_SHA256     a default digest for any download that has no pin of its
                      own. Prefer the per-download forms below, which do not
                      apply to a download the caller did not name.
  SANDHOME_SHA256_<NAME>    pin one toolchain, e.g. SANDHOME_SHA256_RIPGREP.
                      <NAME> is the toolchain name, upper-cased.
  SANDHOME_SHA256_<ASSET>   pin one url asset, e.g.
                      SANDHOME_SHA256_JQ_LINUX_AMD64. <ASSET> is the url's
                      last path segment, upper-cased, without its extension,
                      with hyphens written as underscores.
                      Resolution order per download: <NAME>, then <ASSET>, then
                      a digest the publisher published, then SANDHOME_SHA256.
                      See docs/decisions/pinning.md.
  SANDHOME_DOH_URL    DNS-over-HTTPS resolver, e.g. https://1.1.1.1/dns-query.
                      Unset, and the fallback is off until it is set. Used
                      only after the system resolver fails twice with curl
                      exit 6; the retry pins the resolver by IP literal so it
                      cannot itself need DNS.
```

## Toolsets

| name | toolchains |
| --- | --- |
| `minimal` | jq |
| `cli` | jq ripgrep fd |
| `developer` | jq ripgrep fd python node |
| `languages` | jq ripgrep fd python node rust go |
| `agent` | jq ripgrep fd python node rust go |

## Environment variables

| variable | read by | default |
| --- | --- | --- |
| `SANDHOME_BIN_DIR` | bootstrap.sh sandhome | `$SH_REPO_DIR/bin` |
| `SANDHOME_DOH_CANARY` | fetch.sh | `https://github.com` |
| `SANDHOME_DOH_URL` | fetch.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_EXEC` | env.sh report.sh space.sh bootstrap.sh sandhome fd.sh go.sh jq.sh node.sh python.sh ripgrep.sh rust.sh zig.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_FETCH_DIR` | bootstrap.sh | `$SH_FETCH_DIR` |
| `SANDHOME_GO_DL_JSON_URL` | sandhome go.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_GO_VERSION_URL` | sandhome go.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_HERE` | profile.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_HOME` | env.sh profile.sh space.sh bootstrap.sh sandhome go.sh node.sh python.sh rust.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_MIN_EXEC_MB` | space.sh sandhome | `128` |
| `SANDHOME_NODE_INDEX_URL` | sandhome node.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_NO_PROFILE` | profile.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_NO_REFETCH` | bootstrap.sh | `1` |
| `SANDHOME_NO_RUN` | bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_PASSWD` | env.sh shim.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_PASSWD_USERS` | shim.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_PROFILE` | profile.sh | `1` |
| `SANDHOME_REF` | bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_REPO` | env.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_REPO_DIR` | env.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_REQUIRE_DIGEST` | fetch.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_RUST_TARGETS` | sandhome rust.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256` | fetch.sh bootstrap.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_FD` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_GO` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_LINUX_AMD64` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_LINUX_ARM64` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_LINUX_I386` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_JQ_MACOS_AMD64` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_NODE` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_PYTHON` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_RIPGREP` | fetch.sh bootstrap.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_RUST` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHA256_ZIG` | fetch.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_SHIMS` | env.sh shim.sh sandhome | `unset, and the feature is off until it is set` |
| `SANDHOME_ZIG_INDEX_URL` | sandhome zig.sh | `unset, and the feature is off until it is set` |
| `SANDHOME_ZIG_VERSION` | sandhome zig.sh | `unset, and the feature is off until it is set` |

## errandsh variables

| variable | default |
| --- | --- |
| `ERRANDSH_HISTORY` | `(unset)` |
| `ERRANDSH_MAXHIST` | `(unset)` |
| `ERRANDSH_NAME` | `(unset)` |
| `ERRANDSH_SHELL` | `(unset)` |

## Toolchains

| name | binaries on PATH | description |
| --- | --- | --- |
| `fd` | `bin/fd` | fd, a fast and user-friendly find replacement |
| `go` | `go/bin/go go/bin/gofmt` | Go, from the official go.dev tarball (GOROOT stays in the home root) |
| `jq` | `bin/jq` | jq, the command-line JSON processor (single static binary) |
| `node` | `bin/node bin/npm bin/npx` | Node.js with the bundled npm, from the official nodejs.org tarball |
| `python` | `(via its own PATH fragment)` | CPython, installed by uv (uv is always left on PATH) |
| `ripgrep` | `bin/rg` | ripgrep (rg), the fast recursive search tool |
| `rust` | `cargo/bin/rustup cargo/bin/cargo` | Rust via rustup (rustc, cargo, rustup; minimal profile) |
| `zig` | `zig` | zig cc cross compiler (also links native rust when the sysroot is noexec) |

## Tests

| file | what it checks |
| --- | --- |
| `sh tests/syntax.sh` | that will read it. `dash -n` is the check that matters; bash --posix is a |
| `sh tests/unit.sh` | machine. A helper exercised only through a full bootstrap is a helper whose bug |
| `sh tests/space.sh` | tests/space.sh - the two-root plan, the exec probe and the mirror. |
| `sh tests/toolchain.sh` | requirements cycle must be refused, and a linear requirement must install in |
| `sh tests/shims.sh` | tests/shims.sh - build and actually use both LD_PRELOAD shims. |
| `sh tests/docs.sh` | tests/docs.sh - the documentation is checked against the code, not trusted. |
| `sh tests/bootstrap.sh` | does NOT run binaries, prove the exec split put it where it runs, and prove the |
| `sh tests/errandsh-posix.sh` | errandsh's test, and it is a test rather than a claim. |
