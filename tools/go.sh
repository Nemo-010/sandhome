#!/bin/sh
# go - the Go toolchain, from the official tarball into the sandhome root.
TC_go_DESC='Go, from the official go.dev tarball (GOROOT stays in the home root)'
TC_go_BINS='go/bin/go go/bin/gofmt'

tc_go_probe() {
    sh_have go && go version >/dev/null 2>&1
}

tc_go_version_latest() {
    # # STOP: sh_fetch AND NOT curl, so a machine with only wget still resolves a
    # version. go.dev/VERSION?m=text answers with the version on line one.
    # SANDHOME_GO_VERSION_URL exists so the parser can be tested against a local
    # file, and so a mirror can be pointed at without editing this module.
    sh_gv_url=${SANDHOME_GO_VERSION_URL:-'https://go.dev/VERSION?m=text'}
    sh_gv_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_gv_stage" 2>/dev/null || { printf ''; return 0; }
    sh_gv_file="$sh_gv_stage/.go-version.$$"
    if ! sh_fetch "$sh_gv_url" "$sh_gv_file"; then
        printf ''
        return 0
    fi
    sh_gv_line=$(sh_first_line cat "$sh_gv_file")
    rm -f "$sh_gv_file" 2>/dev/null
    sh_first_word printf '%s' "$sh_gv_line"
}

# tc_go_sha_from FILE FILENAME -> the sha256 go.dev lists for FILENAME, or
# nothing. # STOP: THERE IS NO `.sha256` SIDECAR: https://go.dev/dl/<file>.sha256 is an
# HTML redirect page, so that URL "succeeds" and yields the word `<!DOCTYPE` as a
# digest. The digests are in dl/?mode=json.
#
# NOTE: THE PARSER DOES NOT DEPEND ON THE FORMATTING. The previous version read one
# line at a time and set a "seen" flag on the line carrying `"filename"` and used
# the following line that carried `"sha256"`. That works only when the two keys
# are on separate lines, which is how go.dev pretty-prints today; against a
# compact one-line-per-release document - or any future reformat, or a proxy
# that minifies JSON - the flag was never set, the function answered nothing, and
# the install continued with an EMPTY expected digest. A digest that quietly
# disappears is worse than one that is missing loudly. This reads the whole file
# as one string and pulls the `sha256` that sits inside the same `{...}` object as
# the named `filename`, so leading, trailing and inline whitespace do not matter.
tc_go_sha_from() {
    sh_gs_want=$2
    [ -r "$1" ] || return 1
    sh_gs_all=$(sh_read_file_spaces "$1")
    [ -n "$sh_gs_all" ] || return 1
    sh_gs_scan=$sh_gs_all
    while :; do
        sh_gs_head=${sh_gs_scan#*\"filename\"}
        [ "$sh_gs_head" != "$sh_gs_scan" ] || break
        sh_gs_head=${sh_gs_head#*:}
        sh_gs_rest=$sh_gs_head
        while :; do
            case "$sh_gs_rest" in
                [' ']*) sh_gs_rest=${sh_gs_rest#?} ;;
                *) break ;;
            esac
        done
        case "$sh_gs_rest" in
            *\"*) sh_gs_rest=${sh_gs_rest#\"} ;;
            *) sh_gs_scan=$sh_gs_head; continue ;;
        esac
        sh_gs_val=${sh_gs_rest%%\"*}
        if [ "$sh_gs_val" = "$sh_gs_want" ]; then
            sh_gs_obj=${sh_gs_rest#*\"}
            case "$sh_gs_obj" in
                *\}*) sh_gs_obj=${sh_gs_obj%%\}*} ;;
                *) ;;
            esac
            sh_gs_s=${sh_gs_obj#*\"sha256\"}
            [ "$sh_gs_s" != "$sh_gs_obj" ] || return 1
            sh_gs_s=${sh_gs_s#*:}
            while :; do
                case "$sh_gs_s" in
                    [' ']*) sh_gs_s=${sh_gs_s#?} ;;
                    *) break ;;
                esac
            done
            sh_gs_s=${sh_gs_s#\"}
            sh_gs_d=${sh_gs_s%%\"*}
            [ -n "$sh_gs_d" ] || return 1
            # Shape-validate the manifest field and drop the record if it
            # fails (issue #10): a non-hex or short digest is not compared,
            # it is refused as a record.
            sh_is_hex64 "$sh_gs_d" || return 1
            printf '%s' "$sh_gs_d"
            return 0
        fi
        sh_gs_scan=$sh_gs_rest
    done
    return 1
}

tc_go_install() {
    sh_gi_root=$(sh_toolchain_root go)
    sh_gi_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_gi_stage" 2>/dev/null || return 1
    sh_gi_ver=$(tc_go_version_latest)
    case "$sh_gi_ver" in
        go[0-9]*) ;;
        *)
            sh_warn 'could not resolve the current Go release from go.dev/VERSION'
            return 1
            ;;
    esac
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_gi_os=linux  sh_gi_arch=amd64 ;;
        Linux:aarch64|Linux:arm64)  sh_gi_os=linux  sh_gi_arch=arm64 ;;
        Linux:i386|Linux:i686)      sh_gi_os=linux  sh_gi_arch=386 ;;
        Darwin:x86_64)              sh_gi_os=darwin sh_gi_arch=amd64 ;;
        Darwin:arm64)               sh_gi_os=darwin sh_gi_arch=arm64 ;;
        *) sh_warn "no Go tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    # A Go tarball is about 70MB compressed and 250MB unpacked; the exec view
    # needs room for pkg/tool, which are real executables the go command runs.
    sh_space_need 400 home || return 1
    sh_gi_url="https://go.dev/dl/${sh_gi_ver}.${sh_gi_os}-${sh_gi_arch}.tar.gz"
    if [ "$SH_DRY_RUN" = 1 ]; then
        sh_step "would install $sh_gi_url into $sh_gi_root"
        return 0
    fi
    # go.dev lists the digest in dl/?mode=json; taking it means the download is
    # checked rather than only hashed.
    sh_gi_sha=''
    sh_gi_json="$sh_gi_stage/.go-json.$$"
    if sh_fetch "${SANDHOME_GO_DL_JSON_URL:-https://go.dev/dl/?mode=json}" "$sh_gi_json"; then
        sh_gi_sha=$(tc_go_sha_from "$sh_gi_json" "${sh_gi_ver}.${sh_gi_os}-${sh_gi_arch}.tar.gz")
    fi
    rm -f "$sh_gi_json" 2>/dev/null
    rm -rf "$sh_gi_root" 2>/dev/null
    mkdir -p "$sh_gi_root" 2>/dev/null || return 1
    sh_gi_tar="$sh_gi_stage/go-$sh_gi_ver.tar.gz"
    if ! sh_fetch_verified "$sh_gi_url" "$sh_gi_tar" "$(sh_pin_for "$sh_gi_url" go "$sh_gi_sha")"; then
        return 1
    fi
    if ! sh_untar "$sh_gi_tar" "$sh_gi_root"; then
        sh_warn "could not unpack $sh_gi_tar"
        rm -f "$sh_gi_tar" 2>/dev/null
        return 1
    fi
    rm -f "$sh_gi_tar" 2>/dev/null
    if [ ! -x "$sh_gi_root/go/bin/go" ]; then
        sh_warn "the Go archive did not put go at $sh_gi_root/go/bin/go"
        return 1
    fi
    return 0
}

tc_go_env() {
    sh_ge_view=$(sh_toolchain_view go)
    sh_ge_root="$sh_ge_view/go"
    # An adopted system go has no sandhome root. Pointing GOROOT at a tree that
    # was never installed would break a toolchain that works, so its own
    # environment is left alone.
    if [ ! -x "$(sh_toolchain_root go)/go/bin/go" ]; then
        return 0
    fi
    mkdir -p "$SH_EXEC/tmp" "$SH_EXEC/cache/go-build" 2>/dev/null || true
    # # STOP: GOCACHE IS ON THE EXEC ROOT, NOT THE HOME. `go run` and `go test` build
    # an executable into the build cache and then execve it; a cache on a noexec
    # home made every one of them fail with `fork/exec ... permission denied`
    # after a successful compile. Downloads and the module cache are data and stay
    # in the home.
    sh_env_write_fragment go <<EOF
GOROOT="$sh_ge_root"
GOPATH="\$SANDHOME_HOME/go"
GOCACHE="\$SANDHOME_EXEC/cache/go-build"
GOTMPDIR="$SH_EXEC/tmp"
export GOROOT GOPATH GOCACHE GOTMPDIR
case ":\$PATH:" in
  *":$sh_ge_root/bin:"*) ;;
  *) PATH="$sh_ge_root/bin:\$PATH" ;;
esac
export PATH
EOF
    return $?
}

tc_go_version() {
    if sh_have go; then go env GOVERSION 2>/dev/null; fi
}
