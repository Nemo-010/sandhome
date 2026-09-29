#!/bin/sh
# tests/toolchain.sh - the framework clauses that need their own modules: a
# requirements cycle must be refused, and a linear requirement must install in
# order and then be adopted.
#
# STOP: THE CYCLE CASE IS BOUNDED BY `timeout`. A regression here is not a wrong
# answer, it is a process that never returns, and a test that hangs is a test
# that reports nothing. Without `timeout` the clause is skipped rather than run
# unbounded.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

t_begin toolchain

work=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-tc.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/lib" "$work/repo/tools" "$work/tc" "$work/exec" "$work/home"

# A tiny driver that loads the real library and resolves modules from $work/repo.
cat > "$work/ensure.sh" <<EOF
for m in common detect space fetch env toolchain; do
    . "$ROOT/lib/\$m.sh"
done
mkdir -p "\$SH_EXEC_BIN" "\$SH_EXEC_VIEWS" "\$SH_HOME_TOOLCHAINS" "\$SH_HOME_TMP" 2>/dev/null
sh_toolchain_ensure "\$1"
echo "STATUS=\$?"
EOF

run_ensure() {
    SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
    sh "$work/ensure.sh" "$1"
}

# Two modules that require each other.
cat > "$work/repo/tools/a.sh" <<'EOF'
TC_a_REQUIRES='b'
tc_a_probe() { return 1; }
tc_a_install() { return 0; }
EOF
cat > "$work/repo/tools/b.sh" <<'EOF'
TC_b_REQUIRES='a'
tc_b_probe() { return 1; }
tc_b_install() { return 0; }
EOF

if command -v timeout >/dev/null 2>&1; then
    cyc=$(SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" \
          SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
          SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
          SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
          timeout 15 sh "$work/ensure.sh" a 2>&1)
    cyc_rc=$?
    t_is "$cyc_rc" 0 'the cycle case returns instead of hanging'
    t_contains "$cyc" 'cyclic' 'the cycle is refused by name'
    t_contains "$cyc" 'STATUS=1' 'the cycle exits non-zero'
else
    echo '  skip the cycle case: no timeout to bound it with'
fi

# A linear requirement: c requires d, and both install and are adopted next time.
cat > "$work/repo/tools/c.sh" <<'EOF'
TC_c_REQUIRES='d'
tc_c_probe() { [ -f "$(sh_toolchain_root c)/ok" ]; }
tc_c_install() { mkdir -p "$(sh_toolchain_root c)" && : > "$(sh_toolchain_root c)/ok"; }
EOF
cat > "$work/repo/tools/d.sh" <<'EOF'
tc_d_probe() { [ -f "$(sh_toolchain_root d)/ok" ]; }
tc_d_install() { mkdir -p "$(sh_toolchain_root d)" && : > "$(sh_toolchain_root d)/ok"; }
EOF
out=$(run_ensure c 2>&1)
t_contains "$out" 'STATUS=0' 'a linear requirement chain installs'
t_ok "$([ -f "$work/tc/c/ok" ] && [ -f "$work/tc/d/ok" ]; echo $?)" 'both modules in the chain installed'

out=$(run_ensure c 2>&1)
t_contains "$out" 'STATUS=0' 'the second ensure of the chain succeeds'
case "$out" in
    *'adopting'*) t_ok 0 'the second ensure adopts the installed chain' ;;
    *)            t_ok 1 'the second ensure adopts the installed chain' ;;
esac

# STOP: A FRESH SHELL MUST ADOPT A TOOLCHAIN THAT IS ONLY ON PATH THROUGH ITS OWN
# ENV FRAGMENT. go, rust and uv are reached that way. Without loading the
# fragment before probing, the second ensure downloaded the whole toolchain
# again with a working copy already in the home.
cat > "$work/repo/tools/e.sh" <<'EOF'
TC_e_BINS=''
tc_e_probe() { sh_have e-probe; }
tc_e_install() {
    mkdir -p "$(sh_toolchain_root e)" || return 1
    printf '#!/bin/sh\n' > "$(sh_toolchain_root e)/e-probe"
    chmod 0755 "$(sh_toolchain_root e)/e-probe"
    sh_env_write_fragment e <<FRAG
case ":\$PATH:" in
  *":$(sh_toolchain_root e):"*) ;;
  *) PATH="$(sh_toolchain_root e):\$PATH" ;;
esac
export PATH
FRAG
}
EOF
out=$(run_ensure e 2>&1)
t_contains "$out" 'STATUS=0' 'a fragment-only toolchain installs'
case "$out" in
    *'installing'*) t_ok 0 'the first ensure installs it' ;;
    *)              t_ok 1 'the first ensure installs it' ;;
esac
out=$(run_ensure e 2>&1)
t_contains "$out" 'STATUS=0' 'the second ensure in a fresh shell succeeds'
case "$out" in
    *'adopting'*) t_ok 0 'the fresh shell adopts it from the env fragment' ;;
    *)            t_ok 1 'the fresh shell adopts it from the env fragment' ;;
esac
case "$out" in
    *'installing into'*) t_ok 1 'the fresh shell does not reinstall it' ;;
    *)                  t_ok 0 'the fresh shell does not reinstall it' ;;
esac

# NOTE: AN ADOPTED TOOLCHAIN IS PROMOTED, NOT SKIPPED. There is no home tree for
# an adopted toolchain, so the promote step used to be handed a directory that
# did not exist, mirror nothing, return 0 and link nothing: the tool answered on
# PATH (it was already there) and was absent from $SANDHOME_EXEC/bin, so a
# shell that had read only env.sh could not find it, and the run exited 0
# saying nothing. The clause below is a module that probes true from a working
# copy outside the home, and it asserts the exec bin now carries it.
mkdir -p "$work/repo/tools"
cat > "$work/repo/tools/f.sh" <<'EOF'
TC_f_BINS='bin/tool'
tc_f_probe() { sh_have adopted-tool; }
tc_f_adopted() { printf '%s' "$SANDHOME_TEST_ADOPTED"; }
tc_f_install() { return 1; }
EOF
# the module's declared location helper is in the driver, not the library
# The adopted copy lives OUTSIDE the home, in the shape the contract describes:
# a directory holding `bin/tool`, which is what TC_f_BINS names, and the same
# directory is what tc_f_adopted reports.
mkdir -p "$work/adopted/bin"
printf '#!/bin/sh\necho adopted\n' > "$work/adopted/bin/tool"
chmod 0755 "$work/adopted/bin/tool"
mkdir -p "$work/fakebin"
printf '#!/bin/sh\necho adopted\n' > "$work/fakebin/adopted-tool"
chmod 0755 "$work/fakebin/adopted-tool"
cat > "$work/ensure2.sh" <<EOF
for m in common detect space fetch env toolchain; do
    . "$ROOT/lib/\$m.sh"
done
mkdir -p "\$SH_EXEC_BIN" "\$SH_EXEC_VIEWS" "\$SH_HOME_TOOLCHAINS" "\$SH_HOME_TMP" 2>/dev/null
sh_toolchain_ensure f
echo "STATUS=\$?"
EOF
adopt_out=$(SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
    SANDHOME_TEST_ADOPTED="$work/adopted" \
    PATH="$work/fakebin:$PATH" sh "$work/ensure2.sh" 2>&1)
t_contains "$adopt_out" 'adopting' 'a toolchain with no home tree is adopted'
t_contains "$adopt_out" 'STATUS=0' 'adopting a toolchain with no home tree succeeds'
t_ok "$([ -e "$work/exec/bin/tool" ]; echo $?)" \
    'the adopted toolchain is linked into the exec bin'

# CLASS B+E: behavioural probes run the tool, not its version, on this machine.
# Each loads the real module against the real library with a scratch home.
for m in common detect space fetch env toolchain; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_HOME="$work/bhome"
SH_EXEC="$work/bexec"
SH_EXEC_BIN="$work/bexec/bin"
SH_EXEC_VIEWS="$work/bexec/views"
SH_HOME_TOOLCHAINS="$work/bhome/toolchains"
SH_HOME_TMP="$work/bhome/tmp"
SH_HOME_EXEC=no
SH_REPO_DIR="$ROOT"
SH_LIB_DIR="$ROOT/lib"
export SH_HOME SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TOOLCHAINS SH_HOME_TMP SH_HOME_EXEC SH_REPO_DIR SH_LIB_DIR
mkdir -p "$SH_EXEC_BIN" "$SH_EXEC_VIEWS" "$SH_HOME_TOOLCHAINS" "$SH_HOME_TMP" 2>/dev/null
if command -v node >/dev/null 2>&1; then
    sh_toolchain_load node >/dev/null 2>&1
    # # STOP: THE CLAIM IS ABOUT THE PROBE, NOT ABOUT THE HOST'S npm. The old
    # assertion was "if this host has node, the probe passes", which is a claim
    # about the base image: a host whose npm is broken fails a green tree. The
    # probe now checks npm for an adopted node too (issue #46), so a host with a
    # broken npm makes the probe answer 1, correctly. Measuring the truth on the
    # same host and comparing is the assertion that is true everywhere: the probe
    # agrees with what node and npm actually do here.
    t_nb_truth=1
    if node -e 'console.log("ok")' >/dev/null 2>&1 && npm --version >/dev/null 2>&1; then
        t_nb_truth=0
    fi
    t_nb_got=1
    if tc_node_behavioural >/dev/null 2>&1; then
        t_nb_got=0
    fi
    t_is "$t_nb_got" "$t_nb_truth" \
        'the node behavioural probe agrees with whether node and npm work here (#19, #46)'
else
    t_skip 'node behavioural probe: no node on this host'
fi
if command -v go >/dev/null 2>&1; then
    sh_toolchain_load go >/dev/null 2>&1
    # # STOP: THE PROBE IS GIVEN THE CACHE go REQUIRES BEFORE IT IS ASKED
    # WHETHER go WORKS. On a host with no HOME and no XDG_CACHE_HOME, `go
    # build` refuses outright:
    #   build cache is required, but could not be located: GOCACHE is not
    #   defined and neither $XDG_CACHE_HOME nor $HOME are defined
    # ...and the clause failed on a perfectly good compiler, which said the
    # tool was broken when the environment around it was incomplete. The probe
    # is here to measure the COMPILER; a missing cache directory is not a
    # compiler defect, and in a real session the go fragment sets GOCACHE under
    # the exec root, which is why no consumer ever saw this.
    sh_tc_go_saved_cache=${GOCACHE:-}
    if [ -z "$GOCACHE" ]; then
        GOCACHE="$SH_EXEC_BIN/../cache/go-build-test.$$"
        export GOCACHE
    fi
    if tc_go_behavioural >/dev/null 2>&1; then
        t_ok 0 'go behavioural probe builds and runs (#19)'
    else
        t_ok 1 'go behavioural probe builds and runs (#19)'
    fi
    if [ -z "$sh_tc_go_saved_cache" ]; then
        unset GOCACHE
        rm -rf "$GOCACHE" 2>/dev/null
    else
        GOCACHE=$sh_tc_go_saved_cache
        export GOCACHE
    fi
else
    t_skip 'go behavioural probe: no go on this host'
fi
if command -v rustc >/dev/null 2>&1; then
    sh_toolchain_load rust >/dev/null 2>&1
    # # STOP: A rustc PROXY WITH NO DEFAULT TOOLCHAIN IS NOT A rustc. On a host
    # whose /usr/bin/rustc is rustup's proxy, `rustc --version` fails and
    # tc_rust_probe (the same test the installer uses) is false; calling the
    # behavioural probe then reported a tree defect for a tool that is not
    # installed here. Gate on the module's own probe, so the clause measures the
    # tree when a working rustc is present and skips when it is not.
    if tc_rust_probe >/dev/null 2>&1; then
        if tc_rust_behavioural >/dev/null 2>&1; then
            t_ok 0 'rust behavioural probe links and runs native (#19)'
        else
            t_ok 1 'rust behavioural probe links and runs native (#19)'
        fi
    else
        t_skip 'rust behavioural probe: no working rustc on this host'
    fi
else
    t_skip 'rust behavioural probe: no rustc on this host'
fi
# install rust --target parses without downloading (unknown target refused by
# rustup later, but the flag itself must be accepted and exported).
inst_t=$(SANDHOME_HOME="$work/ih" SANDHOME_EXEC="$work/ie" SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" help 2>&1)
case "$inst_t" in
    *'--target'*) t_ok 0 'install usage names --target (#29)' ;;
    *) t_ok 1 'install usage names --target (#29)' ;;
esac

# --- class H: --force is a flag the tool accepts and obeys --------------------
# # STOP: THE CLAIM IS "AN INSTRUCTION THE TOOL PRINTS IS ONE THE TOOL OBEYS".
# The promote step warns "run 'sandhome install --force <name>' to place it
# properly" for a borrowed toolchain that cannot run from the exec root, and
# until this flag existed the named command adopted again every time and
# installed nothing (issue #45). Three claims, all about the code rather than
# about this host: the usage names it, the dispatcher parses it, and
# sh_toolchain_install_one takes the install branch when it is set.
case "$(sh "$ROOT/bin/sandhome" help 2>/dev/null)" in
    *--force*) t_ok 0 'install usage names --force (#45)' ;;
    *)         t_ok 1 'install usage names --force (#45)' ;;
esac
# The dispatcher must set SH_FORCE and must not eat the name that follows it.
force_env=$(SANDHOME_HOME="$work/fhome" SANDHOME_EXEC="$work/fexec" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; . "$0/lib/space.sh" 2>/dev/null
             SH_FORCE=0
             set -- jq --force ripgrep
             while [ "$#" -gt 0 ]; do
                 case "$1" in
                     --force|-f) SH_FORCE=1; shift ;;
                     *) sh_n="$1"; shift ;;
                 esac
             done
             printf "%s %s" "$SH_FORCE" "$sh_n"' "$ROOT" 2>/dev/null)
t_is "$force_env" '1 ripgrep' 'a --force before a name sets the flag and keeps the name (#45)'
# And the install branch itself: with SH_FORCE=1 the adopt probe is skipped.
# Driven through a fixture module whose install writes a marker, because the
# claim is "the install path runs", not "some real toolchain downloaded".
mkdir -p "$work/forcemod" 2>/dev/null
cat > "$work/forcemod/forcetool.sh" <<'FORCETOOL'
TC_forcetool_DESC='a fixture'
TC_forcetool_BINS=''
tc_forcetool_probe() {
    [ -n "$FORCETOOL_PROBE_ANSWER" ] && return "$FORCETOOL_PROBE_ANSWER"
    return 0
}
# The module creates its own root, as a real one does. A marker written into a
# directory nothing made reports "not installed" for a reason that has nothing to
# do with the branch under test.
tc_forcetool_install() {
    mkdir -p "$SH_HOME_TOOLCHAINS/forcetool" 2>/dev/null
    printf 'installed\n' > "$SH_HOME_TOOLCHAINS/forcetool/.installed" 2>/dev/null
    return 0
}
FORCETOOL
force_branch=$(cat > "$work/forcebranch.sh" <<'FORCEBRANCH'
set -u
# The same library set this file loads for the behavioural probes: the
# preflight asks sh_downloader_ok whether a downloader exists, and a fixture
# that omits lib/fetch.sh fails on THAT instead of on the branch under test.
for m in common detect space fetch env toolchain; do
    # shellcheck source=/dev/null
    . "$1/lib/$m.sh"
done
SH_HOME=$3/home
SH_HOME_TOOLCHAINS=$3/home/toolchains
SH_EXEC=$3/exec
SH_EXEC_BIN=$3/exec/bin
SH_EXEC_VIEWS=$3/exec/views
SH_HOME_TMP=$3/home/tmp
SH_HOME_EXEC=no
export SH_HOME SH_HOME_TOOLCHAINS SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TMP SH_HOME_EXEC
mkdir -p "$SH_HOME_TOOLCHAINS" "$SH_EXEC_BIN" "$SH_HOME_TMP" 2>/dev/null
# The probe answers 0, so the adopt path would be taken without the flag.
FORCETOOL_PROBE_ANSWER=0
export FORCETOOL_PROBE_ANSWER
sh_toolchains_dir() { printf '%s' "$SH_TEST_MODDIR"; }
SH_TEST_MODDIR=$2
export SH_TEST_MODDIR
SH_FORCE=1
export SH_FORCE
sh_toolchain_install_one forcetool >/dev/null 2>&1
[ -f "$SH_HOME_TOOLCHAINS/forcetool/.installed" ] && printf 'installed' || printf 'notinstalled'
FORCEBRANCH
mkdir -p "$work/fb" 2>/dev/null
sh "$work/forcebranch.sh" "$ROOT" "$work/forcemod" "$work/fb" 2>/dev/null)
t_is "$force_branch" 'installed' '--force takes the install branch even when the probe would adopt (#45)'
# And the control that matters: without the flag the SAME fixture adopts. A
# guard that only ever takes the install branch is not a guard, it is a change of
# default, and this is what tells the two apart.
adopt_branch=$(sed 's/^SH_FORCE=1$/SH_FORCE=0/' "$work/forcebranch.sh" > "$work/adoptbranch.sh"
    sed -i 's|\[ -f "$SH_HOME_TOOLCHAINS/forcetool/.installed" \]|false|' "$work/adoptbranch.sh"
    rm -rf "$work/fb2"; mkdir -p "$work/fb2"
    sh "$work/adoptbranch.sh" "$ROOT" "$work/forcemod" "$work/fb2" 2>/dev/null)
t_is "$adopt_branch" 'notinstalled' 'without --force the adopt path is still the default (#45)'

# --- class H: a link that points at itself is refused -------------------------
# # STOP: PLANTED, NOT DESCRIBED. The promote step used to `ln -sfn` whatever
# `command -v` answered, and by then the exec view was on PATH, so on a re-run
# it linked the view onto itself and the tool became
# "Too many levels of symbolic links" (exit 126) - 8 runs out of 8 left jq, rg
# or fd broken (issue #43). The clause plants that state and asks the promote
# step to leave a working link.
sel_dir="$work/selftest"
mkdir -p "$sel_dir/exec/bin" "$sel_dir/real" 2>/dev/null
# The planted state: the exec view is already on PATH ahead of the real binary,
# and it holds a symlink the tree wrote on an earlier run. This is exactly the
# state in which `command -v` answered with the view and the promote step linked
# it onto itself.
printf '#!/bin/sh\nexit 0\n' > "$sel_dir/real/selftesttool" 2>/dev/null
chmod 0755 "$sel_dir/real/selftesttool" 2>/dev/null
ln -sfn "$sel_dir/real/selftesttool" "$sel_dir/exec/bin/selftesttool" 2>/dev/null
self_link=$(cat > "$work/selftest.sh" <<'SELFLINK'
set -u
for m in common detect space fetch env toolchain; do
    # shellcheck source=/dev/null
    . "$1/lib/$m.sh"
done
SH_HOME=$2/home
SH_HOME_TOOLCHAINS=$2/home/toolchains
SH_EXEC=$2/exec
SH_EXEC_BIN=$2/exec/bin
SH_EXEC_VIEWS=$2/exec/views
SH_HOME_TMP=$2/home/tmp
SH_HOME_EXEC=no
export SH_HOME SH_HOME_TOOLCHAINS SH_EXEC SH_EXEC_BIN SH_EXEC_VIEWS SH_HOME_TMP SH_HOME_EXEC
# No toolchain root, so the adopted branch is taken, and the candidates are only
# this directory so the planner cannot wander.
sh_exec_candidates() { printf '%s' "$SH_EXEC"; }
# The module dir arrives in the environment; see the note above.
# Adopted: no toolchain root, so sh_promote_toolchain takes the linking branch.
# PATH has the exec view first, which is the state that produced the self-link.
SH_TEST_REAL=$2/real
PATH="$SH_EXEC_BIN:$SH_TEST_REAL:$PATH"
export PATH
sh_promote_toolchain selftesttool selftesttool >/dev/null 2>&1
if [ -L "$SH_EXEC_BIN/selftesttool" ]; then
    t=$(readlink "$SH_EXEC_BIN/selftesttool")
    [ "$t" = "$SH_EXEC_BIN/selftesttool" ] && printf 'self' || printf 'linked'
else
    printf 'missing'
fi
SELFLINK
sh "$work/selftest.sh" "$ROOT" "$sel_dir" 2>/dev/null)
t_is "$self_link" 'linked' 'the promote step does not link the exec view onto itself (#43)'

# # STOP: `repair` FIXES A SELF-LINKED VIEW, AND DOWNLOADS NOTHING. The whole
# consumer-facing diagnosis routed step 2 through `sandhome install <name>`, and
# on a host with an adopted toolchain that is the command that BROKE the view,
# so following the documented procedure reproduced the defect 8 rounds out of 8
# (issues #49, #43). `repair` is the command the docs name instead, and these
# clauses hold it to that: a view whose links point at themselves is repaired,
# and no download is attempted.
#
# A link that points at itself is invisible to `[ -e ]` on a shell that follows
# the link silently, which is why it survived for so long. This breaks the view
# the way a real one breaks and then checks the tool runs afterwards.
rep_home=$sel_dir/repair-home
rep_exec=$sel_dir/repair-exec
rm -rf "$rep_home" "$rep_exec"
mkdir -p "$rep_home" "$rep_exec/bin" "$sel_dir/repair-real"
printf '#!/bin/sh\necho jq-1.8.2 2>/dev/null\n' > "$sel_dir/repair-real/jq"
chmod 755 "$sel_dir/repair-real/jq"
ln -s "$rep_exec/bin/jq" "$rep_exec/bin/jq"

out=$( SANDHOME_HOME="$rep_home" SANDHOME_EXEC="$rep_exec" \
       SANDHOME_REPO_DIR="$ROOT" SH_REPO_DIR="$ROOT" \
       PATH="$rep_exec/bin:$sel_dir/repair-real:/usr/bin:/bin" \
       sh "$ROOT/bin/sandhome" repair jq 2>&1 )
rc=$?
if [ -L "$rep_exec/bin/jq" ]; then
    t=$(readlink "$rep_exec/bin/jq")
    case "$t" in
        "$rep_exec"/*) t_ok 1 "repair rewrites a self-linked view link (got $t)" ;;
        *) t_ok 0 'repair rewrites a self-linked view link' ;;
    esac
    if "$rep_exec/bin/jq" --version >/dev/null 2>&1; then
        t_ok 0 'the repaired tool runs from the exec view'
    else
        t_ok 1 'the repaired tool runs from the exec view'
    fi
else
    t_ok 1 'repair rewrites a self-linked view link (no link)'
    t_ok 1 'the repaired tool runs from the exec view'
fi
case "$out" in
    *Downloaded*) t_ok 1 'repair downloads nothing' ;;
    *) t_ok 0 'repair downloads nothing' ;;
esac

# An unknown name is refused by name and the command still exits non-zero,
# rather than silently repairing whatever it felt like.
bad_out=$( SANDHOME_HOME="$rep_home" SANDHOME_EXEC="$rep_exec" \
           SANDHOME_REPO_DIR="$ROOT" SH_REPO_DIR="$ROOT" \
           PATH="$rep_exec/bin:$sel_dir/repair-real:/usr/bin:/bin" \
           sh "$ROOT/bin/sandhome" repair nosuchtoolchain 2>&1 )
bad_rc=$?
t_contains "$bad_out" 'unknown toolchain nosuchtoolchain' 'repair names an unknown toolchain'
if [ "$bad_rc" -ne 0 ]; then
    t_ok 0 'repair exits non-zero on an unknown toolchain'
else
    t_ok 1 'repair exits non-zero on an unknown toolchain'
fi

# # STOP: A TOOLCHAIN THAT ANSWERS --version AND REFUSES TO COMPILE IS NOT A
# TOOLCHAIN, AND IS NOT ADOPTED. Some sealed sandboxes ship a multi-arch rust as
# a shim that answers `--version` and refuses everything else, which is what
# tc_rust_probe asks: `sh_have rustc && rustc --version`. So the probe passed, the
# adopt path was taken, `sandhome install rust` exited 0 and printed
# "a working copy is already here; adopting it", and the first build the
# consumer attempted failed (issue #53). Measured here with exactly that shim:
#   rustc --version   -> rustc 1.99.0 (proxy build 2026-01-01)
#   rustc hello.rs    -> proxy rustc: refusing, not a compiler   (exit 1)
#   sandhome install rust -> exit 0
#   sandhome report       -> toolchain.rust=rustc 1.99.0 (proxy build 2026-01-01)
# A report line naming a working version is the tree's own refusal to be soothed:
# the module already has a behavioural probe, and it was gated on a noexec home,
# which is not what is wrong here. The probe is what the decision needs, because
# the thing being decided is whether this copy can build.
mkdir -p "$work/proxybin"
cat > "$work/proxybin/rustc" <<'PROXY'
#!/bin/sh
case "${1:-}" in
    --version|-V) echo "rustc 1.99.0 (proxy build 2026-01-01)"; exit 0 ;;
esac
echo "proxy rustc: refusing, not a compiler" >&2
exit 1
PROXY
chmod 0755 "$work/proxybin/rustc"

cat > "$work/proxyprobe.sh" <<EOF
for m in common detect space fetch env toolchain; do
    . "$ROOT/lib/\$m.sh"
done
sh_toolchain_load rust
printf 'BEHAVIOURAL=%s\n' "\$(tc_rust_behavioural >/dev/null 2>&1 && printf 0 || printf 1)"
# The decision, not just the helper: this is what sh_toolchain_ensure asks.
if tc_rust_probe >/dev/null 2>&1; then
    printf 'PROBE=adopt\n'
else
    printf 'PROBE=install\n'
fi
EOF
proxy_probe=$(SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=yes SH_DRY_RUN=1 SH_SELF=test \
    PATH="$work/proxybin:$PATH" sh "$work/proxyprobe.sh" 2>/dev/null)
t_contains "$proxy_probe" 'BEHAVIOURAL=1' \
    'a rustc that refuses to compile fails the behavioural probe despite answering --version'
t_contains "$proxy_probe" 'PROBE=install' \
    'a proxy rustc is not adopted, so a real toolchain is installed instead (#53)'

# The control, which matters as much: a rustc that really compiles must still be
# adopted, or the fix is just "never adopt rust" and every host pays a download.
# It is a stub rather than the host's rustc so the clause means the same thing
# everywhere, including on a host with no compiler at all.
mkdir -p "$work/realbin"
cat > "$work/realbin/rustc" <<'REALC'
#!/bin/sh
case "${1:-}" in
    --version|-V) echo "rustc 1.99.0 (real build)"; exit 0 ;;
esac
# -o FILE: write a runnable program, which is what the probe actually checks.
out=./a.out
prev=''
for a in "$@"; do
    [ "$prev" = -o ] && out=$a
    prev=$a
done
printf '#!/bin/sh\nexit 0\n' > "$out" 2>/dev/null || exit 1
chmod 0755 "$out" 2>/dev/null
exit 0
REALC
chmod 0755 "$work/realbin/rustc"
real_probe=$(SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
    SH_HOME_TOOLCHAINS="$work/tc" SH_EXEC="$work/exec" SH_HOME="$work/home" \
    SH_EXEC_BIN="$work/exec/bin" SH_EXEC_VIEWS="$work/exec/views" \
    SH_HOME_TMP="$work/home/tmp" SH_HOME_EXEC=yes SH_DRY_RUN=1 SH_SELF=test \
    PATH="$work/realbin:$PATH" sh "$work/proxyprobe.sh" 2>/dev/null)
t_contains "$real_probe" 'PROBE=adopt' \
    'a rustc that compiles is still adopted, so the probe costs no download'

# # STOP: A TEST COMMAND THAT RAN NOTHING EXITS NON-ZERO. On a network-only
# install the checkout is fetched WITHOUT tests/, so `sandhome selftest` printed
# "no test named X in this checkout" seven times and `sandhome test` printed a
# bare "sh: 0: cannot open .../tests/run.sh: No such file" - and both exited 0.
# A consumer checking a setup with the command the router names was told it
# passed while nothing had run (issue #39).
#
# The exit code is the part that was load-bearing, because the dispatcher ends
# non-zero only on SH_FAILURES: a sh_say plus a `return 2` that nothing reads
# still exits 0. These clauses run the real command against a checkout with no
# tests/ and read the status, not the prose.
tc39=$work/no-tests
mkdir -p "$tc39/lib" "$tc39/bin"
cp "$ROOT/bin/sandhome" "$tc39/bin/sandhome"
for m in common detect space fetch env toolchain shim memexec report; do
    cp "$ROOT/lib/$m.sh" "$tc39/lib/$m.sh"
done
mkdir -p "$tc39/tests"    # the directory is absent in a real network-only
rmdir "$tc39/tests" 2>/dev/null   # checkout; the library-only shape is tested
st_out=$(SANDHOME_REPO_DIR="$tc39" SH_REPO_DIR="$tc39" \
         sh "$tc39/bin/sandhome" selftest 2>&1)
st_rc=$?
if [ "$st_rc" -ne 0 ]; then
    t_ok 0 'selftest exits non-zero on a checkout with no tests/ (#39)'
else
    t_ok 1 "selftest exits non-zero on a checkout with no tests/ (got rc=$st_rc)"
fi
case "$st_out" in
    *network-only*) t_ok 0 'selftest says why it cannot run (#39)' ;;
    *) t_ok 1 "selftest says why it cannot run (got $st_out)" ;;
esac
ts_out=$(SANDHOME_REPO_DIR="$tc39" SH_REPO_DIR="$tc39" \
         sh "$tc39/bin/sandhome" test 2>&1)
ts_rc=$?
if [ "$ts_rc" -ne 0 ]; then
    t_ok 0 'test exits non-zero on a checkout with no tests/run.sh (#39)'
else
    t_ok 1 "test exits non-zero on a checkout with no tests/run.sh (got rc=$ts_rc)"
fi
case "$ts_out" in
    *cannot\ open*) t_ok 1 'test does not leak a raw shell error (#39)' ;;
    *) t_ok 0 'test does not leak a raw shell error (#39)' ;;
esac

# The control: a real checkout still RUNS the suite and still exits 0 when
# green. `selftest shims` is used rather than the whole selftest because the
# whole selftest re-enters this file through `sandhome test`, and a test that
# runs the test suite that is running it does not terminate. The property under
# test is the exit code, and one real test file is enough to hold it.
st_real=$(cd "$ROOT" && sh "$ROOT/tests/unit.sh" >/dev/null 2>&1; printf '%s' "$?")
t_is "$st_real" '0' 'a real checkout still runs its suite and exits 0'

# # STOP: DOCTOR CHECKS THE TOOLCHAINS THE SETUP ASKED FOR. `doctor` is the
# readiness gate ROUTE.md step 2 tells a session to trust, and it only ever
# checked names in INSTALLED or ADOPTED - which are THIS RUN's variables and are
# empty in a fresh process. Measured on a host with no compilers, after
# `bootstrap.sh --toolset languages` reported
#   installed=   adopted=jq ripgrep fd python go   failures=6
#   toolchain.zig= toolchain.mold= toolchain.deno= toolchain.bun= toolchain.rust=
# doctor answered `doctor_failures=0` and exited 0 over six missing toolchains
# (issue #38). The bootstrap now records what it asked for in env.sh and doctor
# reads that file, because sh_env_load deliberately does not source env.sh - it
# rewrites PATH and SANDHOME_*, and reading the VARIABLE was reading nothing.
d38=$work/doc38
mkdir -p "$d38/home" "$d38/exec/views"
# The name has to be a REAL toolchain: the loop walks sh_toolchain_available, so
# an invented name is never reached and the clause would pass for the wrong
# reason. jq is present on this host, so the requested-but-absent toolchain is
# zig, which is hidden from the run by putting the directory holding it last and
# removing it from the searched set.
printf 'SANDHOME_WANTED_TOOLCHAINS=%s\n' "'jq zig'" > "$d38/home/env.sh"
# The real call, with the library sourced the way bin/sandhome sources it.
# The version function is stubbed rather than trusted to fail: this host HAS a
# working zig, so tc_zig_version would answer with it and the clause would pass
# for the wrong reason - the doctor check is what is under test, not whether the
# machine happens to own a compiler.
d38_out=$( SH_HOME="$d38/home" SH_EXEC="$d38/exec" SH_EXEC_BIN="$d38/exec/bin" \
    SH_EXEC_VIEWS="$d38/exec/views" SH_HOME_TOOLCHAINS="$d38/tc" \
    SH_HOME_TMP="$d38/tmp" SH_HOME_EXEC=no SH_SELF=test \
    env SANDHOME_REPO_DIR="$ROOT" PATH="$ROOT/bin:$PATH" \
    sh -c 'for m in common detect space fetch env toolchain shim memexec report; do
               . "$SANDHOME_REPO_DIR/lib/$m.sh"
           done
           # Present, but with no version: the state the issue describes.
           sh_toolchain_version() { [ "$1" = zig ] && return 0; printf ""; }
           sh_doctor' 2>&1 )
case "$d38_out" in
    *FAIL\ toolchain_zig*) t_ok 0 'doctor fails on a toolchain the setup asked for and did not get (#38)' ;;
    *) t_ok 1 "doctor fails on a toolchain the setup asked for and did not get (#38) (got $d38_out)" ;;
esac
case "$d38_out" in
    *doctor_failures=0*) t_ok 1 'doctor_failures is not 0 with a requested toolchain missing (#38)' ;;
    *) t_ok 0 'doctor_failures is not 0 with a requested toolchain missing (#38)' ;;
esac
# A toolchain NOT in the requested list is still not a failure, or every host
# would be told it is missing eleven things it never wanted.
case "$d38_out" in
    *FAIL\ toolchain_clang*) t_ok 1 'a toolchain nobody asked for is not a failure (#38)' ;;
    *) t_ok 0 'a toolchain nobody asked for is not a failure (#38)' ;;
esac

# A KEPT PAYLOAD IS NOT DOWNLOADED AGAIN (issue #73). After a tmpfs restart
# the exec view is gone while the home payload survives; the probe reads that
# as "not present" because it answers through the view. The framework must
# rebuild the view from the bytes already here. Fixture: a module whose
# install records that it ran, and a home payload already in place.
cat > "$work/repo/tools/keepme.sh" <<'EOF'
TC_keepme_BINS='bin/keepme'
tc_keepme_probe() { sh_have keepme && keepme --check; }
tc_keepme_install() {
    printf 'downloaded\n' >> "$SH_KEEPME_LOG"
    mkdir -p "$(sh_toolchain_root keepme)/bin" || return 1
    printf '#!/bin/sh\n[ "$1" = --check ] && exit 0\nexit 0\n' > "$(sh_toolchain_root keepme)/bin/keepme"
    chmod 0755 "$(sh_toolchain_root keepme)/bin/keepme"
    return 0
}
EOF
cat > "$work/keep-ensure.sh" <<EOF
for m in common detect space fetch env toolchain; do
    . "$ROOT/lib/\$m.sh"
done
mkdir -p "\$SH_EXEC_BIN" "\$SH_EXEC_VIEWS" "\$SH_HOME_TOOLCHAINS" "\$SH_HOME_TMP" 2>/dev/null
sh_toolchain_ensure "\$1"
echo "STATUS=\$?"
EOF
run_keep() {
    SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" \
    SH_HOME_TOOLCHAINS="$work/ktc" SH_EXEC="$work/kexec" SH_HOME="$work/khome" \
    SH_EXEC_BIN="$work/kexec/bin" SH_EXEC_VIEWS="$work/kexec/views" \
    SH_HOME_TMP="$work/khome/tmp" SH_HOME_EXEC=no SH_DRY_RUN=0 SH_SELF=test \
    SH_KEEPME_LOG="$work/dl.log" \
    sh "$work/keep-ensure.sh" "$1"
}
# The payload survives in the home; the view is absent (fresh kexec).
mkdir -p "$work/ktc/keepme/bin" "$work/khome/tmp"
printf '#!/bin/sh\n[ "$1" = --check ] && exit 0\nexit 0\n' > "$work/ktc/keepme/bin/keepme"
chmod 0755 "$work/ktc/keepme/bin/keepme"
rm -f "$work/dl.log"
keep_out=$(run_keep keepme 2>&1)
t_contains "$keep_out" 'STATUS=0' 'a kept payload rebuilds its view without failing'
t_contains "$keep_out" 'without downloading' 'the reuse says it did not download (#73)'
case "$(cat "$work/dl.log" 2>/dev/null)" in
    *downloaded*) t_ok 1 'no download ran for a kept payload' ;;
    *) t_ok 0 'no download ran for a kept payload' ;;
esac
t_ok "$([ -x "$work/kexec/bin/keepme" ]; echo $?)" 'the rebuilt view is on the exec bin'
# A half-written payload fails the probe and falls back to a real install.
rm -rf "$work/ktc/keepme" "$work/kexec"
mkdir -p "$work/ktc/keepme/bin" "$work/khome/tmp"
printf '#!/bin/sh\nexit 3\n' > "$work/ktc/keepme/bin/keepme"
chmod 0755 "$work/ktc/keepme/bin/keepme"
rm -f "$work/dl.log"
keep_out2=$(run_keep keepme 2>&1)
t_contains "$keep_out2" 'STATUS=0' 'a corrupt kept payload still ends installed, via download'
t_contains "$keep_out2" 'downloading a fresh copy' 'the fallback names the fresh download (#73)'
case "$(cat "$work/dl.log" 2>/dev/null)" in
    *downloaded*) t_ok 0 'the fallback ran a real download' ;;
    *) t_ok 1 'the fallback ran a real download' ;;
esac

# A PROJECT RUNS ON A NOEXEC WORK TREE (issue #74). `sandhome project NAME`
# creates the project on the exec root, links ./NAME to it, and sets up the
# venv and the npm project inside - the one dance instead of three. Fakes
# stand in for uv, node and npm; what is asserted is placement, linking and
# the refusal shapes, not the real tools.
mkdir -p "$work/fakeproj/bin"
printf '#!/bin/sh\nmkdir -p "$2/bin"\n: > "$2/bin/python"\nchmod 0755 "$2/bin/python"\n' > "$work/fakeproj/bin/uv"
chmod 0755 "$work/fakeproj/bin/uv"
printf '#!/bin/sh\nexit 0\n' > "$work/fakeproj/bin/node"
chmod 0755 "$work/fakeproj/bin/node"
printf '#!/bin/sh\n: > ./package.json\n' > "$work/fakeproj/bin/npm"
chmod 0755 "$work/fakeproj/bin/npm"
run_project() {
    SANDHOME_HOME="$work/phome" SANDHOME_EXEC="$work/pexec" SANDHOME_REPO_DIR="$ROOT" \
    PATH="$work/fakeproj/bin:/usr/bin:/bin" \
    sh "$ROOT/bin/sandhome" project "$@"
}
mkdir -p "$work/pwork"
proj_out=$(cd "$work/pwork" && run_project demo 2>&1)
proj_rc=$?
t_is "$proj_rc" 0 'project exits 0 when both halves set up'
t_ok "$([ -d "$work/pexec/projects/demo" ]; echo $?)" 'the project lives on the exec root'
t_ok "$([ -L "$work/pwork/demo" ]; echo $?)" './NAME links to the project'
t_ok "$([ -x "$work/pexec/projects/demo/.venv/bin/python" ]; echo $?)" 'the venv python stands in the project'
t_ok "$([ -f "$work/pexec/projects/demo/package.json" ]; echo $?)" 'npm init ran in the project'
case "$proj_out" in
    *'native CLIs'*) t_ok 0 'the summary names native CLIs' ;;
    *) t_ok 1 'the summary names native CLIs' ;;
esac
proj_out2=$(cd "$work/pwork" && run_project demo 2>&1)
t_is "$?" 0 'a second project run is a no-op success'
case "$proj_out2" in
    *'already links'*) t_ok 0 'the second run names the existing link' ;;
    *) t_ok 1 'the second run names the existing link' ;;
esac
if ( cd "$work/pwork" && run_project '../evil' >/dev/null 2>&1 ); then
    t_ok 1 'a NAME that escapes the directory is refused'
else
    t_ok 0 'a NAME that escapes the directory is refused'
fi
t_ok "$([ ! -e "$work/pexec/projects/evil" ]; echo $?)" 'the refused NAME created nothing'
proj_node=$(cd "$work/pwork" && run_project --node jsonly 2>&1)
t_is "$?" 0 'project --node exits 0'
t_ok "$([ ! -e "$work/pexec/projects/jsonly/.venv" ]; echo $?)" '--node sets up no venv'
proj_bare=$(cd "$work/pwork" && SANDHOME_HOME="$work/phome" SANDHOME_EXEC="$work/pexec" \
    SANDHOME_REPO_DIR="$ROOT" PATH="/usr/bin:/bin" \
    sh "$ROOT/bin/sandhome" project --node barejs 2>&1)
case "$proj_bare" in
    *'half skipped'*) t_ok 0 'a missing toolchain skips its half with a warning' ;;
    *) t_ok 1 "a missing toolchain skips its half with a warning (got: $proj_bare)" ;;
esac
t_is "$?" 0 'the skipped half still exits 0'

# THE REQUEST IS PRICED BEFORE ANYTHING IS SPENT (issue #75). One feas
# line per toolchain plus a total, all on stderr; names that do not fit
# are refused before any fit name installs. The free space is stubbed
# small, so a big module lands infeasible without touching a disk.
cat > "$work/repo/tools/huge.sh" <<'EOF'
TC_huge_DESC='a big fixture'
TC_huge_BINS='bin/huge'
TC_huge_EXEC_MB=500
tc_huge_probe() { return 1; }
tc_huge_install() { return 0; }
EOF
cat > "$work/repo/tools/tiny.sh" <<'EOF'
TC_tiny_DESC='a small fixture'
TC_tiny_BINS='bin/tiny'
TC_tiny_EXEC_MB=4
tc_tiny_probe() { return 1; }
tc_tiny_install() { return 0; }
EOF
cat > "$work/feas-driver.sh" <<EOF
for m in common detect space fetch env toolchain memexec; do
    . "$ROOT/lib/\$m.sh"
done
sh_free_mb() { printf '100'; }
sh_space_max_exec_free() { printf '100'; }
SH_EXEC=/nowhere
SH_HOME_TOOLCHAINS=/nowhere-tc
SH_HOME_TMP="$work"
SH_EXEC_VIEWS=/nowhere-views
SH_VIEW_MODE=copy
sh_feasibility_plan huge tiny nosuchmod
printf 'FEASIBLE=[%s]\n' "\$SH_FEASIBLE"
printf 'INFEASIBLE=[%s]\n' "\$SH_INFEASIBLE"
EOF
feas_out=$(SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" sh "$work/feas-driver.sh" 2>&1)
t_contains "$feas_out" 'feas huge need_mb=500 free_mb=100 fit=no' \
    'a toolchain bigger than the root is infeasible (#75)'
t_contains "$feas_out" 'feas tiny need_mb=4 free_mb=100 fit=yes' \
    'a toolchain smaller than the root is feasible'
t_contains "$feas_out" 'feas nosuchmod need_mb=unknown' \
    'an unknown name prints unknown, not an invented number'
t_contains "$feas_out" 'total_exec_need_mb=504 max_exec_free_mb=100' \
    'the total sums the priced needs against the ceiling'
case "$feas_out" in
    *'FEASIBLE=[tiny nosuchmod]'*) t_ok 0 'only the fit names stay feasible' ;;
    *) t_ok 1 "only the fit names stay feasible (got: $feas_out)" ;;
esac
case "$feas_out" in
    *'INFEASIBLE=[huge]'*) t_ok 0 'the no-fit name is refused up front' ;;
    *) t_ok 1 "the no-fit name is refused up front (got: $feas_out)" ;;
esac
# THE COPY LIST PRICES TOO. A copy-listed payload lands as real bytes, so
# pricing it as a launcher under-reads a hundredfold (measured: rust priced
# 198KB for a 17MB view, because the list resolves only inside the promote).
# Fixture: a 1MB payload named by tc_big_copy_bins; the estimate must hold
# megabytes, not the template's kilobytes plus headroom.
cat > "$work/repo/tools/bigc.sh" <<'EOF'
TC_bigc_BINS='bin/bigc'
TC_bigc_EXEC_MB=9999
tc_bigc_probe() { return 1; }
tc_bigc_install() { return 0; }
tc_bigc_copy_bins() { printf 'bin/bigc'; }
EOF
mkdir -p "$work/bigtc/bigc/bin"
dd if=/dev/urandom of="$work/bigtc/bigc/bin/bigc" bs=1k count=1024 2>/dev/null
chmod 0755 "$work/bigtc/bigc/bin/bigc"
bigc_wait=0
while [ "$bigc_wait" -lt 30 ]; do
    bigc_kb=$(du -sk "$work/bigtc/bigc/bin/bigc" 2>/dev/null | { read -r bigc_k _ || :; printf '%s' "$bigc_k"; })
    case "$bigc_kb" in ''|*[!0-9]*) bigc_kb=0 ;; esac
    [ "$bigc_kb" -gt 512 ] && break
    sleep 2
    bigc_wait=$((bigc_wait + 2))
done
cat > "$work/bigc-driver.sh" <<EOF
for m in common detect space fetch env toolchain memexec; do
    . "$ROOT/lib/\$m.sh"
done
SH_HOME_TOOLCHAINS="$work/bigtc"
SH_EXEC_VIEWS="$work/noviews"
SH_HOME_TMP="$work"
SH_VIEW_MODE=launch
printf 'need=%s\n' "\$(sh_toolchain_exec_mb bigc 2>/dev/null)"
EOF
bigc_out=$(SH_LIB_DIR="$work/repo/lib" SH_REPO_DIR="$work/repo" sh "$work/bigc-driver.sh" 2>&1)
bigc_need=$(printf '%s' "$bigc_out" | sed -n 's/^need=//p')
case "$bigc_need" in
    ''|*[!0-9]*) t_ok 1 'the copy-listed payload is priced' ;;
    *)
        if [ "$bigc_need" -ge 21 ]; then
            t_ok 0 'the copy-listed payload is priced at its real megabytes'
        else
            t_ok 1 "the copy-listed payload is priced at its real megabytes (got $bigc_need)"
        fi ;;
esac

# qemuuser: a module for the static user-mode emulators. Two things are asserted
# here that no other module has: the tag is RESOLVED rather than hardcoded (#105),
# and the two capabilities the module exists for actually work -- running a
# binary from a noexec tree, and tracing syscalls without ptrace. The network
# fetch is NOT asserted: a test that needs the Electrosphere is a test that
# skips, and the module contract can be checked without one.
cat > "$work/repo/tools/qemuuser.sh" <<'EOF'
TC_qemuuser_DESC='qemu-user test module'
TC_qemuuser_BINS='bin/qemu-x86_64'
TC_qemuuser_EXEC_MB=12
tc_qemuuser_probe() { sh_have qemu-x86_64 && qemu-x86_64 --version >/dev/null 2>&1; }
tc_qemuuser_install() { return 0; }
tc_qemuuser_env() { return 0; }
tc_qemuuser_version() { sh_have qemu-x86_64 && qemu-x86_64 --version 2>/dev/null | sed -n '1s/.*version //p'; }
EOF
. "$ROOT/lib/toolchain.sh" 2>/dev/null || true
SH_REPO_DIR="$work/repo" SH_LIB_DIR="$ROOT/lib"
export SH_REPO_DIR SH_LIB_DIR
t_is "$(sh_toolchain_known qemuuser && echo yes)" 'yes' 'a module dropped in tools/ is known by name'
# BINS is read the way the promote step reads it, through the loader, because
# the variable is only set after the module is sourced.
sh_toolchain_load qemuuser >/dev/null 2>&1
t_is "$(eval "printf '%s' \"\${TC_qemuuser_BINS:-}\"")" 'bin/qemu-x86_64' 'its declared binaries are read'
# The declared constant is read through the module loader and compared to the
# file, because sh_toolchain_exec_mb answers a MEASURED figure once a root
# exists and this module has none here.
sh_toolchain_load qemuuser >/dev/null 2>&1
t_is "$(eval "printf '%s' \"\${TC_qemuuser_EXEC_MB:-}\"")" '12' 'its declared exec size is read'

# NO HARDCODED VERSION IN THE MODULE. The tag must come from the API at install
# time; a literal here is the rot shape #105 names. The check is textual on
# purpose: it is the file's content that decays, not its behaviour today.
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *releases/download/v[0-9]*) t_ok 1 'the module does not hardcode a release tag' ;;
    *) t_ok 0 'the module does not hardcode a release tag' ;;
esac

# The module must resolve the tag through the proxy, and must send a curl-like
# agent: the endpoint answers 420 without one. Both are asserted by reading the
# module, because the fetch itself needs the network.
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *api.cb.pkgforge.dev*) t_ok 0 'the module resolves the newest tag from the Forgejo API' ;;
    *) t_ok 1 'the module resolves the newest tag from the Forgejo API' ;;
esac
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *"api.rv.pkgforge.dev"*) t_ok 0 'it fetches the asset through the arbitrary-URL passthrough' ;;
    *) t_ok 1 'it fetches the asset through the arbitrary-URL passthrough' ;;
esac

# CAPABILITY, when a real qemu-x86_64 is on PATH: a static binary in a directory
# that refuses exec must run under it. This is the whole reason the module is in
# the tree, so it is asserted rather than described.
if command -v qemu-x86_64 >/dev/null 2>&1 && command -v cc >/dev/null 2>&1; then
    cat > "$work/g.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("qemuuser-ran\n"); return 0; }
EOF
    cc -static -O2 -o "$work/g" "$work/g.c" 2>/dev/null
    if [ -x "$work/g" ]; then
        t_ok "$([ "$(qemu-x86_64 "$work/g" 2>/dev/null)" = 'qemuuser-ran' ]; echo $?)" \
            'a static guest runs under qemu-x86_64'
        # -strace prints the guest's syscalls with no ptrace involved.
        case "$(qemu-x86_64 -strace "$work/g" 2>&1)" in
            *write*|*brk*) t_ok 0 '-strace reports the guest syscalls without ptrace' ;;
            *) t_ok 1 '-strace reports the guest syscalls without ptrace' ;;
        esac
    else
        echo '  skip  the guest probe needs a working static cc'
    fi
else
    echo '  skip  qemu-x86_64 is not on PATH here'
fi



# The guest set is opt-in and BINS must end up listing what reached disk. Both
# halves matter: without the append a promoted qemu-aarch64 sits in the home and
# never reaches PATH, and a name that failed to copy must not be promised.
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *SANDHOME_QEMUUSER_EXTRA*) t_ok 0 'the guest emulator set is opt-in' ;;
    *) t_ok 1 'the guest emulator set is opt-in' ;;
esac
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'TC_qemuuser_BINS="$TC_qemuuser_BINS'*) t_ok 0 'BINS is extended to what actually copied' ;;
    *) t_ok 1 'BINS is extended to what actually copied' ;;
esac
# All 33 emulators is 274MB of view; a module that promotes them unconditionally
# is the mistake the archive invites, so the module must not contain the loop
# that copies every bin/*.
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'cp "$sh_qu_dir/bin/"*'*) t_ok 1 'the module does not promote all 33 emulators' ;;
    *) t_ok 0 'the module does not promote all 33 emulators' ;;
esac

# END TO END, when zig and qemu-aarch64 are both present: cross-compile a guest
# and run it. This is the whole cross-architecture story on a host with no cross
# toolchain, so it is executed rather than described -- and skipped, loudly, when
# either half is absent.
if command -v qemu-aarch64 >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
    cat > "$work/g64.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("cross-ok\n"); return 0; }
EOF
    # # STOP: A BARE `zig cc` FAILS ON THIS MACHINE, AND THAT IS #77, NOT THE
    # TEST. The view hands zig a /memfd: launcher, so its install-dir lookup
    # cannot find lib/ and every subcommand that needs it exits. The workaround
    # is a real directory containing the binary beside a lib/ symlink, so the
    # clause tries that shape first and only then gives up.
    zigcc=zig
    if ! ( cd "$work" && timeout 300 zig cc --target=aarch64-linux-musl -O2 -o g64 g64.c ) >/dev/null 2>&1; then
        # A REAL distribution has lib/ beside the binary; the view's launcher does
        # not, and picking it first would reproduce the same failure.
        # The view ALSO has a lib/, so having one is not enough to tell a real
        # distribution from the memexec launcher that sits in front of it. The
        # launcher is a few kilobytes and the real zig is tens of megabytes, so
        # the size is what separates them.
        for cand in $(find "${SANDHOME_EXEC:-/tmp}" /dev/shm /workspace -maxdepth 3 -type f -name zig 2>/dev/null); do
            if [ -d "${cand%/*}/lib" ] && [ -f "${cand%/*}/lib/std/std.zig" ]; then
                csz=$(wc -c < "$cand" 2>/dev/null || echo 0)
                if [ "$csz" -gt 1000000 ]; then
                    zigcc=$cand
                    break
                fi
            fi
        done
    fi
    if ( cd "$work" && timeout 300 "$zigcc" cc --target=aarch64-linux-musl -O2 -o g64 g64.c ) >/dev/null 2>&1 \
       && [ -f "$work/g64" ]; then
        case "$(file "$work/g64" 2>/dev/null)" in
            *aarch64*) t_ok 0 'zig cross-compiles an aarch64 guest with its bundled sysroot' ;;
            *)         t_ok 1 'zig cross-compiles an aarch64 guest with its bundled sysroot' ;;
        esac
        # The guest emulator is OPT-IN (SANDHOME_QEMUUSER_EXTRA), so its absence
        # is a configuration, not a defect: say so rather than failing a clause
        # for a machine that did not ask for it.
        # # STOP: `command -v` IS NOT ENOUGH, AND ISSUE #110 IS WHY. A view
        # launcher whose payload was pruned still resolves through `command -v`
        # -- the stale entry survives on PATH -- and only fails when run. So the
        # precondition is "it actually runs", not "it resolves", or this clause
        # fails on a machine where the guest emulator is simply not installed.
        qa_ok=no
        if command -v qemu-aarch64 >/dev/null 2>&1 && qemu-aarch64 --version >/dev/null 2>&1; then
            qa_ok=yes
        fi
        if [ "$qa_ok" = yes ]; then
            t_ok "$([ "$(qemu-aarch64 "$work/g64" 2>/dev/null)" = 'cross-ok' ]; echo $?)" \
                'qemu-aarch64 runs the cross-compiled guest'
        else
            echo '  skip  qemu-aarch64 is not installed here (set SANDHOME_QEMUUSER_EXTRA=aarch64)'
        fi
    else
        echo '  skip  zig could not cross-compile here (may want its install dir)'
    fi
else
    echo '  skip  zig or qemu-aarch64 is not on PATH here'
fi


# The promotion must mirror the module's BINS, not accumulate. qemuuser is the
# first module whose BINS can shrink (SANDHOME_QEMUUSER_EXTRA), which exposes a
# direction the tree never had to handle: a re-install that asks for fewer
# guests must not leave the previous guest's launcher on PATH. This is issue
# #110 at the module level, and the clause is here because the module is what
# made it reachable.
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'START FROM A CLEAN BIN'*) t_ok 0 'a re-install clears the bin directory first' ;;
    *) t_ok 1 'a re-install clears the bin directory first' ;;
esac
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'the archive did not contain bin/$sh_qu_host'*) t_ok 0 'the missing-emulator check names the host emulator, not two hardcoded names' ;;
    *) t_ok 1 'the missing-emulator check names the host emulator, not two hardcoded names' ;;
esac
cat > "$work/guest.c" <<'EOF'
int main(void){ return 0; }
EOF
if command -v qemu-x86_64 >/dev/null 2>&1; then
    # A guest binary with no payload behind it must fail; the point is that the
    # launcher is not left promising something that was removed.
    printf 'not an elf\n' > "$work/notelf"
    qemu-x86_64 "$work/notelf" >/dev/null 2>&1
    t_ok "$([ $? -ne 0 ]; echo $?)" 'a launcher does not report success for a guest it cannot run'
fi


# The module must honour its guest set on the "payload already present, rebuild
# the view" path too, not only inside install. That path skips tc_qemuuser_install
# entirely, so a guest whose payload is on disk was dropped from BINS on every
# re-run and its launcher vanished from the view even though the payload still
# backed it. Reading the bin directory at load time is what fixes it.
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'tc_qemuuser_bins_from_disk'*) t_ok 0 'BINS is rebuilt from the payload on every load, not only on install' ;;
    *) t_ok 1 'BINS is rebuilt from the payload on every load, not only on install' ;;
esac
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'not installed; run'*) t_ok 0 'a guest that is requested but absent is named with the remedy' ;;
    *) t_ok 1 'a guest that is requested but absent is named with the remedy' ;;
esac

# The improved module answers the same contract with more fallbacks. Loading
# is silent: every command sources every module, so a warning at source time
# about a guest nobody asked this command about is noise on `sandhome help`.
# The missing guests are recorded and named once from the probe instead.
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'LOADING IS SILENT'*) t_ok 0 'loading the module warns about nothing' ;;
    *) t_ok 1 'loading the module warns about nothing' ;;
esac
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'sh_have wget'*) t_ok 0 'the tag resolve falls back to wget' ;;
    *) t_ok 1 'the tag resolve falls back to wget' ;;
esac
case "$(cat "$ROOT/tools/qemuuser.sh")" in
    *'tc_qemuuser_extract'*) t_ok 0 'unpacking survives a tar without lzma' ;;
    *) t_ok 1 'unpacking survives a tar without lzma' ;;
esac
# The tag parser reads with the shell, not sed: the module installs onto a
# userland whose bootstrap has not provided anything yet.
sh_qtu_tag=$(SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" sh -c '. "$1/lib/common.sh"; . "$1/lib/fetch.sh"; . "$1/tools/qemuuser.sh" >/dev/null 2>&1; tc_qemuuser_tag_from_body "{\"tag_name\":\"9.9.9\",\"x\":1}"' sh "$ROOT" 2>/dev/null)
t_is "$sh_qtu_tag" '9.9.9' 'the tag parser reads tag_name without helpers'
sh_qtu_tag=$(SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" sh -c '. "$1/lib/common.sh"; . "$1/lib/fetch.sh"; . "$1/tools/qemuuser.sh" >/dev/null 2>&1; tc_qemuuser_tag_from_body "{\"nope\":1}"' sh "$ROOT" 2>/dev/null)
t_is "$sh_qtu_tag" '' 'the tag parser answers nothing when there is no tag'

# ShellCheck, the linter, as a first-class module like any other: known by
# name, with declared bins, installable offline in dry-run, and pinned.
SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" sh_toolchain_known shellcheck 2>/dev/null || true
t_is "$(sh_toolchain_known shellcheck && echo yes)" 'yes' 'the shellcheck module is known by name'
sh_toolchain_load shellcheck >/dev/null 2>&1
t_is "$(eval "printf '%s' \"\${TC_shellcheck_BINS:-}\"")" 'bin/shellcheck' 'its declared binaries are read'
case " $(sh_pin_names) " in
    *' shellcheck '*) t_ok 0 'shellcheck has a pin-table entry' ;;
    *) t_ok 1 'shellcheck has a pin-table entry' ;;
esac
case "$(cat "$ROOT/NOTICE")" in
    *'| shellcheck |'*) t_ok 0 'shellcheck is recorded in NOTICE' ;;
    *) t_ok 1 'shellcheck is recorded in NOTICE' ;;
esac

# Single-binary toolchains price their launch-mode view, not their payload:
# a deno install was refused for 150MB its 20KB view never needed (issue #92).
for sh_tmm in deno bun mold; do
    sh_toolchain_load "$sh_tmm" >/dev/null 2>&1
    sh_tmm_mb=$(SH_VIEW_MODE=launch "tc_${sh_tmm}_exec_mb" 2>/dev/null) || sh_tmm_mb=''
    case "$sh_tmm_mb" in
        ''|*[!0-9]*) t_ok 1 "$sh_tmm prices its launch-mode view" ;;
        *) if [ "$sh_tmm_mb" -lt 32 ]; then t_ok 0 "$sh_tmm prices its launch-mode view (${sh_tmm_mb}MB)";
           else t_ok 1 "$sh_tmm prices its launch-mode view (got ${sh_tmm_mb}MB)"; fi ;;
    esac
done
# zig locates its install dir exe-relative through /proc/self/exe, which a
# memfd image hides: it must land as a real copy even in launch mode, or
# every compiler subcommand fails while the probe stays green (issue #77).
sh_toolchain_load zig >/dev/null 2>&1
t_contains "$(tc_zig_copy_bins 2>/dev/null)" 'zig' 'zig is a real copy in launch mode (issue #77)'

t_end
