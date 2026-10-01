# Decision: one pin per download, and the bare value is a default

Date: 2026-09-28. Status: settled. Supersedes the pinning half of
[fetching-and-digests.md](fetching-and-digests.md).

## What was wrong

`SANDHOME_SHA256` was documented, in `bootstrap.sh --help`, as

```
SANDHOME_SHA256     pin a sha256 for every download this run makes
```

and it was passed to **every** download the run made. One variable cannot hold
three digests and the code did not try to distinguish them, so a toolset with
more than one fetch could only ever match the first one:

```
$ SANDHOME_SHA256=<the digest of the jq binary> sh bootstrap.sh --toolset cli
bootstrap: toolchain jq: not present; installing into …
bootstrap:   sha256 matches the value from SANDHOME_SHA256 (pinned by the caller)
bootstrap: toolchain ripgrep: not present; installing into …
bootstrap: [-] …/ripgrep-15.2.0-…tar.gz does not match the expected sha256
    (got 33e15bcf… with sha256sum, wanted b1c22172…870f)
bootstrap: [-] could not fetch or unpack ripgrep
```

Two things are wrong with that and only one of them is the digest.

1. **The result was order-dependent.** Whichever toolchain was fetched first was
   the only one that could match. A caller who pinned ripgrep's digest instead
   got jq and fd failing. A check whose outcome depends on the order of an
   unrelated list is broken, not strict.
2. **A weaker check the caller set for one download disabled a stronger one.**
   `tools/go.sh` and `tools/node.sh` pass a digest their **publisher** published
   beside the bytes, through the same third argument:

   ```sh
   sh_fetch_verified "$sh_gi_url" "$sh_gi_tar" "${SANDHOME_SHA256:-$sh_gi_sha}"
   ```

   Setting `SANDHOME_SHA256` replaced go.dev's `dl/?mode=json` digest with the
   caller's value, silently. The documentation called that value "the stronger
   check"; in that position it was the weaker one, and it was applied to a
   download the caller never mentioned.

## The rule

One pin per download, resolved in this order. The first match wins.

| order | source | example |
| --- | --- | --- |
| 1 | `SANDHOME_SHA256_<NAME>`, the toolchain name upper-cased | `SANDHOME_SHA256_RIPGREP` |
| 2 | `SANDHOME_SHA256_<ASSET>`, the URL's last path segment, upper-cased, its LAST extension stripped, hyphens turned into underscores | `SANDHOME_SHA256_JQ_LINUX_AMD64` |
| 3 | the value the **publisher** published beside the bytes | go.dev `dl/?mode=json`, nodejs.org `SHASUMS256.txt` |
| 4 | `SANDHOME_SHA256`, the bare value | a default for one-download runs |

Rule 3 above rule 4 is the load-bearing one. A caller who sets the bare value
to pin one download no longer turns off a publisher's digest for another.

## Why the asset spelling uses underscores

`sh_pin_key` derives its key from a **file name**, so it keeps the file's
hyphens: `jq-linux-amd64`. The **variable** a caller sets cannot hold a hyphen
at all:

```console
$ SANDHOME_SHA256_JQ-LINUX-AMD64=bbb sh -c 'echo ok'
dash: 1: SANDHOME_SHA256_JQ-LINUX-AMD64=bbb: not found
```

A POSIX sh assignment is `NAME=word` where `NAME` is `[A-Za-z_][A-Za-z0-9_]*`.
The first design of this decision spelled the variable with hyphens, and the
arm that read it could never see a value because the caller could not set it.
The two spellings are joined by the `case` in `sh_pin_for`, and
`tests/unit.sh` requires both to answer for the same URL.

## Why the lookup is a `case` and not `eval`

POSIX sh has no indirect expansion. The only way to read a variable whose name
is held in another variable is `eval "x=\${$var:-}"`, and that is a `case`
pattern or a **command** as soon as the name contains a hyphen, `*` or `/`:

```console
$ eval "x=\${SANDHOME_SHA256_JQ-LINUX-AMD64:-}"; echo "$x"
dash: 1: eval: Bad substitution
```

Both were produced here before the lookup became a `case` over literals. The
names it has to read are a **closed set**: seven toolchain names and a handful
of asset basenames, all written out. `sh_pin_names` prints the toolchain list
and `tests/unit.sh` requires one entry per module in `tools/`, so a new
toolchain without a pin is a failing clause rather than a silently unpinnable
one.

The same test caught a second one of the same shape: an asset key derived from
`go.tar.gz` is `GO.TAR`, the underscored variable would be
`SANDHOME_SHA256_GO.TAR`, and `eval` on that is `Bad substitution` again. The
guard is now a `case` on the character class, because a value that cannot be a
variable name has no variable to read.

## The provenance line names the pin that answered

`sh_fetch_verified` reports where the expected digest came from, and it reads
that from **the value it was handed**, not from which variables happen to be
set. A first version said `SANDHOME_SHA256` whenever the bare variable was
non-empty, which is true for a run with four pins and false about every one of
them: the download was held to `SANDHOME_SHA256_RIPGREP` and the report named
`SANDHOME_SHA256`. A provenance that cannot be wrong is not a provenance.

```
sha256 matches the value from SANDHOME_SHA256_RIPGREP (pinned by the caller) (taken with sha256sum)
sha256 matches the value from the published digest (taken with sha256sum)
sha256 b1c22172…870f (taken with sha256sum; no digest to compare against)
```

## What is still not proven

A digest fetched from the same release as the bytes proves **transport**, not
authorship. Whoever could replace one could replace the other. That is
unchanged by any of this and is why rule 3 sits above rule 4 only in the sense
of "do not discard a stronger source", never as "trust the publisher".

`SANDHOME_REF` still pins the **repository tarball** and nothing else. Every
toolchain module resolves "latest" at run time, so the same `SANDHOME_REF` on
two days installs two different toolchains. Pinning the bytes is now possible
per download; recording what was installed is not, and that gap is
[the pinned manifest feature request](https://github.com/talaria0101/sandhome/issues/15).
