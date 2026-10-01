# Decision: the emscripten toolchain and the linker rustc does not own

Date: 2026-10-01. Status: settled.

Adding a rust cross target (`rustup target add`) is necessary but not
sufficient for `wasm32-unknown-emscripten`: the link runs `emcc`, a separate
~640MB toolchain with its own LLVM/Binaryen and its own `EM_CONFIG`, and
without it the build dies with `linker 'emcc' not found`, which reads like a
broken `PATH` rather than a missing toolchain.

## The shape

`tools/emscripten.sh` follows the module contract with four emsdk-specific
answers:

- The payload is the emsdk checkout plus the activated SDK, on the home.
  Fetch is git clone first, tarball through `sh_tar` second, so the uid-0
  unpack abort cannot bite this path either way.
- `EM_CONFIG` is written beside the exec view with view paths, never copied
  from the activate step: activate writes payload-absolute paths, and on a
  split root those point at the home that refuses `execve`.
- The fragment sets `CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER=emcc`
  as a guarded default alongside `EMSDK` and `EM_CONFIG`.
- The doctor runs `emcc --version` and requires the config file to exist
  when the toolchain is ours; an adopted emcc carries its own config.

The release is pinned (`SANDHOME_EMSDK_VERSION`, default 3.1.73), not
latest: a moving default turns a 640MB fetch into a surprise. Measured
2026-10-01: install in 47s, C-to-wasm link and run, and a Rust
`--target wasm32-unknown-emscripten` link producing a 4.5MB module.

## What was deliberately not done

`--with emscripten` is in no toolset: 900MB for one target is carried only
on request. And no wrapper synthesises the linker: the failure it produces
would read like a broken `PATH`, which is the exact confusion this closes.
