#!/bin/sh
# tests/shims.sh - build and actually use both LD_PRELOAD shims.
#
# A shim that compiles and is never called is a claim, not a capability. The two
# probes below exercise isatty(0) over a pipe and getpwnam over a synthetic
# database, in the exact shape a cage has: no pty, no /etc/passwd.
#
# Exit 2 when there is no C compiler, because that is `could not run`.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space env shim; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR
SH_SELF=shims-test

if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    echo 'shims: no C compiler to build with' >&2
    exit 2
fi

t_begin shims
sh_detect_all

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-shims.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

SH_HOME="$tmp"; SH_HOME_TMP="$tmp/tmp"; export SH_HOME SH_HOME_TMP
mkdir -p "$SH_HOME_TMP"

sh_shim_build fakepty "$ROOT/shims/fakepty.c" && t_ok 0 'fakepty compiles' || t_ok 1 'fakepty compiles'
sh_shim_build fakepwd "$ROOT/shims/fakepwd.c" && t_ok 0 'fakepwd compiles' || t_ok 1 'fakepwd compiles'
t_ok "$([ -f "$(sh_shims_dir)/fakepty.so" ] && [ -f "$(sh_shims_dir)/fakepwd.so" ]; echo $?)" 'both shared objects exist'

cat > "$tmp/probe.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <pwd.h>
int main(void){
    struct passwd *p = getpwnam("sandhome-test");
    printf("isatty0=%d name=%s\n", isatty(0), p ? p->pw_name : "(none)");
    return 0;
}
EOF
cc -O2 -o "$tmp/probe" "$tmp/probe.c" 2>/dev/null || gcc -O2 -o "$tmp/probe" "$tmp/probe.c" 2>/dev/null
t_ok "$([ -x "$tmp/probe" ]; echo $?)" 'the probe compiles'

# Without any shim: stdin is /dev/null, so no isatty, and the synthetic user is
# not in the real database.
out=$( "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'isatty0=0' 'without fakepty a pipe is not a terminal'
t_contains "$out" 'name=(none)' 'without fakepwd the user is absent'

# fakepty alone.
out=$( LD_PRELOAD="$(sh_shims_dir)/fakepty.so" "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'isatty0=1' 'fakepty makes fds 0-2 look like a terminal'

# fakepwd alone, with the synthetic database it is pointed at.
{
    printf 'sandhome-test:x:4242:4242:test:/tmp:/bin/sh\n'
} > "$(sh_shims_dir)/passwd"
out=$( SANDHOME_PASSWD="$(sh_shims_dir)/passwd" LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'name=sandhome-test' 'fakepwd answers getpwnam from SANDHOME_PASSWD'

# NOTE: THE OLD VARIABLE NAME STILL ANSWERS. fakepwd shipped answering to
# SANDSSH_PASSWD before it moved here, and a machine configured against that
# name must not break on upgrade. The clause drives the shim with only the old
# name set, and requires it to work.
out=$( SANDSSH_PASSWD="$(sh_shims_dir)/passwd" LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'name=sandhome-test' 'fakepwd still answers to the older SANDSSH_PASSWD name'

# NOTE: A FAILED BUILD SAYS WHY. The build discarded the compiler's stderr, so a
# failure reported only "cc could not build fakepty" and the operator was left to
# guess. Measured on a machine where `cc` was present and reachable but its
# assembler and linker were not on PATH: the real answer was three lines of
# `as: not found` that the build had thrown away. The error is now shown.
cat > "$tmp/bad.c" <<'EOF'
#error this will not compile
int main(void) { return; }
EOF
build_rc=0
sh_shim_build broken "$tmp/bad.c" 2>"$tmp/build-err.txt" || build_rc=$?
t_ok "$([ "$build_rc" != 0 ]; echo $?)" 'a shim that does not compile reports failure'
t_contains "$(cat "$tmp/build-err.txt" 2>/dev/null)" 'this will not compile' \
    'the compiler error is shown, not swallowed'

# NOTE: THE REPORT READS THE OBJECTS OFF THE DISK, NOT THE INTENT.
rep=$(sh_shim_report)
t_contains "$rep" 'fakepty_built=yes' 'the shim report says fakepty is built, and it is'
t_contains "$rep" 'fakepwd_built=yes' 'the shim report says fakepwd is built, and it is'
t_contains "$rep" 'passwd_file=' 'the shim report names the synthetic passwd file'
rm -f "$(sh_shims_dir)/fakepwd.so"
rep2=$(sh_shim_report)
case "$rep2" in
    *'fakepwd_built=no'*) t_ok 0 'a shim that is not there is reported as not built' ;;
    *) t_ok 1 'a shim that is not there is reported as not built' ;;
esac
case "$rep2" in
    *'fakepwd_built=yes'*) t_ok 1 'the report does not claim a shim that was removed' ;;
    *) t_ok 0 'the report does not claim a shim that was removed' ;;
esac

t_end
