# Decisions

Each page records a shape that is settled, and the measurement or reason behind
it. A later session should read the relevant one before changing an interface it
describes.

| page | what it settles |
| --- | --- |
| [`exec-split.md`](exec-split.md) | data and executables may live on different roots; shared objects are symlinked, binaries copied |
| [`adopt-before-install.md`](adopt-before-install.md) | a working toolchain is adopted; every install ends in a probe |
| [`toolchain-contract.md`](toolchain-contract.md) | what a `tools/<name>.sh` module declares and the rules behind it |
| [`posix-sh-only.md`](posix-sh-only.md) | POSIX `sh`, no `local`, and a deliberately tiny dependency set |
| [`fetching-and-digests.md`](fetching-and-digests.md) | one download path, digests read from the release, and the schema traps in the version chains |
| [`pinning.md`](pinning.md) | one pin per download; a published digest outranks a caller's default, and a POSIX sh variable name cannot hold a hyphen |
| [`research-parity.md`](research-parity.md) | what the thirteen-reference sweep taught and where each adopted, documented or refused line went |
| [`global-env.md`](global-env.md) | the environment is installed once into a directory already on `PATH`, not sourced at the top of every command |
