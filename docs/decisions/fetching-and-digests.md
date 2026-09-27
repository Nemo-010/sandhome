# Decision: one fetch path, and digests that come from the release itself

Date: 2026-09-27. Status: settled.

## The fetch path

`lib/fetch.sh` owns every download and every unpack:

- `sh_fetch URL DEST`  -  `curl`, then `wget`, then BSD `fetch`, and a refusal that
  names the absence rather than failing as a transport error later.
- `sh_fetch_verified URL DEST EXPECTED`  -  fetch, digest, compare, refuse. The
  digest chain asks `sha256sum`, `sha256`, `shasum -a 256`, `openssl dgst`,
  `python3`, `node`, in that order, and **the report names the one that
  answered and where the expected value came from**. Measured:

  ```
  sha256 b1c22172...870f (taken with sha256sum; no digest to compare against)
  sha256 matches the value from SANDHOME_SHA256 (pinned by the caller) (taken with sha256sum)
  ... does not match the expected sha256 (got b1c22172...870f with sha256sum, wanted 0000...)
  ```

  It used to say "matches the release digest" even when the value had been
  pinned by the caller, and never said which tool produced the hash, so a check
  nobody could reproduce was reported as if it could.
- `sh_untar FILE DEST`  -  `.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`, `.tar`,
  `.zip`, with a named warning when the decompressor is absent.

## Where a digest comes from

The expected digest is taken from the release where one is published:

- Go: `https://go.dev/dl/?mode=json`, found by matching the archive's own
  `filename`, because **there is no `.sha256` sidecar**. That URL answers `200`
  with an HTML redirect page, so a naive fetch of it "succeeds" and yields
  `<!DOCTYPE` as a digest.
- Node.js: `SHASUMS256.txt` beside the release.
- Anything else: `SANDHOME_SHA256` pins a value the caller holds, and the run
  prints the computed digest when there is nothing to compare against.

## Two defects found here

1. `sh_first_line` and `sh_first_word` tested `read`'s exit status. `read`
   returns non-zero at EOF **without a newline** and still sets the variable, so
   both answered nothing for `printf 'a'` or a file that does not end in a
   newline. Go's `VERSION?m=text` lookup happened to end in one; the internal
   `sh_first_word printf` did not, and `go` could not resolve a version at all.
   Both now use `read ... || :`. Pinned in `tests/unit.sh`.
2. **A last line with no newline.** `while read` drops it and exits before the
   body has seen it. Measured: a one-line JSON document read through it came
   back as the **empty string**, so the Go release-digest parser and the Node
   index parser both found nothing and the download continued unchecked. The
   readers are `sh_read_file` and `sh_read_file_spaces`, which carry that line
   out of the loop with `read ... || [ -n "$line" ]`.
3. **A digest parser that depended on formatting.** `tc_go_sha_from` set a flag
   on the line carrying `"filename"` and read the `sha256` from a *later* line,
   so it worked only against go.dev's pretty-printed JSON. Against a compact
   document it answered nothing, and the caller passed an empty expected digest
   rather than failing. It now finds the `"filename"` whose value is the one
   asked for and reads the `sha256` in the same object, and reads a document
   that does not end in a newline.
4. The schema assumption itself. `nodejs.org/dist/latest/` redirects to
   `latest-v24.x/`, a **train** and not a version; the version has to come from
   `index.json`, and its first line is `[`, not the first release. Both parsers
   are now tested against a local file through the `SANDHOME_*_URL` overrides.

## What a digest does not prove

A digest fetched from the same release as the bytes proves transport, not
authorship: whoever could replace one could replace the other. `SANDHOME_SHA256`
is the stronger check, and pinning `SANDHOME_REF` to a commit is what makes the
curl-pipe bootstrap reproducible.

Two of the seven toolchains fetch from a source that publishes a digest beside
the archive (Go from `dl/?mode=json`, Node from `SHASUMS256.txt`). The other
five publish none in a form this can read, so their downloads are hashed and
the digest is printed with no value to compare against, which is a weaker claim
than it looks. `SANDHOME_SHA256` pins one, and `SANDHOME_REQUIRE_DIGEST=1`
refuses the download outright when no digest tool is present instead of warning
and continuing.
