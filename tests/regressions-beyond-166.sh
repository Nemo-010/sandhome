#!/bin/sh
# tests/regressions-beyond-166.sh - one clause for each improvement this round
# makes past PR #166 (issues #151-#165).
#
# WHY A SECOND FILE. tests/regressions-151-164.sh holds the round that closed
# the issues at the mechanism; this file holds the round that takes each of
# those fixes past the easy win: the toolchain that was documented instead of
# built, the installer class fixed by environment instead of by patching, the
# command that could print an empty line, the gate that checked a different
# directory from the tools. Each clause fails against the tree at pr166 and
# passes after, or is a control that must pass both ways.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space env fetch toolchain shim report; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-beyond-166

tmp=$(t_exec_tmpdir sandhome-regr-beyond-166)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

sh_regr_run() {
    SH_HOME="$tmp/home" SH_EXEC="$tmp/exec" \
    SH_HOME_TOOLCHAINS="$tmp/home/toolchains" SH_EXEC_VIEWS="$tmp/exec/views" \
    SH_EXEC_BIN="$tmp/exec/bin" SH_HOME_TMP="$tmp/home/tmp" \
    SH_REPO_DIR="$ROOT" SH_LIB_DIR="$ROOT/lib" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/env.sh"; . "$0/lib/toolchain.sh"; . "$0/lib/shim.sh"; . "$0/lib/report.sh"; '"$1" \
        "$ROOT" 2>/dev/null
}

# --- TAR_OPTIONS: third-party tar calls unpack as the caller ---------------
t_ok "$(sh_regr_run 'sh_env_body' | grep -q TAR_OPTIONS && echo 0 || echo 1)" \
    'env.sh defaults TAR_OPTIONS so foreign-uid tarballs unpack (beyond #162)'
t_ok "$(grep -q tar_no_same_owner "$ROOT/lib/report.sh" && echo 0 || echo 1)" \
    'doctor gates the TAR_OPTIONS declaration in env.sh (beyond #162)'
t_ok "$(sh_regr_run 'sh_env_body' | grep -q 'no-same-owner' && echo 0 || echo 1)" \
    'the default carries --no-same-owner (beyond #162)'

# --- CARGO_TARGET_DIR: the naive cargo build lands where it runs ------------
t_ok "$(sh_regr_run 'sh_env_body' | grep -q CARGO_TARGET_DIR && echo 0 || echo 1)" \
    'env.sh defaults CARGO_TARGET_DIR under the exec root (beyond #156)'

# --- exec-dir never prints an empty line ------------------------------------
mkdir -p "$tmp/edhome" "$tmp/edexec/bin"
printf "SANDHOME_HOME='%s'\nSANDHOME_EXEC='%s'\n" "$tmp/edhome" "$tmp/edexec" > "$tmp/edhome/env.sh"
cmd_exec_dir=$(sed -n '/^cmd_exec_dir() {/,/^}/p' "$ROOT/bin/sandhome")
t_is "$(env -i PATH=/usr/bin:/bin SH_HOME="$tmp/edhome" sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; '"$cmd_exec_dir"'; cmd_exec_dir' "$ROOT" 2>/dev/null)" \
    "$tmp/edexec" 'exec-dir reads the recorded file when no variable is set (beyond #156)'
t_ok "$(env -i PATH=/usr/bin:/bin SH_HOME=/nonexistent-home-$$ HOME=/nonexistent-home-$$ sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; '"$cmd_exec_dir"'; cmd_exec_dir' "$ROOT" >/dev/null 2>&1; [ $? -ne 0 ] && echo 0 || echo 1)" \
    'exec-dir fails loudly instead of printing an empty line (beyond #156)'

# --- resume seeds the rust target list too -----------------------------------
t_ok "$(grep -q sh_rust_targets_from_file "$ROOT/bin/sandhome" && echo 0 || echo 1)" \
    'cmd_resume seeds SH_RUST_TARGETS from the file before planning (beyond #163)'

# --- deno: redundancy across re-exec spellings, no lower bar ------------------
# A deno that refuses outputSync but honours async spawn re-executes itself,
# which is what workers need, so the second spelling passes it. A deno that
# answers --version but refuses both spellings proves it starts, not that it
# spawns, and the gate stays red for it: the bar is the re-exec, twice
# spelled, never the version.
mkdir -p "$tmp/home/toolchains/deno/bin" "$tmp/exec/views/deno" "$tmp/exec/bin"
printf '#!/bin/sh\ncase "$1" in --version) printf "deno 2.0.0\\n"; exit 0 ;; esac\ncase "$*" in *outputSync*) exit 1 ;; esac\nexit 0\n' > "$tmp/exec/views/deno/deno"
chmod +x "$tmp/exec/views/deno/deno"
mount_deno='. "$0/tools/deno.sh"; if tc_deno_doctor; then printf pass; else printf fail; fi'
t_is "$(sh_regr_run "$mount_deno")" 'pass' 'a deno that honours async spawn passes without outputSync (beyond #151)'
printf '#!/bin/sh\ncase "$1" in --version) printf "deno 2.0.0\\n"; exit 0 ;; esac\ncase "$*" in *outputSync*|*spawn*) exit 1 ;; esac\nexit 0\n' > "$tmp/exec/views/deno/deno"
chmod +x "$tmp/exec/views/deno/deno"
t_is "$(sh_regr_run "$mount_deno")" 'fail' 'a deno that answers --version but refuses both re-exec spellings is still reported (beyond #151)'

# --- node repair: verified source, loud when unrestorable --------------------
rm -rf "$tmp/ejs"
mkdir -p "$tmp/ejs/home/toolchains/node/lib/node_modules/npm/bin" \
         "$tmp/ejs/exec/views/node/lib/node_modules/npm/bin"
printf '#!/usr/bin/env node\nconsole.log(1)\n' > "$tmp/ejs/home/toolchains/node/lib/node_modules/npm/bin/npm-cli.js"
printf '#!/bin/sh\nprintf shim\n' > "$tmp/ejs/exec/views/node/lib/node_modules/npm/bin/npm-cli.js"
sh_regr_run 'SH_HOME_TOOLCHAINS='"$tmp"'/ejs/home/toolchains SH_EXEC_VIEWS='"$tmp"'/ejs/exec/views; . "$0/tools/node.sh"; tc_node_repair_cli_js '"$tmp"'/ejs/exec/views/node '"$tmp"'/ejs/home/toolchains/node' >/dev/null 2>&1
t_is "$(sed -n 1p "$tmp/ejs/exec/views/node/lib/node_modules/npm/bin/npm-cli.js")" \
    '#!/usr/bin/env node' 'the repair restores verified JavaScript (beyond #157)'
rm -rf "$tmp/ejs2"
mkdir -p "$tmp/ejs2/home/toolchains/node/lib/node_modules/npm/bin" \
         "$tmp/ejs2/exec/views/node/lib/node_modules/npm/bin"
printf '#!/bin/sh\nprintf shim\n' > "$tmp/ejs2/exec/views/node/lib/node_modules/npm/bin/npm-cli.js"
printf '#!/bin/sh\nprintf also-shim\n' > "$tmp/ejs2/home/toolchains/node/lib/node_modules/npm/bin/npm-cli.js"
out2=$(SH_HOME="$tmp/ejs2/home" SH_EXEC="$tmp/ejs2/exec" SH_HOME_TOOLCHAINS="$tmp/ejs2/home/toolchains" SH_EXEC_VIEWS="$tmp/ejs2/exec/views" SH_REPO_DIR="$ROOT" sh -c '. "$0/lib/common.sh"; . "$0/tools/node.sh"; tc_node_repair_cli_js "$1" "$2"' "$ROOT" "$tmp/ejs2/exec/views/node" "$tmp/ejs2/home/toolchains/node" 2>&1)
t_ok "$(printf '%s' "$out2" | grep -q 'shell text' && echo 0 || echo 1)" \
    'an unrestorable view is reported, not silently kept (beyond #157)'

# --- python downloads: the operator's override survives the fragment --------
# The installed-python fragment capped downloads at `never`, unconditionally,
# and the fragment is loaded inside the install process itself, so an explicit
# per-command UV_PYTHON_DOWNLOADS=manual was overwritten and
# `install --force python` could never fetch the CPython it reinstalls.
# Guarded now, like every other policy default in this tree.
t_ok "$(grep -F 'UV_PYTHON_DOWNLOADS="' "$ROOT/tools/python.sh" | grep -q 'UV_PYTHON_DOWNLOADS:-never' && echo 0 || echo 1)" \
    'the python fragment yields to an explicit downloads override (beyond #152)'
# --- no backticks inside unquoted heredoc bodies --------------------------------
# A comment with backticks inside an unquoted heredoc is command substitution:
# the shell runs it while building the body. Measured: a note in the python
# fragment writer executed two stray commands on every env write. Quoted
# delimiters are exempt; every other body must be clean.
if command -v python3 >/dev/null 2>&1; then
    bt_bad=$(python3 - "$ROOT" <<'PYEOFINNER' 2>/dev/null
import re, sys, glob
bad = []
seen = glob.glob(sys.argv[1] + '/tools/*.sh') + glob.glob(sys.argv[1] + '/lib/*.sh')
seen += [sys.argv[1] + '/bin/sandhome', sys.argv[1] + '/bootstrap.sh']
for f in seen:
    in_h = None
    for i, l in enumerate(open(f).read().split(chr(10)), 1):
        m = re.search(r'<<(\-?)\s*([\'\"]?)(\w+)\2\s*$', l)
        if m and in_h is None:
            in_h = (m.group(3), bool(m.group(2)))
            continue
        if in_h and l == in_h[0]:
            in_h = None
            continue
        if in_h and not in_h[1] and chr(96) in l:
            bad.append('%s:%d' % (f, i))
if bad:
    print(' '.join(bad))
    sys.exit(1)
PYEOFINNER
)
    t_ok "$([ -z "$bt_bad" ] && echo 0 || echo 1)"         'no unquoted heredoc body carries backticks'
else
    t_skip 'no python3 here, so the heredoc backtick sweep could not run'
fi

# --- installed python leaves uv on the exec bin, not only the view --------------
# TC_python_BINS is empty, so a bare promote linked nothing into the exec bin
# and the hook never served uv/uvx although the description promises uv is
# always left on PATH. The installed env names bin/uv bin/uvx, which creates
# the links; the sweep then keeps exactly that set on later installs.
t_ok "$(grep -q 'sh_promote_toolchain python bin/uv bin/uvx' "$ROOT/tools/python.sh" && echo 0 || echo 1)" \
    'installed python promotes bin/uv bin/uvx onto the exec bin (beyond #152)'

t_ok "$(grep -q sh_bc_dst_n "$ROOT/lib/env.sh" && echo 0 || echo 1)" \
    'the bake verifies size as well as syntax (beyond #165)'

# --- the entry point parses ---------------------------------------------------
rm -rf "$tmp/eew"
mkdir -p "$tmp/eew/home" "$tmp/eew/exec/bin"
SH_HOME="$tmp/eew/home" SH_EXEC="$tmp/eew/exec" SH_EXEC_BIN="$tmp/eew/exec/bin" \
SH_REPO_DIR="$ROOT" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_entry_write' "$ROOT" >/dev/null 2>&1
t_ok "$(sh -n "$tmp/eew/home/entry.sh" 2>/dev/null && echo 0 || echo 1)" \
    'the written entry point parses (beyond #154)'

# --- doctor probes the effective cache, not a substituted one -----------------
rm -rf "$tmp/dcache"
mkdir -p "$tmp/dcache/home" "$tmp/dcache/exec/bin" "$tmp/dcache/exec/views"
printf "SANDHOME_HOME=%s\nSANDHOME_EXEC=%s\nSANDHOME_WANTED_TOOLCHAINS='jq'\nXDG_CACHE_HOME=%s/cache\n" \
    "$tmp/dcache/home" "$tmp/dcache/exec" "$tmp/dcache/exec" > "$tmp/dcache/home/env.sh"
printf 'not-a-directory' > "$tmp/dcache/blocker"
doc_cache=$(env -i HOME="$tmp/dcache/home" PATH=/usr/bin:/bin XDG_CACHE_HOME="$tmp/dcache/blocker" \
    SH_HOME="$tmp/dcache/home" SH_EXEC="$tmp/dcache/exec" SH_EXEC_BIN="$tmp/dcache/exec/bin" \
    SH_EXEC_VIEWS="$tmp/dcache/exec/views" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/env.sh"; . "$0/lib/toolchain.sh"; . "$0/lib/report.sh"; sh_doctor' \
    "$ROOT" 2>&1)
t_ok "$(printf '%s' "$doc_cache" | grep -q 'FAIL cache_dir_exec' && echo 0 || echo 1)" \
    'doctor fails a caller-set cache that cannot run a file (beyond #158)'

# --- emscripten: the module exists and honours the contract ------------------
t_ok "$([ -r "$ROOT/tools/emscripten.sh" ] && echo 0 || echo 1)" \
    'tools/emscripten.sh exists (beyond #163)'
t_ok "$(grep -q '^TC_emscripten_DESC=' "$ROOT/tools/emscripten.sh" && grep -q '^TC_emscripten_BINS=' "$ROOT/tools/emscripten.sh" && grep -q '^TC_emscripten_EXEC_MB=' "$ROOT/tools/emscripten.sh" && echo 0 || echo 1)" \
    'the emscripten module declares DESC, BINS and EXEC_MB (beyond #163)'
for fn in tc_emscripten_probe tc_emscripten_install tc_emscripten_env tc_emscripten_doctor tc_emscripten_version; do
    t_ok "$(grep -q "$fn" "$ROOT/tools/emscripten.sh" && echo 0 || echo 1)" \
        "the emscripten module defines $fn (beyond #163)"
done
t_ok "$(grep -q '| emscripten |' "$ROOT/NOTICE" && echo 0 || echo 1)" \
    'NOTICE records the emscripten bytes, version and digest (beyond #163)'
t_ok "$(grep -q 'sandhome install emscripten' "$ROOT/lib/report.sh" && echo 0 || echo 1)" \
    'the emscripten_linker failure names the install that fixes it (beyond #163)'
t_ok "$(grep -q 'CARGO_TARGET_WASM32_UNKNOWN_EMSCRIPTEN_LINKER' "$ROOT/tools/emscripten.sh" && echo 0 || echo 1)" \
    'the emscripten fragment sets the cargo linker variable (beyond #163)'
rm -rf "$tmp/eem"
mkdir -p "$tmp/eem/exec/bin" "$tmp/eem/exec/views" "$tmp/eem/fakebin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/eem/fakebin/emcc"
chmod +x "$tmp/eem/fakebin/emcc"
t_is "$(SH_EXEC_VIEWS="$tmp/eem/exec/views" SANDHOME_EXEC="$tmp/eem/exec" PATH="$tmp/eem/fakebin:/usr/bin:/bin" \
    sh -c '. "$0/lib/common.sh"; . "$0/tools/emscripten.sh"; if tc_emscripten_doctor; then printf pass; else printf fail; fi' "$ROOT" 2>/dev/null)" \
    'pass' 'an emcc that answers --version passes the emscripten doctor (beyond #163)'
t_is "$(env -i PATH=/usr/bin:/bin SH_EXEC_VIEWS=/nonexistent SH_EXEC="$tmp/eem/exec" \
    sh -c '. "$0/lib/common.sh"; . "$0/tools/emscripten.sh"; if tc_emscripten_doctor; then printf pass; else printf fail; fi' "$ROOT" 2>/dev/null)" \
    'fail' 'no emcc anywhere fails the emscripten doctor (beyond #163)'
rm -rf "$tmp/eemc"
mkdir -p "$tmp/eemc/home/toolchains/emscripten" "$tmp/eemc/exec/views/emscripten" "$tmp/eemc/exec/bin"
cfg=$(SH_EXEC="$tmp/eemc/exec" sh -c '. "$0/lib/common.sh"; . "$0/tools/emscripten.sh"; tc_emscripten_write_config "$1/exec/views/emscripten" "$1/home/toolchains/emscripten"' "$ROOT" "$tmp/eemc" 2>/dev/null)
t_ok "$([ -r "$cfg" ] && echo 0 || echo 1)" \
    'the emscripten config writer produces a file (beyond #163)'
t_ok "$(grep -q "$tmp/eemc/exec/views/emscripten" "$cfg" 2>/dev/null && echo 0 || echo 1)" \
    'the emscripten config names the view, not the home (beyond #163)'

# --- prebind: the launcher ships, builds, binds and execs ---------------------
t_ok "$([ -r "$ROOT/skills/sealed-sandbox/prebind.c" ] && echo 0 || echo 1)" \
    'prebind.c ships beside the skill (beyond #160)'
if command -v cc >/dev/null 2>&1; then
    mkdir -p "$tmp/pb"
    if cc -O2 -o "$tmp/pb/prebind" "$ROOT/skills/sealed-sandbox/prebind.c" 2>/dev/null; then
        t_ok "$([ -x "$tmp/pb/prebind" ] && echo 0 || echo 1)" \
            'prebind.c compiles (beyond #160)'
        rm -f "$tmp/pb/pb.sock"
        "$tmp/pb/prebind" "$tmp/pb/pb.sock" 4 sh -c 'test -S "$1/pb.sock"' sh "$tmp/pb" 2>/dev/null
        t_ok "$([ -S "$tmp/pb/pb.sock" ] && echo 0 || echo 1)" \
            'prebind binds the path before exec (beyond #160)'
        rm -f "$tmp/pb/pb.sock"
        t_ok "$("$tmp/pb/prebind" "$tmp/pb/x.sock" 1 id >/dev/null 2>&1; [ $? -eq 2 ] && echo 0 || echo 1)" \
            'prebind refuses stdio fds (beyond #160)'
        rm -f "$tmp/pb/x.sock"
    else
        t_skip 'cc could not build prebind.c here'
    fi
else
    t_skip 'no cc here, so prebind.c could not be compiled'
fi

# --- docs name the new behaviour, not the old workaround -----------------------
t_ok "$(grep -q TAR_OPTIONS "$ROOT/docs/guide.md" && echo 0 || echo 1)" \
    'the guide names the TAR_OPTIONS default (beyond #162)'
t_ok "$(grep -q 'sandhome install emscripten' "$ROOT/docs/guide.md" && echo 0 || echo 1)" \
    'the guide names the emscripten install (beyond #163)'
t_ok "$(grep -q CARGO_TARGET_DIR "$ROOT/ROUTE.md" && echo 0 || echo 1)" \
    'ROUTE names the CARGO_TARGET_DIR default (beyond #156)'
t_ok "$(grep -q 'prebind.c -o prebind.c' "$ROOT/skills/sealed-sandbox/SKILL.md" && echo 0 || echo 1)" \
    'the sealed-sandbox skill fetches prebind.c instead of retyping it (beyond #160)'

t_end
