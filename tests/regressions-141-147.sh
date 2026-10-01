#!/bin/sh
# tests/regressions-141-147.sh - one clause for each defect fixed in the round
# that closed issues #141-#147.
#
# WHY A FILE OF ITS OWN. Five of the seven fixes live in code a normal suite run
# does not reach: an installed CLI's gc treatment, a dispatcher that only exists
# on the exec root, a browser cache in a node fragment, a qemu payload predicate
# and the private mirror. Each clause below fails against the tree as it stood
# when the issue was filed (the mechanism is named in the issue) and holds after.
#
# The clauses are BEHAVIOURAL where a cheap isolated call can ask the question.
# A grep on the source would not have caught the dispatcher naming the wrong
# remedy at runtime, nor `gc` deleting a real `go install` binary; both are
# driven here through the functions a caller actually runs.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space env fetch toolchain; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-141-147

tmp=$(t_exec_tmpdir sandhome-regr-141-147)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# --- #141: gc must not reclaim an installed CLI -----------------------------
# Mechanism: the gc scan named $SH_EXEC/go-bin among the exec caches and DAYS=0
# removed everything in it, so `gc 0` deleted a real `go install` binary while
# calling it a cache (lib/space.sh sh_space_gc). A cache entry must still go.
mkdir -p "$tmp/gc/exec/cache" "$tmp/gc/exec/go-bin" "$tmp/gc/home"
printf 'blob\n' > "$tmp/gc/exec/cache/blob"
printf 'tool\n' > "$tmp/gc/exec/go-bin/mytool"
( SH_HOME="$tmp/gc/home" SH_EXEC="$tmp/gc/exec" SANDHOME_GC_FORCE=1 sh_space_gc 0 ) >/dev/null 2>&1
[ -f "$tmp/gc/exec/go-bin/mytool" ] && t_ok 0 'gc keeps a go-bin payload (#141)' || t_ok 1 'gc keeps a go-bin payload (#141)'
[ -e "$tmp/gc/exec/cache/blob" ] && t_ok 1 'gc still reclaims an exec cache (#141)' || t_ok 0 'gc still reclaims an exec cache (#141)'

# --- #141: space --largest tags an installed CLI as yours --------------------
# The legend said `sandhome` is what gc reclaims, so tagging go-bin sandhome
# told the operator to run the command that deletes their tools. The tag must
# now mean "this tree owns it" and only cache/staging/tmp are reclaimable.
mkdir -p "$tmp/sl/exec/go-bin" "$tmp/sl/exec/cache"
head -c 4096 /dev/zero > "$tmp/sl/exec/go-bin/mytool" 2>/dev/null
head -c 4096 /dev/zero > "$tmp/sl/exec/cache/blob" 2>/dev/null
sl_out=$(SH_HOME="$tmp/sl/home" SH_EXEC="$tmp/sl/exec" sh_space_largest 10 2>/dev/null)
case "$sl_out" in
    *"$tmp/sl/exec/go-bin"*'(yours)'*) t_ok 0 'space --largest tags go-bin as yours (#141)' ;;
    *) t_ok 1 "space --largest tags go-bin as yours (#141; got: $sl_out)" ;;
esac
case "$sl_out" in
    *"$tmp/sl/exec/cache"*'(sandhome)'*) t_ok 0 'space --largest still tags cache as sandhome (#141)' ;;
    *) t_ok 1 'space --largest still tags cache as sandhome (#141)' ;;
esac

# --- #141: an unknown install aborts before env.sh is rewritten -------------
# cmd_install counted the unknown name and fell through to sh_env_write and
# sh_global_install, so `install stringer` rewrote env.sh and the hook before
# the counter turned the exit code non-zero. The sentinel is the proof.
mkdir -p "$tmp/un/home" "$tmp/un/exec"
printf 'SENTINEL=keep\n' > "$tmp/un/home/env.sh"
SANDHOME_HOME="$tmp/un/home" SANDHOME_EXEC="$tmp/un/exec" SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" install nosuchtool > "$tmp/un/out" 2>&1
un_rc=$?
t_is "$un_rc" 1 'install of an unknown toolchain exits non-zero (#141)'
t_is "$(cat "$tmp/un/home/env.sh" 2>/dev/null)" 'SENTINEL=keep' 'install of an unknown toolchain leaves env.sh alone (#141)'

# --- #142: the dispatcher links a CLI an installer writes -------------------
# A fresh shell could not find `npm install -g cowsay` until the operator ran
# `sandhome global`, because the hook's names were a static list. The generated
# dispatcher now runs installer names as a child and links what they wrote.
disp=$(SH_HOME="$tmp/disp" SH_EXEC="$tmp/disp-exec" SH_EXEC_BIN="$tmp/disp-exec/bin" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_global_write_dispatch "$1" "$2" "$3"; cat "$1"' \
    "$ROOT" "$tmp/disp-dispatch" "$tmp/disp" "$tmp/disp-exec/bin" 2>/dev/null)
case "$disp" in
    *_sandhome_install=yes*) t_ok 0 'the dispatcher has an installer refresh path (#142)' ;;
    *) t_ok 1 'the dispatcher has an installer refresh path (#142)' ;;
esac
case "$disp" in
    *'ln -sf .sandhome-dispatch'*) t_ok 0 'the dispatcher links the names an installer writes (#142)' ;;
    *) t_ok 1 'the dispatcher links the names an installer writes (#142)' ;;
esac
sh -n "$tmp/disp-dispatch" 2>/dev/null && t_ok 0 'the generated dispatcher parses (#142)' || t_ok 1 'the generated dispatcher parses (#142)'

# --- #143: the node fragment points the browser caches at the exec root -----
# Puppeteer and Playwright defaulted to $HOME/.cache, the mount that refuses
# execve, so a downloaded browser could not run. The fragment must name both,
# with a caller's value kept, and the two dirs must exist.
mkdir -p "$tmp/node/bin" "$tmp/node-exec/views" "$tmp/node-exec/bin" "$tmp/node-home/toolchains/node"
printf '#!/bin/sh\necho 10.0.0\n' > "$tmp/node/bin/npm"; chmod 0755 "$tmp/node/bin/npm"
PATH="$tmp/node/bin:$PATH" SH_HOME="$tmp/node-home" SH_EXEC="$tmp/node-exec" SH_REPO_DIR="$ROOT" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/env.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/node.sh"
           SH_HOME_TOOLCHAINS="$SH_HOME/toolchains"; SH_EXEC_VIEWS="$SH_EXEC/views"; SH_EXEC_BIN="$SH_EXEC/bin"
           export SH_HOME_TOOLCHAINS SH_EXEC_VIEWS SH_EXEC_BIN
           tc_node_env >/dev/null 2>&1' "$ROOT" >/dev/null 2>&1
node_frag=$(cat "$tmp/node-home/env.d/node.sh" 2>/dev/null)
case "$node_frag" in
    *'PUPPETEER_CACHE_DIR="${PUPPETEER_CACHE_DIR:-$SANDHOME_EXEC/puppeteer}"'*) t_ok 0 'the node fragment points PUPPETEER_CACHE_DIR at the exec root (#143)' ;;
    *) t_ok 1 'the node fragment points PUPPETEER_CACHE_DIR at the exec root (#143)' ;;
esac
case "$node_frag" in
    *'PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$SANDHOME_EXEC/ms-playwright}"'*) t_ok 0 'the node fragment points PLAYWRIGHT_BROWSERS_PATH at the exec root (#143)' ;;
    *) t_ok 1 'the node fragment points PLAYWRIGHT_BROWSERS_PATH at the exec root (#143)' ;;
esac
[ -d "$tmp/node-exec/puppeteer" ] && [ -d "$tmp/node-exec/ms-playwright" ] && \
    t_ok 0 'the browser cache directories are created (#143)' || \
    t_ok 1 'the browser cache directories are created (#143)'

# --- #144: the sanitizer options are set only where ptrace is denied ---------
# LSan stops threads with ptrace and dies with the programme's stdout unflushed,
# so env.sh now records the measured ptrace answer and sets detect_leaks=0 when
# it is not `yes`. The pair of clauses is the point: the option is added where
# it is needed and NOT added where leak checking works.
asan_body() {
    SH_HOME="$tmp/as" SH_EXEC="$tmp/as-exec" SH_REPO_DIR="$ROOT" SH_PTRACE="$1" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_env_body' "$ROOT" 2>/dev/null
}
case "$(asan_body no)" in
    *'ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"'*) t_ok 0 'env.sh disables leak checking when ptrace=no (#144)' ;;
    *) t_ok 1 'env.sh disables leak checking when ptrace=no (#144)' ;;
esac
case "$(asan_body yes)" in
    *'detect_leaks=0'*) t_ok 1 'env.sh leaves leak checking on when ptrace=yes (#144)' ;;
    *) t_ok 0 'env.sh leaves leak checking on when ptrace=yes (#144)' ;;
esac
case "$(asan_body no)" in
    *"SANDHOME_PTRACE='no'"*) t_ok 0 'env.sh records the ptrace answer (#144)' ;;
    *) t_ok 1 'env.sh records the ptrace answer (#144)' ;;
esac

# --- #145: faketty names a terminal when the caller did not -----------------
# A userspace pty with TERM unset or dumb still fails every terminfo lookup, so
# `less` answered "'unknown': I need something more specific". A real TERM must
# survive untouched.
: > "$tmp/dummy.so"
term_unset=$(env -u TERM SANDHOME_FAKEPTY="$tmp/dummy.so" sh "$ROOT/shell/faketty" sh -c 'printf %s "${TERM:-}"' 2>/dev/null)
t_is "$term_unset" 'xterm-256color' 'faketty defaults an unset TERM (#145)'
term_dumb=$(TERM=dumb SANDHOME_FAKEPTY="$tmp/dummy.so" sh "$ROOT/shell/faketty" sh -c 'printf %s "$TERM"' 2>/dev/null)
t_is "$term_dumb" 'xterm-256color' 'faketty replaces a dumb TERM (#145)'
term_real=$(TERM=screen SANDHOME_FAKEPTY="$tmp/dummy.so" sh "$ROOT/shell/faketty" sh -c 'printf %s "$TERM"' 2>/dev/null)
t_is "$term_real" 'screen' 'faketty keeps a real TERM (#145)'
term_over=$(env -u TERM SANDHOME_FAKEPTY="$tmp/dummy.so" SANDHOME_FAKEPTY_TERM=vt100 sh "$ROOT/shell/faketty" sh -c 'printf %s "${TERM:-}"' 2>/dev/null)
t_is "$term_over" 'vt100' 'faketty honours SANDHOME_FAKEPTY_TERM (#145)'

# --- #146: a payload that cannot serve the request is not "already present" --
# qemuuser could hold the host emulator and be asked for --extra aarch64; the
# ensure path then printed "rebuilding the view without downloading" and,
# after the probe, "downloading a fresh copy". The predicate is asked first.
# # THE PAYLOAD DIR IS <toolchains>/qemuuser/bin, NOT <toolchains>/bin. The
# first fixture here put the host emulator one level too high, so every clause
# below answered "missing" for the wrong reason and the positive clause passed
# while the predicate was blind to the directory it was asked about. `tc_qemuuser_root`
# is `sh_toolchain_root qemuuser`; the layout is asserted beside the behaviour.
mkdir -p "$tmp/qemu/toolchains/qemuuser/bin"
: > "$tmp/qemu/toolchains/qemuuser/bin/qemu-x86_64"
qemu_sat() {
    SANDHOME_QEMUUSER_EXTRA="$1" SH_HOME_TOOLCHAINS="$tmp/qemu/toolchains" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/space.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"; tc_qemuuser_payload_satisfies' "$ROOT" >/dev/null 2>&1
}
qemu_root=$(SH_HOME_TOOLCHAINS="$tmp/qemu/toolchains" sh -c '. "$0/lib/common.sh"; . "$0/lib/space.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"; tc_qemuuser_root' "$ROOT" 2>/dev/null)
t_is "$qemu_root" "$tmp/qemu/toolchains/qemuuser" 'the qemu payload root is <toolchains>/qemuuser (#146)'
qemu_sat '' && t_ok 0 'a host-only qemu payload satisfies a host-only request (#146)' || t_ok 1 'a host-only qemu payload satisfies a host-only request (#146)'
qemu_sat aarch64 && t_ok 1 'a payload without the guest does not satisfy --extra (#146)' || t_ok 0 'a payload without the guest does not satisfy --extra (#146)'
# The positive control: with the guest on disk the predicate must say yes, or
# the clause above is satisfied by a function that only ever answers no.
: > "$tmp/qemu/toolchains/qemuuser/bin/qemu-aarch64"
qemu_sat aarch64 && t_ok 0 'a payload with the guest satisfies --extra (#146)' || t_ok 1 'a payload with the guest satisfies --extra (#146)'
qemu_sat arm && t_ok 1 'a payload without a different guest does not satisfy --extra (#146)' || t_ok 0 'a payload without a different guest does not satisfy --extra (#146)'

# --- #146: the archive is kept so a second --extra does not re-download ------
# Callers may reuse the bytes for the next guest; the install must not delete
# qu.tar.xz with the extracted tree. The check is on the cleanup line, because
# the full fetch needs the Electrosphere and a 63MB transfer.
grep_reused=$(case "$(cat "$ROOT/tools/qemuuser.sh" 2>/dev/null)" in
    *'rm -rf "$sh_qu_dir" "$sh_qu_root/qu.tar.xz"'*) printf 'deleted' ;;
    *) printf 'kept' ;;
esac)
if [ "$grep_reused" = kept ]; then
    t_ok 0 'the qemu archive is kept for reuse (#146)'
else
    t_ok 1 'the qemu archive is kept for reuse (#146)'
fi

# --- #149: an explicit --exec is not collapsed into the home ----------------
# MEASURED END TO END, BECAUSE THE ISOLATED CALL CANNOT SEE THIS. A single
# `sh_promote_toolchain` on a fresh payload takes the direct-link path before
# the branch that collapses, so a fixture calling it once passes on the broken
# tree as well as the fixed one. The defect only appears through a real install:
# `--exec DIR` was honoured for the ROOT (`exec_reason=explicit`) and then every
# VIEW was sent into the home, so the caller paid for a second root that stayed
# empty. Measured on the tree as filed: `bootstrap --toolset minimal --exec $E`
# with a home that runs files left `$E/views` EMPTY and put jq's view under the
# home; after the fix `$E/views/jq` exists and the roots line names both.
# jq is the smallest toolchain in the minimal toolset (2.2MB), so this is a real
# install and not a shape.
r149_h="$tmp/r149/h"
r149_e="$tmp/r149/e"
mkdir -p "$r149_h/bin" "$r149_e" "$tmp/r149/wb"
timeout 900 env -i HOME="$r149_h" PATH="$r149_h/bin:$tmp/r149/wb:/usr/bin:/bin" TMPDIR="$tmp" \
    http_proxy="$http_proxy" https_proxy="$https_proxy" no_proxy="$no_proxy" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --exec "$r149_e" \
    --no-shims --no-skills --no-shell --no-profile --no-global \
    > "$tmp/r149/log" 2>&1
r149_rc=$?
if [ "$r149_rc" != 0 ]; then
    t_skip "the #149 bootstrap could not run here (rc=$r149_rc)"
else
    r149_exec=$(sed -n 's/^exec=//p' "$tmp/r149/log" | head -1)
    t_is "$r149_exec" "$r149_e" 'the explicit exec root is the recorded root (#149)'
    if [ -d "$r149_e/views/jq" ] || [ -d "$r149_e/views/jq/bin" ]; then
        t_ok 0 'the named exec root receives the toolchain view (#149)'
    else
        t_ok 1 "the named exec root receives the toolchain view (#149; $r149_e/views holds: $(ls "$r149_e/views" 2>/dev/null | tr '\n' ' '))"
    fi
    # The control the fix must not break: a home that runs files and NO named
    # root still collapses, so nothing is copied needlessly.
    r149_c="$tmp/r149c"
    mkdir -p "$r149_c/h/bin" "$r149_c/e" "$r149_c/wb"
    timeout 900 env -i HOME="$r149_c/h" PATH="$r149_c/h/bin:$r149_c/wb:/usr/bin:/bin" TMPDIR="$tmp" \
        http_proxy="$http_proxy" https_proxy="$https_proxy" no_proxy="$no_proxy" \
        sh "$ROOT/bootstrap.sh" --toolset minimal \
        --no-shims --no-skills --no-shell --no-profile --no-global \
        > "$tmp/r149c/log" 2>&1
    if [ $? = 0 ]; then
        r149_chome=$(sed -n 's/^home=//p' "$tmp/r149c/log" | head -1)
        r149_cexec=$(sed -n 's/^exec=//p' "$tmp/r149c/log" | head -1)
        t_is "$r149_cexec" "$r149_chome" 'with no named root the home is still chosen (control, #149)'
    else
        t_skip "the #149 control bootstrap could not run here"
    fi
fi

# --- the hook must never take a directory inside the exec root --------------
# # THE DOCTOR GATE, NOT ONLY THE INSTALL RULE. A hook written into a view bin
# answers a fresh shell and therefore read as `on:<dir>` (healthy), while it
# shadowed that view's tools with another view's names. The install rule below
# stops it being written; this clause stops it reading as healthy if it exists.
# Driven through sh_doctor itself, with a recorded hook directory under the
# exec root and one outside it, so both directions are seen.
hook_doctor_case() {
    dh="$tmp/hd/home"; de="$tmp/hd/exec"
    mkdir -p "$dh" "$de/bin" "$de/views/probe/bin" "$tmp/hd/consumer" 2>/dev/null
    printf '#!/bin/sh\nexit 0\n' > "$de/bin/sandhome" 2>/dev/null
    printf 'SANDHOME_HOME=%s\nSANDHOME_EXEC=%s\n' "$dh" "$de" > "$dh/env.sh" 2>/dev/null
    SH_HOME="$dh" SH_EXEC="$de" SH_EXEC_BIN="$de/bin" SH_HOME_TOOLCHAINS="$dh/toolchains" \
    SH_EXEC_VIEWS="$de/views" SANDHOME_HOME="$dh" SANDHOME_EXEC="$de" SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/env.sh"; . "$0/lib/toolchain.sh"; . "$0/lib/shim.sh"; . "$0/lib/report.sh"
               st=$(sh_global_state_dir 2>/dev/null); mkdir -p "$st/d" 2>/dev/null
               printf "%s\n" "$1" > "$st/dirs" 2>/dev/null
               sh_doctor 2>/dev/null | sed -n "s/^[^ ]*  *global_hook=//p"' \
        "$ROOT" "$2" 2>/dev/null | head -1
}
# A recorded directory under the exec root must be a failure by name.
hd_inside=$(hook_doctor_case "$tmp/hd" "$tmp/hd/exec/views/probe/bin")
case "$hd_inside" in
    inside-exec-root:*) t_ok 0 'doctor fails a hook recorded inside the exec root (#149)' ;;
    *) t_ok 1 "doctor fails a hook recorded inside the exec root (#149; got: $hd_inside)" ;;
esac
# The control: a consumer directory outside the exec root stays healthy.
hd_outside=$(hook_doctor_case "$tmp/hd" "$tmp/hd/consumer")
case "$hd_outside" in
    on:*|stale:*) t_ok 0 'doctor accepts a hook outside the exec root (control, #149)' ;;
    *) t_ok 1 "doctor accepts a hook outside the exec root (control, #149; got: $hd_outside)" ;;
esac

# --- the hook must never take a directory inside the exec root --------------
# A bootstrap whose PATH already carried the view bins (the PATH env.sh
# writes, which the hook install runs WITH) took `$SH_EXEC/views/node/bin` and
# `$SH_EXEC/views/python/bin` as hook directories: it wrote .sandhome-dispatch
# and node/npm/npx links into the python view, so `command -v node` answered
# from the python view and the hook clashed with uv/uvx. The rule is the one
# already spelled for NAMES: a hit inside the exec root is this tree's own
# indirection, never a PATH entry a fresh shell consults.
skip_case() {
    SH_EXEC="$tmp/skip/exec" SH_EXEC_BIN="$tmp/skip/exec/bin" SH_HOME="$tmp/skip/home" SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/space.sh"; . "$0/lib/env.sh"; sh_global_skip_entry "$1"' "$ROOT" "$1" 2>/dev/null
}
for in_tree in "$tmp/skip/exec/views/node/bin" "$tmp/skip/exec/views/python/bin" \
               "$tmp/skip/exec/npm-global/bin" "$tmp/skip/exec/go-bin" "$tmp/skip/exec/bin" \
               "$tmp/skip/exec/global"; do
    mkdir -p "$in_tree" 2>/dev/null
    if skip_case "$in_tree"; then
        t_ok 0 "the hook refuses $in_tree (inside the exec root)"
    else
        t_ok 1 "the hook refuses $in_tree (inside the exec root)"
    fi
done
mkdir -p "$tmp/skip/consumer-bin"
if skip_case "$tmp/skip/consumer-bin"; then
    t_ok 1 'the hook still takes a consumer bin directory (control)'
else
    t_ok 0 'the hook still takes a consumer bin directory (control)'
fi

# --- a hook written in place into a bin dir is cleaned up, not left ---------
# The repair path only relocated a directory replaced by a SYMLINK, so an
# in-place hook kept its dispatcher and name links after the rule changed.
mkdir -p "$tmp/heal/exec/views/node/bin"
printf '#!/bin/sh\n' > "$tmp/heal/exec/views/node/bin/.sandhome-dispatch"
chmod 0755 "$tmp/heal/exec/views/node/bin/.sandhome-dispatch"
ln -sf .sandhome-dispatch "$tmp/heal/exec/views/node/bin/node"
mkdir -p "$tmp/heal/state"
printf '%s\n' "$tmp/heal/exec/views/node/bin" > "$tmp/heal/state/dirs"
mkdir -p "$tmp/heal/state/d/0"
printf 'no\n' > "$tmp/heal/state/d/0/link"
SH_EXEC="$tmp/heal/exec" SH_HOME="$tmp/heal/home" SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/space.sh"; . "$0/lib/env.sh"; sh_global_relocate_record "$1" "$2"' \
    "$ROOT" "$tmp/heal/state" "$tmp/heal/exec/views/node/bin" >/dev/null 2>&1
[ -e "$tmp/heal/exec/views/node/bin/.sandhome-dispatch" ] && \
    t_ok 1 'a stale in-place hook is cleaned up (#149 follow-up)' || \
    t_ok 0 'a stale in-place hook is cleaned up (#149 follow-up)'
[ -e "$tmp/heal/exec/views/node/bin/node" ] && \
    t_ok 1 'the shadowing name link is removed (#149 follow-up)' || \
    t_ok 0 'the shadowing name link is removed (#149 follow-up)'

# --- #147: a copy with no environment finds its private mirror ---------------
# env -i finds the mirror, and the mirror is the directory it names. The
# `sandhome path` at the end is the proof and not decoration: the bake
# deliberately disagrees with the home, so the only way `env -i` can reach the
# mirror is through `$0`, and the path it reports is either the exec root (the
# defect, which discarded the mirror it had just read) or the mirror itself.
mkdir -p "$tmp/mir/bin" "$tmp/mir/.sandhome-lib"
cp -R "$ROOT/lib" "$tmp/mir/.sandhome-lib/lib" 2>/dev/null
cp "$ROOT/bin/sandhome" "$tmp/mir/bin/sandhome" 2>/dev/null
chmod 0755 "$tmp/mir/bin/sandhome" 2>/dev/null
sed "s|^SH_BAKED_REPO_DIR=''|SH_BAKED_REPO_DIR='/nonexistent-repo'|" \
    "$tmp/mir/bin/sandhome" > "$tmp/mir/bin/sandhome.baked" 2>/dev/null && \
    mv -f "$tmp/mir/bin/sandhome.baked" "$tmp/mir/bin/sandhome" 2>/dev/null
chmod 0755 "$tmp/mir/bin/sandhome" 2>/dev/null
# # SANDHOME_EXEC IS NAMED FOR THE CHILD, BECAUSE THE ROOT IS A SECOND INPUT.
# `env -i ... path` prints the exec ROOT, and the root is planned even when the
# library came from the mirror: the candidate list names $PWD/.sandhome/exec and
# /workspace/.sandhome/exec ahead of anything scratch, and on a machine whose
# checkout runs binaries one of those wins. Without the variable the clause
# would be about the box, not about the mirror, so the fixture names the root
# beside itself and the answer it asserts is the mirror home the copy resolved.
# The REPO, not the root, is what this clause is about; `env -i` still supplies
# no library path (`sh_repo` is unreachable except through the mirror) and the
# bake is deliberately wrong.
mkdir -p "$tmp/mir-exec"
mir_res=$(env -i SANDHOME_EXEC="$tmp/mir-exec" "$tmp/mir/bin/sandhome" path 2>/dev/null); mir_rc=$?
t_is "$mir_rc" 0 'env -i finds the private mirror (#147)'
case "$mir_res" in
    "$tmp/mir-exec/bin") t_ok 0 'the mirror copy resolves the repo to the mirror itself (#147)' ;;
    *) t_ok 1 "the mirror copy resolves the repo to the mirror itself (#147; got: $mir_res)" ;;
esac
# # THE NEGATIVE HALF, BECAUSE THE CLAUSE ABOVE CANNOT SEE THE BUG ALONE. The
# defect was that sh_repo became the exec ROOT (the directory above the mirror)
# and the next readability check threw the mirror away, so `sandhome` could not
# start at all. The broken parse names $tmp/mir as the repo, and /nonexistent as
# the root; run the unpatched line on purpose and the same command must fail.
sed "s|sh_priv/.sandhome-lib\" 2>/dev/null|sh_priv\" 2>/dev/null|" \
    "$tmp/mir/bin/sandhome" > "$tmp/mir/bin/sandhome.broken" 2>/dev/null
if cmp -s "$tmp/mir/bin/sandhome" "$tmp/mir/bin/sandhome.broken"; then
    t_ok 1 'the repro fixture patched the mirror line (it did not match)'
else
    chmod 0755 "$tmp/mir/bin/sandhome.broken" 2>/dev/null
    env -i SANDHOME_EXEC="$tmp/mir-exec" "$tmp/mir/bin/sandhome.broken" path >/dev/null 2>&1
    t_ok "$([ $? -ne 0 ]; echo $?)" 'the unpatched mirror line cannot start, so the clause above is not vacuous (#147)'
fi
case "$(cat "$ROOT/bootstrap.sh" 2>/dev/null)" in
    *'sh_exec_mirror_library || true'*) t_ok 0 'the bootstrap writes the private mirror (#147)' ;;
    *) t_ok 1 'the bootstrap writes the private mirror (#147)' ;;
esac

# --- #147: the mirror writer puts lib/ and bin/ on the exec root -------------
# The behavioural half of the writer, so the clause above is not only a claim
# about a call site: point the writer at a scratch exec root and read the bytes.
mkdir -p "$tmp/mw-exec"
SH_EXEC="$tmp/mw-exec" SH_REPO_DIR="$ROOT" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_exec_mirror_library' "$ROOT" >/dev/null 2>&1
[ -r "$tmp/mw-exec/.sandhome-lib/lib/common.sh" ] && \
    t_ok 0 'the mirror writer copies lib/ into .sandhome-lib (#147)' || \
    t_ok 1 'the mirror writer copies lib/ into .sandhome-lib (#147)'

t_end
