#!/bin/sh
# python - a self-contained CPython through uv. uv is one static binary and it
# installs a python-build-standalone CPython into the sandhome root, so this
# never touches the system interpreter. Adopted system pythons still get uv on
# the exec view (see tc_python_ensure_uv); when uv cannot be fetched the fragment
# names `python3 -m ensurepip` and venv instead of claiming uv is present.
TC_python_DESC='CPython, installed by uv (uv is always left on PATH)'
TC_python_BINS=''
TC_python_EXEC_MB=30

tc_python_probe() {
    if sh_have python3 && python3 --version >/dev/null 2>&1; then
        return 0
    fi
    if sh_have python && python --version >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

tc_python_install() {
    sh_pi_root=$(sh_toolchain_root python)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_pi_arch='x86_64-unknown-linux-gnu' ;;
        Linux:aarch64|Linux:arm64)  sh_pi_arch='aarch64-unknown-linux-gnu' ;;
        Linux:armv7l)               sh_pi_arch='armv7-unknown-linux-gnueabihf' ;;
        Darwin:x86_64)              sh_pi_arch='x86_64-apple-darwin' ;;
        Darwin:arm64)               sh_pi_arch='aarch64-apple-darwin' ;;
        *) sh_warn "no uv build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_space_need 400 home || return 1
    rm -rf "$sh_pi_root" 2>/dev/null
    mkdir -p "$sh_pi_root/bin" 2>/dev/null || return 1
    sh_pi_url="https://github.com/astral-sh/uv/releases/latest/download/uv-${sh_pi_arch}.tar.gz"
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install uv from $sh_pi_url and CPython 3.12 into $sh_pi_root"
        return 0
    fi
    if ! sh_fetch_unpack "$sh_pi_url" "$sh_pi_root/uv"; then
        sh_warn 'could not fetch or unpack uv'
        return 1
    fi
    # The archive's uv and uvx are moved to the module's own bin directory.
    for sh_pi_tool in uv uvx; do
        if [ -f "$sh_pi_root/uv/$sh_pi_tool" ]; then
            mv "$sh_pi_root/uv/$sh_pi_tool" "$sh_pi_root/bin/$sh_pi_tool" 2>/dev/null || true
        fi
    done
    rm -rf "$sh_pi_root/uv" 2>/dev/null

    # uv itself must run to install python, so the exec view is built now, before
    # the tool that needs it is used.
    sh_promote_toolchain python >/dev/null 2>&1
    sh_pi_view=$(sh_toolchain_view python)
    sh_pi_uv="$sh_pi_view/bin/uv"
    if [ ! -x "$sh_pi_uv" ]; then
        sh_warn "the promoted uv at $sh_pi_uv does not run"
        return 1
    fi
    mkdir -p "$sh_pi_root/python" "$SH_HOME/cache/uv" 2>/dev/null || true
    # UV_PYTHON_DOWNLOADS=manual: the env.sh this process loaded exports
    # `UV_PYTHON_DOWNLOADS=never` into it, so a plain `install --force python`
    # inherits `never` and uv refuses to fetch the CPython it is explicitly
    # being asked to install — measured: "Python downloads are not allowed
    # (`python-downloads = \"never\"`)", the toolchain root left empty, and
    # the next shell falling back to the system interpreter (issue #174).
    # `manual` permits exactly this explicit install and nothing implicit, so
    # the fragment's hermetic default is unchanged at runtime.
    if ! UV_PYTHON_DOWNLOADS=manual UV_PYTHON_INSTALL_DIR="$sh_pi_root/python" UV_CACHE_DIR="$SH_HOME/cache/uv" \
         "$sh_pi_uv" python install 3.12 >/dev/null 2>&1; then
        sh_warn 'uv could not install CPython 3.12'
        return 1
    fi
    return 0
}

# tc_python_ensure_uv -> 0 when a runnable uv is on the exec view, fetching it
# when missing. The adopted-python path used to return before this, so a host
# with system python and no uv ended with no package manager at all.
tc_python_ensure_uv() {
    if sh_have uv && uv --version >/dev/null 2>&1; then
        sh_promote_toolchain python >/dev/null 2>&1
        return 0
    fi
    sh_pu_root=$(sh_toolchain_root python)
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_pu_arch='x86_64-unknown-linux-gnu' ;;
        Linux:aarch64|Linux:arm64)  sh_pu_arch='aarch64-unknown-linux-gnu' ;;
        Linux:armv7l)               sh_pu_arch='armv7-unknown-linux-gnueabihf' ;;
        Darwin:x86_64)              sh_pu_arch='x86_64-apple-darwin' ;;
        Darwin:arm64)               sh_pu_arch='aarch64-apple-darwin' ;;
        *) sh_warn "no uv build for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_space_need "$TC_python_EXEC_MB" exec || return 1
    mkdir -p "$sh_pu_root/bin" 2>/dev/null || return 1
    sh_pu_url="https://github.com/astral-sh/uv/releases/latest/download/uv-${sh_pu_arch}.tar.gz"
    if ! sh_fetch_unpack "$sh_pu_url" "$sh_pu_root/uv"; then
        sh_warn 'could not fetch or unpack uv for the adopted python'
        return 1
    fi
    for sh_pu_tool in uv uvx; do
        if [ -f "$sh_pu_root/uv/$sh_pu_tool" ]; then
            mv "$sh_pu_root/uv/$sh_pu_tool" "$sh_pu_root/bin/$sh_pu_tool" 2>/dev/null || true
        fi
    done
    rm -rf "$sh_pu_root/uv" 2>/dev/null
    sh_promote_toolchain python bin/uv bin/uvx >/dev/null 2>&1
    sh_have uv && uv --version >/dev/null 2>&1
}

tc_python_env() {
    # Bounded and isolated like every probe: an interpreter that never
    # answers must fail the adoption, not wedge the install. Routes through
    # the framework probe so the isolation applies here too.
    if sh_toolchain_probe python && ! sh_have uv; then
        # Adopted system python with no uv: still provide uv on the exec view
        # without putting the adopted interpreter behind ours. The fragment only
        # carries uv plus cache env, and names ensurepip/venv when uv cannot
        # be fetched.
        if tc_python_ensure_uv; then
            sh_pe_view=$(sh_toolchain_view python)
            mkdir -p "$SH_EXEC/cache/uv" 2>/dev/null || true
            sh_env_write_fragment python <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
UV_CACHE_DIR="\$SANDHOME_EXEC/cache/uv"
UV_TOOL_DIR="\$SANDHOME_EXEC/uv-tools"
UV_TOOL_BIN_DIR="\$SANDHOME_EXEC/uv-bin"
PIP_DISABLE_PIP_VERSION_CHECK=1
export UV_CACHE_DIR UV_TOOL_DIR UV_TOOL_BIN_DIR PIP_DISABLE_PIP_VERSION_CHECK
case ":\$PATH:" in
  *":$sh_pe_view/bin:"*) ;;
  *) PATH="$sh_pe_view/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/uv-bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/uv-bin:\$PATH" ;;
esac
export PATH
EOF
            return 0
        fi
        sh_warn 'adopted python has neither uv nor pip; use python3 -m ensurepip then python3 -m venv (.venv) and . .venv/bin/activate'
        return 0
    fi
    sh_pe_root=$(sh_toolchain_root python)
    # The uv links are named, not swept and not skipped: TC_python_BINS is
    # empty (the interpreter lives behind the fragment's PATH entry), so a
    # bare promote links nothing into the exec bin and the hook never serves
    # uv/uvx, while the description promises uv is always left on PATH. Naming
    # bin/uv bin/uvx here creates the links the hook reads; the promote sweep
    # keeps exactly this set on later installs instead of removing it.
    sh_promote_toolchain python bin/uv bin/uvx >/dev/null 2>&1
    sh_pe_view=$(sh_toolchain_view python)
    sh_pe_bin=''
    for sh_pe_d in "$sh_pe_view"/python/*/bin "$sh_pe_root"/python/*/bin; do
        if [ -x "$sh_pe_d/python3" ] || [ -x "$sh_pe_d/python" ]; then
            sh_pe_bin=$sh_pe_d
            break
        fi
    done
    mkdir -p "$SH_HOME/cache/uv" 2>/dev/null || true
    # Self-sufficient under `set -u`: see tools/go.sh. Which fragment aborts
    # first depends on host state (uv present or not), so the fix is the binding
    # and not one fragment.
    sh_env_write_fragment python <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
UV_PYTHON_INSTALL_DIR="$sh_pe_root/python"
UV_CACHE_DIR="\$SANDHOME_HOME/cache/uv"
UV_TOOL_DIR="\$SANDHOME_EXEC/uv-tools"
UV_TOOL_BIN_DIR="\$SANDHOME_EXEC/uv-bin"
# Guarded, not pinned: an installed CPython is hermetic by default (never
# auto-downloads), but the fragment is also loaded inside the install
# process itself, so a literal never here defeats an operator's explicit
# per-command override and install --force python can never fetch the
# CPython it is reinstalling. Every other policy default in this tree
# (ASAN_OPTIONS, TAR_OPTIONS, XDG_CACHE_HOME) yields to the caller; this
# one does too.
UV_PYTHON_DOWNLOADS="\${UV_PYTHON_DOWNLOADS:-never}"
PIP_DISABLE_PIP_VERSION_CHECK=1
export UV_PYTHON_INSTALL_DIR UV_CACHE_DIR UV_TOOL_DIR UV_TOOL_BIN_DIR UV_PYTHON_DOWNLOADS PIP_DISABLE_PIP_VERSION_CHECK
case ":\$PATH:" in
  *":$sh_pe_view/bin:"*) ;;
  *) PATH="$sh_pe_view/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/uv-bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/uv-bin:\$PATH" ;;
esac
export PATH
EOF
    if [ -n "$sh_pe_bin" ]; then
        cat >> "$(sh_env_fragment python)" <<EOF
case ":\$PATH:" in
  *":$sh_pe_bin:"*) ;;
  *) PATH="$sh_pe_bin:\$PATH" ;;
esac
export PATH
EOF
    fi
    return 0
}

tc_python_version() {
    if sh_have python3; then sh_first_line python3 --version 2>/dev/null; return 0; fi
    if sh_have python;  then sh_first_line python --version 2>/dev/null; return 0; fi
    printf ''
}
