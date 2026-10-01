# consumer proof for #131-#139

Two logs, one script, one host. Read them in that order: the first is what the
tree answered before, the second is what it answers now, and every difference
between them is a claim with a command beside it.

| file | what it is |
| --- | --- |
| `FAILING-BEFORE-main.log` | the nine reports reproduced against `main` (`aff8491`'s parent, `a8bf21b`) |
| `PASSING-AFTER-fix.log` | the same nine checks against this branch |
| `issues.sh` | the script that produced both, one section per report |
| `build.sh` | the consumer-shaped install: HOME on the noexec mount, exec root on the roomy one |

## The host, because exec permissions differ by sandbox and the numbers mean nothing without it

Linux x86_64, glibc, uid 0, no `/dev/ptmx`, no `/etc/passwd`, no listener,
`bind=unix` only. **`memfd_create` is blocked by seccomp on this host**, so the
launch (run-from-memory) view cannot be exercised by a real install: the run
says `view=copy` and `memexec=built but the probe fails here; views fall back to
copies`. Two consequences the logs state rather than hide:

1. Wherever a launch-mode behaviour is under test, the fixture **stamps
   `shims/memexec.c` over the view copies by hand**, which is exactly what
   launch mode does, and says so in a `fixture:` line.
2. The copy-list fix in `tests/space.sh` is verified **by construction**: with
   `SH_VIEW_MODE=launch` the promote produced a 17-byte launcher where the real
   binary is 150425704 bytes, and produces the real bytes once the module's copy
   list reaches the reader.

`/workspace`, `/state` and `/tmp` are directories here, but a file written into
`/tmp` or `/state` cannot be `execve`d, which is the split this tree exists for.
The `dash -c` form of a login shell reads no startup file at all, so a
**non-interactive LOGIN** shell (HOME set, `bash -lc`) is the faithful #131
fixture, and the same shell reports `SANDHOME_EXEC` before and after the fix.

## Reproducing

```sh
# a pristine main, for the before log
mkdir -p /tmp/mainunit && git -C /workspace/sandhome archive main | tar -x -C /tmp/mainunit

# the rig: HOME on the noexec mount, exec root on the roomy one
sh build.sh /tmp/mainunit              /workspace/tri/before /state/before-home /workspace/tri/before-exec developer
sh build.sh /workspace/sandhome        /workspace/tri/after  /state/after-home  /workspace/tri/after-exec  developer

# the checks
sh issues.sh /tmp/mainunit       before /state/before-home /workspace/tri/before-exec --stamp
sh issues.sh /workspace/sandhome after  /state/after-home  /workspace/tri/after-exec  --stamp
```

Each section names the issue, the command and the answer. Two sections carry
their own **control**: #138 runs the same npm link in a real `bin` directory and
shows it working, and #139 stamps the view and shows `doctor` failing and then
passing when the copy is restored, so the gate is seen to fire rather than
assumed to.

## What each section proves, in one line

| report | before | after |
| --- | --- | --- |
| #131 | `bash -lc` reports `SANDHOME_EXEC` UNSET and node dies `cannot map this copy back` | the same shell reports the exec root |
| #132 | `npm`/`npx` are `NONE`, `npm: not found` | both resolve and `npm --version` answers |
| #133 | 1 baked line after the bootstrap, 0 after one `repair`, 0 after one `install`, `env -i doctor` exits 2 | 1 / 1 / 1, and `env -i doctor` exits 0 |
| #134 | `sandhome skills` -> `unknown command`, exit 2; ROUTE.md has 3 hand-written curl lines and no lead | `skills_installed=3` with per-skill origin, and the document leads with the fact |
| #135 | `TC_rust_BINS` names cargo and rustup only; `rustc` is NONE; `rustc --version` -> not found | six bins declared, and `rustc --version` answers from a shell that sourced nothing |
| #136 | dash prints `shift: can't shift that many` and exits 2 | usage on stdout, empty stderr, exit 0, on dash, sh and bash |
| #137 | `npm init failed` swallowed, `all run there` printed anyway, `package.json` absent, exit 0 | `package.json` written, both halves real, exit 0 |
| #138 | `npm-global/bin` is a symlink to the hook dir, the CLI link dangles (control: same link in a real dir answers 1.6.0) | a real directory, and the installed CLI answers from a shell that sourced nothing |
| #139 | the view node is a launcher (memfd path), and doctor carries no spawn check | `process.execPath` is a real path, `spawnSync` status 0, `toolchain_node_spawn` in doctor and firing when the view is broken |