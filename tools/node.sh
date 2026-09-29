#!/bin/sh
# node - Node.js and its bundled npm, from nodejs.org.
TC_node_DESC='Node.js with the bundled npm, from the official nodejs.org tarball'
# npm AND npx ARE NAMED, NOT LEFT TO THE FRAGMENT. They are the two commands a
# caller reaches for immediately after node, and both live in the tarball's bin
# directory. Naming them here means the promote step links them into the shared
# exec bin next to node, so `npm` is on PATH from a shell that read only env.sh
# and never sourced the module's own fragment.
TC_node_BINS='bin/node bin/npm bin/npx'
TC_node_EXEC_MB=200

# tc_node_exec_mb -> the fresh-install exec need in MB: 16 in launch mode
# (launcher copies for node, npm and npx; the tree measured 5MB), 200 in copy
# mode (the full tree). Read by the install gate below and the feasibility
# plan so the two never disagree (issues #92, #105).
tc_node_exec_mb() {
    if [ "${SH_VIEW_MODE:-copy}" = launch ]; then
        printf '16'
    else
        printf '200'
    fi
}

tc_node_probe() {
    sh_have node && node --version >/dev/null 2>&1
}

# STOP: THE `latest/` REDIRECT NAMES A TRAIN, NOT A VERSION. nodejs.org/dist/latest/
# lands on `dist/latest-v24.x/`, a directory, so the version is read from
# index.json, whose first entry is the newest release. Measured 2026-09-27: the
# redirect target was https://nodejs.org/dist/latest-v24.x/ and it carried no
# version, so the old rule resolved nothing and the install refused.
tc_node_latest_tag() {
    sh_nt_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_nt_stage" 2>/dev/null || { printf ''; return 0; }
    sh_nt_file="$sh_nt_stage/.node-index.$$"
    # SANDHOME_NODE_INDEX_URL exists so the parser can be tested against a local
    # file, and so a mirror can be pointed at without editing this module.
    if ! sh_fetch "${SANDHOME_NODE_INDEX_URL:-https://nodejs.org/dist/index.json}" "$sh_nt_file"; then
        printf ''
        return 0
    fi
    # # STOP: THE FILE IS PRETTY-PRINTED. Line one is `[` and the first entry begins on
    # line two, so the version is the first line that carries one, not the first
    # line of the file. Measured 2026-09-27: index.json began `[\n{"version":"v26.10.0"`.
    sh_nt_tag=''
    while IFS= read -r sh_nt_line || [ -n "$sh_nt_line" ]; do
        case "$sh_nt_line" in
            *'"version":"'*)
                sh_nt_rest=${sh_nt_line#*'"version":"'}
                sh_nt_tag=${sh_nt_rest%%\"*}
                break
                ;;
        esac
    done < "$sh_nt_file"
    rm -f "$sh_nt_file" 2>/dev/null
    printf '%s' "$sh_nt_tag"
}

tc_node_install() {
    sh_ni_root=$(sh_toolchain_root node)
    sh_ni_tag=$(tc_node_latest_tag)
    case "$sh_ni_tag" in
        v[0-9]*) ;;
        *) sh_warn 'could not resolve the current Node.js release'; return 1 ;;
    esac
    case "${SH_KERNEL:-unknown}:${SH_ARCH:-unknown}" in
        Linux:x86_64|Linux:amd64)   sh_ni_os=linux  sh_ni_arch=x64 ;;
        Linux:aarch64|Linux:arm64)  sh_ni_os=linux  sh_ni_arch=arm64 ;;
        Linux:armv7l)               sh_ni_os=linux  sh_ni_arch=armv7l ;;
        Darwin:x86_64)              sh_ni_os=darwin sh_ni_arch=x64 ;;
        Darwin:arm64)               sh_ni_os=darwin sh_ni_arch=arm64 ;;
        *) sh_warn "no Node.js tarball for ${SH_KERNEL:-unknown} ${SH_ARCH:-unknown}"; return 1 ;;
    esac
    sh_ni_name="node-${sh_ni_tag}-${sh_ni_os}-${sh_ni_arch}"
    sh_ni_base="https://nodejs.org/dist/${sh_ni_tag}"
    sh_ni_url="$sh_ni_base/${sh_ni_name}.tar.xz"
    sh_ni_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_ni_stage" 2>/dev/null || return 1
    sh_space_need 300 home || return 1
    # The exec view holds the node runtime plus npm/npx and their tree (about
    # 163MB measured, up to ~244MB with the bundled npm). Gate it the same way
    # as go (issue #66): a home-only check let the install succeed into a root
    # the view did not fit. Mode-aware: launch mode holds launcher copies
    # (5MB measured), copy mode the tree above.
    sh_space_need "$(tc_node_exec_mb)" exec || return 1

    sh_ni_sha=''
    if sh_have curl || sh_have wget; then
        sh_ni_sums="$sh_ni_stage/node-SHASUMS256.$$"
        if sh_fetch "$sh_ni_base/SHASUMS256.txt" "$sh_ni_sums"; then
            # Shape-validate every manifest field and drop the record if any
            # one fails (issue #10); carry the last line out of read so a
            # file with no trailing newline still yields its entry.
            while read -r sh_ni_hex sh_ni_file || [ -n "$sh_ni_hex" ]; do
                case "$sh_ni_file" in
                    *"${sh_ni_name}.tar.xz")
                        if sh_is_hex64 "$sh_ni_hex" && sh_is_nonempty "$sh_ni_file"; then
                            sh_ni_sha=$sh_ni_hex
                        fi
                        break ;;
                esac
            done < "$sh_ni_sums"
            rm -f "$sh_ni_sums" 2>/dev/null
        fi
    fi

    rm -rf "$sh_ni_root" 2>/dev/null
    mkdir -p "$sh_ni_root" 2>/dev/null || return 1
    sh_ni_tar="$sh_ni_stage/${sh_ni_name}.tar.xz"
    if ! sh_fetch_verified "$sh_ni_url" "$sh_ni_tar" "$(sh_pin_for "$sh_ni_url" node "$sh_ni_sha")"; then
        return 1
    fi
    if ! sh_untar "$sh_ni_tar" "$sh_ni_root"; then
        sh_warn "could not unpack $sh_ni_tar"
        rm -f "$sh_ni_tar" 2>/dev/null
        return 1
    fi
    rm -f "$sh_ni_tar" 2>/dev/null
    # The archive's one top-level directory becomes the root's bin/lib/content.
    if [ -d "$sh_ni_root/$sh_ni_name" ]; then
        sh_ni_inner="$sh_ni_root/$sh_ni_name"
        for sh_ni_e in "$sh_ni_inner"/* "$sh_ni_inner"/.[!.]*; do
            [ -e "$sh_ni_e" ] || continue
            mv "$sh_ni_e" "$sh_ni_root/" 2>/dev/null || true
        done
        rmdir "$sh_ni_inner" 2>/dev/null || true
    fi
    if [ ! -x "$sh_ni_root/bin/node" ]; then
        sh_warn "the Node.js archive did not put node at $sh_ni_root/bin/node"
        return 1
    fi
    # # NOTE: EVERY DECLARED BINARY IS CHECKED IN THE ARCHIVE, AND ITS TARGET IS
    # CHECKED TOO. `npm` and `npx` are symlinks into lib/node_modules; an
    # archive that shipped the link without the target, or a future release that
    # renamed them, would otherwise install "without an error" and fail inside
    # the first build. A broken symlink is a file that is present and is not a
    # file at all, and `[ -x ]` on it is false, so the check is the same one.
    for sh_ni_need in node npm npx; do
        if [ ! -x "$sh_ni_root/bin/$sh_ni_need" ]; then
            sh_warn "the Node.js archive did not put a working $sh_ni_need at bin/$sh_ni_need"
            return 1
        fi
    done
    return 0
}

# STOP: npm AND npx ARE NOT COPIED BY NAME. In a nodejs.org tarball they are
# symlinks into lib/node_modules, and a symlink into a noexec home does not run.
# The generic promote copies a symlink's target when the target is executable,
# which turns npm-cli.js into a file with its own `#!/usr/bin/env node` shebang;
# that works only once node is on PATH, which the fragment below guarantees. What
# is checked afterwards is that npm answers at all, and a miss is reported rather
# than left to fail inside a later build.
tc_node_env() {
    sh_ne_root=$(sh_toolchain_root node)
    # # STOP: A NODE WHOSE npm DOES NOT RUN GETS ONE, HERE, BEFORE ANY FRAGMENT
    # IS WRITTEN. This used to return 0 for an adopted node on the grounds that
    # "an adopted system node has no sandhome root; its npm configuration is not
    # ours to rewrite" - and the toolset then exited 0 with no working npm
    # (issue #46). Not rewriting the HOST's npm is right and is still what
    # happens: the repair puts a working npm on the exec view, which is ours.
    # A node whose npm already answers takes the version probe only and fetches
    # nothing, so a healthy host pays one command.
    if ! npm --version >/dev/null 2>&1; then
        tc_node_ensure_npm || sh_warn "npm does not run on this machine; run 'sandhome install --force node' for a node that ships one"
    fi
    if [ ! -d "$sh_ne_root" ]; then
        return 0
    fi
    sh_ne_view=$(sh_toolchain_view node)
    # STOP: THE PREFIX AND CACHE LIVE ON THE EXEC ROOT, NOT THE HOME (issue
    # #21). A prefix under the noexec home leaves global CLIs neither on PATH
    # nor executable (`bad interpreter: Permission denied` on a `#!/usr/bin/env
    # node` script whose inode is noexec). The npx one-shot cache
    # (`~/.npm/_npx`) has the same property, so it is relocated too.
    mkdir -p "$SH_EXEC/npm-global" "$SH_EXEC/cache/npm" 2>/dev/null || true
    # Self-sufficient under `set -u`: a leftover fragment must not abort a shell
    # that sources it with the names unset. See tools/go.sh for the shape.
    sh_env_write_fragment node <<EOF
: "\${SANDHOME_HOME:=$SH_HOME}"
: "\${SANDHOME_EXEC:=$SH_EXEC}"
export SANDHOME_HOME SANDHOME_EXEC
NPM_CONFIG_PREFIX="\$SANDHOME_EXEC/npm-global"
NPM_CONFIG_CACHE="\$SANDHOME_EXEC/cache/npm"
NPM_CONFIG_UPDATE_NOTIFIER=false
export NPM_CONFIG_PREFIX NPM_CONFIG_CACHE NPM_CONFIG_UPDATE_NOTIFIER
case ":\$PATH:" in
  *":\$SANDHOME_EXEC/npm-global/bin:"*) ;;
  *) PATH="\$SANDHOME_EXEC/npm-global/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":$sh_ne_view/bin:"*) ;;
  *) PATH="$sh_ne_view/bin:\$PATH" ;;
esac
export PATH
EOF
    sh_ne_frag=$?
    # # STOP: THE VIEW IS ONLY WARNED ABOUT WHEN A VIEW WAS ACTUALLY BUILT. An
    # adopted node has no toolchain root, so no exec view was made for it, and
    # this check ran anyway and named a directory that does not exist:
    #   the promoted node at /tmp/views/node/bin/node does not run
    # while `node --version` answered v26.8.1 from the exec bin the whole time.
    # A warning about a path that was never made is a false alarm about the
    # machine, and a consumer who reads it has been told to go fix something that
    # is not broken. The file's own rule is that a probe is a question about the
    # world, not about what we made; the directory has to exist first.
    if [ -x "$sh_ne_view/bin/node" ] && ! "$sh_ne_view/bin/node" --version >/dev/null 2>&1; then
        sh_warn "the promoted node at $sh_ne_view/bin/node does not run; node needs an exec-capable home or a larger exec root"
    fi
    if ! tc_node_behavioural >/dev/null 2>&1; then
        sh_warn "node installed without an error and still does not run a script from the exec view (home $SH_HOME is noexec)"
    fi
    return "$sh_ne_frag"
}

# tc_node_ensure_npm -> 0 when `npm` runs, fetching and shimming a real one
# when it does not.
#
# # STOP: AN ADOPTED NODE WITH A BROKEN npm GETS A WORKING ONE, NOT AN EXCUSE.
# The old behaviour checked npm only when a toolchain root existed, which is
# precisely the adopted case, and excused a borrowed node on the grounds that a
# broken host npm is "the host's defect, not this toolchain's". The result was
# `--toolset developer` exiting 0 and reporting a working node while
# `npm --version` died with MODULE_NOT_FOUND and `npx` was not on PATH at all
# (issue #46). Whose defect it is does not change what the consumer got. The
# ask was a developer toolset where npm works, and a warning is not a tool.
tc_node_npm_url() {
    # # STOP: THE npm VERSION IS NOT THE NODE VERSION, AND THE REGISTRY ANSWER
    # IS ONE LINE. Two mistakes this replaces, both measured. Asking for
    # npm-<node version>.tgz, which the first draft did, is a 404: node v26.8.1
    # and npm 11.x have independent version lines, so the URL built was
    # https://registry.npmjs.org/npm/-/npm-26.8.1.tgz -> HTTP 404. And /latest
    # is a single line of JSON, so taking its first line yields the whole
    # document and a match for a tarball name never finds one.
    #
    # The version is read out of the document by key, and the tarball URL is
    # built from npm's documented layout rather than guessed from a field.
    sh_nu_tmp=$SH_HOME_TMP/npm-latest.$$
    sh_fetch 'https://registry.npmjs.org/npm/latest' "$sh_nu_tmp" || {
        rm -f "$sh_nu_tmp" 2>/dev/null
        return 1
    }
    sh_nu_ver=''
    # # STOP: THE FIRST "version" IN THE DOCUMENT IS NOT THE PACKAGE'S. The
    # npm manifest carries nested objects that have their own version key -
    # `"tap":{"nyc":{...,"version":"5.1.1"...}}` - and taking the first match
    # resolved npm 5.1.1, whose tarball is a 404, on a registry whose current npm
    # is 12.1.0. The top-level version is the one that ends the document in this
    # layout, but relying on that is fragile, so the name is checked as well: a
    # match is only accepted when the document says it is the npm manifest.
    sh_nu_is_npm=no
    case "$(cat "$sh_nu_tmp")" in
        *'"name":"npm"'*) sh_nu_is_npm=yes ;;
    esac
    if [ "$sh_nu_is_npm" = yes ]; then
        # The last "version" in a flat npm manifest is the package's own; the
        # nested ones belong to objects that come earlier.
        for sh_nu_line in $(tr ',' '\n' < "$sh_nu_tmp" | grep '"version"'); do
            sh_nu_rest=${sh_nu_line#*'"version"'}
            sh_nu_rest=${sh_nu_rest#*:}
            sh_nu_rest=${sh_nu_rest#*\"}
            sh_nu_ver=${sh_nu_rest%%\"*}
        done
    fi
    rm -f "$sh_nu_tmp" 2>/dev/null
    case "$sh_nu_ver" in
        [0-9]*.[0-9]*)
            printf 'https://registry.npmjs.org/npm/-/npm-%s.tgz' "$sh_nu_ver"
            return 0 ;;
    esac
    return 1
}

tc_node_ensure_npm() {
    sh_have npm && npm --version >/dev/null 2>&1 && return 0

    sh_en_root=$(sh_toolchain_root node)
    sh_en_lib=$(sh_toolchain_adopted_root node)
    if [ -n "$sh_en_lib" ]; then
        for sh_en_c in "$sh_en_lib/npm/lib/node_modules/npm" "$sh_en_lib/npm"; do
            [ -r "$sh_en_c/bin/npm-cli.js" ] && { sh_en_lib=$sh_en_c; break; }
        done
    fi
    if [ -z "$sh_en_lib" ] || [ ! -r "$sh_en_lib/bin/npm-cli.js" ]; then
        sh_en_url=$(tc_node_npm_url) || {
            sh_warn "could not resolve an npm for node $(node --version 2>/dev/null); npm and npx are unavailable"
            return 1
        }
        sh_space_need 20 home || return 1
        rm -rf "$sh_en_root/npm" 2>/dev/null
        mkdir -p "$sh_en_root/npm" 2>/dev/null || return 1
        if ! sh_fetch_unpack "$sh_en_url" "$sh_en_root/npm"; then
            sh_warn "could not fetch or unpack $sh_en_url"
            rm -rf "$sh_en_root/npm" 2>/dev/null
            return 1
        fi
        # A registry tarball unpacks as package/.
        if [ -d "$sh_en_root/npm/package" ] && [ ! -d "$sh_en_root/npm/package/lib" ]; then
            for sh_en_f in "$sh_en_root/npm/package"/* "$sh_en_root/npm/package"/.[!.]*; do
                [ -e "$sh_en_f" ] || continue
                mv "$sh_en_f" "$sh_en_root/npm/" 2>/dev/null || true
            done
            rmdir "$sh_en_root/npm/package" 2>/dev/null || true
        fi
        for sh_en_c in "$sh_en_root/npm/lib/node_modules/npm" "$sh_en_root/npm"; do
            if [ -r "$sh_en_c/bin/npm-cli.js" ]; then
                sh_en_lib=$sh_en_c
                break
            fi
        done
    fi
    if [ -z "$sh_en_lib" ] || [ ! -r "$sh_en_lib/bin/npm-cli.js" ]; then
        sh_warn 'the npm that was fetched has no bin/npm-cli.js'
        return 1
    fi

    # Shims on the exec view. The node beside this npm is not ours to rewrite,
    # and a `#!/usr/bin/env node` script does not run from a noexec root, so the
    # shims live where they can be exec'd.
    mkdir -p "$SH_EXEC_BIN" 2>/dev/null || true
    sh_en_saved=$PATH
    PATH="$SH_EXEC_BIN:$PATH"
    export PATH
    for sh_en_name in npm npx; do
        sh_en_cli="$sh_en_lib/bin/${sh_en_name}-cli.js"
        [ -r "$sh_en_cli" ] || continue
        printf '#!/bin/sh\n# written by sandhome: the npm beside this node does not run here\nexec node %s "$@"\n' \
            "$sh_en_cli" > "$SH_EXEC_BIN/$sh_en_name" 2>/dev/null || continue
        chmod 0755 "$SH_EXEC_BIN/$sh_en_name" 2>/dev/null || true
    done
    # Report what is true: the shim runs, or it does not.
    if npm --version >/dev/null 2>&1; then
        PATH=$sh_en_saved
        export PATH
        sh_step "provided a working npm $(npm --version 2>/dev/null) for node $(node --version 2>/dev/null)"
        return 0
    fi
    PATH=$sh_en_saved
    export PATH
    sh_warn 'the npm that was fetched does not run on this machine'
    return 1
}

tc_node_behavioural() {
    sh_nb_tmp=${SH_EXEC:-${TMPDIR:-/tmp}}/node-probe.$$
    mkdir -p "$sh_nb_tmp" 2>/dev/null || return 1
    if ! node -e 'console.log("ok")' >/dev/null 2>&1; then
        rm -rf "$sh_nb_tmp" 2>/dev/null
        return 1
    fi
    # # STOP: npm IS PART OF THE PROBE FOR AN ADOPTED NODE TOO. The old probe
    # checked npm only when a toolchain root existed, which is precisely the
    # adopted case, and excused a borrowed node on the grounds that a broken
    # host npm is "the host's defect, not this toolchain's". The result was
    # `--toolset developer` exiting 0 and reporting a working node while
    # `npm --version` died with MODULE_NOT_FOUND and `npx` was not on PATH at
    # all (issue #46). Whether the base image is broken is a fact about the base
    # image; what the consumer asked for is a toolset where npm works.
    #
    # THIS IS A PROBE AND IT HAS NO SIDE EFFECTS. It answers "does node with its
    # npm work here", and it is what the post-promote check in
    # sh_toolchain_install_one reads. Repairing is tc_node_ensure_npm's job and
    # it runs from tc_node_env, so a probe that fails says so instead of
    # quietly fetching something. A probe with side effects also cannot be
    # asserted on: tests/toolchain.sh calls this directly and a probe that tries
    # to fix what it finds is a probe whose result depends on the network.
    if ! npm --version >/dev/null 2>&1; then
        rm -rf "$sh_nb_tmp" 2>/dev/null
        return 1
    fi
    rm -rf "$sh_nb_tmp" 2>/dev/null
    return 0
}

tc_node_version() {
    sh_have node && sh_first_line node --version 2>/dev/null
}
