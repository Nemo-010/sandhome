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

# A host whose only jq is this project's own global hook (a symlink to
# .sandhome-dispatch) must not be adopted by the main end-to-end run below. The
# dispatcher is a wrapper script, and adopting it correctly leaves it on PATH
# rather than linking it into the isolated exec view, so the split clauses could
# not run. The hook is the project's artifact, not a toolchain carrier, so force
# a real install when it is all the host has; a real jq is still adopted as
# before. Only this run is forced: the hermetic runs use a PATH with no jq at
# all, and their "second run adopts" clauses must still see an adoption.
force_jq=''
case "$(readlink "$(command -v jq 2>/dev/null)" 2>/dev/null)" in
    *'.sandhome-dispatch') force_jq=jq ;;
esac

t_begin bootstrap

work=$(t_exec_tmpdir sandhome-e2e)
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

out=$(SANDHOME_HOME="$home" SANDHOME_EXEC="$exec_root" SANDHOME_FORCE="$force_jq" \
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
            env dirname basename date mktemp sleep; do
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
         sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --dry-run 2>&1)
t_contains "$dryout" 'feas jq need_mb=' 'a dry run prices each requested toolchain (#75)'
t_contains "$dryout" 'total_exec_need_mb=' 'a dry run totals the request against the ceiling (#75)'
t_contains "$dryout" 'shims=' 'a dry run reports no built shims'
case "$dryout" in
    *'shims=fakepty'*|*'shims=fakepwd'*|*'shims=antiptrace'*) t_ok 1 'a dry run names no built shim' ;;
    *)                                  t_ok 0 'a dry run names no built shim' ;;
esac
t_ok "$([ ! -e "$dryhome/shims/fakepty.so" ]; echo $?)" 'a dry run writes no shim object'
t_ok "$([ ! -d "$dryhome/toolchains/jq" ]; echo $?)" 'a dry run downloads no toolchain'
# A ONE-PASTE SETUP READS THE PROJECT IT IS RUN FROM (issue #116). A rust
# checkout asked for `--toolset developer` used to get no rust, and the first
# `cargo build` paid an `sandhome install rust` round-trip. The marker folds
# the toolchain in, and --no-detect takes it back out.
proj="$work/project"
mkdir -p "$proj" 2>/dev/null
printf '[package]\nname = "x"\n' > "$proj/Cargo.toml"
printf 'module x\n' > "$proj/go.mod"
detout=$(cd "$proj" && SANDHOME_HOME="$work/det-home" SANDHOME_EXEC="$work/det-exec" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --dry-run 2>&1)
t_contains "$detout" 'detected a project marker for rust' 'a rust marker folds rust into the request (#116)'
t_contains "$detout" 'detected a project marker for go' 'a go marker folds go into the request (#116)'
# A CMake or meson project folds in the BUILD SYSTEM itself, not only its
# compiler and linker: `cmake -S . -B build` failed with `command not found`
# on a CMakeLists project before the catalog shipped cmake (issue #123).
cmproj="$work/cmproject"
mkdir -p "$cmproj" 2>/dev/null
printf 'cmake_minimum_required(VERSION 3.10)\nproject(x C)\n' > "$cmproj/CMakeLists.txt"
cmout=$(cd "$cmproj" && SANDHOME_HOME="$work/cm-home" SANDHOME_EXEC="$work/cm-exec" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-skills --dry-run 2>&1)
t_contains "$cmout" 'detected a project marker for cmake' 'a CMakeLists folds cmake in (#123)'
t_contains "$cmout" 'detected a project marker for clang' 'a CMakeLists still folds clang in (#116)'
mesproj="$work/mesproject"
mkdir -p "$mesproj" 2>/dev/null
printf "project('x', 'c')\n" > "$mesproj/meson.build"
mesout=$(cd "$mesproj" && SANDHOME_HOME="$work/mes-home" SANDHOME_EXEC="$work/mes-exec" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-skills --dry-run 2>&1)
t_contains "$mesout" 'detected a project marker for meson' 'a meson.build folds meson in (#123)'
# The project toolset names the whole from-source C/C++ chain in one command.
# Read through the real command, not the function: sh_toolset_names lives inside
# bootstrap.sh, which this test does not source.
projout=$(SANDHOME_HOME="$work/proj-home" SANDHOME_EXEC="$work/proj-exec" \
    sh "$ROOT/bootstrap.sh" --toolset project --no-profile --no-path-line --no-skills --dry-run 2>&1)
t_contains "$projout" 'cmake' 'the project toolset names cmake (#123)'
t_contains "$projout" 'meson' 'the project toolset names meson (#123)'
t_contains "$projout" 'clang' 'the project toolset names clang (#123)'
detout_off=$(cd "$proj" && SANDHOME_HOME="$work/det-home2" SANDHOME_EXEC="$work/det-exec2" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-detect --dry-run 2>&1)
case "$detout_off" in
    *'detected a project marker'*) t_ok 1 '--no-detect turns the project scan off (#116)' ;;
    *) t_ok 0 '--no-detect turns the project scan off (#116)' ;;
esac
# MONOREPO SUBDIRS AND MAKEFILES FOLD IN TOO. Top-level-only missed
# frontend/package.json and backend/Cargo.toml entirely, and a Makefile
# named no toolchain at all. One subdir level plus the make signal must
# appear without a second install round-trip.
mono="$work/mono"
mkdir -p "$mono/frontend" "$mono/backend" 2>/dev/null
printf '{"name":"f"}' > "$mono/frontend/package.json"
printf '[package]\nname = "b"\n' > "$mono/backend/Cargo.toml"
printf 'all:\n\tcc -o x x.c\n' > "$mono/Makefile"
monoout=$(cd "$mono" && SANDHOME_HOME="$work/mono-home" SANDHOME_EXEC="$work/mono-exec" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-skills --dry-run 2>&1)
t_contains "$monoout" 'detected a project marker for node' 'a subdir node marker folds node in (#116)'
t_contains "$monoout" 'detected a project marker for rust' 'a subdir rust marker folds rust in (#116)'
t_contains "$monoout" 'detected a project marker for clang' 'a Makefile folds clang in (#116)'
# The skills ride the same flag discipline: installed by default, suppressed
# by --no-skills, and only announced on a dry run (issue #89).
t_contains "$dryout" 'would install the skills' 'a dry run announces the skills install'
skillsout=$(SANDHOME_HOME="$dryhome" SANDHOME_EXEC="$work/dry-exec" \
         sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-skills --dry-run 2>&1)
case "$skillsout" in
    *'would install the skills'*) t_ok 1 '--no-skills suppresses the skills install' ;;
    *)                            t_ok 0 '--no-skills suppresses the skills install' ;;
esac
# A dry run persists no durable library either (issue #70): sh_repo_persist
# was the one write step with no dry-run branch, so a preview from a pipe
# (SH_REPO_DIR under a scratch dir) left 39 files in a fresh home. Driven
# directly: a scratch repo dir plus a fresh home, with and without the flag.
cat > "$work/persist-driver.sh" <<'DRIVER'
for m in common detect space fetch env toolchain shim memexec report; do
    . "$1/lib/$m.sh"
done
SH_REPO_DIR=$2; SH_HOME=$3; SH_DRY_RUN=$4; SH_SELF=test
SH_HOME_TMP=$3/tmp
sh_repo_persist
DRIVER
mkdir -p "$work/scratch/lib" "$work/scratch/tools"
: > "$work/scratch/lib/common.sh"
# The repo dir must read as a scratch fetch dir (under TMPDIR), which is the
# only shape that persists; a clone path takes no branch either way. $work may
# itself be on an exec-capable volume outside TMPDIR (t_exec_tmpdir prefers
# /workspace), so the scratch tree is made under TMPDIR explicitly, not under
# $work, or the dry-run branch never triggers and the clause fails against
# correct code.
scratch_base=${TMPDIR:-/tmp}/sandhome-scratch-$$
rm -rf "$scratch_base"
mkdir -p "$scratch_base/lib" "$scratch_base/tools"
: > "$scratch_base/lib/common.sh"
sh "$work/persist-driver.sh" "$ROOT" "$scratch_base" "$work/phome" 1 > "$work/persist.out" 2>&1
t_contains "$(cat "$work/persist.out" 2>/dev/null)" 'would install the durable library' \
    'a dry run names the durable library as would-install'
t_ok "$([ ! -e "$work/phome/repo" ]; echo $?)" 'a dry run writes no durable library (#70)'
rm -rf "$scratch_base" 2>/dev/null
sh "$work/persist-driver.sh" "$ROOT" "$ROOT" "$work/phome2" 0 >/dev/null 2>&1
t_ok "$([ ! -e "$work/phome2/repo" ]; echo $?)" 'a clone checkout persists nothing (nothing to persist)'
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
SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" SANDHOME_FORCE="$force_jq" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line --no-shell \
    >/dev/null 2>"$work/doc-err.txt"
if [ -r "$doc_home/env.sh" ]; then
    # STOP: THE SPACE THRESHOLDS ARE PINNED, BECAUSE THE EXEC ROOT IS NOT.
    # $work lives under /tmp, so these clauses measured how much room was
    # free in /tmp when the suite ran: on a small or busy /tmp doctor
    # truthfully reported exec_space=low and the suite failed a sound home
    # for a host fact, not a tree fact (issue #108). Zeroing the low/critical
    # floors makes room unjudgeable here -- only a literally full root still
    # fails -- so the clauses assert what the tree built, deterministically.
    doc_out=$(SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
              SANDHOME_LOW_EXEC_MB=0 SANDHOME_CRIT_MB=0 \
              sh "$ROOT/bin/sandhome" doctor 2>/dev/null)
    doc_rc_line=$(printf '%s\n' "$doc_out" | tail -n 1)
    t_is "$doc_rc_line" 'doctor_failures=0' 'doctor reports no failures on a home that was just built'
    # # NOTE: AND IT EXITS 0/1, NEVER THE COUNT.
    SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
        SANDHOME_LOW_EXEC_MB=0 SANDHOME_CRIT_MB=0 \
        sh "$ROOT/bin/sandhome" doctor >/dev/null 2>&1
    t_is "$?" 0 'doctor exits 0 on a sound home'
    # THE INSTALLED COPY CARRIES ITS LIBRARY (issue #88). A process with no
    # inherited environment starts from the exec copy alone; the exact
    # invocation from the issue must gate rather than fail to start. Greenness
    # itself is ambient (/tmp room is a host fact, issue #108), so what is
    # asserted is the gate shape: exit 0/1 with a failures count, never the
    # exit-2 cannot-find-the-library of the old behavior.
    t_ok "$([ "$(grep -c '^SH_BAKED_REPO_DIR=.' "$doc_exec/bin/sandhome" 2>/dev/null)" = 1 ]; echo $?)" \
        'the installed copy bakes exactly one repo path'
    doc_noenv_out=$(env -i "$doc_exec/bin/sandhome" doctor 2>/dev/null)
    doc_noenv_rc=$?
    doc_noenv_tail=$(printf '%s\n' "$doc_noenv_out" | tail -n 1)
    case "$doc_noenv_rc" in
        0|1)
            case "$doc_noenv_tail" in
                doctor_failures=*) t_ok 0 'env -i <exec-bin>/sandhome doctor gates (exit 0/1 with a count)' ;;
                *) t_ok 1 "env -i <exec-bin>/sandhome doctor gates (got tail: $doc_noenv_tail)" ;;
            esac ;;
        *) t_ok 1 "env -i <exec-bin>/sandhome doctor gates (got rc=$doc_noenv_rc)" ;;
    esac
    env -i "$doc_exec/bin/sandhome" exec jq --version >/dev/null 2>&1
    t_is "$?" 0 'env -i <exec-bin>/sandhome exec runs a tool with the right environment'
    # RESUME REHYDRATES WITHOUT FETCHING (issue #88). Wipe the exec copy and
    # the views the way a tmpfs restart does, then resume must rebuild and
    # gate green with no network beyond what repair needs (nothing here).
    rm -rf "$doc_exec/bin" "$doc_exec/views"
    SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
        SANDHOME_LOW_EXEC_MB=0 SANDHOME_CRIT_MB=0 \
        sh "$ROOT/bin/sandhome" resume >/dev/null 2>&1
    t_is "$?" 0 'resume rebuilds a wiped exec root and gates green'
    SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
        SANDHOME_LOW_EXEC_MB=0 SANDHOME_CRIT_MB=0 \
        sh "$ROOT/bin/sandhome" doctor >/dev/null 2>&1
    t_is "$?" 0 'doctor is green after resume'
    # STATUS IS THE ONE-LINE GATE (issue #88), prose and JSON, with the exit
    # code of doctor in both forms.
    doc_status=$(SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
        SANDHOME_LOW_EXEC_MB=0 SANDHOME_CRIT_MB=0 \
        sh "$ROOT/bin/sandhome" status 2>/dev/null)
    case "$doc_status" in
        'ready=yes home='*' exec='*' toolchains='*) t_ok 0 'status prints one readiness line' ;;
        *) t_ok 1 "status prints one readiness line (got: $doc_status)" ;;
    esac
    doc_sjson=$(SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
        SANDHOME_LOW_EXEC_MB=0 SANDHOME_CRIT_MB=0 \
        sh "$ROOT/bin/sandhome" status --json 2>/dev/null)
    case "$doc_sjson" in
        *'"ready":"yes"'*'"build_root"'*'"next_action"'*) t_ok 0 'status --json carries readiness plus workdir/build fields' ;;
        *) t_ok 1 "status --json carries readiness plus workdir/build fields (got: $doc_sjson)" ;;
    esac
    if command -v python3 >/dev/null 2>&1; then
        if printf '%s' "$doc_sjson" | python3 -m json.tool >/dev/null 2>&1; then
            t_ok 0 'status --json parses'
        else
            t_ok 1 "status --json parses (got: $doc_sjson)"
        fi
        doc_djson=$(SANDHOME_REPO_DIR="$ROOT" SANDHOME_HOME="$doc_home" SANDHOME_EXEC="$doc_exec" \
            SANDHOME_LOW_EXEC_MB=0 SANDHOME_CRIT_MB=0 \
            sh "$ROOT/bin/sandhome" doctor --json 2>/dev/null)
        if printf '%s' "$doc_djson" | python3 -m json.tool >/dev/null 2>&1; then
            t_ok 0 'doctor --json parses'
        else
            t_ok 1 "doctor --json parses (got: $doc_djson)"
        fi
        case "$doc_djson" in
            *'"failures":0'*) t_ok 0 'doctor --json reports zero failures on a sound home' ;;
            *) t_ok 1 "doctor --json reports zero failures on a sound home (got: $doc_djson)" ;;
        esac
    else
        t_skip 'no python3 to parse the status/doctor JSON with'
    fi
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
cmd_fake_home=$work/cmd-fake-home
cmd_home=$cmd_fake_home/.local/share/sandhome
cmd_exec=$work/cmd-exec
mkdir -p "$cmd_fake_home"
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

    # # THE ENTRY POINT IS THE PATH-FREE WAY IN (issue #122). The clauses above
    # still need SANDHOME_HOME (or PATH) handed to them; the bootstrap also
    # leaves a SOURCEABLE snippet beside the home, so a shell that inherited
    # nothing finds the command and the toolchains from the home alone. It is
    # sourced and not executed because the home is often noexec: a copy there
    # cannot run at all. The clause runs it in a bare environment with only the
    # documented home path available.
    if [ -r "$cmd_home/entry.sh" ]; then
        t_ok 0 'the bootstrap leaves an entry point beside the home'
        entryout=$(env -i HOME="$cmd_fake_home" PATH=/usr/bin:/bin \
                   sh -c '. "${XDG_DATA_HOME:-$HOME/.local/share}/sandhome/entry.sh"; sandhome version; printf "|%s" "$SANDHOME_EXEC"' \
                   </dev/null 2>&1)
        t_contains "$entryout" 'sandhome/1' 'a shell with no PATH runs sandhome through the entry point'
        t_contains "$entryout" "|$cmd_exec" 'the entry point exports the exec root it baked'
    else
        t_ok 1 'the bootstrap leaves an entry point beside the home'
    fi

    # # STOP: `eval "$(sandhome env)"` WORKS IN A SHELL THAT SOURCED NOTHING.
    # ROUTE.md step 4 offers the eval form for a shell where sourcing is not
    # possible, and it is the form a tool harness uses: no .profile, no .bashrc,
    # no variables set. The copy PATH names lives on the exec root, where "the
    # parent of $0" is the exec root and there is no lib/ under it, so with no
    # SANDHOME_REPO_DIR in the environment the command could not find its own
    # library and printed
    #   sandhome: no library under /tmp; set SANDHOME_REPO
    # naming a variable that is documented as the owner/name slug to fetch from
    # a pipe, not a path, so following the error could not work either. The eval
    # was therefore impossible exactly where the docs recommend it.
    #
    # Both roots are discoverable without being told: the copy is on the exec
    # root, and the home is where the env file that would have said so lives.
    bare=$(env -i HOME="$cmd_fake_home" PATH="$cmd_exec/bin:/usr/bin:/bin" \
           sh -c 'eval "$(sandhome env)"; printf "%s|%s" "$SANDHOME_EXEC" "$SANDHOME_REPO_DIR"' \
           </dev/null 2>&1)
    case "$bare" in
        "$cmd_exec"*) t_ok 0 'a shell that sourced nothing can eval sandhome env' ;;
        *) t_ok 1 "a shell that sourced nothing can eval sandhome env (got $bare)" ;;
    esac
    case "$bare" in
        *"|$ROOT") t_ok 0 'the eval form finds the checkout and reports it' ;;
        *) t_ok 1 "the eval form finds the checkout and reports it (got $bare)" ;;
    esac

    # The installed copy carries its library with it (issue #88), so a bare
    # environment with an impossible HOME still runs: the baked path
    # resolves, and version answers instead of the old missing-library
    # error. The error path itself is still covered below with an unbaked
    # copy, where no source resolves and the message must name the variable.
    nomsg=$(env -i HOME=/nonexistent-home-xyz PATH="$cmd_exec/bin:/usr/bin:/bin" \
            sh -c 'sandhome version' </dev/null 2>&1)
    case "$nomsg" in
        'sandhome/1') t_ok 0 'a baked copy runs with no HOME and no environment' ;;
        *) t_ok 1 "a baked copy runs with no HOME and no environment (got $nomsg)" ;;
    esac
    # Unbaked: the checkout binary copied where no repo, home, or baked path
    # resolves. Then the error must name the variable that resolves one.
    mkdir -p "$work/norepo" 2>/dev/null
    cp "$ROOT/bin/sandhome" "$work/norepo/sandhome" 2>/dev/null
    chmod 0755 "$work/norepo/sandhome" 2>/dev/null || true
    nobaked=$(env -i HOME=/nonexistent-home-xyz PATH="$work/norepo:/usr/bin:/bin" \
            sh -c 'sandhome version' </dev/null 2>&1)
    case "$nobaked" in
        *SANDHOME_REPO_DIR*) t_ok 0 'the missing-library error names SANDHOME_REPO_DIR' ;;
        *) t_ok 1 "the missing-library error names SANDHOME_REPO_DIR (got $nobaked)" ;;
    esac
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

# NOTE: THE DOCUMENTED INVOCATION SETS NOTHING BY HAND (issues #18/#26, class A).
# All nine invocations above pre-set SANDHOME_HOME/SANDHOME_EXEC, so the suite
# was structurally unable to catch the documented ROUTE.md path aborting with
# "SANDHOME_HOME: parameter not set" under `set -u`. This runs it the way the
# router documents it: a fresh non-login shell with the names absent.
# Trigger 1 (pre-install load with a leftover fragment) and trigger 2 (the
# adopt path writing the first fragment) are the same binding, tested twice.
doc_home_base=$work/doc-names-absent
doc_fake_home=$doc_home_base/home
mkdir -p "$doc_fake_home"
# Virgin run with the names absent must exit 0 and write env.sh.
doc_out=$(env -i PATH=/usr/bin:/bin HOME="$doc_fake_home" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line \
    --no-shell --no-shims 2>&1)
doc_rc=$?
t_is "$doc_rc" 0 'the documented invocation with the names absent exits 0'
doc_default_home="$doc_fake_home/.local/share/sandhome"
if [ -r "$doc_default_home/env.sh" ]; then
    t_ok 0 'the documented invocation writes env.sh at the default home'
else
    t_ok 1 'the documented invocation writes env.sh at the default home'
fi
# A leftover fragment in the old shape (bare `$SANDHOME_HOME`) must not abort
# the next run with the names absent: the binding and the defensive load own
# this, not the fragment that happens to be on disk.
mkdir -p "$doc_default_home/env.d"
cat > "$doc_default_home/env.d/node.sh" <<'FRAG'
NPM_CONFIG_PREFIX="$SANDHOME_HOME/npm-global"
export NPM_CONFIG_PREFIX
FRAG
doc_out2=$(env -i PATH=/usr/bin:/bin HOME="$doc_fake_home" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-profile --no-path-line \
    --no-shell --no-shims 2>&1)
t_is "$?" 0 'a re-run with a leftover fragment and the names absent exits 0'
case "$doc_out2" in
    *'parameter not set'*) t_ok 1 'the re-run shows no set -u abort' ;;
    *) t_ok 0 'the re-run shows no set -u abort' ;;
esac

rm -rf "$home" 2>/dev/null
# # STOP: RE-BOOTSTRAPPING WITH A DIFFERENT EXEC ROOT REPLACES THE PATH BLOCK
# INSTEAD OF ADDING A SECOND ONE. sh_append_once de-duplicates an IDENTICAL
# line, and a different exec root is a different line, so moving the root left
# every previous block in place:
#   # Added by bootstrap.
#   export PATH="/dev/shm/bin:$PATH"
#   # Added by bootstrap.
#   if [ -r '...profile.sh' ]; then . '...profile.sh'; fi
#   # Added by bootstrap.
#   export PATH="/tmp/bin:$PATH"
# Three blocks, of which the first points at an exec root nothing maintains any
# more, and the superseded root keeps a full bin/ and views/ that nothing names
# or removes (issue #41). The line a consumer reads first is the one that is
# wrong, because PATH is prepended and the stale root wins.
mv_home=$work/movehome
mv_fake_home=$work/move-fake-home
mv_exec_a=$work/move-exec-a
mv_exec_b=$work/move-exec-b
rm -rf "$mv_home" "$mv_fake_home" "$mv_exec_a" "$mv_exec_b"
mkdir -p "$mv_fake_home"
HOME="$mv_fake_home" SANDHOME_HOME="$mv_home" SANDHOME_EXEC="$mv_exec_a" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-shims >/dev/null 2>/dev/null
HOME="$mv_fake_home" SANDHOME_HOME="$mv_home" SANDHOME_EXEC="$mv_exec_b" \
    sh "$ROOT/bootstrap.sh" --toolset minimal --no-shims >/dev/null 2>/dev/null
if [ -r "$mv_fake_home/.profile" ]; then
    n=$(grep -c 'Added by bootstrap' "$mv_fake_home/.profile" 2>/dev/null || printf 0)
    # One block for the exec root, one for the profile fragment. Anything more
    # means a superseded root is still on PATH.
    if [ "$n" -le 2 ]; then
        t_ok 0 'a re-bootstrap with a new exec root does not stack PATH blocks'
    else
        t_ok 1 "a re-bootstrap with a new exec root does not stack PATH blocks ($n blocks)"
    fi
    if grep -q "$mv_exec_a" "$mv_fake_home/.profile" 2>/dev/null; then
        t_ok 1 'the superseded exec root is gone from .profile'
    else
        t_ok 0 'the superseded exec root is gone from .profile'
    fi
    if grep -q "$mv_exec_b" "$mv_fake_home/.profile" 2>/dev/null; then
        t_ok 0 'the current exec root is on .profile'
    else
        t_ok 1 'the current exec root is on .profile'
    fi
    # A login shell must end up with the CURRENT root first, not the stale one.
    login_path=$(HOME="$mv_fake_home" sh -c '. "$HOME/.profile" 2>/dev/null; printf "%s" "$PATH"' 2>/dev/null)
    # Compared with a prefix test rather than a case pattern: a quoted variable
    # inside a case PATTERN is a literal, not an expansion, so a pattern written
    # this way silently never matches and the clause fails against correct code.
    login_first=${login_path%%:*}
    if [ "$login_first" = "$mv_exec_b/bin" ]; then
        t_ok 0 'a login shell resolves the current exec root first'
    else
        t_ok 1 "a login shell resolves the current exec root first (got $login_first)"
    fi
else
    t_skip 'no .profile to check the exec-root move against'
fi

# # STOP: A SHELL WITH NO HOME GETS A MESSAGE, NOT A SHELL ERROR. This file runs
# under `set -u`, and the candidate list for the library used a bare `$HOME`, so
# the preamble ended the process before it could say anything:
#
#   $ env -i PATH=/exec/bin:/usr/bin:/bin sandhome doctor
#   /exec/bin/sandhome: 44: HOME: parameter not set      (exit 126)
#
# Every command failed that way - version, doctor, space, path, env, report,
# toolchains - because the preamble runs before anything else. It is the worst
# failure for the case #40 exists to serve: a tool harness that sets no HOME,
# running the command the router names, getting an error that mentions neither
# sandhome, nor the library, nor what to set.
#
# The clauses run the real binary in a real `env -i` with no HOME. A control
# matters as much: the same shell with SANDHOME_HOME set must still WORK, or
# the fix is "refuse everything", and a refusal is not the same as a repair.
nh_bin=$work/nohome-bin
mkdir -p "$nh_bin"
cp "$ROOT/bin/sandhome" "$nh_bin/sandhome"
nh_out=$(env -i PATH="$nh_bin:$ROOT/bin:/usr/bin:/bin" sh "$nh_bin/sandhome" version 2>&1)
nh_rc=$?
case "$nh_out" in
    # The shell's own wording is "parameter not set", and a backtick-prefixed
    # path is how dash and bash both report it. A message of OURS is allowed to
    # contain the word HOME - it has to, to name the lever - so matching on that
    # word proves nothing and the first version of this clause failed against
    # correct output.
    *"parameter not set"*|*': not found'*) t_ok 1 "no HOME produces a shell error, not a message (got $nh_out)" ;;
    *"sandhome"*) t_ok 0 'a shell with no HOME gets a message naming sandhome' ;;
    *) t_ok 1 "a shell with no HOME gets a message naming sandhome (got $nh_out)" ;;
esac
if [ "$nh_rc" -eq 126 ]; then
    t_ok 1 'a shell with no HOME does not die with 126'
else
    t_ok 0 'a shell with no HOME does not die with 126'
fi
# The message must say what to do, and this is the case where a harness has
# nothing to go on: the shell is bare, so the only lever is an exported
# variable.
case "$nh_out" in
    *SANDHOME_REPO_DIR*|*HOME*) t_ok 0 'the no-HOME message names the lever' ;;
    *) t_ok 1 "the no-HOME message names the lever (got $nh_out)" ;;
esac
# The control: with SANDHOME_HOME and no HOME, the command must work.
nh_ok=$(env -i SANDHOME_HOME="$work" SANDHOME_REPO_DIR="$ROOT" \
        PATH="$nh_bin:/usr/bin:/bin" sh "$nh_bin/sandhome" version 2>&1)
case "$nh_ok" in
    *sandhome/1*) t_ok 0 'the command still works with SANDHOME_HOME and no HOME' ;;
    *) t_ok 1 "the command still works with SANDHOME_HOME and no HOME (got $nh_ok)" ;;
esac

# EVERY COMMAND THAT PARSES FLAGS REFUSES AN UNKNOWN ONE WITH RC=2 (issue
# #125). toolchains, shims and report silently accepted `--bogus` with rc=0;
# the fix names the accepted flags and refuses the rest, and this loop keeps
# the set from drifting: a new command that parses flags and forgets the
# refusal fails here rather than silently ignoring a script's typo.
if [ -n "${cmd_home:-}" ] && [ -r "$cmd_home/env.sh" ] && [ -n "${cmd_exec:-}" ]; then
    flag_fail=''
    for flag_cmd in "toolchains" "shims" "report" "space" "install" "doctor" "status" "repair" "resume" "gc" "prune" "add" "project" "exec"; do
        flag_out=$(SANDHOME_HOME="$cmd_home" SANDHOME_EXEC="$cmd_exec" SANDHOME_REPO_DIR="$ROOT" \
            sh "$ROOT/bin/sandhome" "$flag_cmd" --definitely-not-a-flag 2>&1)
        flag_rc=$?
        # gc takes DAYS as a bare word but still refuses dash flags; exec takes
        # --shell as its only flag; the rest take --help/--json or nothing.
        if [ "$flag_rc" = 2 ]; then
            :
        else
            flag_fail="$flag_fail $flag_cmd:$flag_rc"
        fi
    done
    t_is "$flag_fail" '' 'every flag-parsing command refuses an unknown flag with rc=2'
    # exec --shell names the string form explicitly, and a single non-program
    # argument already runs through the shell; both must work with the env loaded.
    shell_out=$(SANDHOME_HOME="$cmd_home" SANDHOME_EXEC="$cmd_exec" SANDHOME_REPO_DIR="$ROOT" \
        sh "$ROOT/bin/sandhome" exec --shell 'echo shell-ok' 2>&1)
    t_contains "$shell_out" 'shell-ok' 'exec --shell runs the string through the shell'
    single_out=$(SANDHOME_HOME="$cmd_home" SANDHOME_EXEC="$cmd_exec" SANDHOME_REPO_DIR="$ROOT" \
        sh "$ROOT/bin/sandhome" exec 'echo single-ok' 2>&1)
    t_contains "$single_out" 'single-ok' 'a single non-program argument runs through the shell'
    # The report names the invoking shell, whether the exec bin is on PATH now,
    # and the entry path, so a harness that spawns a non-login shell per call
    # sees what it needs without discovering the asymmetry itself (issue #122).
    rep_out=$(SANDHOME_HOME="$cmd_home" SANDHOME_EXEC="$cmd_exec" SANDHOME_REPO_DIR="$ROOT" \
        sh "$ROOT/bin/sandhome" report 2>&1)
    t_contains "$rep_out" 'login_shell=' 'the report names whether this shell is a login shell'
    t_contains "$rep_out" 'env_on_path=' 'the report names whether the exec bin is on PATH'
    t_contains "$rep_out" 'entry=' 'the report names the entry point'
    # The entry point tries three roots, not one baked path: a snippet read
    # before `resume` rewrites it still finds a moved view via SANDHOME_EXEC.
    if [ -r "$cmd_home/entry.sh" ]; then
        entry_src=$(cat "$cmd_home/entry.sh" 2>/dev/null)
        t_contains "$entry_src" 'SANDHOME_EXEC/bin/sandhome' 'the entry point falls back to SANDHOME_EXEC'
        t_contains "$entry_src" 'repo/bin/sandhome' 'the entry point falls back to the durable repo after a tmpfs clear'
        t_contains "$entry_src" 'command -v sandhome' 'the entry point falls back to PATH'
        t_contains "$entry_src" 'return 127' 'the entry point fails loudly when nothing resolves'
    else
        t_ok 1 'the entry point falls back to SANDHOME_EXEC'
    fi
else
    t_skip 'no installed home to check flag refusal against'
fi

t_end
