#!/bin/sh
# tests/regressions-151-164.sh - one clause for each defect and doc gap fixed
# in the round that closed issues #151 through #164.
#
# WHY A FILE OF ITS OWN. The #141-#147 clauses live in one file and the
# #149-#150 clauses in another; this round is a third. The clauses are
# BEHAVIOURAL where a cheap isolated call can ask the question: the deno
# re-exec, the uv-link sweep, the wanted-list seed, the entry fallback, the
# profile environment, the node .js repair, the cache directory, the writable
# rustup home, and the atomic bake. Each names the mechanism, fails against
# the tree as it stood when the issue was filed, and holds after. The doc
# clauses read the file the issue is about, because a doc gap cannot be
# asked of a function.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space env fetch toolchain shim report; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-151-164

tmp=$(t_exec_tmpdir sandhome-regr-151-164)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# Load the sandhome library inside a subprocess with a scratch home and exec
# root, then run "$1". The module under test is appended by the caller, so each
# clause sources only what it needs.
sh_regr_run() {
    SH_HOME="$tmp/home" SH_EXEC="$tmp/exec" \
    SH_HOME_TOOLCHAINS="$tmp/home/toolchains" SH_EXEC_VIEWS="$tmp/exec/views" \
    SH_EXEC_BIN="$tmp/exec/bin" SH_HOME_TMP="$tmp/home/tmp" \
    SH_REPO_DIR="$ROOT" SH_LIB_DIR="$ROOT/lib" \
        sh -c ". \"\$0/lib/common.sh\"; . \"\$0/lib/detect.sh\"; . \"\$0/lib/space.sh\"; . \"\$0/lib/fetch.sh\"; . \"\$0/lib/env.sh\"; . \"\$0/lib/toolchain.sh\"; . \"\$0/lib/shim.sh\"; . \"\$0/lib/report.sh\"; $1" \
        "$ROOT" 2>/dev/null
}

# --- #151: the deno doctor re-execs, it does not call a missing API ---------
# Deno.Command has outputSync()/output()/spawn(); there is no spawnSync, so the
# old probe ran a method that does not exist and reported a working deno as
# broken. The fake models a deno that refuses the bogus name, which is what the
# real one did.
mkdir -p "$tmp/home/toolchains/deno/bin" "$tmp/exec/views/deno" "$tmp/exec/bin"
printf '#!/bin/sh\ncase "$*" in *spawnSync*) exit 1 ;; esac\nexit 0\n' > "$tmp/exec/views/deno/deno"
chmod +x "$tmp/exec/views/deno/deno"
mount_deno='. "$0/tools/deno.sh"; if tc_deno_doctor; then printf pass; else printf fail; fi'
t_is "$(sh_regr_run "$mount_deno")" 'pass' 'the deno doctor accepts a deno that re-execs itself (#151)'
# The negative control: a deno that refuses every re-exec spelling is still
# reported. It refuses outputSync AND spawn (the two spellings the doctor
# tries), so neither probe can mistake it for a working runtime. A fake that
# refused only outputSync would pass through the async-spawn fallback, which
# is correct behaviour, not a hole: honouring spawn() IS re-executing.
printf '#!/bin/sh\ncase "$*" in *outputSync*|*spawn*) exit 1 ;; esac\nexit 0\n' > "$tmp/exec/views/deno/deno"
chmod +x "$tmp/exec/views/deno/deno"
t_is "$(sh_regr_run "$mount_deno")" 'fail' 'a deno that cannot re-exec is still reported (#151)'
printf '#!/bin/sh\ncase "$*" in *spawnSync*) exit 1 ;; esac\nexit 0\n' > "$tmp/exec/views/deno/deno"
chmod +x "$tmp/exec/views/deno/deno"

# --- #152: an empty bin set does not sweep the view's own links -------------
# `sandhome install python` installed uv/uvx into the view, then the framework
# promote ran with no arguments and its sweep removed every exec-bin link not
# in the (empty) set, deleting the uv links the just-finished install made.
mkdir -p "$tmp/home/toolchains/py/bin" "$tmp/exec/views/py/bin" "$tmp/exec/bin" "$tmp/home/tmp"
printf '#!/bin/sh\n' > "$tmp/home/toolchains/py/bin/tool"
printf '#!/bin/sh\n' > "$tmp/exec/views/py/bin/uv"
printf '#!/bin/sh\n' > "$tmp/exec/views/py/bin/uvx"
ln -s "$tmp/exec/views/py/bin/uv"  "$tmp/exec/bin/uv"
ln -s "$tmp/exec/views/py/bin/uvx" "$tmp/exec/bin/uvx"
sh_regr_run 'sh_promote_toolchain py' >/dev/null 2>&1
t_ok "$([ -L "$tmp/exec/bin/uv" ] && [ -L "$tmp/exec/bin/uvx" ] && echo 0 || echo 1)" \
    'a no-argument promote keeps the view links it did not make (#152)'
# The sweep still does its job when the caller names the binaries: a link that
# is not in the set is stale and must go.
printf '#!/bin/sh\n' > "$tmp/exec/views/py/bin/stale"
ln -s "$tmp/exec/views/py/bin/stale" "$tmp/exec/bin/stale"
sh_regr_run 'sh_promote_toolchain py bin/tool' >/dev/null 2>&1
t_ok "$([ ! -e "$tmp/exec/bin/stale" ] && echo 0 || echo 1)" \
    'a named promote still sweeps links outside the set (#152)'

# --- #153: resume seeds the wanted list from the file it is resuming --------
# The file on disk is the record; cmd_resume planned from whatever the caller
# happened to export, so a later-installed toolchain was not repaired. The seed
# is one line; the clause proves the round-trip it protects.
mkdir -p "$tmp/home"
printf "SANDHOME_HOME='%s'\nSANDHOME_EXEC='%s'\nSANDHOME_WANTED_TOOLCHAINS='jq rust meson'\n" \
    "$tmp/home" "$tmp/exec" > "$tmp/home/env.sh"
want=$(sh_regr_run 'sh_wanted_from_file')
t_is "$want" 'jq rust meson' 'the wanted list reads back from env.sh (#153)'
sh_regr_run 'SH_WANTED_TOOLCHAINS=$(sh_wanted_from_file); sh_env_write' >/dev/null 2>&1
t_ok "$(sed -n "s/^SANDHOME_WANTED_TOOLCHAINS=//p" "$tmp/home/env.sh" | tr -d "'" | grep -qx 'jq rust meson' && echo 0 || echo 1)" \
    'a seeded wanted list survives a rewrite of env.sh (#153)'
t_ok "$(grep -q 'SH_WANTED_TOOLCHAINS=$(sh_wanted_from_file)' "$ROOT/bin/sandhome" && echo 0 || echo 1)" \
    'cmd_resume seeds the wanted list from the file (#153)'

# --- #154: the entry point can still resume after the exec root is wiped ----
# entry.sh's fallback guarded on the repo launcher being executable. A checkout
# at 0644 is readable but not executable, and `command -v sandhome` matched the
# shell function itself, so the last resort exited 127 with "not found". The
# repo copy is now read through `sh`, and the self-match is refused.
rm -rf "$tmp/e154"
mkdir -p "$tmp/e154/home" "$tmp/e154/exec/bin" "$tmp/e154/repo/bin"
printf '#!/bin/sh\nprintf "REPO-RAN %%s\\n" "$*"\n' > "$tmp/e154/repo/bin/sandhome"
chmod 0644 "$tmp/e154/repo/bin/sandhome"
SH_HOME="$tmp/e154/home" SH_EXEC="$tmp/e154/exec" SH_EXEC_BIN="$tmp/e154/exec/bin" \
SH_REPO_DIR="$tmp/e154/repo" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_entry_write' "$ROOT" >/dev/null 2>&1
rm -rf "$tmp/e154/exec/bin"
t_is "$(env -i HOME="$tmp/e154/home" PATH=/usr/bin:/bin sh -c '. "$1/home/entry.sh"; sandhome resume' sh "$tmp/e154" 2>/dev/null)" \
    'REPO-RAN resume' 'entry.sh reaches a readable repo launcher after the exec root is wiped (#154)'
# With the repo launcher gone too there is nothing left to run; the message must
# name every place it looked, not answer 127 with a bare "not found".
rm -rf "$tmp/e154/repo"
t_is "$(env -i HOME="$tmp/e154/home" PATH=/usr/bin:/bin sh -c '. "$1/home/entry.sh"; sandhome' sh "$tmp/e154" 2>&1 >/dev/null)" \
    "sandhome: no working copy (baked $tmp/e154/exec/bin/sandhome missing, SANDHOME_EXEC/bin/sandhome missing, repo/bin/sandhome missing, nothing on PATH; re-run the setup)" \
    'the nothing-left message is not a bare "not found" (#154, #122)'

# --- #155: the profile fragment loads the whole environment -----------------
# The fragment eval'd five names out of env.sh, and left SANDHOME_EXEC and the
# runtime workarounds (ASAN_OPTIONS/LSAN_OPTIONS, XDG_CACHE_HOME) unset. A
# non-login shell that reads it must see everything env.sh exports.
rm -rf "$tmp/e155"
mkdir -p "$tmp/e155/home/.local/share/sandhome" "$tmp/e155/exec"
printf 'SANDHOME_HOME=%s\nSANDHOME_EXEC=%s\nASAN_OPTIONS=detect_leaks=0\nexport ASAN_OPTIONS\n' \
    "$tmp/e155/home/.local/share/sandhome" "$tmp/e155/exec" > "$tmp/e155/home/.local/share/sandhome/env.sh"
cp "$ROOT/lib/profile.sh" "$tmp/e155/home/.local/share/sandhome/profile.sh"
t_is "$(env -i HOME="$tmp/e155/home" PATH=/usr/bin:/bin dash -c \
    '. "$1/home/.local/share/sandhome/profile.sh"; printf "%s %s" "${SANDHOME_EXEC:-EMPTY}" "${ASAN_OPTIONS:-EMPTY}"' \
    sh "$tmp/e155" 2>/dev/null)" \
    "$tmp/e155/exec detect_leaks=0" 'the profile fragment loads all of env.sh, not five names (#155)'

# --- #156: the exec root is nameable from a hook shell ----------------------
# The shell the setup leaves has no exported SANDHOME_EXEC (the hook applies
# env.sh to the tool it dispatches), and ROUTE.md told the reader to build
# under that empty variable, creating /build. exec-dir is the name.
cmd_exec_dir=$(sed -n '/^cmd_exec_dir() {/,/^}/p' "$ROOT/bin/sandhome")
t_is "$(SH_EXEC="$tmp/exec" sh -c "$cmd_exec_dir; cmd_exec_dir" 2>/dev/null)" \
    "$tmp/exec" 'sandhome exec-dir names the exec root with no exported variable (#156)'
t_ok "$(grep -q 'sandhome exec-dir' "$ROOT/ROUTE.md" && echo 0 || echo 1)" \
    'ROUTE.md names exec-dir where it names the build root (#156)'

# --- #157: the node view keeps real JavaScript at the .js paths -------------
# Installing node replaced npm-cli.js/npx-cli.js in the view with shell
# wrappers, so `node <view>/npm` died with a SyntaxError while `npm` (the shim
# on the exec bin) worked. tc_node_env now restores the payload's file.
rm -rf "$tmp/e157"
mkdir -p "$tmp/e157/home/toolchains/node/lib/node_modules/npm/bin" \
         "$tmp/e157/exec/views/node/lib/node_modules/npm/bin"
printf '#!/usr/bin/env node\nconsole.log(1)\n' > "$tmp/e157/home/toolchains/node/lib/node_modules/npm/bin/npm-cli.js"
printf '#!/usr/bin/env node\nconsole.log(2)\n' > "$tmp/e157/home/toolchains/node/lib/node_modules/npm/bin/npx-cli.js"
printf '#!/bin/sh\nprintf shim\n' > "$tmp/e157/exec/views/node/lib/node_modules/npm/bin/npm-cli.js"
sh_regr_run "SH_HOME_TOOLCHAINS=$tmp/e157/home/toolchains SH_EXEC_VIEWS=$tmp/e157/exec/views; . \"\$0/tools/node.sh\"; tc_node_repair_cli_js $tmp/e157/exec/views/node $tmp/e157/home/toolchains/node"
t_is "$(sed -n 1p "$tmp/e157/exec/views/node/lib/node_modules/npm/bin/npm-cli.js")" \
    '#!/usr/bin/env node' 'the node view gets the payload npm-cli.js back (#157)'

# --- #158: env.sh points the cache at the exec root -------------------------
# A downloaded executable lands under XDG_CACHE_HOME by default, which is the
# noexec home. The variable must be declared in env.sh, not only in the
# installer's process, or a later shell gets the unwritable default back.
t_ok "$(sh_regr_run 'sh_env_body' | grep -q 'XDG_CACHE_HOME="\$SANDHOME_EXEC/cache"' && echo 0 || echo 1)" \
    'env.sh declares XDG_CACHE_HOME on the exec root (#158)'

# --- #159: an adopted, unwritable RUSTUP_HOME gets a writable stand-in ------
# A read-only home made `rustup target add` fail with "Read-only file system"
# and still exit 0, so a build later died on a missing std. The toolchain real
# files stay where they are; only the write side moves.
rm -rf "$tmp/e159"; mkdir -p "$tmp/e159/adopted/toolchains/stable-x86_64-unknown-linux-gnu/bin" "$tmp/e159/exec"
printf 'default_toolchain = "stable-x86_64-unknown-linux-gnu"\n' > "$tmp/e159/adopted/settings.toml"
printf '#!/bin/sh\n' > "$tmp/e159/adopted/toolchains/stable-x86_64-unknown-linux-gnu/bin/rustc"
chmod 500 "$tmp/e159/adopted"
out=$(sh_regr_run ". \"\$0/tools/rust.sh\"; tc_rust_writable_rustup $tmp/e159/adopted; printf '%s' \"\$SH_RUST_WRITABLE_RUSTUP\"; : > \"\$SH_RUST_WRITABLE_RUSTUP/tmp/probe\" && printf ' WRITE-OK'")
chmod 700 "$tmp/e159/adopted"
t_is "$out" "$tmp/exec/rustup WRITE-OK" 'an unwritable adopted RUSTUP_HOME gets a writable, linked stand-in (#159)'
# A writable adopted home is handed back as-is: no copy, no symlinks.
mkdir -p "$tmp/e159rw/rustup/toolchains"
t_is "$(sh_regr_run ". \"\$0/tools/rust.sh\"; tc_rust_writable_rustup $tmp/e159rw/rustup; printf '%s' \"\$SH_RUST_WRITABLE_RUSTUP\"")" \
    "$tmp/e159rw/rustup" 'a writable adopted RUSTUP_HOME is used as-is (#159)'

# --- the bake is atomic and whole -------------------------------------------
# sh_bake_command rewrote the launcher by `cp`-ing the new copy onto the path
# the running process was executing. A `cp` truncates the destination first, so
# a large launcher was briefly an 8KB half-file with an unterminated quote and
# every `sandhome` call in that window died with a syntax error. The bake now
# writes a sibling and renames it into place, which is atomic on one filesystem.
rm -rf "$tmp/bake"; mkdir -p "$tmp/bake/home"
{ printf '#!/bin/sh\n'; head -c 4096 /dev/zero | tr '\0' x; printf '\n'; printf "SH_BAKED_REPO_DIR=''\nSH_BAKED_HOME=''\nprintf '%%s\\n' BAKED\n"; } > "$tmp/bake/src"
lines_before=$(wc -l < "$tmp/bake/src")
# A second hard link to the destination inode is the running shell's open
# handle. `cp -f src dst` truncates THAT inode, so the handle reads the new
# bytes; an atomic rename replaces the NAME and leaves the inode alone, so the
# handle still reads the original. This fails against the old writer and passes
# against the new one, deterministically, with no race to reproduce.
printf 'ORIGINAL-INODE\n' > "$tmp/bake/dst"
ln "$tmp/bake/dst" "$tmp/bake/dst.hold"
SH_REPO_DIR="$ROOT" SH_HOME="$tmp/bake/home" SH_EXEC="$tmp/bake" sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_bake_command "$1/src" "$1/dst"' "$ROOT" "$tmp/bake" >/dev/null 2>&1
t_is "$(sed -n 1p "$tmp/bake/dst.hold")" 'ORIGINAL-INODE' \
    'the bake replaces the name, never truncating the inode a running shell holds (#122, truncation)'
t_is "$(sh -n "$tmp/bake/dst" 2>&1 && printf ok || printf bad)" 'ok' 'the baked launcher parses (#122, truncation)'
t_ok "$([ "$(wc -l < "$tmp/bake/dst")" -ge "$lines_before" ] && echo 0 || echo 1)" \
    'the bake keeps every line of the source (#122, truncation)'
t_ok "$(grep -q "^SH_BAKED_REPO_DIR='$ROOT'$" "$tmp/bake/dst" && grep -q "^SH_BAKED_HOME='$tmp/bake/home'$" "$tmp/bake/dst" && echo 0 || echo 1)" \
    'the bake records the values it was given (#122)'

# --- #160/#161/#162/#163/#164: the docs a consumer had to be told -----------
t_ok "$(grep -q 'socket-fd' "$ROOT/skills/sealed-sandbox/SKILL.md" && grep -q 'prebind' "$ROOT/skills/sealed-sandbox/SKILL.md" && echo 0 || echo 1)" \
    'the sealed-sandbox skill shows the inherited-listener path (#160)'
t_ok "$(grep -q 'outlives the process' "$ROOT/skills/sealed-sandbox/SKILL.md" && grep -q 'zombie' "$ROOT/skills/sealed-sandbox/SKILL.md" && echo 0 || echo 1)" \
    'the sealed-sandbox skill warns that a bound socket path outlives its process (#161)'
t_ok "$(grep -qi 'no-same-owner' "$ROOT/skills/sandhome/SKILL.md" && echo 0 || echo 1)" \
    'the tree names the tar --no-same-owner failure (#162)'
# A recorded wasm32-unknown-emscripten target with no emcc must red the gate:
# a target whose linker is a different toolchain is the failure the issue says
# reads like a broken PATH.
rm -rf "$tmp/e163"; mkdir -p "$tmp/e163/home" "$tmp/e163/exec/bin" "$tmp/e163/exec/views"
printf "SANDHOME_HOME=%s\nSANDHOME_EXEC=%s\nSANDHOME_WANTED_TOOLCHAINS='jq'\nSANDHOME_RUST_TARGETS='wasm32-unknown-emscripten'\nXDG_CACHE_HOME=%s\n" \
    "$tmp/e163/home" "$tmp/e163/exec" "$tmp/e163/exec/cache" > "$tmp/e163/home/env.sh"
# The recorded request must survive the routine rewrite that follows an
# unrelated install, or the doctor row it feeds is dead code (same class as
# #153). sh_env_body seeds SH_RUST_TARGETS from the file when this process
# holds nothing.
env -i HOME="$tmp/e163/home" PATH=/usr/bin:/bin \
    SH_HOME="$tmp/e163/home" SH_EXEC="$tmp/e163/exec" SH_EXEC_BIN="$tmp/e163/exec/bin" \
    SH_EXEC_VIEWS="$tmp/e163/exec/views" SH_REPO_DIR="$ROOT" SH_LIB_DIR="$ROOT/lib" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/env.sh"; sh_env_write' \
    "$ROOT" >/dev/null 2>&1
t_ok "$(grep -q "^SANDHOME_RUST_TARGETS='wasm32-unknown-emscripten'$" "$tmp/e163/home/env.sh" && echo 0 || echo 1)" \
    'a recorded rust target survives a routine env.sh rewrite (#163)'
doc_em=$(env -i HOME="$tmp/e163/home" PATH=/usr/bin:/bin \
    SH_HOME="$tmp/e163/home" SH_EXEC="$tmp/e163/exec" SH_EXEC_BIN="$tmp/e163/exec/bin" \
    SH_EXEC_VIEWS="$tmp/e163/exec/views" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/env.sh"; . "$0/lib/toolchain.sh"; . "$0/lib/report.sh"; sh_doctor' \
    "$ROOT" 2>&1)
t_ok "$(printf '%s' "$doc_em" | grep -q 'FAIL emscripten_linker' && echo 0 || echo 1)" \
    'doctor reds a recorded target whose linker is a toolchain that is absent (#163)'
t_ok "$(grep -q "linker 'emcc' not found" "$ROOT/skills/sandhome/SKILL.md" && echo 0 || echo 1)" \
    'the tree names the separate emscripten linker (#163)'
t_ok "$(grep -q 'per `write(2)`' "$ROOT/docs/guide.md" && echo 0 || echo 1)" \
    'the tree states the file-size cap binds writes, not only downloads (#164)'
t_ok "$(grep -q 'file_size_limit' "$ROOT/lib/report.sh" && echo 0 || echo 1)" \
    'the report names the measured per-file cap (#164)'

t_end
