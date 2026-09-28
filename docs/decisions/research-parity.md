# Research parity: what the reference sweep taught, and where each line went

Issue #2's brief gave thirteen shell projects and four dispositions: adopt
some, use some directly, document some, reimplement some ourself. The sweep
itself (issue #15) was triage plus evidence only: one issue per reference
(#3, #4, #5, #6, #7, #8, #9, #10, #11, #12, #13, #14, #17), a subject-side
defect filed separately (#16), and nothing implemented. This page records
where every line went once the implementing sessions did the work.

Rule for all of it, per the operator's ruling: mechanisms are reimplemented
in this tree's own words and cited by file and line. No reference code is
pasted anywhere below or in the tree.

## Adopted and implemented

| reference | mechanism | where it lives |
| --- | --- | --- |
| `hackerschoice/hackshell` (#3) | capability probe: run `wget --help`, pick GNU vs BusyBox spelling by literal AND fetch with the matching argv, every fallback under one function name | `sh_tool_runs`, `sh_wget_flavor`, `sh_wget_fetch`, `sh_downloader_ok`, fallthrough `sh_fetch` in `lib/fetch.sh`; minimal twin `sh_fr_runs`/`sh_fr_fetch` in `bootstrap.sh` |
| `oneclickvirt/ecs` (#6) | DoH bootstrap gated on a confirmed resolver failure; endpoint a variable, fallback off unless asked | `sh_fetch_via_doh` and gate in `lib/fetch.sh`; `SANDHOME_DOH_URL`, `bootstrap.sh --doh-url` |
| `ibsgss/TcpQuality` (#10) | shape-validate every manifest field, drop the record on any failure; check before unpacking; third-party bytes state version, source and digest | `sh_is_hex64`/`sh_is_digits`/`sh_is_nonempty` in `lib/fetch.sh`; validated in `tools/go.sh` and `tools/node.sh`; `NOTICE` |
| `masonr/yet-another-bench-script` (#8) | default a nullable field before formatting it | defaults in `lib/report.sh` |
| `nxtrace/NTrace-core` (#13) | name the route the bytes came from; probe the installed binary | `Downloaded from:` lines in `sh_fetch`; post-promote probe already in `lib/toolchain.sh` |
| `kejilion/sh` (#17) | pinned digest compared before bytes are executable; persisted preference | atomic `sh_fetch_verified` in `lib/fetch.sh`; `sh_pref_set`/`sh_pref_get` in `lib/env.sh` |
| `LemonBench/LemonBench` (#5) | dependency preflight: probe and name prerequisites before the run | `sh_toolchain_preflight` in `lib/toolchain.sh` |
| `LloydAsp/NodeBench` (#7) | provider-detecting prerequisite install line | `sh_downloader_hint` in `lib/fetch.sh` |
| `lmc999/RegionRestrictionCheck` (#9) | probe by running, not by resolving | `sh_tool_runs` in `lib/fetch.sh` |
| `leitbogioro/Tools` (#4) | retry-after-verify ordering (their order inverted); sha256 only, md5 refused by name | atomic `sh_fetch_verified`; `sh_expected_wellformed` |
| `vpsxb/testrace` (#14) | probe the specific distribution, not generic linux | `sh_detect_os_id` in `lib/detect.sh` (already did; clause added) |
| `Chennhaoo/Shell_Bash` (#12) | probe availability before acting | `sh_exec_probe` shape in `lib/space.sh` (already did) |

## Refused, and why the refusal is the finding

Eight of the thirteen are benchmark collectors or service installers whose
value is a measurement set or a host configuration, not a mechanism a
toolchain bootstrap lacks. Adopting any of their architectures would be
adopting a problem sandhome does not have. That is the result the sweep's
abandon criterion was written to detect, and it is reported as a result.

- `1-stream/RegionRestrictionCheck` (#11) is a genuine rewrite of #9 at
  two-thirds the size with a live tracker. No mechanism lives in it; the
  mechanism is the rewrite, and the diff against the original is what to
  read if this tree ever forks a reference wholesale.
- The `nxtrace/NTrace-core` mirror-fallback loop is not adopted: this tree
  has one URL per download and no evidence it needs a fallback. Adding a
  mirror client without that evidence would be the defect, not the fix.
- The `kejilion/sh` region-declared mirror selection (never probed, no
  fallback) and the `oneclickvirt/ecs` dead `noninteractive` guard are kept
  as named anti-patterns. The guard for the second is executed:
  `tests/syntax.sh` fails on any `noninteractive` token and on any `SH_`
  flag read without an assignment.
- The `Chennhaoo/Shell_Bash` in-tree binaries with no version manifest are
  the concrete example of what `NOTICE` refuses: every module in `tools/`
  has a row there, and `tests/docs.sh` fails when one does not. Committed
  ELF objects fail `tests/syntax.sh`.
- The `vpsxb/testrace` unpinned `bash <(curl)` of another project is the
  pattern `sh_fetch_verified` exists to refuse.

## What the sweep did not establish

- Nothing from any reference was executed. Every claim about a reference
  is from reading its source at the captured commit; the only runs were
  syntax probes and this tree's own suite.
- The measurements are about this tree, not the references. The one live
  measurement was the `dirname` defect (#16).
- One machine, one day. The sandbox answers no to most capabilities, so
  the network testers' core mechanism could not be exercised here.
- Two trackers were searched, not read end to end (`nxtrace/NTrace-core`
  at 320 records, `masonr/yet-another-bench-script` at 125). A closed
  issue in either contradicting a finding here would not have been seen.
- The second half of #2's brief, "match parity and exceed", is answered
  per mechanism above: each row names the parity point and the place this
  tree exceeds it (fallthrough where they warn, atomic where they write
  first, IP-pinned retry where they hardcode, multi-accept where they take
  one).
