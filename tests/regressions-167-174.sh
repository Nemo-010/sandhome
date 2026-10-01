#!/bin/sh
# tests/regressions-167-174.sh - one clause for every defect this round closes
# (issues #167-#174), found by consuming ROUTE.md across projects and toolchains.
#
# Every clause fails against the tree before its fix and passes after, except the
# two marked (control), which must pass both ways. The product fixes live in
# lib/env.sh, bootstrap.sh, lib/space.sh, tools/emscripten.sh, tools/rust.sh,
# tools/meson.sh and tools/python.sh.
#
#  #167 CARGO_TARGET_DIR was keyed on the directory BASENAME, so two projects in
#       .../a/dup and .../b/dup shared target-dup; cargo treated the second as
#       fresh, `cargo run` printed the first crate's binary, and `cargo clean` in
#       one removed the other's artifacts.
#  #168 bootstrap's self-fetch blamed a MISSING downloader when curl and wget
#       were present and failing, and printed the whole failure twice.
#  #169 emcc/em++ are `#!` wrappers whose last line reads "$0.py"; the launch
#       view memfd-execs them, so the install failed its own probe while the SDK
#       was fine.
#  #170 rust wrote a zig linker wrapper for wasm32-unknown-emscripten, which
#       overrode the emscripten fragment's emcc and broke the link.
#  #171 the emscripten fragment prepended upstream/bin, shadowing the installed
#       clang with the SDK's bundled LLVM.
#  #172 meson's payload lived under uv-tools on the exec root, so a tmpfs restart
#       stranded the launcher on PATH.
#  #173 the launch view stamped interpreter source with a memexec binary, so
#       `import platform` died with "source code string cannot contain null
#       bytes".
#  #174 `install --force python` inherited UV_PYTHON_DOWNLOADS=never from the
#       loaded env.sh and could not fetch the CPython it was asked to install.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for sh_rg_m in common detect space env fetch toolchain shim report; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$sh_rg_m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-167-174

tmp=$(t_exec_tmpdir sandhome-regr-167-174)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# --- #167: CARGO_TARGET_DIR is keyed on the absolute path ---------------------
ct_home="$tmp/ct-home"; ct_exec="$tmp/ct-exec"
ct_body=$(SH_HOME="$ct_home" SH_EXEC="$ct_exec" sh_env_body)
mkdir -p "$tmp/ct/a/dup" "$tmp/ct/b/dup"
ct_read() {
    ( cd "$1" && sh -c "$ct_body
printf '%s' \"\$CARGO_TARGET_DIR\"" 2>/dev/null )
}
ct_a=$(ct_read "$tmp/ct/a/dup")
ct_b=$(ct_read "$tmp/ct/b/dup")
ct_a2=$(ct_read "$tmp/ct/a/dup")
t_ok "$([ -n "$ct_a" ] && [ "$ct_a" != "$ct_b" ] && echo 0 || echo 1)" \
     'two same-basename projects get different CARGO_TARGET_DIR (issue #167)'
t_is "$ct_a2" "$ct_a" 'the same project path gets a stable CARGO_TARGET_DIR (issue #167)'

# --- #168: a self-fetch failure names the downloaders that were present -------
sf_dir="$tmp/selfetch"; mkdir -p "$sf_dir"
for sf_x in curl wget; do
    printf '#!/bin/sh\ncase "$1" in --version|--help) exit 0 ;; esac\nexit 22\n' > "$sf_dir/$sf_x"
    chmod 0755 "$sf_dir/$sf_x"
done
sf_out=$( SANDHOME_NO_RUN=1 PATH="$sf_dir:/usr/bin:/bin" sh -c '
    . "$1/bootstrap.sh"
    sh_fr_fetch "https://example.invalid/x" "$2/selfetch.out" 2>&1
    printf "RC=%s\n" "$?"
' sh "$ROOT" "$tmp" 2>&1 )
t_contains "$sf_out" 'every downloader present failed' \
     'a failed self-fetch names the present downloaders, not a missing one (issue #168)'
case "$sf_out" in
    *'no curl, wget or fetch on PATH'*) t_ok 1 'a failed self-fetch never claims no downloader is on PATH (issue #168)' ;;
    *) t_ok 0 'a failed self-fetch never claims no downloader is on PATH (issue #168)' ;;
esac
sf_dedup=$( SANDHOME_NO_RUN=1 PATH="$sf_dir:/usr/bin:/bin" SANDHOME_REF=no-such-ref-168 \
    sh -c '. "$1/bootstrap.sh"; sh_bootstrap_refetch --dry-run 2>&1' sh "$ROOT" 2>&1 )
t_is "$(printf '%s' "$sf_dedup" | grep -c 'curl could not fetch')" '1' \
     'a self-fetch failure tries each distinct owner once, not the default twice (issue #168)'
t_is "$(printf '%s' "$sf_dedup" | grep -c 'every downloader present failed')" '1' \
     'a self-fetch failure reports the all-failed state once (issue #168)'

# --- #169: emcc and em++ must be real copies in the launch view ---------------
sh_toolchain_load emscripten >/dev/null 2>&1
sh_rg_em=$(SH_VIEW_MODE=launch tc_emscripten_copy_bins 2>/dev/null) || sh_rg_em=''
t_contains "$sh_rg_em" 'upstream/emscripten/emcc' 'emcc is a real copy in launch mode (issue #169)'
t_contains "$sh_rg_em" 'upstream/emscripten/em++' 'em++ is a real copy in launch mode (issue #169)'

# --- #170: no zig wrapper for wasm32-unknown-emscripten ----------------------
rg_home="$tmp/rust170"; rg_exec="$tmp/rust170-exec"
rg_bin="$rg_home/toolchains/rust/rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin"
mkdir -p "$rg_bin" "$rg_exec/bin" "$rg_exec/views"
for sh_rg_b in rustc rustdoc clippy-driver; do
    printf '#!/bin/sh\n' > "$rg_bin/$sh_rg_b"; chmod 0755 "$rg_bin/$sh_rg_b"
done
printf '#!/bin/sh\n' > "$rg_exec/bin/zig"; chmod 0755 "$rg_exec/bin/zig"
SH_HOME="$rg_home" SH_EXEC="$rg_exec" SH_EXEC_BIN="$rg_exec/bin" \
SH_HOME_TOOLCHAINS="$rg_home/toolchains" SH_EXEC_VIEWS="$rg_exec/views" \
SH_VIEW_MODE=launch SH_RUST_TARGETS='wasm32-unknown-emscripten,x86_64-unknown-linux-gnu' \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/space.sh"; . "$1/lib/env.sh"; . "$1/lib/toolchain.sh"; . "$1/tools/rust.sh"; tc_rust_env >/dev/null 2>&1' sh "$ROOT" 2>/dev/null
t_is "$([ -e "$rg_exec/bin/rust-link-wasm32-unknown-emscripten" ] && echo yes || echo no)" 'no' \
     'no zig wrapper is written for wasm32-unknown-emscripten (issue #170)'
t_is "$([ -e "$rg_exec/bin/rust-link-x86_64-unknown-linux-gnu" ] && echo yes || echo no)" 'yes' \
     'a normal cross target still gets its zig wrapper (issue #170 control)'
t_is "$(grep -c 'CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER' "$rg_home/env.d/rust.sh" 2>/dev/null)" '0' \
     'the rust fragment does not overwrite the emscripten linker (issue #170)'
t_is "$(grep -c 'CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER' "$rg_home/env.d/rust.sh" 2>/dev/null)" '2' \
     'the rust fragment still sets a normal target linker (issue #170 control)'

# --- #171: emscripten appends upstream/bin, so the installed clang wins ------
ee_home="$tmp/ee171"; ee_exec="$tmp/ee171-exec"
mkdir -p "$ee_home/toolchains/emscripten/emsdk" \
         "$ee_exec/views/emscripten/emsdk/upstream/bin" \
         "$ee_exec/views/emscripten/emsdk/upstream/emscripten"
SH_HOME="$ee_home" SH_EXEC="$ee_exec" SH_EXEC_BIN="$ee_exec/bin" \
SH_HOME_TOOLCHAINS="$ee_home/toolchains" SH_EXEC_VIEWS="$ee_exec/views" \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; . "$1/lib/env.sh"; . "$1/lib/toolchain.sh"; . "$1/tools/emscripten.sh"; tc_emscripten_write_config() { printf "%s" "$1/.emscripten"; }; tc_emscripten_env' sh "$ROOT" 2>/dev/null
ee_frag="$ee_home/env.d/emscripten.sh"
t_is "$(grep -c 'PATH="\$PATH:.*emsdk/upstream/bin"' "$ee_frag" 2>/dev/null)" '1' \
     'emscripten appends upstream/bin to PATH (issue #171)'
t_is "$(grep -c 'PATH=".*emsdk/upstream/bin:\$PATH"' "$ee_frag" 2>/dev/null)" '0' \
     'emscripten does not prepend upstream/bin to PATH (issue #171)'

# --- #172: meson's payload lives on the home, not the exec root --------------
me_home="$tmp/mes172"; me_exec="$tmp/mes172-exec"
mkdir -p "$me_home/toolchains" "$me_exec/bin"
cat > "$me_exec/bin/uv" <<'MESUV'
#!/bin/sh
case "$1 $2" in
  "pip install")
    prev=''; target=''
    for a in "$@"; do [ "$prev" = --target ] && target=$a; prev=$a; done
    [ -n "$target" ] && { mkdir -p "$target/mesonbuild"; : > "$target/mesonbuild/mesonmain.py"; }
    printf 'Installed 1 package meson\n'; exit 0 ;;
  "tool install")
    mkdir -p "$UV_TOOL_BIN_DIR"
    printf '#!/bin/sh\n# uv tool shim\nexec "%s/uv-tools/meson/bin/python" -c x\n' "$SANDHOME_EXEC" > "$UV_TOOL_BIN_DIR/meson"
    chmod 0755 "$UV_TOOL_BIN_DIR/meson"
    printf 'Installed 1 executable meson\n'; exit 0 ;;
  *) exit 0 ;;
esac
MESUV
chmod 0755 "$me_exec/bin/uv"
SANDHOME_EXEC="$me_exec" SH_HOME="$me_home" SH_EXEC="$me_exec" SH_EXEC_BIN="$me_exec/bin" \
SH_HOME_TOOLCHAINS="$me_home/toolchains" SH_EXEC_VIEWS="$me_exec/views" \
UV_TOOL_BIN_DIR="$me_exec/uv-bin" SH_DRY_RUN=0 \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; . "$1/lib/env.sh"; . "$1/lib/toolchain.sh"; . "$1/tools/meson.sh"; sh_have() { [ "$1" = uv ] && return 1; command -v "$1" >/dev/null 2>&1; }; tc_meson_install >/dev/null 2>&1' sh "$ROOT" 2>/dev/null
t_ok "$([ -f "$me_home/toolchains/meson/lib/mesonbuild/mesonmain.py" ] && echo 0 || echo 1)" \
     'meson unpacks onto the persistent home (issue #172)'
t_is "$(grep -c 'uv-tools' "$me_home/toolchains/meson/bin/meson" 2>/dev/null)" '0' \
     'the meson launcher does not name the exec-root uv-tools venv (issue #172)'
t_is "$(grep -c 'SANDHOME_MESON_LIB' "$me_home/toolchains/meson/bin/meson" 2>/dev/null)" '3' \
     'the meson launcher runs the exec-view python against the home package (issue #172)'

# --- #173: the launch view must not stamp interpreter source -----------------
sp="$tmp/promote173"; mkdir -p "$sp/src/lib" "$sp/src/bin" "$sp/dst" "$sp/exec/bin"
printf 'import platform\n' > "$sp/src/lib/mod.py"; chmod 0755 "$sp/src/lib/mod.py"
if cp /bin/true "$sp/src/bin/prog" 2>/dev/null; then
    chmod 0755 "$sp/src/bin/prog"
    cp /bin/true "$sp/exec/bin/sandhome-memexec" 2>/dev/null || printf '#!/bin/sh\nexit 0\n' > "$sp/exec/bin/sandhome-memexec"
    chmod 0755 "$sp/exec/bin/sandhome-memexec"
    SH_HOME="$sp/home" SH_EXEC="$sp/exec" SH_EXEC_BIN="$sp/exec/bin" \
    SH_HOME_TOOLCHAINS="$sp/home/toolchains" SH_EXEC_VIEWS="$sp/exec/views" SH_VIEW_MODE=launch \
        sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; . "$1/lib/memexec.sh"; sh_promote_tree "$2/src" "$2/dst"' sh "$ROOT" "$sp" 2>/dev/null
    t_is "$(head -c 6 "$sp/dst/lib/mod.py" 2>/dev/null)" 'import' \
         'an executable .py is copied readable, not stamped (issue #173)'
    t_ok "$(head -c 4 "$sp/dst/bin/prog" 2>/dev/null | grep -q ELF && echo 0 || echo 1)" \
         'a real ELF program is still stamped into the launch view (issue #173 control)'
else
    t_skip 'no /bin/true here, so the promotion fixture could not run'
fi

# --- #174: force-reinstalling python may fetch the CPython it needs ----------
py_home="$tmp/py174"; py_exec="$tmp/py174-exec"
mkdir -p "$py_home/toolchains/python/bin" "$py_exec/bin" "$py_exec/views"
cat > "$tmp/uv174" <<'PUV'
#!/bin/sh
case "$1 $2" in
  "python install") printf '%s\n' "${UV_PYTHON_DOWNLOADS:-unset}" > "$SH_174_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
PUV
chmod 0755 "$tmp/uv174"
SH_UV174_STUB="$tmp/uv174" SH_174_LOG="$py_home/uv.log" UV_PYTHON_DOWNLOADS=never \
SH_KERNEL=Linux SH_ARCH=x86_64 \
SH_HOME="$py_home" SH_EXEC="$py_exec" SH_EXEC_BIN="$py_exec/bin" \
SH_HOME_TOOLCHAINS="$py_home/toolchains" SH_EXEC_VIEWS="$py_exec/views" \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; . "$1/lib/env.sh"; . "$1/lib/toolchain.sh"; . "$1/tools/python.sh"
      sh_fetch_unpack() { mkdir -p "$2"; cp "$SH_UV174_STUB" "$2/uv"; cp "$SH_UV174_STUB" "$2/uvx"; chmod 0755 "$2/uv" "$2/uvx"; return 0; }
      sh_promote_toolchain() { mkdir -p "$SH_EXEC_VIEWS/$1/bin"; cp "$SH_HOME_TOOLCHAINS/$1/bin/uv" "$SH_EXEC_VIEWS/$1/bin/uv"; chmod 0755 "$SH_EXEC_VIEWS/$1/bin/uv"; return 0; }
      sh_space_need() { return 0; }
      tc_python_install >/dev/null 2>&1' sh "$ROOT" 2>/dev/null
t_is "$(cat "$py_home/uv.log" 2>/dev/null)" 'manual' \
     'python install does not inherit UV_PYTHON_DOWNLOADS=never (issue #174)'

t_end
