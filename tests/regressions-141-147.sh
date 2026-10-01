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
mkdir -p "$tmp/qemu/toolchains/qemuuser/bin"
: > "$tmp/qemu/toolchains/qemuuser/bin/qemu-x86_64"
qemu_sat() {
    SANDHOME_QEMUUSER_EXTRA="$1" SH_HOME_TOOLCHAINS="$tmp/qemu/toolchains" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"; tc_qemuuser_payload_satisfies' "$ROOT" >/dev/null 2>&1
}
qemu_sat '' && t_ok 0 'a host-only qemu payload satisfies a host-only request (#146)' || t_ok 1 'a host-only qemu payload satisfies a host-only request (#146)'
qemu_sat aarch64 && t_ok 1 'a payload without the guest does not satisfy --extra (#146)' || t_ok 0 'a payload without the guest does not satisfy --extra (#146)'

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

# --- #147: a copy with no environment finds its private mirror ---------------
# bin/sandhome tested the mirror and then set the repo to the directory BESIDE
# it, so the mirror was checked and discarded and `env -i <exec>/bin/sandhome`
# exited 2. The mirror-only tree here has no bake and no home pointer to rescue
# it. The bootstrap half is checked beside it: only the bootstrap writes the
# mirror on a fresh pipe setup.
mkdir -p "$tmp/mir/bin" "$tmp/mir/.sandhome-lib"
cp -R "$ROOT/lib" "$tmp/mir/.sandhome-lib/lib" 2>/dev/null
cp "$ROOT/bin/sandhome" "$tmp/mir/bin/sandhome" 2>/dev/null
chmod 0755 "$tmp/mir/bin/sandhome" 2>/dev/null
mir_out=$(env -i "$tmp/mir/bin/sandhome" version 2>/dev/null); mir_rc=$?
t_is "$mir_rc" 0 'env -i finds the private mirror (#147)'
case "$mir_out" in
    sandhome/*) t_ok 0 'the mirror-only copy answers version (#147)' ;;
    *) t_ok 1 "the mirror-only copy answers version (#147; got: $mir_out)" ;;
esac
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
