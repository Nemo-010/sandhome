#!/bin/sh
# tests/regressions-187-192.sh - one clause per defect found by driving the
# CONSUMER round of this run: provision a fresh sandbox from ROUTE.md and use it
# as a real workstation, from a hello-world C file up through the niche
# toolchains (zig cross, qemu-user, rust wasm, emscripten, cargo install), over
# the Electrosphere.
#
# Every clause below FAILS against the tree as it stood before the fix and
# passes after it. The #188 and #192 clauses drive the REAL append helper and
# the REAL bootstrap against a real ~/.profile, because the whole defect was
# that the string the code writes and the file the shell later reads disagreed;
# a grep for `export PATH=` in bootstrap.sh said the fix was there and the file
# said otherwise. The #187 and #190 clauses RUN the generated artefact (the env
# fragment, the cargo wrapper) under `set -u` and in a real shell, for the same
# reason: inspecting the source is what let both through.
#
# RUNNING AGAINST THE OLD TREE. Every clause reads the functions from $ROOT/lib
# and $ROOT/tools and the bootstrap from $ROOT/bootstrap.sh, so `git stash` the
# product fix, run this file, and the named clauses fail. No network and no
# toolchain install is needed: the fixtures are local files.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib.sh"

SH_REPO_DIR=$ROOT
SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-187-192

tmp=$(t_exec_tmpdir sandhome-regr-187-192)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# sh_regr_lib ROOTS SNIPPET -> run SNIPPET with the library sourced and the two
# roots pinned. stderr is discarded; a clause that wants it redirects inside.
sh_regr_lib() {
    sh_rl_roots=$1
    SANDHOME_HOME=$sh_rl_roots/home SANDHOME_EXEC=$sh_rl_roots/exec \
    SH_HOME=$sh_rl_roots/home SH_HOME_TOOLCHAINS=$sh_rl_roots/home/toolchains \
    SH_HOME_TMP=$sh_rl_roots/home/tmp SH_HOME_EXEC=no \
    SH_EXEC=$sh_rl_roots/exec SH_EXEC_BIN=$sh_rl_roots/exec/bin \
    SH_EXEC_VIEWS=$sh_rl_roots/exec/views \
    SH_REPO_DIR=$ROOT SH_LIB_DIR=$ROOT/lib SH_SELF=test \
    SH_DRY_RUN=0 SH_VIEW_MODE=copy \
    sh -c 'for m in common detect space env fetch toolchain shim memexec report; do . "$SH_REPO_DIR/lib/$m.sh"; done; eval "$1"' \
        _ "$2" 2>/dev/null
}

# =====================================================================  #187
# THE EMSCRIPTEN ENV HEREDOC IS UNQUOTED, AND A COMMENT IN IT SAYS `$dir`.
# tc_emscripten_env builds its fragment with `<<EOF` (not `<<'EOF'`), so the
# shell expands every `$name` in the body - including the comment that documents
# the empty-PATH hazard, which contains a literal `$dir`. `dir` is unset and the
# install runs under `set -u`, so the function aborts before the fragment is
# written; the SDK is fully installed and emcc still does not answer, and doctor
# reads `FAIL toolchain_emscripten=no (wanted yes)`.
#
# THE CLAUSE RUNS THE FUNCTION, UNDER `set -u`, AGAINST A STUB PAYLOAD. The old
# clauses for #171 only grep the module text, which is exactly why this slipped
# through: the comment that documents a fix was itself the bug, and a text scan
# cannot tell an escaped dollar from an expanding one.
r187=$tmp/r187
mkdir -p "$r187/home/toolchains/emscripten/emsdk" "$r187/home/env.d" \
         "$r187/exec/views/emscripten" "$r187/exec/bin"
sh_regr_lib "$r187" '
    set -u
    . "$SH_REPO_DIR/tools/emscripten.sh"
    tc_emscripten_env
' >/dev/null 2>&1
t_ok "$([ -r "$r187/home/env.d/emscripten.sh" ] && echo 0 || echo 1)" \
    'the emscripten env fragment is written under set -u (#187)'
# The fragment must still carry the real, expanding names a shell needs, and
# only the comment dollars are literal: a fragment that escaped everything would
# pass the existence check and hand a shell a literal $SANDHOME_EXEC.
t_ok "$(grep -q 'EM_CONFIG="\$SANDHOME_EXEC/emscripten/.emscripten"' "$r187/home/env.d/emscripten.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the fragment names the view EM_CONFIG through $SANDHOME_EXEC (#187)'
t_ok "$(grep -q 'CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER' "$r187/home/env.d/emscripten.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the fragment still sets the rust emscripten linker variable (#187)'

# =====================================================================  #188
# THE BOOTSTRAP PATH LINE REPLACED ANY `export PATH=` LINE BY PREFIX. The
# bootstrap passed the prefix `export PATH="` to sh_append_once, which replaced
# the FIRST matching line and DROPPED every later one. A user's own PATH exports
# share the prefix, so the setup silently deleted them and left only sandhome's.
#
# THE CLAUSE DRIVES THE REAL HELPER WITH THE REAL ORDER, then reads the file.
r188=$tmp/r188
mkdir -p "$r188/home" "$r188/exec/bin"
printf 'export PATH="$HOME/bin:$PATH"\nexport PATH="/usr/local/go/bin:$PATH"\nexport EDITOR=vim\n' \
    > "$r188/home/.profile"
HOME=$r188/home sh -c '
    . "$1/lib/common.sh"
    SH_SELF=bootstrap
    sh_append_login "export PATH=\"$2/bin:\$PATH\" # sandhome" \
        "$2/bin" "export PATH=\"" "# sandhome"
' _ "$ROOT" "$r188/exec" >/dev/null 2>&1
t_ok "$(grep -q 'HOME/bin:\$PATH' "$r188/home/.profile" && echo 0 || echo 1)" \
    "a hand-written PATH line survives the setup (#188)"
t_ok "$(grep -q '/usr/local/go/bin' "$r188/home/.profile" && echo 0 || echo 1)" \
    "a second hand-written PATH line is not dropped (#188)"
t_ok "$(grep -q "$r188/exec/bin" "$r188/home/.profile" && echo 0 || echo 1)" \
    "the sandhome PATH line is installed (#188)"
# A re-run with a DIFFERENT exec root must replace only ours and keep the two
# hand-written lines, which is the whole point of the marker.
HOME=$r188/home sh -c '
    . "$1/lib/common.sh"
    SH_SELF=bootstrap
    sh_append_login "export PATH=\"$2/bin2:\$PATH\" # sandhome" \
        "$2/bin2" "export PATH=\"" "# sandhome"
' _ "$ROOT" "$r188/exec" >/dev/null 2>&1
t_ok "$(grep -q 'HOME/bin:\$PATH' "$r188/home/.profile" && grep -q '/usr/local/go/bin' "$r188/home/.profile" && echo 0 || echo 1)" \
    "a re-run keeps both hand-written PATH lines (#188)"
t_ok "$(grep -c 'sandhome' "$r188/home/.profile" | grep -qx 1 && echo 0 || echo 1)" \
    "a re-run leaves exactly one sandhome PATH line (#188)"

# =====================================================================  #189
# THE DOCS DESCRIBED --toolset languages/agent AS "developer plus rust and go".
# The code installs the whole compiler set, clang included (>1GB). The clause
# expands the real preset from the code and checks the three consumer documents
# against it, so the next edit cannot drift again - tests/docs.sh checks flags
# and variables, not preset membership.
# The preset is read from the function the bootstrap defines, WITHOUT running
# the bootstrap: sourcing it would install a sandbox. `sed -n` prints just the
# function body and `sh` evaluates it, which is the same text the bootstrap
# uses. Running it is the point: a table transcribed into the test would pass
# while the code changed under it.
r189_lang=$(sh -c 'eval "$(sed -n "/^sh_toolset_names() {/,/^}/p" "$1/bootstrap.sh")"; sh_toolset_names languages'     _ "$ROOT" 2>/dev/null)
case "$r189_lang" in
    *clang*) r189_has_clang=yes ;;
    *)       r189_has_clang=no ;;
esac
t_is "$r189_has_clang" yes \
    'the languages preset really carries clang (#189)'
for r189_doc in ROUTE.md skills/sandhome/SKILL.md README.md; do
    t_ok "$(grep -q 'plus rust and go' "$ROOT/$r189_doc" 2>/dev/null && echo 1 || echo 0)" \
        "$r189_doc no longer says languages/agent are only rust and go (#189)"
done
t_ok "$(grep -q 'clang' "$ROOT/ROUTE.md" && grep -q 'clang' "$ROOT/README.md" && echo 0 || echo 1)" \
    'the consumer docs name clang in the full compiler set (#189)'

# =====================================================================  #190
# THE CARGO WRAPPER REDIRECTED CARGO_TARGET_DIR EVEN ON AN EXEC-CAPABLE TREE.
# env.sh/wrapper move the target out of the project, so `cargo build` then
# `./target/debug/<bin>` is ENOENT - the path cargo documents. The fix probes
# exec by RUNNING a file in the project directory and redirects only when that
# fails.
#
# THE CLAUSE RUNS THE GENERATED WRAPPER IN BOTH PROJECTS: one exec-capable, one
# with write permission removed so the probe cannot stage a runnable file. The
# real cargo is a stub that prints the CARGO_TARGET_DIR it was handed.
r190=$tmp/r190
mkdir -p "$r190/home/toolchains" "$r190/home/tmp" "$r190/exec/bin" \
         "$r190/exec/views/rust/cargo/bin" "$r190/exec-proj" "$r190/noexec-proj"
printf '#!/bin/sh\nprintf "CTD=%%s\\n" "${CARGO_TARGET_DIR:-none}"\n' > "$r190/real-cargo"
chmod 0755 "$r190/real-cargo"
ln -sfn "$r190/real-cargo" "$r190/exec/views/rust/cargo/bin/cargo"
printf '[package]\nname = "p"\nversion = "0.0.0"\n' > "$r190/exec-proj/Cargo.toml"
printf '[package]\nname = "q"\nversion = "0.0.0"\n' > "$r190/noexec-proj/Cargo.toml"
sh_regr_lib "$r190" '
    . "$SH_REPO_DIR/tools/rust.sh"
    sh_toolchain_rust_target_wrapper "$SH_EXEC_BIN" "$SANDHOME_EXEC/views/rust/cargo/bin/cargo"
' >/dev/null 2>&1
t_ok "$([ -x "$r190/exec/bin/cargo" ] && echo 0 || echo 1)" \
    'the cargo wrapper is written for the clause to run (#190)'
# Exec-capable project: the wrapper must leave CARGO_TARGET_DIR alone.
r190_exec=$(cd "$r190/exec-proj" && SANDHOME_EXEC="$r190/exec" \
    timeout 10 "$r190/exec/bin/cargo" 2>/dev/null)
t_contains "$r190_exec" 'CTD=none' \
    'an exec-capable project keeps cargo target dir unset, so ./target/debug/<bin> works (#190)'
# Noexec project: the wrapper must redirect.
chmod 0555 "$r190/noexec-proj" 2>/dev/null || true
r190_noexec=$(cd "$r190/noexec-proj" && SANDHOME_EXEC="$r190/exec" \
    timeout 10 "$r190/exec/bin/cargo" 2>/dev/null)
chmod 0755 "$r190/noexec-proj" 2>/dev/null || true
t_contains "$r190_noexec" 'target-noexec-proj' \
    'a noexec project still gets a target dir under the exec root (#190)'

# The env.sh DEFAULT is probed too: the fragment env.sh writes must not set
# CARGO_TARGET_DIR on an exec-capable PWD, or the naive cargo path is broken
# before any wrapper is reached. The generator is RUN, and the fragment is
# sourced in an exec-capable directory and a probe-refused one.
r190b=$tmp/r190b
mkdir -p "$r190b/project" "$r190b/exec"
printf '[package]\nname = "r"\nversion = "0.0.0"\n' > "$r190b/project/Cargo.toml"
sh -c '. "$1/lib/common.sh"; . "$1/lib/space.sh"; . "$1/lib/env.sh"
       SH_HOME=/tmp/r190b-home; SH_EXEC=/tmp/r190b-exec
       SH_HOME_TOOLCHAINS=/tmp/r190b-home/toolchains; sh_env_body' _ "$ROOT" \
    > "$r190b/env.sh" 2>/dev/null
t_ok "$([ -s "$r190b/env.sh" ] && echo 0 || echo 1)" \
    'the env.sh body is generated for the clause to source (#190)'
# env.sh still provides the startup default (the wrapper corrects it per
# invocation), and that default must be a real redirect so a shell that runs
# cargo through something other than the wrapper is still safe.
r190b_exec=$(cd "$r190b/project" && SANDHOME_EXEC="$r190b/exec" \
    sh -c '. "$1"; printf "%s" "${CARGO_TARGET_DIR:-unset}"' _ "$r190b/env.sh" 2>/dev/null)
t_contains "$r190b_exec" 'target-' \
    'env.sh still records a startup CARGO_TARGET_DIR default (#190)'
# AND THE WRAPPER MUST DROP IT WHERE THE PROJECT CAN RUN A FILE: the wrapper is
# run in an exec-capable project (the scratch root) and must leave no
# CARGO_TARGET_DIR for cargo, so ./target/debug/<bin> is where cargo puts it.
r190b_wrap=$(cd "$r190b/project" && CARGO_TARGET_DIR="$r190b/exec/target-x" \
    SANDHOME_CARGO_TARGET_DEFAULT="$r190b/exec/target-x" SANDHOME_EXEC="$r190b/exec" \
    timeout 10 "$r190/exec/bin/cargo" 2>/dev/null)
t_contains "$r190b_wrap" 'CTD=none' \
    'the cargo wrapper drops a stale exec-root default in an exec-capable project (#190)'

# =====================================================================  #191
# A FAILED REQUESTED INSTALL LEFT THE NAME IN SANDHOME_WANTED_TOOLCHAINS, so
# doctor stayed red and nothing named the command that clears it. The clause
# greps the two message sites for the remedy that actually exists.
t_ok "$(grep -q 'install --without \$sh_te_name' "$ROOT/lib/toolchain.sh" && echo 0 || echo 1)" \
    'a failed install names sandhome install --without NAME (#191)'
t_ok "$(grep -q 'drop it: sandhome install --without' "$ROOT/lib/report.sh" && echo 0 || echo 1)" \
    'the doctor FAIL line names the command that drops a wanted toolchain (#191)'
t_ok "$(grep -q 'retry: sandhome install --force' "$ROOT/lib/report.sh" && echo 0 || echo 1)" \
    'the doctor FAIL line also names the retry (#191)'
# The remedy must be real: --without is a bootstrap/sandhome argument.
t_ok "$(grep -q -- '--without' "$ROOT/bootstrap.sh" && grep -q 'without)' "$ROOT/bin/sandhome" && echo 0 || echo 1)" \
    'the named remedy is a real flag (#191)'

# =====================================================================  #192
# A THROWAWAY --home/--exec RUN STILL EDITED THE CALLER'S REAL ~/.profile. The
# clause runs the real bootstrap with a named root and a real HOME, and asserts
# the profile is byte-for-byte unchanged.
r192=$tmp/r192
mkdir -p "$r192/home" "$r192/sandhome-home" "$r192/sandhome-exec"
printf 'export PATH="$HOME/bin:$PATH"\nexport EDITOR=vim\n' > "$r192/home/.profile"
cp "$r192/home/.profile" "$r192/before"
env -i HOME="$r192/home" PATH=/usr/bin:/bin \
    SANDHOME_GLOBAL=0 \
    sh "$ROOT/bootstrap.sh" --home "$r192/sandhome-home" --exec "$r192/sandhome-exec" \
        --no-global --no-skills --no-shell --toolset none --only jq \
        >/dev/null 2>&1
t_ok "$(cmp -s "$r192/home/.profile" "$r192/before" && echo 0 || echo 1)" \
    'a named-root run leaves the caller ~/.profile byte-for-byte unchanged (#192)'
t_ok "$(grep -q 'sandhome-home/profile.sh' "$r192/home/.profile" 2>/dev/null && echo 1 || echo 0)" \
    'a named-root run does not source the throwaway fragment from the login files (#192)'
# ... and the login files ARE still installed when the caller asks, so the fix
# did not simply disable the feature.
r192b=$tmp/r192b
mkdir -p "$r192b/home" "$r192b/sandhome-home" "$r192b/sandhome-exec"
printf 'export EDITOR=vim\n' > "$r192b/home/.profile"
env -i HOME="$r192b/home" PATH=/usr/bin:/bin SANDHOME_LOGIN=1 SANDHOME_GLOBAL=0 \
    sh "$ROOT/bootstrap.sh" --home "$r192b/sandhome-home" --exec "$r192b/sandhome-exec" \
        --no-global --no-skills --no-shell --toolset none --only jq \
        >/dev/null 2>&1
t_ok "$(grep -q 'sandhome-home/profile.sh' "$r192b/home/.profile" 2>/dev/null && echo 0 || echo 1)" \
    'SANDHOME_LOGIN=1 still installs the login fragment for a named root (#192)'

t_end
