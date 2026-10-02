#!/bin/sh
# tests/regressions-181-186.sh - one clause per defect found by driving a real
# consumer round against PR #180 on an exec-capable exec root.
#
# The round that produced these six found them in a sandbox whose exec root is
# /workspace (20GB, runs binaries) and whose home is /state/home (refuses
# execve), which is the shape this project exists for. Every clause below is
# written so that it FAILS against the tree as it stood, and the two clauses
# that matter most - #176 and #184 - drive the real generated rust fragment
# through a real shell with a real PATH, because the whole defect was that
# inspecting the string said the fix was there and running the shell said
# otherwise. That asymmetry is the reason these clauses are not grep-shaped.
#
# RUNNING AGAINST THE OLD TREE. Every clause reads the functions from $ROOT/lib
# and $ROOT/tools, so `git stash` the product fix, run this file, and the named
# clauses fail. The #176 and #184 clauses need no network and no rust install:
# they need two Cargo.toml files, which is all the wrapper looks at.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$HERE/lib.sh"

SH_REPO_DIR=$ROOT
SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-181-186

tmp=$(t_exec_tmpdir sandhome-regr-181-186)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# sh_regr_lib ROOTS SNIPPET -> run SNIPPET with the library sourced and the two
# roots pinned, and PRINT what the snippet prints on stdout. The snippet is $1.
# stderr is discarded because the library's sh_step/sh_warn chatter is not what
# a clause is reading, and a clause that wants it redirects inside the snippet.
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

# sh_rust_fragment -> the real generated env.d/rust.sh for a given root, with a
# stub tc_rust_ld_fragment so no linker is needed. It is the FILE a shell
# sources, so the clauses below can hand it to a real shell and ask PATH a
# question, which is the only way the #176 defect is visible.
#
# THE ROOT MUST LOOK INSTALLED, NOT ADOPTED, because the installed path is the
# one that writes the five prepends this clause is about. tc_rust_env chooses
# between them by whether the toolchain root has a rustup/toolchains or a
# cargo/bin, and an empty root takes the adopt branch, whose fragment has one
# prepend. The fixture therefore puts a toolchain there: this is the path the
# defect was measured on.
sh_rust_fragment() {
    sh_rf_roots=$1
    sh_rf_out=$2
    # The output path has to exist before the shell opens it for writing. That
    # is a fact about a shell redirect, not about the code under test, and it
    # is worth stating because the symptom it produces - an empty fragment and
    # every clause that sources it failing - looks exactly like the defect.
    mkdir -p "${sh_rf_out%/*}" 2>/dev/null
    # The fixture has to satisfy tc_rust_env's OWN guards, or the function stops
    # before the prepends that this clause is about. There are two: the
    # installed branch is chosen by a toolchain root existing, and the run
    # itself refuses to continue without a real rustc under
    # <view>/rustup/toolchains/*/bin. A toolchain a function insists on before
    # it writes anything is not a detail of the fixture, it is what the fixture
    # has to provide, so it provides real ones.
    mkdir -p "$sh_rf_roots/home/toolchains/rust/rustup/toolchains" \
             "$sh_rf_roots/home/toolchains/rust/cargo/bin" \
             "$sh_rf_roots/home/env.d" \
             "$sh_rf_roots/exec/views/rust/rustup/toolchains/stable/bin" 2>/dev/null
    printf '#!/bin/sh\nprintf "rustc 1.99.0\\n"\n' \
        > "$sh_rf_roots/home/toolchains/rust/cargo/bin/rustc"
    printf '#!/bin/sh\nprintf "rustc 1.99.0\\n"\n' \
        > "$sh_rf_roots/exec/views/rust/rustup/toolchains/stable/bin/rustc"
    chmod 0755 "$sh_rf_roots/home/toolchains/rust/cargo/bin/rustc" 2>/dev/null
    chmod 0755 "$sh_rf_roots/exec/views/rust/rustup/toolchains/stable/bin/rustc" 2>/dev/null
    # A FRAGMENT IS A FILE, NOT OUTPUT. sh_env_write_fragment writes
    # $SH_HOME/env.d/<name>.sh and returns; it prints nothing. The first version
    # of this helper captured tc_rust_env's STDOUT and got an empty file every
    # time, which is indistinguishable from the defect under test - so the
    # helper reads the file the function wrote, which is also the file a shell
    # sources. Reading the artefact rather than the program's account of it is
    # the whole point.
    sh_regr_lib "$sh_rf_roots" '
        . "$SH_REPO_DIR/tools/rust.sh"
        tc_rust_ld_fragment() { :; }
        sh_rust_target_resolver() { :; }
        tc_rust_lib_dirs() { :; }
        sh_toolchain_ensure_targets() { :; }
        tc_rust_env
    ' >/dev/null 2>&1
    cp "$sh_rf_roots/home/env.d/rust.sh" "$sh_rf_out" 2>/dev/null
    [ -s "$sh_rf_out" ]
}

# =====================================================================  #181
# A PROXY-ONLY HOST LOSES ITS NETWORK IN EVERY COLD PATH THIS PROJECT
# DOCUMENTS. The dispatcher loads env.sh for the PROCESS it runs, and a child
# cannot change its parent, so a tool invoked by name from a shell that sourced
# nothing ran with no route out at all. Measured on the sandbox this round was
# run in: curl returned 000 for nodejs.org, npm answered getaddrinfo
# EAI_AGAIN, pip answered "from versions: none" and go refused the resolver;
# every one of them succeeded with the variables carried through, which is what
# isolates the scrub as the cause rather than the registries.
#
# The clause reads the two artifacts a cold path actually reads. One of them
# existing is not the claim; the claim is that a shell which read NOTHING has
# the variables afterwards, so the clause runs a real scrubbed shell.
r181=$tmp/r181
mkdir -p "$r181/home/toolchains" "$r181/home/tmp" "$r181/exec/bin" "$r181/exec/views"
PROXY_IN='http://169.254.169.1:40295'
sh_regr_lib "$r181" '
    http_proxy='"$PROXY_IN"' https_proxy='"$PROXY_IN"' no_proxy=169.254.169.1 \
    HTTP_PROXY='"$PROXY_IN"' HTTPS_PROXY='"$PROXY_IN"' NO_PROXY=169.254.169.1 \
    sh_env_write >/dev/null && sh_env_write_proxy && printf written
' >/dev/null 2>&1
t_ok "$([ -r "$r181/home/env.sh" ] && echo 0 || echo 1)" \
    'env.sh is written alongside the egress file (#181)'
t_ok "$([ -r "$r181/home/proxy.env" ] && echo 0 || echo 1)" \
    'the egress configuration is a file the hook can source (#181)'

# The real claim: a shell that sourced NOTHING ends up with the variables.
t_is "$(env -i PATH=/usr/bin:/bin sh -c ". $r181/home/proxy.env; printf '%s' \"\${http_proxy:-unset}\"")" \
    "$PROXY_IN" \
    'a scrubbed shell has the egress configuration after sourcing the one file (#181)'

# And the same through the generated dispatcher, which is the path a fresh
# hook-only shell actually takes. The dispatcher is written from the same
# function the installer calls, so the clause writes it the way install does.
sh_regr_lib "$r181" '
    mkdir -p "$SH_EXEC/global" 2>/dev/null
    sh_global_write_dispatch "$SH_EXEC/global/.sandhome-dispatch" "$SH_HOME" "$SH_EXEC_BIN"
' >/dev/null 2>&1
t_ok "$([ -x "$r181/exec/global/.sandhome-dispatch" ] && echo 0 || echo 1)" \
    'the dispatcher is written for the clause to read (#181)'
# The dispatcher is what a fresh hook-only shell actually runs, and it has to
# leave the egress configuration in the environment of the PROCESS it starts,
# because a child cannot change its parent. So the clause asks the process the
# hook starts, not the shell that started it: the dispatcher EXECs the tool, so
# there is nothing to print afterwards. A fake tool on the exec bin prints its
# own environment, which is the only place the claim is visible, and it is
# reached through a NAME LINK the way the hook directory reaches it, so
# $_sandhome_name is the tool's name rather than the dispatcher's own.
t_is "$(env -i PATH=/usr/bin:/bin sh -c "sh $r181/exec/global/.sandhome-dispatch node >/dev/null 2>&1; printf '%s' \"\${https_proxy:-unset}\"")" \
    'unset' \
    'the dispatcher execs the tool rather than returning to the shell (#181)'
printf '#!/bin/sh\nprintf "%%s" "${https_proxy:-unset}"\n' > "$r181/exec/bin/node"
chmod 0755 "$r181/exec/bin/node"
ln -sfn '.sandhome-dispatch' "$r181/exec/global/node"
t_is "$(env -i PATH="$r181/exec/global:/usr/bin:/bin" node 2>/dev/null)" \
    "$PROXY_IN" \
    'the hook applies the egress configuration to the process it dispatches (#181)'

# A machine with no proxy must leave no artefact naming one, or the file
# becomes a claim about a host that does not exist.
r181b=$tmp/r181b
mkdir -p "$r181b/home" "$r181b/exec/bin"
env -u http_proxy -u https_proxy -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u NO_PROXY -u all_proxy -u ALL_PROXY \
    sh_regr_lib "$r181b" 'sh_env_write >/dev/null; sh_env_write_proxy; printf done' >/dev/null 2>&1
t_ok "$([ ! -e "$r181b/home/proxy.env" ] && echo 0 || echo 1)" \
    'a machine with no proxy records no egress file rather than an empty one (#181)'

# The report must answer from the FILE, not from its own process, because the
# shells that need the answer are the ones whose process has no proxy. This is
# the difference between a report and a mirror of the caller. The host with no
# proxy gets an EMPTY file written on purpose, because the writer removes the
# file in that case and the reader then answers `unknown`, which is a different
# claim from `direct` and the clause has to be able to tell them apart.
t_is "$(sh_regr_lib "$r181" 'SH_HOME='"$r181"'/home sh_report_egress' 2>/dev/null)" \
    "proxy:http_proxy,https_proxy,no_proxy,HTTP_PROXY,HTTPS_PROXY,NO_PROXY" \
    'the report names the egress variables the hook will apply (#181)'
: > "$r181b/home/proxy.env"
t_is "$(sh_regr_lib "$r181b" 'SH_HOME='"$r181b"'/home sh_report_egress' 2>/dev/null)" \
    'direct' \
    'the report says direct on a host that recorded no egress variable (#181)'
rm -f "$r181b/home/proxy.env"
t_is "$(sh_regr_lib "$r181b" 'SH_HOME='"$r181b"'/home sh_report_egress' 2>/dev/null)" \
    'unknown' \
    'the report says unknown when nobody recorded the egress configuration (#181)'

# =====================================================================  #182
# (reserved: #182 is the issue number gh assigned to the proxy report, whose
# body is the #181 finding. The clauses above are the finding.)

# =====================================================================  #183
# THE TARGET-DIR WRAPPER EXISTED ONLY ON THE INSTALL PATH.
# sh_toolchain_rust_target_wrapper had exactly one call site in the tree and it
# sat below the `return 0` the adopt branch reaches, so a host that already
# carried rust was reported as having a working toolchain with no wrapper, no
# cargo on the exec bin, and no cargo for the hook to serve at all. Measured:
# `adopted=jq ripgrep fd python node`, `toolchain.rust=rustc 1.98.1`,
# `failures=0`, and then `ls $SANDHOME_EXEC/bin/cargo` answered "No such file".
# The clause drives the real tc_rust_env with a probe-green host rust, so the
# adopt branch is the one under test.
r183=$tmp/r183
mkdir -p "$r183/home/toolchains" "$r183/home/tmp" "$r183/exec/bin" \
         "$r183/exec/views/rust/cargo/bin" "$r183/fakebin" "$r183/fakehome"
# A host rustup home whose rustc answers, which is what makes the probe green.
mkdir -p "$r183/fakehome/.rustup/toolchains/stable/bin"
printf '#!/bin/sh\nprintf "rustc 1.98.1 (host)\\n"\n' > "$r183/fakehome/.rustup/toolchains/stable/bin/rustc"
chmod 0755 "$r183/fakehome/.rustup/toolchains/stable/bin/rustc"
ln -sfn "$r183/fakehome/.rustup/toolchains/stable/bin" "$r183/fakehome/cargo-bin"
for n in cargo rustc rustup rustdoc cargo-clippy cargo-fmt; do
    printf '#!/bin/sh\nprintf "%s 1.98.1 (host)\\n"\n' "$n" > "$r183/fakehome/cargo-bin/$n"
    chmod 0755 "$r183/fakehome/cargo-bin/$n"
done
sh_regr_lib "$r183" '
    . "$SH_REPO_DIR/tools/rust.sh"
    # The adopt branch: the probe finds a working host rustc, so nothing is
    # installed and the branch under test is the one that used to return early.
    sh_toolchain_root() { printf "%s" "$SH_HOME/toolchains/rust"; }
    tc_rust_probe() { return 0; }
    tc_rust_install() { printf "INSTALLED-BY-TEST" >&2; return 0; }
    tc_rust_ensure_targets() { :; }
    tc_rust_behavioural() { return 0; }
    tc_rust_ld_fragment() { :; }
    sh_rust_target_resolver() { :; }
    tc_rust_adopted() { printf "%s" "'"$r183"'/fakehome/cargo-bin"; }
    SH_RUST_WRITABLE_RUSTUP=
    mkdir -p "$SH_HOME/env.d" "$SH_EXEC_VIEWS/rust/cargo/bin" 2>/dev/null
    cp "'"$r183"'/fakehome/cargo-bin/cargo" "$SH_EXEC_VIEWS/rust/cargo/bin/cargo" 2>/dev/null
    chmod 0755 "$SH_EXEC_VIEWS/rust/cargo/bin/cargo" 2>/dev/null
    # sh_path_where is what the adopt branch reads to find the toolchain bin it
    # prepends, and a stub returning the fake host bin is what makes the branch
    # resolve a real directory instead of whatever this test host has.
    sh_path_where() { printf "%s/cargo" "'"$r183"'/fakehome/cargo-bin"; }
    tc_rust_env >/dev/null 2>&1
    printf "INSTALLED=%s\n" "$SH_TEST_SAW_INSTALL"
' >"$r183/out" 2>"$r183/err"
t_ok "$([ ! -e "$r183/home/toolchains/rust/rustup" ] && echo 0 || echo 1)" \
    'the adopt branch really was the one taken: no toolchain was installed (#183)'
t_ok "$([ -f "$r183/exec/bin/cargo" ] && echo 0 || echo 1)" \
    'an adopted rust still gets the target-dir wrapper on the exec bin (#183)'
t_ok "$([ -L "$r183/exec/cargo-wrap/cargo" ] && echo 0 || echo 1)" \
    'an adopted rust still gets the wrapper directory the fragment prepends (#183)'
# The wrapper is only useful if something reaches it, and on the adopt path the
# branch writes its OWN fragment. It had no cargo-wrap prepend at all, so the
# wrapper this same function creates sat on no PATH at all. This clause is the
# half of #183 that the first two miss, and it is the half that is invisible
# without a real shell.
t_ok "$([ -r "$r183/home/env.d/rust.sh" ] && grep -q 'cargo-wrap' "$r183/home/env.d/rust.sh" && echo 0 || echo 1)" \
    'the adopted fragment puts the wrapper directory on PATH (#183)'
r183_path=$(env -i PATH="/usr/bin:/bin" sh -c "
    . '$r183/home/env.d/rust.sh' 2>/dev/null
    command -v cargo
" 2>/dev/null)
t_is "$r183_path" "$r183/exec/cargo-wrap/cargo" \
    'a shell that sources the adopted fragment resolves cargo to the wrapper (#183)'

# =====================================================================  #184
# THE WRAPPER DIRECTORY WAS PINNED ABOVE THE WRAPPER BY ORDERING ALONE, AND
# THE GUARD THAT WAS SUPPOSED TO KEEP IT THERE DISABLED IT INSTEAD.
# The prepend was guarded on the directory not already being on PATH, the same
# guard as every other directory. So any shell that already carried
# $SH_EXEC/cargo-wrap skipped the prepend, the toolchain bin that is prepended
# after it became first, and cargo resolved to the real binary with the wrapper
# never executed. Measured, two real same-basename crates, one hook-only login
# shell, one target dir between them:
#   cargo-wrap NOT on PATH:      PROJECT-A, PROJECT-B
#   cargo-wrap already on PATH:  PROJECT-A, PROJECT-A
# The clause below runs the REAL generated fragment in a real shell, because the
# defect is not in the string: the old fragment's text is correct and its
# behaviour is wrong. A grep clause would have passed on the broken tree.
r184=$tmp/r184
mkdir -p "$r184/home/env.d" "$r184/home/tmp" "$r184/exec/bin" \
         "$r184/exec/views/rust/cargo/bin" "$r184/exec/cargo-wrap"
printf '#!/bin/sh\nexit 0\n' > "$r184/exec/views/rust/cargo/bin/cargo"
chmod 0755 "$r184/exec/views/rust/cargo/bin/cargo"
sh_rust_fragment "$r184" "$r184/rust.sh"
t_ok "$([ -r "$r184/rust.sh" ] && echo 0 || echo 1)" \
    'the real rust fragment was generated for the clause to source (#184)'

# The real cargo, in the wrapper directory and in a toolchain bin, so a real
# shell has something to resolve and the answer to `command -v cargo` is a fact
# about PATH order rather than about a string.
printf '#!/bin/sh\nprintf "REAL-CARGO\\n"\n' > "$r184/real-cargo"
chmod 0755 "$r184/real-cargo"
cp "$r184/real-cargo" "$r184/exec/cargo-wrap/cargo"
mkdir -p "$r184/toolchain-bin"
cp "$r184/real-cargo" "$r184/toolchain-bin/cargo"

# Read the generated fragment the way a login shell reads it, and the way
# ROUTE step 4 describes the cold path: with NOTHING set. A fragment that
# depends on a variable the shell happens to carry is not a fragment, and the
# clause that would not have caught it set SANDHOME_EXEC by hand - which is
# precisely the mistake. Each case is its own child, so one cannot leave PATH
# altered for the next.
r184_ask() {
    env -i PATH="$1:/usr/bin:/bin" sh -c "
        . '$r184/rust.sh' 2>/dev/null
        command -v cargo
    " 2>/dev/null
}

# The starting PATH already carries the wrapper directory, which is the state
# the global hook creates. The old fragment's guard sees it and skips, so the
# real cargo wins. This is the measured state, and the two same-basename crates
# behind it printed one project's binary for both.
t_is "$(r184_ask "$r184/exec/cargo-wrap")" "$r184/exec/cargo-wrap/cargo" \
    'the wrapper stays first even when its directory was already on PATH (#184)'

# And the ordinary case still works, with the directory absent to begin with.
t_is "$(r184_ask "/usr/bin")" "$r184/exec/cargo-wrap/cargo" \
    'the wrapper is prepended when its directory was not already on PATH (#184)'

# Idempotence: a second read of the fragment must not grow PATH or leave two
# copies, because a login shell reads the profile and env.sh more than once.
r184_n=$(env -i PATH="$r184/exec/cargo-wrap:/usr/bin:/bin" sh -c "
    . '$r184/rust.sh' 2>/dev/null
    . '$r184/rust.sh' 2>/dev/null
    printf '%s' \"\$PATH\" | tr ':' '\n' | grep -c '^$r184/exec/cargo-wrap\$'
" 2>/dev/null)
t_is "$r184_n" 1 'sourcing the fragment twice leaves one copy of the wrapper directory (#184)'

# The wrapper has to WIN, not merely be present. A toolchain bin on PATH is the
# installed case, because that is what the fragment itself prepends, and the
# answer still has to be the wrapper.
t_is "$(r184_ask "$r184/toolchain-bin")" "$r184/exec/cargo-wrap/cargo" \
    'the wrapper wins over a toolchain bin already on PATH (#184)'

# =====================================================================  #185
# THE GLOBAL HOOK WAS INSTALLED INTO A DIRECTORY THIS TREE PUTS ON PATH.
# sh_global_skip_entry refuses the view, the exec root, the dispatcher
# directory and the sandboxes, all by name, in a list written when the list was
# written. $SANDHOME_EXEC/cargo-wrap was created afterwards and prepended by the
# rust fragment; install and repair call sh_env_load before sh_global_install,
# so it was on PATH, writable and exec-capable, and the hook was written into
# it. Measured: `global=on:/workspace/sandexec/cargo-wrap`, every tool the hook
# advertised there invisible to the next fresh shell, and #176 behind it.
# The clause checks the rule, not the incident: a directory this tree marks as
# on-PATH is refused, and a directory it did not mark is still a candidate.
r185=$tmp/r185
mkdir -p "$r185/home/toolchains" "$r185/home/tmp" "$r185/exec/bin" \
         "$r185/exec/views/node/bin" "$r185/exec/cargo-wrap" \
         "$r185/exec/plain-bin" "$r185/exec/npm-global/bin" "$r185/plain-path-dir"
sh_regr_lib "$r185" '
    : > "$SH_EXEC/cargo-wrap/.sandhome-on-path"
    : > "$SH_EXEC/bin/.sandhome-on-path"
    : > "$SH_EXEC/npm-global/bin/.sandhome-on-path"
    for d in "$SH_EXEC/cargo-wrap" "$SH_EXEC/bin" "$SH_EXEC/views/node/bin" "$SH_EXEC/npm-global/bin"; do
        sh_global_skip_entry "$d" || printf "NOT-REFUSED %s\n" "$d"
    done
' > "$r185/refused" 2>/dev/null
t_ok "$([ ! -s "$r185/refused" ] && echo 0 || echo 1)" \
    'every directory this tree put on PATH is refused as a hook directory (#185)'
# The control. A directory this tree did not create and did not mark is the
# only thing that can serve a shell that sourced nothing, so it must stay a
# candidate; this is the clause that stops the fix from becoming "nothing on
# the exec root may host a hook".
t_is "$(sh_regr_lib "$r185" '
    if sh_global_skip_entry "$SH_EXEC/plain-bin"; then printf REFUSED; else printf CANDIDATE; fi
' 2>/dev/null)" 'CANDIDATE' \
    'a neutral directory this tree did not create is still a hook candidate (#185)'
t_is "$(sh_regr_lib "$r185" '
    if sh_global_skip_entry "'"$r185"'/plain-path-dir"; then printf REFUSED; else printf CANDIDATE; fi
' 2>/dev/null)" 'CANDIDATE' \
    'a PATH directory outside the exec root is still a hook candidate (#185)'
# The mark is written where the directory is put on PATH, so a directory
# invented after the skip list was written cannot be taken by mistake.
t_is "$(sh_regr_lib "$r185" '
    mkdir -p "$SH_EXEC/brand-new-dir" 2>/dev/null
    sh_env_mark_onpath "$SH_EXEC/brand-new-dir"
    if [ -e "$SH_EXEC/brand-new-dir/.sandhome-on-path" ]; then printf yes; else printf no; fi
' 2>/dev/null)" 'yes' \
    'a directory this tree puts on PATH is marked where the prepend writes it (#185)'
# A view is never marked: the mark would put a file inside a tree the promote
# step mirrors, and the view is already refused by its own path pattern.
t_is "$(sh_regr_lib "$r185" '
    sh_env_mark_onpath "$SH_EXEC/views/node/bin"
    if [ -e "$SH_EXEC/views/node/bin/.sandhome-on-path" ]; then printf yes; else printf no; fi
' 2>/dev/null)" 'no' \
    'a toolchain view is refused by its path and never marked (#185)'

# =====================================================================  #186
# PR #180 DID NOT PASS THIS REPOSITORY OWN DOCS GATE. The suite reported
# `docs: 68 run, 1 failed`, `failed : docs`, exit 1, with the clause
# "docs/reference.md has drifted; run sh docs/generate-reference.sh". The PR
# added SANDHOME_CARGO_TARGET_DEFAULT and did not regenerate the reference. The
# clause regenerates and compares, which is the gate's own rule applied to the
# gate: a tree that adds a variable and forgets the reference must be red here
# and not only in a suite someone has to remember to run.
r186_ref=$tmp/reference.md
if sh "$ROOT/docs/generate-reference.sh" > "$r186_ref" 2>/dev/null; then
    t_ok 0 'the generated reference is reproducible (#186)'
else
    t_ok 1 'the generated reference is reproducible (#186)'
fi
t_ok "$(cmp -s "$r186_ref" "$ROOT/docs/reference.md" && echo 0 || echo 1)" \
    'docs/reference.md matches what the code generates (#186)'
# The variable PR #180 forgot is named, so the clause says which one rather
# than only that something differs.
t_ok "$(grep -q 'SANDHOME_CARGO_TARGET_DEFAULT' "$ROOT/docs/reference.md" && echo 0 || echo 1)" \
    'the variable PR #180 added is in the generated reference (#186)'
# The egress variables are named too, and their file is documented, because a
# reference that lists a variable and not the file that carries it is half a
# claim.
t_ok "$(grep -q 'SANDHOME_PROXY_VARS' "$ROOT/docs/reference.md" && echo 0 || echo 1)" \
    'the egress variable is in the generated reference (#186)'
t_ok "$(grep -q 'proxy.env' "$ROOT/docs/guide.md" && echo 0 || echo 1)" \
    'the guide names the egress file the hook sources (#186)'

# =====================================================================  DEEP REVIEW 1
# THREE DEFECTS THE FIRST PASS OF THIS SUITE DID NOT COVER. Each was found by
# using the fix, not by reading it, and each is a way the fix is right on the
# machine it was written on and wrong on a neighbour.
#
# A MARK THAT CANNOT BE WRITTEN. The refusal is a file inside the directory, and
# a read-only exec root refuses to create one. The tree then has no record and
# takes the directory as a hook directory, which is the whole of #185. The home
# is writable on every host this tree supports, because env.sh lives there, so
# the directory is also appended to $SH_HOME/on-path.dirs and read back. The
# clause makes the exec root unwritable and asks the question the failure would
# otherwise hide.
r187=$tmp/r187
mkdir -p "$r187/home/toolchains" "$r187/home/tmp" "$r187/exec/bin" \
         "$r187/exec/plain-bin"
chmod 555 "$r187/exec" 2>/dev/null
t_is "$(sh_regr_lib "$r187" '
    sh_env_mark_onpath "$SH_EXEC/bin"
    if sh_global_skip_entry "$SH_EXEC/bin"; then printf REFUSED; else printf CANDIDATE; fi
' 2>/dev/null)" 'REFUSED' \
    'a directory this tree put on PATH is refused even when it cannot be marked in place (review 1)'
t_is "$(sh_regr_lib "$r187" '
    sh_env_mark_onpath "$SH_EXEC/bin"
    if sh_global_skip_entry "$SH_EXEC/plain-bin"; then printf REFUSED; else printf CANDIDATE; fi
' 2>/dev/null)" 'CANDIDATE' \
    'the second record does not refuse a directory this tree never put on PATH (review 1)'
chmod 755 "$r187/exec" 2>/dev/null

# A PROXY VALUE WITH A QUOTE IN IT. The block is emitted through printf and
# then read by a shell at shell start, so a value that is not a plain word has
# to survive the round trip or the environment is broken at every shell start,
# not just at install. The control reads the generated file, because that is
# the artefact, and then sources it in a scrubbed shell, because that is what a
# consumer does.
r187q=$tmp/r187q
mkdir -p "$r187q/home/toolchains" "$r187q/home/tmp" "$r187q/exec/bin"
QVAL="it's a \"test\" \$x"
env -i PATH=/usr/bin:/bin http_proxy="$QVAL" \
    SANDHOME_HOME=$r187q/home SANDHOME_EXEC=$r187q/exec SH_HOME=$r187q/home \
    SH_HOME_TOOLCHAINS=$r187q/home/toolchains SH_HOME_TMP=$r187q/home/tmp \
    SH_HOME_EXEC=no SH_EXEC=$r187q/exec SH_EXEC_BIN=$r187q/exec/bin \
    SH_EXEC_VIEWS=$r187q/exec/views SH_REPO_DIR=$ROOT SH_LIB_DIR=$ROOT/lib \
    sh -c '. "$SH_LIB_DIR"/common.sh 2>/dev/null; . "$SH_LIB_DIR"/env.sh; sh_env_write; sh_env_write_proxy' \
    >/dev/null 2>&1
t_is "$(env -i PATH=/usr/bin:/bin sh -c ". $r187q/home/env.sh 2>/dev/null; printf '%s' \"\$http_proxy\"")" \
    "$QVAL" \
    'a proxy value with a quote and a dollar in it survives into a sourced shell (review 1)'

# THE REPORT MUST CARRY IT IN JSON TOO. A harness reads report --json and not
# the prose, so a field present only in the text is a field the machine-readable
# answer does not have, on exactly the hosts that need it.
t_ok "$(grep -q '"egress":"%s"' "$ROOT/lib/report.sh" && echo 0 || echo 1)" \
    'the JSON report carries the egress state as well as the text report (review 1)'

t_end
