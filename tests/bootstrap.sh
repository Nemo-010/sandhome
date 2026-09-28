#!/bin/sh
# tests/bootstrap.sh - the end to end: install a toolchain into a home root that
# does NOT run binaries, prove the exec split put it where it runs, and prove the
# written environment reproduces that in a shell that never ran the bootstrap.
#
# STOP: THE HOME ROOT IS CHOSEN FOR ITS PROPERTY, NOT ITS NAME. When this host has a
# writable mount that denies exec, the test uses it so the split is exercised for
# real; when it has none, the install half still runs and the clauses that need a
# split are reported as such. Choosing /tmp and asserting a split would have
# passed for the wrong reason on this very sandbox once already.
#
# Exit 2 when there is no network or no curl/wget, because the toolchain is
# fetched and that is `could not run`, not `failed`.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"
for m in common detect space; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo 'bootstrap: no curl or wget to fetch with' >&2
    exit 2
fi
if command -v curl >/dev/null 2>&1; then
    curl -fsS -o /dev/null 'https://github.com/jqlang/jq/releases/latest' 2>/dev/null || {
        echo 'bootstrap: no network to github.com' >&2
        exit 2
    }
fi

t_begin bootstrap

work=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-e2e.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Pick a home root that cannot exec, so the split is real. /state/home and
# /workspace are the noexec mounts in the sandbox this was built for; /tmp is the
# fallback and collapses the two roots.
noexec_base=''
exec_base=''
for cand in /state/home /workspace /tmp; do
    [ -d "$cand" ] && [ -w "$cand" ] || continue
    # # NOTE: EVERY CANDIDATE IS EXAMINED, NOT JUST THE FIRST WRITABLE ONE. The loop
    # used to `break` as soon as it found a writable directory, so a machine
    # whose first candidate was exec-capable never learned about a later noexec
    # one, and the clauses that need a split were silently skipped on exactly the
    # machine that has one. It now records the first of each kind and keeps going.
    if sh_exec_probe "$cand"; then
        [ -z "$exec_base" ] && exec_base=$cand
    else
        [ -z "$noexec_base" ] && noexec_base=$cand
    fi
done
if [ -n "$noexec_base" ]; then
    home="$noexec_base/.sandhome-e2e.$$"
else
    home="$work/home"
fi
exec_root="$work/exec"

out=$(SANDHOME_HOME="$home" SANDHOME_EXEC="$exec_root" \
      sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line 2>"$work/err.txt")
status=$?
if [ "$status" != 0 ]; then
    case "$(cat "$work/err.txt")" in
        *'could not download'*|*'could not fetch'*|*'does not match'*)
            echo 'bootstrap: the fetch failed; treating this as could-not-run' >&2
            exit 2 ;;
    esac
fi
t_is "$status" 0 'bootstrap exits 0 on the minimal toolset'
t_contains "$out" 'failures=0' 'the report says no failures'
# STOP: INSTALLED OR ADOPTED, AND THE DISTINCTION IS CHECKED AGAINST THE REPORT.
# The clause used to require `installed=jq`, which holds only on a machine that
# does not already carry jq. On a machine that does, the run adopts it, says so,
# and the clause failed - a correct behaviour reported as a defect. The property
# is that jq is present afterwards and reachable from the exec root; whether that
# arrived by download or by adoption is the report's claim, and the report is
# checked against the machine below.
case "$out" in
    *'installed=jq'*|*'adopted=jq'*) t_ok 0 'the first run ends with jq present (installed or adopted)' ;;
    *) t_ok 1 'the first run ends with jq present (installed or adopted)' ;;
esac

if [ -n "$noexec_base" ]; then
    t_contains "$out" 'home_exec=no' 'a noexec home was detected as noexec'
    if sh_exec_probe "$home"; then
        t_ok 1 'the home root really refuses exec'
    else
        t_ok 0 'the home root really refuses exec'
    fi
    t_ok "$([ -x "$exec_root/bin/jq" ] || [ -L "$exec_root/bin/jq" ]; echo $?)" 'the promoted jq is on the exec root'
else
    t_skip 'this host has no writable noexec mount, so the exec split was not exercised'
fi

# NOTE: THE INSTALL PATH IS EXERCISED EVEN WHERE THE HOST ALREADY CARRIES jq.
# Every clause above runs with this machine's PATH, so on a host that already
# has jq the run ADOPTS it and no download, digest, unpack, promote or exec-view
# mirror is ever executed. The whole mechanism this tree exists for was therefore
# untested on exactly the machines most likely to already have the tools. A
# second bootstrap runs with a PATH that contains no jq and no other toolchain,
# so the probe fails, the download happens, the digest is checked, the archive is
# unpacked, the tree is mirrored and the binary is run - and the report must say
# `installed=jq` for that run and nothing else.
fresh_home=$work/fresh-home
fresh_exec=$work/fresh-exec
# NOTE: THE PATH FOR THE HERMETIC RUN HOLDS NO TOOLCHAIN. `PATH=/usr/bin:/bin`
# is not hermetic on a host that has jq in /usr/bin, which is most of them, and
# the run then adopts, and every clause below reports that it passed while
# testing nothing. A directory is built holding only the programs the bootstrap
# itself cannot do without, and `command -v jq` inside that run cannot answer.
#
# THE LIST COVERS EVERY EXTERNAL CALL AND IS CHECKED, NOT ASSUMED. A partial
# list is a list that fails for the wrong reason: with `df` missing,
# sh_free_mb answered nothing, exec_free_mb came out empty, and the whole
# hermetic clause failed for something that had nothing to do with what it was
# written to check. Each name is verified on this host, and the clause refuses
# to call itself a pass when jq is still resolvable inside the run.
herm_bin=$work/herm-bin
mkdir -p "$herm_bin"
for need in sh dash curl tar sha256sum shasum openssl python3 node wget fetch \
            uname id df cp mv rm mkdir chmod ln cat grep readlink touch find \
            env dirname basename date mktemp; do
    src=$(command -v "$need" 2>/dev/null) || continue
    ln -sfn "$src" "$herm_bin/$need" 2>/dev/null || true
done
# The two conditions the clause depends on, decided before the run rather than
# explained afterwards: the isolated PATH must have the programs the bootstrap
# needs, and it must NOT have jq.
herm_clean=yes
if PATH="$herm_bin" sh -c 'command -v jq' >/dev/null 2>&1; then
    herm_clean=no
fi
for need in sh curl tar uname id df; do
    if [ ! -x "$herm_bin/$need" ]; then
        herm_clean=no
    fi
done
# # NOTE: --no-shims, BECAUSE THIS RUN DELIBERATELY HAS NO COMPILER. The hermetic
# PATH is built from a fixed list that carries no cc and no gcc, so on a machine
# with no pty and no /etc/passwd - which is every machine this was written for -
# both shims are NEEDED, cannot be built, and the bootstrap now counts that as a
# failure and exits 1. That is the correct behaviour and it was the defect: the
# run used to end `failures=0` with two needed shims missing. But this clause is
# about the INSTALL PATH - download, digest, unpack, mirror, run - and the shim
# path is covered by tests/shims.sh against a real compiler. A test that failed
# for a reason it does not claim to check is a test that hides the failure it
# does claim to check, so the shims are turned off here explicitly and the
# clause keeps its own subject.
fresh_out=$(PATH="$herm_bin" SANDHOME_HOME="$fresh_home" SANDHOME_EXEC="$fresh_exec" \
            sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line \
            --no-shell --no-shims 2>"$work/fresh-err.txt")
fresh_status=$?
if [ "$fresh_status" != 0 ]; then
    case "$(cat "$work/fresh-err.txt" 2>/dev/null)" in
        *'could not download'*|*'could not fetch'*|*'does not match'*|*'no sha256'*|*'no curl'*)
            t_skip 'the hermetic install could not run: no network to fetch jq with'
            fresh_status=2 ;;
    esac
fi
if [ "$herm_clean" = no ]; then
    t_skip 'the hermetic PATH does not isolate this host; the hermetic install was not exercised'
    fresh_status=2
fi
if [ "$fresh_status" != 2 ]; then
    t_is "$fresh_status" 0 'a PATH with no jq on it makes the bootstrap install'
    t_contains "$fresh_out" 'installed=jq' 'the hermetic run reports installed=jq, not adopted'
    t_ok "$([ -x "$fresh_home/toolchains/jq/bin/jq" ]; echo $?)" 'the downloaded jq sits in the home root'
    t_ok "$([ -x "$fresh_exec/bin/jq" ] || [ -L "$fresh_exec/bin/jq" ]; echo $?)" \
        'the downloaded jq is promoted onto the exec root'
    # # NOTE: THE OUTPUT IS PARSED, NOT COMPARED WITH jq's OWN PRETTY-PRINTING.
    # jq has changed its default indent and colour output between releases, so a
    # byte comparison pins the test to whichever jq happens to be installed and
    # fails for a reason that has nothing to do with the thing under test. The
    # claim is "a fresh shell finds and runs the installed jq through env.sh",
    # and the proof is that its output parses to the value asked for.
    # `jq -n` AND NOT `jq`: without -n jq reads a filter from stdin, and stdin in
    # a command substitution is the harness's own terminal rather than an empty
    # file, so jq sat there waiting and the clause failed for a reason that had
    # nothing to do with the exec view.
    herm=$(env -i HOME="$work/fakehome2" PATH=/usr/bin:/bin \
           SANDHOME_HOME="$fresh_home" SANDHOME_EXEC="$fresh_exec" \
           sh -c '. "$SANDHOME_HOME/env.sh"; command -v jq; jq -nc "{ok:1}"' </dev/null 2>/dev/null)
    case "$herm" in
        *'/jq'*) t_ok 0 'a fresh shell finds jq through env.sh' ;;
        *)       t_ok 1 'a fresh shell finds jq through env.sh' ;;
    esac
    case "$herm" in
        *'{"ok":1}'*) t_ok 0 'the promoted jq runs and its output is clean (no ANSI)' ;;
        *)             t_ok 1 'the promoted jq runs and its output is clean (no ANSI)' ;;
    esac
    # And the second hermetic run must adopt rather than download again.
    again=$(PATH="$herm_bin" SANDHOME_HOME="$fresh_home" SANDHOME_EXEC="$fresh_exec" \
            sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line \
            --no-shell 2>/dev/null)
    t_contains "$again" 'adopted=jq' 'the second hermetic run adopts what the first installed'
    case "$again" in
        *'installed=jq'*) t_ok 1 'the second hermetic run does not download again' ;;
        *)                t_ok 0 'the second hermetic run does not download again' ;;
    esac
fi

# A fresh shell that reads only env.sh must find and run jq.
probe=$(env -i HOME="$work/fakehome" PATH=/usr/bin:/bin \
        SANDHOME_HOME="$home" SANDHOME_EXEC="$exec_root" \
        sh -c '. "$SANDHOME_HOME/env.sh"; command -v jq >/dev/null 2>&1 && jq --version' 2>/dev/null)
case "$probe" in
    jq-*) t_ok 0 "a fresh shell runs jq through env.sh ($probe)" ;;
    *)    t_ok 1 "a fresh shell runs jq through env.sh (got '$probe')" ;;
esac

# The second run must ADOPT what the first installed, not download it again.
out2=$(SANDHOME_HOME="$home" SANDHOME_EXEC="$exec_root" \
       sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line 2>/dev/null)
t_contains "$out2" 'adopted=jq' 'the second run adopts the first run install'
case "$out2" in
    *'installed=jq'*) t_ok 1 'the second run does not reinstall jq' ;;
    *)                t_ok 0 'the second run does not reinstall jq' ;;
esac

# A dry run installs nothing and must not claim a built shim: the report is read
# from the machine, and one line saying otherwise is the claim this tree refuses.
dryhome="$work/dry-home"
dryout=$(SANDHOME_HOME="$dryhome" SANDHOME_EXEC="$work/dry-exec" \
         sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --dry-run 2>/dev/null)
t_contains "$dryout" 'shims=' 'a dry run reports no built shims'
case "$dryout" in
    *'shims=fakepty'*|*'shims=fakepwd'*) t_ok 1 'a dry run names no built shim' ;;
    *)                                  t_ok 0 'a dry run names no built shim' ;;
esac
t_ok "$([ ! -e "$dryhome/shims/fakepty.so" ]; echo $?)" 'a dry run writes no shim object'
t_ok "$([ ! -d "$dryhome/toolchains/jq" ]; echo $?)" 'a dry run downloads no toolchain'
SANDHOME_REPO="$ROOT" SANDHOME_HOME="$dryhome" SANDHOME_EXEC="$work/dry-exec" \
    sh "$ROOT/bin/sandhome" doctor >/dev/null 2>&1
if [ $? -eq 0 ]; then
    t_ok 1 'doctor exits non-zero on a home that is not set up'
else
    t_ok 0 'doctor exits non-zero on a home that is not set up'
fi

# NOTE: A SET-UP HOME PASSES DOCTOR AND A BROKEN ONE NAMES WHAT IS BROKEN. The
# doctor used to check a shim only when the machine looked like it did not need
# one, so a machine where the shim was needed and the build failed produced a
# clean report - the exact claim this tree exists to refuse. It also exited with
# the COUNT of failures, which is one byte: 130 broken invariants answered 5.
doc_home=$work/doc-home
doc_exec=$work/doc-exec
SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-shell \
    >/dev/null 2>"$work/doc-err.txt"
if [ -r "$doc_home/env.sh" ]; then
    doc_out=$(SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
              sh "$ROOT/bin/sandhome" doctor 2>/dev/null)
    doc_rc_line=$(printf '%s\n' "$doc_out" | tail -n 1)
    t_is "$doc_rc_line" 'doctor_failures=0' 'doctor reports no failures on a home that was just built'
    # # NOTE: AND IT EXITS 0/1, NEVER THE COUNT.
    SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
        sh "$ROOT/bin/sandhome" doctor >/dev/null 2>&1
    t_is "$?" 0 'doctor exits 0 on a sound home'
    # Break one invariant and it must name it and fail.
    rm -f "$doc_home/env.sh"
    broken=$(SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
             sh "$ROOT/bin/sandhome" doctor 2>/dev/null)
    t_contains "$broken" 'FAIL env_file' 'doctor names the invariant that broke'
    SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
        sh "$ROOT/bin/sandhome" doctor >/dev/null 2>&1
    t_is "$?" 1 'doctor exits 1 on a broken home'
else
    t_skip 'the home for the doctor clauses could not be built (no network)'
fi

# NOTE: A SHELL THAT READ ONLY env.sh CAN RUN `sandhome`. The command lives in
# the checkout, which is frequently on a root refusing execve, so it is COPIED to
# the exec root. A PATH entry pointing at the checkout gives a command that
# answers `command -v` and then fails: measured, `sh: sandhome: Permission
# denied`. The clause runs the installed copy from a bare environment.
cmd_home=$work/cmd-home
cmd_exec=$work/cmd-exec
SANDHOME_HOME="$cmd_home" SANDHOME_EXEC="$cmd_exec" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-shell \
    >/dev/null 2>/dev/null
if [ -r "$cmd_home/env.sh" ]; then
    byname=$(env -i HOME="$work/fakehome3" PATH=/usr/bin:/bin \
             SANDHOME_HOME="$cmd_home" SANDHOME_EXEC="$cmd_exec" \
             sh -c '. "$SANDHOME_HOME/env.sh"; command -v sandhome; sandhome version' \
             </dev/null 2>/dev/null)
    case "$byname" in
        *"$cmd_exec"*) t_ok 0 'the installed sandhome is found on the exec root, not the checkout' ;;
        *) t_ok 1 "the installed sandhome is found on the exec root, not the checkout (got $byname)" ;;
    esac
    t_contains "$byname" 'sandhome/1' 'a bare env.sh shell can run sandhome by name'
else
    t_skip 'no home to check the installed command against'
fi

# NOTE: --require-shims WITH --no-shims IS REFUSED, NOT FAILED LATER. The require
# check used to run under a build that --no-shims had suppressed, so the pair
# read a file that was deliberately absent and complained about a shim the
# caller had just said not to build.
contradict=$(SANDHOME_HOME="$work/contra" SANDHOME_EXEC="$work/contra-x" \
             sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line \
             --no-shell --no-shims --require-shims 2>&1)
contra_rc=$?
if [ "$contra_rc" = 2 ]; then
    t_contains "$contradict" 'contradictory' 'the contradictory shim flags are named in the refusal'
    t_ok 0 'the contradictory shim flags exit 2'
else
    t_ok 1 "the contradictory shim flags are refused (got rc=$contra_rc)"
fi

# NOTE: --with REPEATS. `--with rust --with go` is what a caller who reads
# "add a toolchain" types; it used to keep only the last one.
repeat=$(SANDHOME_HOME="$work/rep" SANDHOME_EXEC="$work/rep-x" \
         sh "$ROOT/bootstrap.sh" --toolset minimal --with jq --with ripgrep \
         --no-profile --no-path-line --no-shell --dry-run 2>&1)
t_contains "$repeat" 'ripgrep' 'a repeated --with is not lost'

# NOTE: AN UNKNOWN TOOLCHAIN IS REFUSED BEFORE ANY DOWNLOAD, AND EXITS NON-ZERO.
# `sandhome install nosuchtool` printed the message and exited 0, so a script
# could not tell a typo from a success.
unknown_out=$(SANDHOME_HOME="$work/unk" SANDHOME_EXEC="$work/unk-x" \
             sh "$ROOT/bin/sandhome" install nosuchtool 2>&1)
unknown_rc=$?
t_contains "$unknown_out" 'unknown toolchain nosuchtool' 'an unknown toolchain is named'
t_is "$unknown_rc" 1 'an unknown toolchain exits non-zero'

rm -rf "$home" 2>/dev/null
t_end
