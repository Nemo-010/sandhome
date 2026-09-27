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

t_end
