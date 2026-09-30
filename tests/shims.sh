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

# An exec-capable temp dir, because /tmp refuses execve on some sandboxes while
# /workspace runs it (and the reverse elsewhere). Building probes into a noexec
# tmp fails every run clause with Permission denied, which reads as a shim
# defect when it is a temp-dir defect.
tmp=$(t_exec_tmpdir sandhome-shims)
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

# # STOP: A PROBE THAT ASKS FOR SEVERAL NAMES, BECAUSE THE OLD ONE COULD NOT SEE
# A BOUND. It asked for a single hard-coded user, so a shim that answered 32 of
# 33 entries correctly passed every clause it had; the 33rd entry wrote one
# char[1024] past the end of a static array and killed the process with SIGSEGV,
# and nothing in the suite could tell the difference between a shim that serves
# 255 accounts and one that serves 32. The `u<N>` names below are what make that
# difference observable.
cat > "$tmp/pwprobe.c" <<'EOF'
#include <stdio.h>
#include <pwd.h>
int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        struct passwd *p = getpwnam(argv[i]);
        printf("%s -> %s\n", argv[i], p ? p->pw_name : "(none)");
    }
    return 0;
}
EOF
cc -O2 -o "$tmp/pwprobe" "$tmp/pwprobe.c" 2>/dev/null || gcc -O2 -o "$tmp/pwprobe" "$tmp/pwprobe.c" 2>/dev/null
t_ok "$([ -x "$tmp/pwprobe" ]; echo $?)" 'the multi-name passwd probe compiles'

# Without any shim: stdin is /dev/null, so no isatty, and the synthetic user is
# not in the real database.
out=$( "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'isatty0=0' 'without fakepty a pipe is not a terminal'
t_contains "$out" 'name=(none)' 'without fakepwd the user is absent'

# fakepty alone.
out=$( LD_PRELOAD="$(sh_shims_dir)/fakepty.so" "$tmp/probe" < /dev/null 2>/dev/null )
t_contains "$out" 'isatty0=1' 'fakepty makes fds 0-2 look like a terminal'

# # STOP: isatty() ALONE IS NOT A TERMINAL. A full-screen program also asks for
# a termios and a window size, and opens /dev/tty when it wants keys. The probe
# below asks for all of them, and then makes fd 1 a NEW pipe to prove the
# SCOPED session does not report that pipe as a terminal - the defect the
# unconditional fd 0-2 shim has, which put ANSI codes into `jq | cat`.
cat > "$tmp/ptyprobe.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/ioctl.h>
int main(void){
    struct termios t; struct winsize w; int p[2], save, r;
    printf("isatty0=%d isatty1=%d\n", isatty(0), isatty(1));
    printf("tcgetattr0=%d\n", tcgetattr(0,&t));
    ioctl(1,TIOCGWINSZ,&w); printf("win=%dx%d\n", w.ws_col, w.ws_row);
    printf("devtty=%d\n", open("/dev/tty",O_RDONLY)>=0);
    save=dup(1); pipe(p); dup2(p[1],1); r=isatty(1); dup2(save,1); close(save);
    printf("piped_isatty1=%d\n", r);
    fflush(stdout);
    return 0;
}
EOF
cc -O2 -o "$tmp/ptyprobe" "$tmp/ptyprobe.c" 2>/dev/null || gcc -O2 -o "$tmp/ptyprobe" "$tmp/ptyprobe.c" 2>/dev/null
t_ok "$([ -x "$tmp/ptyprobe" ]; echo $?)" 'the full-terminal probe compiles'

out=$( LD_PRELOAD="$(sh_shims_dir)/fakepty.so" "$tmp/ptyprobe" < /dev/null 2>/dev/null )
t_contains "$out" 'tcgetattr0=0' 'fakepty answers tcgetattr on a faked fd'
t_contains "$out" 'win=80x24' 'fakepty reports a default window size'
t_contains "$out" 'devtty=1' 'fakepty maps /dev/tty onto the session descriptors'
t_contains "$out" 'piped_isatty1=1' 'without a session id a new pipe on fd 1 is still faked (the old behaviour)'

# A size the caller chose wins over the default.
out=$( SANDHOME_FAKEPTY_SIZE=100x40 LD_PRELOAD="$(sh_shims_dir)/fakepty.so" "$tmp/ptyprobe" < /dev/null 2>/dev/null )
t_contains "$out" 'win=100x40' 'SANDHOME_FAKEPTY_SIZE sets the window size'

# SANDHOME_FAKEPTY_ID scopes the faking to the named descriptors, and /proc is
# read through /proc/$$/fd because readlink itself is a child whose fd 1 is the
# command-substitution pipe. With the id set to the session's own fds the probe
# sees a terminal, and the pipe it makes on fd 1 is NOT one.
scoped=$(sh -c '
    id0=$(readlink /proc/$$/fd/0 2>/dev/null || true)
    id1=$(readlink /proc/$$/fd/1 2>/dev/null || true)
    SANDHOME_FAKEPTY_ID="$id0 $id1" LD_PRELOAD="$1" "$2"
' sh "$(sh_shims_dir)/fakepty.so" "$tmp/ptyprobe" < /dev/null 2>/dev/null)
t_contains "$scoped" 'isatty0=1' 'a scoped session still reports its own descriptors as a terminal'
t_contains "$scoped" 'piped_isatty1=0' 'a scoped session leaves a pipe opened later as a pipe (#jq)'

# An id that matches nothing is not a terminal, so an unrelated process cannot
# inherit the faking by accident.
unscoped=$(sh -c 'SANDHOME_FAKEPTY_ID="pipe:[99999999]" LD_PRELOAD="$1" "$2"' \
    sh "$(sh_shims_dir)/fakepty.so" "$tmp/ptyprobe" < /dev/null 2>/dev/null)
t_contains "$unscoped" 'isatty0=0' 'a session id that matches nothing fakes nothing'

# # STOP: ONLCR IS EMULATED, BECAUSE A PIPE DOES NOT DO IT. A program told
# OPOST|ONLCR writes a bare \n and expects the terminal to return the carriage;
# over a pipe that draws a staircase. Byte count is the assertion: A\nB is 3
# bytes, A\r\nB is 4, and the switch turns it off.
cat > "$tmp/crlfprobe.c" <<'EOF'
#include <unistd.h>
int main(void){ return write(1, "A\nB", 3) < 0; }
EOF
cc -O2 -o "$tmp/crlfprobe" "$tmp/crlfprobe.c" 2>/dev/null || gcc -O2 -o "$tmp/crlfprobe" "$tmp/crlfprobe.c" 2>/dev/null
crlf_on=$(LD_PRELOAD="$(sh_shims_dir)/fakepty.so" "$tmp/crlfprobe" < /dev/null 2>/dev/null | wc -c | tr -d ' ')
t_is "$crlf_on" '4' 'the shim turns a bare newline into CRLF like a terminal'
crlf_off=$(SANDHOME_FAKEPTY_CRLF=0 LD_PRELOAD="$(sh_shims_dir)/fakepty.so" "$tmp/crlfprobe" < /dev/null 2>/dev/null | wc -c | tr -d ' ')
t_is "$crlf_off" '3' 'SANDHOME_FAKEPTY_CRLF=0 passes output through byte for byte'

# # STOP: THE WRAPPER IS THE CALLER-FACING HALF, AND IT MUST SURVIVE A
# SUBSHELL. shell/faketty exports the interposer and execs, so a shell the
# command spawns inherits a terminal. The clause runs a child shell from inside
# faketty and asks BOTH whether the preload crossed and whether the child sees a
# tty; a wrapper that only set the variable in its own process would pass the
# first and fail the second.
faketty_out=$(SANDHOME_FAKEPTY="$(sh_shims_dir)/fakepty.so" \
    sh "$ROOT/shell/faketty" sh -c 'printf "CHILD-LD=%s\n" "$LD_PRELOAD"; if [ -t 0 ]; then echo CHILD-TTY; fi' \
    < /dev/null 2>/dev/null)
t_contains "$faketty_out" 'fakepty.so' 'faketty exports the interposer to the command'
t_contains "$faketty_out" 'CHILD-TTY' 'a subshell faketty starts keeps the terminal'
t_ok "$([ -x "$ROOT/shell/faketty" ] || [ -r "$ROOT/shell/faketty" ]; echo $?)" 'faketty is in the tree'

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

# # STOP: THE REPORT NAMES WHAT IS ON DISK, AND THE FIELD IT PRINTS IS A PROBE
# AND NOT A COUNTER. `shims=` read $SH_SHIMS_BUILT, which means "built by THIS
# run", and so it was empty on every path that could reach a report:
#   - a second run: the .so was already there, so nothing was appended;
#   - --dry-run: nothing was compiled, by design, so nothing was appended;
#   - `sandhome report`: it never calls the builder at all, so it was unset.
# The one case that populated it was a fresh home, so a home where an earlier
# run had built both shims reported `shims=` while both .so files sat right
# there. Measured, before the fix, on a home where fakepty.so and fakepwd.so
# both existed:
#   $ sh bin/sandhome report | grep '^shims='
#   shims=
# Three clauses, one per way the old field was empty, plus the negative: a
# machine that needs nothing reports nothing and does not claim it does.
SH_PTY=no; SH_PASSWD=no; SH_PTRACE=no
export SH_PTY SH_PASSWD SH_PTRACE
# The rep2 clauses above removed fakepwd.so to prove the report does not claim
# it, and this block asserts against the reader, so the state is rebuilt first.
# Every clause below then SETS UP its own state and reads it back: a version
# that inherited whatever the clauses above happened to leave behind passed for
# the wrong reason the moment the order changed, and two of these failed for
# exactly that reason before they were given their own setup.
sh_shim_build fakepty "$ROOT/shims/fakepty.c" >/dev/null 2>&1
sh_shim_build fakepwd "$ROOT/shims/fakepwd.c" >/dev/null 2>&1
sh_shim_build antiptrace "$ROOT/shims/antiptrace.c" >/dev/null 2>&1
for sh_ts_s in fakedrm fakeinput fakexenv fakedisplay; do
    sh_shim_build "$sh_ts_s" "$ROOT/shims/$sh_ts_s.c" >/dev/null 2>&1
done
t_is "$(sh_shim_present)" 'fakepty fakepwd antiptrace fakedrm fakeinput fakexenv fakedisplay' 'the present-shim reader names every object on disk'
rm -f "$(sh_shims_dir)/fakepty.so"
t_is "$(sh_shim_present)" 'fakepwd antiptrace fakedrm fakeinput fakexenv fakedisplay' 'removing one object is reflected by the reader'
rm -f "$(sh_shims_dir)/fakepwd.so"
t_is "$(sh_shim_present)" 'antiptrace fakedrm fakeinput fakexenv fakedisplay' 'the reader tracks removals one at a time'
rm -f "$(sh_shims_dir)/antiptrace.so" "$(sh_shims_dir)/fakedrm.so" "$(sh_shims_dir)/fakeinput.so" "$(sh_shims_dir)/fakexenv.so" "$(sh_shims_dir)/fakedisplay.so"
t_is "$(sh_shim_present)" '' 'the present-shim reader names nothing when nothing is there'
# # STOP: THE NEEDED-AND-MISSING READER IS ASSERTED OVER A TABLE OF SHAPES, NOT
# OVER THIS HOST. The old clause branched on an OR of the four headless facts and
# then asserted the empty string, which needs ALL FOUR unneeded - so a host with
# /dev/dri but no DISPLAY took the "headed" branch and got `fakexenv fakedisplay`
# against a wanted ``, which is exactly the six-hour-red shape a GitHub runner has
# (issue #121). The facts are now detectors that write SH_DRM, SH_INPUT, SH_XENV
# and SH_DISPLAY (like SH_PTY/SH_PASSWD/SH_PTRACE before them), so every shape is
# built here and the expectation is computed from the same facts the reader uses.
#
# The expected string is derived, never a literal per branch: dri/input/xenv/
# display each contribute their shim when absent, so a reader that dropped one or
# a need-rule that changed would fail the table rather than pass on one host.
sh_tbl_expected() {
    sh_te_want=''
    [ "$SH_PTY" = no ] && sh_te_want="$sh_te_want fakepty"
    [ "$SH_PASSWD" = no ] && sh_te_want="$sh_te_want fakepwd"
    case "$SH_PTRACE" in no|partial) sh_te_want="$sh_te_want antiptrace" ;; esac
    [ "$SH_DRM" = no ] && sh_te_want="$sh_te_want fakedrm"
    [ "$SH_INPUT" = no ] && sh_te_want="$sh_te_want fakeinput"
    [ "$SH_XENV" = no ] && sh_te_want="$sh_te_want fakexenv"
    [ "$SH_DISPLAY" = no ] && sh_te_want="$sh_te_want fakedisplay"
    printf '%s' "${sh_te_want# }"
}
# A GitHub ubuntu-latest runner: pty yes, passwd yes, ptrace works, /dev/dri and
# /dev/input present, no DISPLAY and no Wayland socket. This is the row that was
# red in CI; it is now built here and would be red on every host, not only there.
SH_PTY=yes; SH_PASSWD=yes; SH_PTRACE=yes; SH_DRM=yes; SH_INPUT=yes; SH_XENV=no; SH_DISPLAY=no
t_is "$(sh_shim_needed_missing)" "$(sh_tbl_expected)" 'the runner shape names exactly fakexenv and fakedisplay'
t_is "$(sh_shim_needed_missing)" 'fakexenv fakedisplay' 'the runner shape is fakexenv fakedisplay, not the empty string'
# A cage: nothing answers, every shim is needed.
SH_PTY=no; SH_PASSWD=no; SH_PTRACE=no; SH_DRM=no; SH_INPUT=no; SH_XENV=no; SH_DISPLAY=no
t_is "$(sh_shim_needed_missing)" "$(sh_tbl_expected)" 'the cage shape names every shim'
t_is "$(sh_shim_needed_missing)" 'fakepty fakepwd antiptrace fakedrm fakeinput fakexenv fakedisplay' 'the needed-and-missing reader names each shim'
# A desktop with dri, input and an X display but no Wayland session: only the
# Wayland shim remains. This row failed on any such host under the old OR/AND bug.
SH_PTY=yes; SH_PASSWD=yes; SH_PTRACE=yes; SH_DRM=yes; SH_INPUT=yes; SH_XENV=yes; SH_DISPLAY=no
t_is "$(sh_shim_needed_missing)" "$(sh_tbl_expected)" 'a headed host with no Wayland socket needs only fakedisplay'
t_is "$(sh_shim_needed_missing)" 'fakedisplay' 'the headed-without-wayland shape is exactly fakedisplay'
# A fully headed host: needs nothing.
SH_PTY=yes; SH_PASSWD=yes; SH_PTRACE=yes; SH_DRM=yes; SH_INPUT=yes; SH_XENV=yes; SH_DISPLAY=yes
t_is "$(sh_shim_needed_missing)" "$(sh_tbl_expected)" 'a fully headed host needs no shim'
t_is "$(sh_shim_needed_missing)" '' 'a headed machine needs no shim at all'
# A host whose only lack is uinput-class input: /dev/input absent but uinput
# absent too, phrased through the detector's own answer so the row is about the
# fact and not about the node.
SH_PTY=yes; SH_PASSWD=yes; SH_PTRACE=yes; SH_DRM=yes; SH_INPUT=no; SH_XENV=yes; SH_DISPLAY=yes
t_is "$(sh_shim_needed_missing)" "$(sh_tbl_expected)" 'a host with no input devices needs fakeinput'
t_is "$(sh_shim_needed_missing)" 'fakeinput' 'the no-input shape is exactly fakeinput'
unset sh_tbl_expected
# With nothing present and both needed, the report must say so rather than
# reporting an empty list, which reads as "none were ever needed".
SH_PTY=no; SH_PASSWD=no; SH_PTRACE=no; SH_DRM=no; SH_INPUT=no; SH_XENV=no; SH_DISPLAY=no
t_contains "$(sh_shim_report)" 'fakepty_built=no' 'a missing shim is reported as not built'
# A machine with a pty and a passwd database and every headless device needs
# nothing, and an empty MISSING list is the right answer there - the same empty
# string as a machine that needs two and has neither, and only the second is a
# problem. The two fields exist so neither is read as the other. This is now
# forced through the facts rather than branched on an OR of the host's.
SH_PTY=yes; SH_PASSWD=yes; SH_PTRACE=yes; SH_DRM=yes; SH_INPUT=yes; SH_XENV=yes; SH_DISPLAY=yes
t_is "$(sh_shim_needed_missing)" '' 'a fully provisioned machine needs no shim at all'
t_is "$(sh_shim_present)" '' 'and has none present, which is the right answer'
SH_PTY=no; SH_PASSWD=no; SH_PTRACE=no; SH_DRM=no; SH_INPUT=no; SH_XENV=no; SH_DISPLAY=no
# Rebuilt for the LD_PRELOAD clauses below.
sh_shim_build fakepty "$ROOT/shims/fakepty.c" >/dev/null 2>&1
sh_shim_build fakepwd "$ROOT/shims/fakepwd.c" >/dev/null 2>&1
sh_shim_build antiptrace "$ROOT/shims/antiptrace.c" >/dev/null 2>&1
for sh_ts_s in fakedrm fakeinput fakexenv fakedisplay; do
    sh_shim_build "$sh_ts_s" "$ROOT/shims/$sh_ts_s.c" >/dev/null 2>&1
done

# The BOOTSTRAP COUNTS A NEEDED SHIM IT COULD NOT BUILD, AND SAYS SO. It used to
# warn once on stderr and finish with `failures=0` and exit 0, because
# sh_shim_build_all returned 0 whatever happened and only --require-shims looked.
# Measured with a PATH holding no compiler, on a machine that needs both shims:
#   bootstrap: [!] no C compiler is present, so fakepty cannot be built
#   bootstrap: [!] no C compiler is present, so fakepwd cannot be built
#   failures=0
#   $? = 0
# This clause runs the real command in a subprocess with a PATH that has the
# shell and the toolchain's prerequisites but no compiler, and reads the exit
# status a script would read.
#
# # STOP: THE SUBPROCESS IS MACHINE-SHAPED, AND THE OLD ASSERTIONS WERE TRUE
# ONLY ON A CAGE (judge, standing finding; every CI run red at this clause).
# The old clause required the literal `shims_missing=fakepty`, but whether ANY
# shim is needed is decided by sh_detect_all from the real machine: a runner
# with /dev/ptmx and a readable /etc/passwd needs neither, so the field is
# empty there and the assertion was red on every push. Worse, the no-compiler
# PATH also lacked curl and wget, so the run failed for the DOWNLOADER, not
# the shim: the exit-non-zero clause passed for the wrong reason on both
# machine shapes. Repaired three ways, measured:
#   - the subprocess PATH now carries curl and wget, so the toolchain installs
#     and the only possible failure left on a cage is the shim one;
#     the branch predicate reads the same SH_PTY/SH_PASSWD the child's own
#     sh_detect_all answers from - no override exists and none is faked -
#     so the subprocess claims asserted here hold on EVERY machine: a run
#     with a downloader and no compiler finishes clean on a host that
#     needs no shim, and the cage-shaped claims are asserted only on a
#     machine that is actually cage-shaped;
#   - the per-shim needed/missing answers are driven directly above with
#     SH_PTY/SH_PASSWD forced, which is machine-independent and where the
#     real contract lives.
nocc_bin="$tmp/nocc"
mkdir -p "$nocc_bin"
for need in sh dash test printf cat rm mkdir uname id df cp mv chmod ln \
            readlink find touch sed grep env dirname basename date mktemp \
            sha256sum shasum curl wget tar cut awk python3; do
    src=$(command -v "$need" 2>/dev/null) || continue
    ln -sfn "$src" "$nocc_bin/$need" 2>/dev/null || true
done
if command -v cc >/dev/null 2>&1 && [ ! -e "$nocc_bin/cc" ] && [ ! -e "$nocc_bin/gcc" ]; then
    nocc_home="$tmp/nocc-home"
    nocc_out=$(PATH="$nocc_bin" SANDHOME_HOME="$nocc_home" SANDHOME_EXEC="$tmp/nocc-exec" \
        SANDHOME_REPO_DIR="$ROOT" sh "$ROOT/bootstrap.sh" --toolset minimal \
        --no-profile --no-path-line --no-shell 2>"$tmp/nocc-err.txt")
    nocc_rc=$?
    # What THIS machine needs, read from the SAME seven-fact answer the child
    # computes, not from two of them. The old predictor asked only sh_detect_pty
    # and sh_detect_passwd; the child's bootstrap also weighs /dev/dri,
    # /dev/input, DISPLAY and WAYLAND_DISPLAY, so a runner that has a pty and a
    # passwd database but no display took the "needs no shim" branch while the
    # child correctly named fakexenv/fakedisplay missing, and four clauses
    # cascaded red (issue #121). The parent now re-reads the real machine and
    # asks the product's own need rule, so the branch and the child answer the
    # same question. The forced SH_* values above are cleared first so they
    # cannot leak into this prediction.
    #
    # The prediction is the NEED set, not sh_shim_needed_missing: the child runs
    # with a fresh SANDHOME_HOME, so every shim it needs is missing there. Asking
    # the presence-filtered reader would subtract the parent's already-built .so
    # files and predict "nothing missing" while the child names them all.
    SH_PTY=$(sh_detect_pty); SH_PASSWD=$(sh_detect_passwd); SH_PTRACE=$(sh_detect_ptrace)
    SH_DRM=$(sh_detect_dri); SH_INPUT=$(sh_detect_input)
    SH_XENV=$(sh_detect_xenv); SH_DISPLAY=$(sh_detect_display)
    nocc_want=''
    for nocc_s in $(sh_shim_names); do
        [ "$(sh_shim_need "$nocc_s")" = yes ] && nocc_want="$nocc_want $nocc_s"
    done
    nocc_want="${nocc_want# }"
    nocc_needs_shims=no
    [ -n "$nocc_want" ] && nocc_needs_shims=yes
    if [ "$nocc_needs_shims" = yes ]; then
        t_ok "$([ "$nocc_rc" -ne 0 ]; echo $?)" \
            'a needed shim that could not be built makes the bootstrap exit non-zero'
        # shims_missing is a SPACE-SEPARATED list, so the first-token sed only
        # ever tested emptiness. Capture the whole value: it is the field that
        # names every shim the run could not build, and the clause must compare
        # all of them, not just the first.
        nocc_missing=$(printf '%s\n' "$nocc_out" | sed -n 's/^shims_missing=//p')
        t_is "$nocc_missing" "$nocc_want" 'a run that failed for shims names exactly what is missing'
        # failures must NOT be 0 here. Checked directly, because a `contains`
        # clause for `failures=` would also match a run that says failures=0.
        case "$nocc_out" in
            *'failures=0'*) t_ok 1 'the failure count is not zero when a needed shim is missing' ;;
            *)              t_ok 0 'the failure count is not zero when a needed shim is missing' ;;
        esac
    else
        # A host that needs no shim must finish this run CLEAN with a
        # downloader present and no compiler: nothing was needed, so nothing
        # may be reported missing. This is the half the old assertions could
        # not see, and it is the claim CI actually measures.
        t_ok "$([ "$nocc_rc" -eq 0 ]; echo $?)" \
            'a host needing no shim finishes clean with no compiler at all'
        t_contains "$nocc_out" 'shims_missing=' 'the report carries the shims_missing field on every machine'
        nocc_empty_missing=$(printf '%s\n' "$nocc_out" | sed -n 's/^shims_missing=$/EMPTY/p')
        case "$nocc_empty_missing" in
            EMPTY) t_ok 0 'no shim is named missing where none is needed' ;;
            *)     t_ok 1 'no shim is named missing where none is needed' ;;
        esac
        case "$nocc_out" in
            *'failures=0'*) t_ok 0 'a clean run reports a zero failure count' ;;
            *)              t_ok 1 'a clean run reports a zero failure count' ;;
        esac
    fi
    unset nocc_want
else
    t_skip 'cc is absent or on the hermetic PATH, so the no-compiler bootstrap did not run'
fi

# # STOP: fakepwd SURVIVES A PASSWD FILE LONGER THAN THE OLD 32-ENTRY TABLE, AND
# THE BOUND IS CHECKED BEFORE fgets IS REACHED. The loop condition was
# `while (fgets(lines[nusers], LNLEN, f) && nusers < MAXU)`, which EVALUATES
# fgets FIRST: with 33 lines it wrote lines[32], one char[1024] past the end of
# the array, overlapping the struct table, and the interposed program died with
# SIGSEGV. 40 entries is reachable without anyone asking: sh_shim_write_passwd
# writes every name in SANDHOME_PASSWD_USERS, and a cage that grants forty
# service accounts crashed every dynamically linked program that asked.
{
    i=1
    while [ "$i" -le 40 ]; do
        printf 'u%d:x:%d:%d:u:/home/u%d:/bin/sh\n' "$i" $((5000 + i)) $((5000 + i)) "$i"
        i=$((i + 1))
    done
} > "$tmp/pw40"
out=$( SANDHOME_PASSWD="$tmp/pw40" LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" \
       "$tmp/pwprobe" u1 u33 u40 2>/dev/null )
out_rc=$?
t_ok "$([ "$out_rc" -ne 139 ] && [ "$out_rc" -lt 128 ]; echo $?)" \
    'a 40-entry passwd file does not segfault the program it is interposed into'
t_contains "$out" 'u1 -> u1' 'fakepwd answers for the first entry'
t_contains "$out" 'u33 -> u33' 'fakepwd answers for an entry past the old 32-entry bound'
t_contains "$out" 'u40 -> u40' 'fakepwd answers for the last entry'

# # STOP: THE ORDER OF THE LOOP CONDITION IS ITS OWN CLAUSE, BECAUSE THE BOUND
# AND THE ORDER ARE SEPARATE DEFECTS WITH THE SAME SYMPTOM. A version of this
# file with `while (fgets(lines[nusers], LNLEN, f) && nusers < MAXU)` - fgets
# evaluated FIRST, so lines[MAXU] is written before the bound is tested - still
# passes the 40-entry clause above when the bound is also 256, because the write
# lands on a slot inside the array and nothing crashes. It is only fatal at
# exactly 33 entries with a 32-entry table, and it corrupts memory silently
# until it does not. A file of 40 entries is measured here for the second time
# with the table raised, so the ORDER is what the second measurement can see.
{
    i=1
    while [ "$i" -le 40 ]; do
        printf 'o%d:x:%d:%d:o:/home/o%d:/bin/sh\n' "$i" $((6000 + i)) $((6000 + i)) "$i"
        i=$((i + 1))
    done
} > "$tmp/pw40b"
out=$( SANDHOME_PASSWD="$tmp/pw40b" LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" \
       "$tmp/pwprobe" o1 o40 2>/dev/null )
out_rc=$?
t_ok "$([ "$out_rc" -eq 0 ]; echo $?)" \
    'a passwd file inside the table bound is served with a clean exit'
t_contains "$out" 'o40 -> o40' 'every entry inside the bound is served, first to last'
# The write-out-of-bounds is only observable at the boundary, so the boundary
# itself is the clause: one entry PAST the documented bound must be refused
# loudly rather than served from a slot the reader never wrote.
{
    i=1
    while [ "$i" -le 260 ]; do
        printf 'b%d:x:%d:%d:b:/home/b%d:/bin/sh\n' "$i" $((7000 + i)) $((7000 + i)) "$i"
        i=$((i + 1))
    done
} > "$tmp/pw260"
out=$( SANDHOME_PASSWD="$tmp/pw260" LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" \
       "$tmp/pwprobe" b1 b256 b260 2>&1 )
case "$out" in
    *b1\ -\>*) t_ok 0 'a 260-entry file is served without crashing' ;;
    *) t_ok 1 "a 260-entry file is served without crashing (got: $out)" ;;
esac
# And past the bound it says so, rather than answering a smaller database in
# silence. That is the whole of the change from a crash to a stated limit.
case "$out" in
    *'not served'*|*'more than'*) t_ok 0 'entries past the bound are reported, not dropped in silence' ;;
    *) t_ok 1 "entries past the bound are reported, not dropped in silence (got: $out)" ;;
esac

# # STOP: AN EMPTY FIELD IS AN EMPTY FIELD AND NOT A MISSING ENTRY. The parser
# used strtok, which treats a run of `:` as ONE delimiter, so a passwd(5) line
# with an empty password field or an empty gecos field produced fewer than seven
# tokens and the WHOLE LINE WAS DROPPED. Both are ordinary: the password field is
# very often empty and the gecos field is empty on plenty of accounts. The
# failure mode is `getpwnam` returning NULL, which an ssh client reads as
# "Permission denied (publickey)" - the exact misdiagnosis SANDHOME_PASSWD_USERS
# exists to prevent. Measured, before the fix:
#   alice::1000:1000:Alice:/home/alice:/bin/sh   -> (none)
#   bob:x:1001:1001::/home/bob:/bin/bash         -> (none)
#   carol:x:1002:1002:Carol:/home/carol:/bin/zsh -> carol
{
    printf 'alice::1000:1000:Alice:/home/alice:/bin/sh\n'
    printf 'bob:x:1001:1001::/home/bob:/bin/bash\n'
    printf 'carol:x:1002:1002:Carol:/home/carol:/bin/zsh\n'
} > "$tmp/pw-empty"
out=$( SANDHOME_PASSWD="$tmp/pw-empty" LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" \
       "$tmp/pwprobe" alice bob carol 2>/dev/null )
t_contains "$out" 'alice -> alice' 'a line whose password field is empty is served'
t_contains "$out" 'bob -> bob' 'a line whose gecos field is empty is served'
t_contains "$out" 'carol -> carol' 'a line with every field populated is still served'

# THE BUILT-IN DEFAULT SHELL IS /bin/sh, BECAUSE THE FILE NAMED /bin/bash.
# The rest of the tree derives the real shell from ${SHELL:-/bin/sh}, and
# getusershell() and an sshd $SHELL read this field; a default pointing at a
# program this image may not carry breaks a login for a reason that looks
# nothing like a missing binary.
cat > "$tmp/shellprobe.c" <<'EOF'
#include <stdio.h>
#include <pwd.h>
int main(void){
    struct passwd *p = getpwuid(0);
    printf("shell=%s\n", p ? p->pw_shell : "(none)");
    return 0;
}
EOF
cc -O2 -o "$tmp/shellprobe" "$tmp/shellprobe.c" 2>/dev/null || gcc -O2 -o "$tmp/shellprobe" "$tmp/shellprobe.c" 2>/dev/null
if [ -x "$tmp/shellprobe" ]; then
    out=$( env -u SANDHOME_PASSWD -u SANDSSH_PASSWD \
           LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" "$tmp/shellprobe" 2>/dev/null )
    t_is "$out" 'shell=/bin/sh' 'the built-in default shell is /bin/sh, like the rest of the tree'
else
    t_skip 'the shell probe did not compile'
fi

# A PASSWD FILE THE CALLER NAMED AND CANNOT OPEN IS REPORTED, NOT ANSWERED WITH
# A SMALLER DATABASE. SANDHOME_PASSWD is the variable that makes this shim work;
# a typo in it was silent, and the operator got a database containing only root
# and no diagnostic anywhere.
missing_err=$( SANDHOME_PASSWD=/nonexistent/passwd LD_PRELOAD="$(sh_shims_dir)/fakepwd.so" \
              "$tmp/pwprobe" alice 2>&1 >/dev/null )
case "$missing_err" in
    *fakepwd*passwd*) t_ok 0 'a SANDHOME_PASSWD that cannot be opened is reported on stderr' ;;
    *) t_ok 1 "a SANDHOME_PASSWD that cannot be opened is reported on stderr (got: $missing_err)" ;;
esac

# antiptrace: a program that self-checks with PTRACE_TRACEME, and reads TracerPid
# from /proc/self/status, refuses to run where the ptrace syscall class is denied.
# This shim is checked the way the other two are: built, then ACTUALLY USED, with
# a probe that prints the same answers a guarded program would branch on.
# STOP: THE STATUS PROBE USES open(), NOT fopen(). glibc's fopen reaches the
# kernel through an internal alias that never crosses the PLT, so no
# LD_PRELOAD interposer sees it: a fopen-based clause passes vacuously on a
# host whose TracerPid is already 0 and proves nothing about the shim. open()
# and openat() cross the PLT and are what cat, grep and python's io use, so
# the probe reads with those and the fixture below carries a non-zero
# TracerPid that only the shim can zero.
cat > "$tmp/antiptrace.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ptrace.h>
static void dump(const char *path) {
    char buf[4096];
    ssize_t n;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { printf("open-fail\n"); return; }
    n = read(fd, buf, sizeof buf - 1);
    if (n < 0) { printf("read-fail\n"); close(fd); return; }
    buf[n] = 0;
    printf("%s", buf);
    close(fd);
}
int main(int argc, char **argv){
    int tr = ptrace(PTRACE_TRACEME, 0, 0, 0);
    printf("traceme=%d errno=%d\n", tr, tr ? errno : 0);
    dump(argc > 1 ? argv[1] : "/proc/self/status");
    return 0;
}
EOF
cc -O2 -o "$tmp/antiptrace-probe" "$tmp/antiptrace.c" 2>/dev/null || \
    gcc -O2 -o "$tmp/antiptrace-probe" "$tmp/antiptrace.c" 2>/dev/null
t_ok "$([ -x "$tmp/antiptrace-probe" ]; echo $?)" 'the antiptrace probe compiles'

# The host's real answer, recorded so the shim clause is measured against it and
# not against a constant. On a host that allows ptrace this is traceme=0 and the
# shim clauses below still hold; on a host that denies it the difference is the
# whole point.
real_traceme=$( "$tmp/antiptrace-probe" 2>/dev/null | sed -n 's/^traceme=\([0-9-]*\).*/\1/p' )
t_ok "$([ -n "$real_traceme" ]; echo $?)" 'the host answers the PTRACE_TRACEME self-check'

# With the shim, the self-check SUCCEEDS. This is the clause that makes the shim
# a capability: without it a guarded program exits before doing anything.
out=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" "$tmp/antiptrace-probe" 2>/dev/null )
t_contains "$out" 'traceme=0' 'antiptrace makes PTRACE_TRACEME report success'

# The fixture carries a TracerPid only the shim can zero: 1234 without it,
# zeros with it, through open() and through openat() (cat). A shim that
# covered open() only would pass the first and fail the second, which is
# exactly the gap the first version of this file shipped.
mkdir -p "$tmp/fakeproc"
printf 'Name:\tprobe\nTracerPid:\t1234\nwchan:\tptrace_stop\n' > "$tmp/fakeproc/status"
out=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" "$tmp/antiptrace-probe" "$tmp/fakeproc/status" 2>/dev/null )
t_contains "$out" 'TracerPid:	0000' 'antiptrace zeroes a non-zero TracerPid through open()'
case "$out" in
    *'TracerPid:	1234'*) t_ok 1 'the unedited value is gone through open()' ;;
    *) t_ok 0 'the unedited value is gone through open()' ;;
esac
t_contains "$out" 'wchan:	00000000000' 'antiptrace zeroes wchan through open()'
out=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" cat "$tmp/fakeproc/status" 2>/dev/null )
t_contains "$out" 'TracerPid:	0000' 'antiptrace zeroes a non-zero TracerPid through openat() (cat)'
case "$out" in
    *'TracerPid:	1234'*) t_ok 1 'the unedited value is gone through openat()' ;;
    *) t_ok 0 'the unedited value is gone through openat()' ;;
esac

# /proc files report size 0, and a shim that sized its buffer off fstat would
# edit nothing on the real path while passing every fixture clause. The size
# is measured first so the clause is about the machine, then the shim serves
# the real file without breaking it.
if [ -r /proc/self/status ] && command -v stat >/dev/null 2>&1; then
    t_is "$(stat -c %s /proc/self/status 2>/dev/null)" '0' '/proc/self/status reports size 0 here'
    out=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" cat /proc/self/status 2>/dev/null | grep -c '^TracerPid:' )
    t_is "$out" '1' 'the shim still serves the size-0 real status file'
else
    t_skip 'no readable /proc/self/status to prove the size-0 path'
fi

# # STOP: THE EDITED FILE MUST BE A FILE THE CALLER CAN ACTUALLY USE. Handing
# back a buffer without a descriptor, or a descriptor that does not seek, breaks
# every consumer that fstat()s or lseek()s what it opened. The probe re-opens,
# seeks and reads, and the clause requires the whole shape to work.
cat > "$tmp/statusfd.c" <<'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
int main(void){
    int fd = open("/proc/self/status", O_RDONLY);
    if (fd < 0) { printf("open=-1\n"); return 1; }
    if (lseek(fd, 0, SEEK_SET) != 0) { printf("seek=fail\n"); return 1; }
    char buf[4096];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    printf("read=%ld\n", (long)n);
    close(fd);
    return 0;
}
EOF
cc -O2 -o "$tmp/statusfd" "$tmp/statusfd.c" 2>/dev/null || gcc -O2 -o "$tmp/statusfd" "$tmp/statusfd.c" 2>/dev/null
out=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" "$tmp/statusfd" 2>/dev/null )
t_ok "$([ -x "$tmp/statusfd" ]; echo $?)" 'the status-fd probe compiles'
out=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" "$tmp/statusfd" 2>/dev/null )
t_ok "$([ -n "$out" ]; echo $?)" 'the status-fd probe produces output through the shim'
t_ok "$(case "$out" in read=[1-9]*) echo 0 ;; *) echo 1 ;; esac)" 'the shim gives back a readable, seekable status file'

# # STOP: THE THIRD ARGUMENT OF open() EXISTS ONLY WITH O_CREAT, AND READING IT
# ANYWAY SEGFAULTS. The first version of the shim called va_arg for a mode_t on
# every call. `cat /proc/self/status` opens WITHOUT O_CREAT, and the shim crashed
# with SIGSEGV on the exact path it exists for, while a call that did pass a mode
# happened to survive. The clause below drives the no-mode path and requires a
# clean run, not a signal.
out=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" cat /proc/self/status 2>/dev/null | grep -c '^TracerPid:' )
t_is "$out" '1' 'opening status without O_CREAT does not crash the shim'
# And a call that DOES pass a mode still works, so the flag test is not merely
# skipping the argument.
modeprobe=$( LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" sh -c 'umask 022; : > "$1"; echo made; stat -c %a "$1"' sh "$tmp/made-by-mode" 2>/dev/null )
t_contains "$modeprobe" 'made' 'a create with a mode still works through the shim'

# The two behaviours are separately switchable, because faking the self-check is
# a bigger change than zeroing a field.
#
# # STOP: "RESTORES THE HOST ANSWER" COMPARES AGAINST THE HOST, NOT AGAINST 0.
# The clause hardcoded `traceme=0`, the answer a host that ALLOWS ptrace gives.
# On a host where TRACEME is refused (measured: a GitHub ubuntu-latest runner),
# the corrected passthrough returns the host's real `traceme=1`, which is right,
# and the clause failed anyway - a test asserting one machine shape while
# measuring whether the shim restores the machine it is on (issue #121).
# real_traceme is the recorded answer from the unshimmed probe above; the
# clause now requires the passthrough to reproduce exactly that.
out=$( SANDHOME_ANTIPTRACE_TRACEME=0 LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" "$tmp/antiptrace-probe" 2>/dev/null )
pt_traceme=$(printf '%s\n' "$out" | sed -n 's/^traceme=\([0-9-]*\).*/\1/p')
t_is "$pt_traceme" "$real_traceme" 'SANDHOME_ANTIPTRACE_TRACEME=0 restores the host answer'
out=$( SANDHOME_ANTIPTRACE_STATUS=0 SANDHOME_ANTIPTRACE_WCHAN=0 LD_PRELOAD="$(sh_shims_dir)/antiptrace.so" "$tmp/antiptrace-probe" 2>/dev/null )
t_contains "$out" 'traceme=0' 'with only the self-check faked, TRACEME still succeeds'

# Detection: the probe this shim is gated on must answer, and must answer what
# this host really is. A detection that always said 'no' would build the shim
# everywhere and hide a host where it is not needed.
#
# # STOP: THE DETECTOR HAS THREE ANSWERS AND THE BRANCH HAD TWO. sh_detect_ptrace
# answers yes, no OR partial (lib/detect.sh), and its own comment says partial
# counts as needed. A host that refuses TRACEME but answers a bogus request with
# EIO/ESRCH instead of EPERM returns partial; the yes/no branch had no arm for it
# and failed with `got partial, wanted yes` (issue #121). The clauses below assert
# the property that matters - a detector answer is never unknown, and the shim is
# needed exactly when the answer is no or partial - rather than a two-way guess.
det=$(sh_detect_ptrace)
t_ok "$([ "$det" != unknown ]; echo $?)" 'the ptrace detector answers on this host'
t_ok "$(case "$det" in yes|no|partial) echo 0 ;; *) echo 1 ;; esac)" 'the detector answer is one of yes, no or partial'
if [ "$real_traceme" = 0 ]; then
    t_ok "$(case "$det" in yes|partial) echo 0 ;; *) echo 1 ;; esac)" 'ptrace answers here, and the detector agrees it is not denied'
else
    t_ok "$(case "$det" in no|partial) echo 0 ;; *) echo 1 ;; esac)" 'ptrace is denied here, and the detector says so'
fi
# The detector's answer and the shim's need must agree, whatever the host.
SH_PTRACE=$det
t_ok "$( { [ "$det" = no ] || [ "$det" = partial ]; } && [ "$(sh_shim_need antiptrace)" = yes ] && echo 0 || { [ "$det" = yes ] && [ "$(sh_shim_need antiptrace)" = no ] && echo 0; } || echo 1)" 'the detector answer and the shim need agree'

# And the shim is NEEDED exactly when ptrace is denied, so a healthy host builds
# nothing. This is the clause that keeps the shim off a machine that does not
# want it.
SH_PTRACE=yes; t_is "$(sh_shim_need antiptrace)" 'no' 'a host with ptrace does not need antiptrace'
SH_PTRACE=no;  t_is "$(sh_shim_need antiptrace)" 'yes' 'a host without ptrace needs antiptrace'
SH_PTRACE=partial; t_is "$(sh_shim_need antiptrace)" 'yes' 'a host with a partly-denied ptrace needs antiptrace too'
SH_PTRACE=unknown; t_is "$(sh_shim_need antiptrace)" 'no' 'an unprobed host is not assumed broken'

# The headless shims: enumeration opens succeed where nothing exists, and
# display probes answer. One probe program with handwritten declarations (no
# X/Wayland headers, same as the shims), resolved through dlsym so the
# binary links with no display libraries. Assignments are sequential
# statements: printf argument order is unspecified, and reading a probe
# out-param inside the same printf that calls the probe is how a passing
# shim once reported its own success as a failure.
cat > "$tmp/headless.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
int main(void){
    int fd, r, ma, ev, er;
    void *d, *w, *rg;
    void *(*xopen)(const char *);
    int (*xscreens)(void *);
    int (*xext)(void *, const char *, int *, int *, int *);
    void *(*wlconn)(const char *);
    void *(*wlreg)(void *);
    struct stat st;
    fd = open("/dev/dri/card0", O_RDONLY);
    printf("dri-open=%d\n", fd); if (fd >= 0) close(fd);
    fd = open("/dev/input/event0", O_RDONLY);
    printf("input-open=%d\n", fd); if (fd >= 0) close(fd);
    r = stat("/dev/dri/card0", &st);
    printf("dri-stat=%d\n", r);
    xopen = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    xscreens = (int (*)(void *))dlsym(RTLD_DEFAULT, "XScreenCount");
    xext = (int (*)(void *, const char *, int *, int *, int *))dlsym(RTLD_DEFAULT, "XQueryExtension");
    wlconn = (void *(*)(const char *))dlsym(RTLD_DEFAULT, "wl_display_connect");
    wlreg = (void *(*)(void *))dlsym(RTLD_DEFAULT, "wl_display_get_registry");
    printf("syms=%d%d%d%d%d\n", !!xopen, !!xscreens, !!xext, !!wlconn, !!wlreg);
    d = xopen ? xopen((const char *)0) : (void *)0;
    printf("xopen=%s\n", d ? "nonnull" : "null");
    if (d && xscreens) { r = xscreens(d); printf("screens=%d\n", r); }
    if (d && xext) { ma = -1; ev = -1; er = -1; r = xext(d, "XTEST", &ma, &ev, &er); printf("xext=%d major=%d\n", r, ma); }
    w = wlconn ? wlconn((const char *)0) : (void *)0;
    printf("wlconnect=%s\n", w ? "nonnull" : "null");
    if (w && wlreg) { rg = wlreg(w); printf("wlreg=%s\n", rg ? "nonnull" : "null"); }
    return 0;
}
EOF
cc -O2 -o "$tmp/headless" "$tmp/headless.c" -ldl 2>/dev/null || \
    gcc -O2 -o "$tmp/headless" "$tmp/headless.c" -ldl 2>/dev/null
t_ok "$([ -x "$tmp/headless" ]; echo $?)" 'the headless probe compiles with no display libraries'
if [ ! -e /dev/dri ] && [ ! -e /dev/input ] && [ ! -e /dev/uinput ]; then
    hs_out=$(LD_PRELOAD="$(sh_shims_dir)/fakedrm.so $(sh_shims_dir)/fakeinput.so $(sh_shims_dir)/fakexenv.so $(sh_shims_dir)/fakedisplay.so" "$tmp/headless" 2>/dev/null)
    case "$hs_out" in
        *'dri-open=-1'*) t_ok 1 "fakedrm opens /dev/dri/card0 (got: $hs_out)" ;;
        *) t_ok 0 'fakedrm opens /dev/dri/card0' ;;
    esac
    case "$hs_out" in
        *'input-open=-1'*) t_ok 1 "fakeinput opens /dev/input/event0 (got: $hs_out)" ;;
        *) t_ok 0 'fakeinput opens /dev/input/event0' ;;
    esac
    t_contains "$hs_out" 'dri-stat=0' 'fakedrm stats /dev/dri/card0'
    t_contains "$hs_out" 'xopen=nonnull' 'fakexenv answers XOpenDisplay'
    t_contains "$hs_out" 'screens=1' 'fakexenv reports one screen'
    t_contains "$hs_out" 'xext=1 major=128' 'fakexenv answers extension queries at a fixed base'
    t_contains "$hs_out" 'wlconnect=nonnull' 'fakedisplay answers wl_display_connect'
    t_contains "$hs_out" 'wlreg=nonnull' 'fakedisplay answers wl_display_get_registry'
    # Each scope switch restores the host answer for its own shim only.
    hs_off=$(SANDHOME_FAKEDRM=0 LD_PRELOAD="$(sh_shims_dir)/fakedrm.so" "$tmp/headless" 2>/dev/null)
    t_contains "$hs_off" 'dri-open=-1' 'SANDHOME_FAKEDRM=0 restores the host refusal'
else
    t_skip 'this host has dri or input devices, so the headless smoke clauses did not run'
fi
# Need-gating reads the seven facts, and every fact is now an SH_* value the
# test sets directly, so each clause asserts the rule for a NAMED shape rather
# than for whatever this host happens to be. Before issue #121 the headless facts
# were read from the filesystem inside sh_shim_need, so the test mutated DISPLAY
# and compared against `[ -e /dev/dri ]`; a host that had /dev/dri could not
# test the absent case at all.
SH_DRM=no;  t_is "$(sh_shim_need fakedrm)" 'yes' 'fakedrm is needed exactly where /dev/dri is absent'
SH_DRM=yes; t_is "$(sh_shim_need fakedrm)" 'no'  'fakedrm stands aside where /dev/dri answers'
SH_INPUT=no;  t_is "$(sh_shim_need fakeinput)" 'yes' 'fakeinput is needed exactly where input devices are absent'
SH_INPUT=yes; t_is "$(sh_shim_need fakeinput)" 'no'  'fakeinput stands aside where input devices answer'
SH_XENV=no;  t_is "$(sh_shim_need fakexenv)" 'yes' 'fakexenv is needed with no DISPLAY'
SH_XENV=yes; t_is "$(sh_shim_need fakexenv)" 'no'  'fakexenv steps aside for a set DISPLAY'
SH_DISPLAY=no;  t_is "$(sh_shim_need fakedisplay)" 'yes' 'fakedisplay is needed with no Wayland socket'
SH_DISPLAY=yes; t_is "$(sh_shim_need fakedisplay)" 'no'  'fakedisplay steps aside for a set socket'
# The detectors answer the machine the same way the variables are set here, so a
# rule that read the wrong fact would disagree with its own detector.
SH_DRM=$(sh_detect_dri); SH_INPUT=$(sh_detect_input)
SH_XENV=$(sh_detect_xenv); SH_DISPLAY=$(sh_detect_display)


t_end
