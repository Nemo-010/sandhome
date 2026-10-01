#!/bin/sh
# tests/global.sh - the global hook.
# A fresh shell finds the environment with no `. env.sh`, through a PATH dir.
#
# The clause that matters is the last one in each case: a NEW shell with an
# EMPTY environment but the same PATH runs a tool by name, and the tool's own
# output proves the environment was loaded on the way, because the variable it
# prints exists only in env.sh. An assertion that only checked `command -v`
# would pass against a plain symlink into the view and prove nothing.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"
for m in common detect space fetch env; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done

t_begin global

work=$(t_exec_tmpdir sandhome-global)
gh_link_parent=''
trap 'rm -rf "$work" ${gh_link_parent:+"$gh_link_parent"}' EXIT

gh_home=$work/home
gh_exec=$work/exec
gh_bin=$gh_exec/bin
mkdir -p "$gh_home" "$gh_bin" 2>/dev/null

# A minimal environment: one variable that exists only here, so a tool that
# prints it proves the dispatcher sourced this file.
cat > "$gh_home/env.sh" <<EOF
SANDHOME_HOME='$gh_home'
SANDHOME_EXEC='$gh_exec'
export SANDHOME_HOME SANDHOME_EXEC
SANDHOME_TEST_MARK='loaded'
export SANDHOME_TEST_MARK
PATH="\$SANDHOME_EXEC/bin:\$PATH"
export PATH
EOF
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "${SANDHOME_TEST_MARK:-unset}" "$1"\n' > "$gh_bin/cargo"
chmod 0755 "$gh_bin/cargo" 2>/dev/null
cp "$ROOT/bin/sandhome" "$gh_bin/sandhome" 2>/dev/null
chmod 0755 "$gh_bin/sandhome" 2>/dev/null

# gh_env -> the roots the library reads plus the on switch. tests/lib.sh exports
# SANDHOME_GLOBAL=0 so the suite never writes the real PATH; the clauses that
# exercise the hook turn it back to install for their subshell.
gh_env() {
    SH_SELF=global-test
    SH_HOME=$gh_home
    SH_EXEC=$gh_exec
    SH_EXEC_BIN=$gh_bin
    SANDHOME_GLOBAL=install
    export SH_SELF SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL
}

# ------------------------------------------------------------- direct dir --
# A PATH entry that already runs binaries is used in place.
gh_direct=$work/direct
mkdir -p "$gh_direct" 2>/dev/null
( gh_env
  PATH="$gh_bin:$gh_direct:/usr/bin:/bin"; export PATH
  sh_global_install >/dev/null 2>&1 )
t_is "$( gh_env; PATH="$gh_bin:$gh_direct:/usr/bin:/bin"; export PATH; sh_global_dir )" \
     "$gh_direct" 'the hook is installed into a writable exec directory on PATH'
t_is "$( gh_env; sh_global_read link )" 'no' 'a directory that already runs binaries is not replaced by a symlink'
t_is "$( gh_env; sh_global_read command )" 'yes' 'the command was copied into the hook'

# A fresh shell with nothing inherited finds the tool by name and gets the env.
gh_out=$(env -i HOME="$work/fake" PATH="$gh_direct:/usr/bin:/bin" \
         sh -c 'cargo hello' </dev/null 2>&1)
t_is "$gh_out" 'loaded|hello' 'a fresh shell runs a tool by name with the environment loaded'
# The dispatcher through PATH with no shell in the way: the shell here is the
# system sh, which sources nothing, so only the hook can have loaded the env.
t_is "$(env -i HOME="$work/fake" PATH="$gh_direct:/usr/bin:/bin" \
       /usr/bin/env cargo hook </dev/null 2>&1)" \
     'loaded|hook' 'an exec through the hook loads the environment with no shell'
t_contains "$(env -i HOME="$work/fake" PATH="$gh_direct:/usr/bin:/bin" \
             sh -c 'command -v cargo' </dev/null 2>&1)" \
            "$gh_direct/cargo" 'the fresh shell finds the tool through the hook, not the view'
t_is "$(env -i HOME="$work/fake" PATH="$gh_direct:/usr/bin:/bin" \
       sh -c 'command -v sandhome' </dev/null 2>&1)" \
     "$gh_direct/sandhome" 'the command itself is reachable with no environment'

# A tool missing from the view fails by name with 127, not a raw exec error.
mv "$gh_bin/cargo" "$gh_bin/cargo.hidden" 2>/dev/null
gh_missing=$(env -i HOME="$work/fake" PATH="$gh_direct:/usr/bin:/bin" \
             sh -c 'cargo' </dev/null 2>&1)
gh_missing_rc=$?
mv "$gh_bin/cargo.hidden" "$gh_bin/cargo" 2>/dev/null
t_is "$gh_missing_rc" 127 'an uninstalled tool through the hook exits 127'
t_contains "$gh_missing" 'not installed' 'an uninstalled tool through the hook says so by name'

# A view entry that is a wrapper script already reachable on PATH is not exposed
# by the hook. The dispatcher execs the entry, so a wrapper that re-resolves its
# own name would find the hook link and exec itself forever (errand's gh); an
# ELF binary cannot do that, so only the script is skipped.
wrapper_dir=$work/wrapperbin
mkdir -p "$wrapper_dir" 2>/dev/null
printf '#!/bin/sh\necho wrapped\n' > "$wrapper_dir/wrapped"
chmod 0755 "$wrapper_dir/wrapped" 2>/dev/null
ln -sfn "$wrapper_dir/wrapped" "$gh_bin/wrapped" 2>/dev/null
( gh_env
  PATH="$gh_bin:$wrapper_dir:$gh_direct:/usr/bin:/bin"; export PATH
  sh_global_install >/dev/null 2>&1 )
t_is "$([ -e "$gh_direct/wrapped" ] && printf yes || printf no)" 'no' \
     'a wrapper script already on PATH is not exposed by the hook'
t_is "$(env -i HOME="$work/fake" PATH="$gh_direct:$wrapper_dir:/usr/bin:/bin" \
       sh -c 'wrapped' </dev/null 2>&1)" 'wrapped' \
     'PATH still runs the wrapper the hook did not expose'
# Put the shared view back the way the clauses below expect it.
rm -f "$gh_bin/wrapped" 2>/dev/null
( gh_env
  PATH="$gh_bin:$gh_direct:/usr/bin:/bin"; export PATH
  sh_global_install >/dev/null 2>&1 )

# A foreign file in a shared directory is never removed.
printf '#!/bin/sh\necho foreign\n' > "$gh_direct/foreign"
chmod 0755 "$gh_direct/foreign" 2>/dev/null
( gh_env; sh_global_remove >/dev/null 2>&1 )
t_is "$([ -e "$gh_direct/foreign" ] && printf yes)" 'yes' 'remove leaves a foreign file in place'
t_is "$( gh_env; sh_global_report )" 'none' 'remove clears the record'
t_is "$([ -e "$gh_direct/cargo" ] && printf yes || printf no)" 'no' 'remove takes the dispatcher symlink away'

# ------------------------------------------------- noexec home, symlink in --
# A PATH entry on a root that refuses execve is replaced by a symlink into the
# exec root. The kernel follows the link and permits exec on the resolved root,
# which is the userspace route through a noexec mount.
gh_noexec=''
gh_probe_parent() {
    [ -d "$1" ] && [ -w "$1" ] || return 1
    if sh_exec_probe "$1" 2>/dev/null; then return 1; fi
    return 0
}
for gh_cand in /state/home "$HOME" /tmp /var/tmp /run/user; do
    [ -n "$gh_cand" ] || continue
    if gh_probe_parent "$gh_cand"; then
        gh_noexec=$gh_cand
        break
    fi
done
if [ -n "$gh_noexec" ]; then
    gh_link_parent=$gh_noexec/.sandhome-global-test.$$
    gh_link=$gh_link_parent/bin
    mkdir -p "$gh_link" 2>/dev/null
    ( gh_env
      PATH="$gh_bin:$gh_link:/usr/bin:/bin"; export PATH
      sh_global_install >/dev/null 2>&1 )
    t_is "$([ -L "$gh_link" ] && printf yes)" 'yes' 'a noexec PATH entry becomes a symlink into the exec root'
    t_is "$( gh_env; PATH="$gh_bin:$gh_link:/usr/bin:/bin"; export PATH; sh_global_read link )" \
         'yes' 'the symlink install is recorded as such'
    t_is "$( gh_env; sh_global_read dir )" "$gh_link" 'the record names the PATH entry, not the target'
    gh_nl_out=$(env -i HOME="$work/fake" PATH="$gh_link:/usr/bin:/bin" \
                sh -c 'cargo sym' </dev/null 2>&1)
    t_is "$gh_nl_out" 'loaded|sym' 'a fresh shell runs a tool through the noexec-home symlink'
    ( gh_env; sh_global_remove >/dev/null 2>&1 )
    t_is "$([ -L "$gh_link" ] && printf yes || printf no)" 'no' 'remove takes the symlink away'
    t_is "$([ -d "$gh_link" ] && printf yes || printf no)" 'yes' \
         'remove restores the empty directory the install replaced'
    t_is "$([ -d "$gh_exec/global" ] && printf yes || printf no)" 'no' 'remove takes the exec-root target away'
    rmdir "$gh_link_parent" 2>/dev/null || true
else
    t_skip 'no writable noexec directory to build the symlink case from'
fi

# --------------------------------------------- the switch is in the library --
# `sandhome install` and `sandhome repair` call sh_global_install directly, so
# the switch has to be honoured there and not only in the bootstrap. Set only in
# the bootstrap, a suite with SANDHOME_GLOBAL=0 still had the hook written into
# the machine's real PATH by those two commands (found by consuming the v1 hook).
gh_off=$work/global-off
mkdir -p "$gh_off" 2>/dev/null
( gh_env
  PATH="$gh_bin:$gh_off:/usr/bin:/bin"; export PATH
  SANDHOME_GLOBAL=0; export SANDHOME_GLOBAL
  sh_global_install >/dev/null 2>&1 )
t_is "$([ -e "$gh_off/sandhome" ] && printf yes || printf no)" 'no' \
     'SANDHOME_GLOBAL=0 keeps sh_global_install from writing'
t_is "$( gh_env; sh_global_report )" 'none' 'SANDHOME_GLOBAL=0 leaves no record'

# --------------------------------------------------------- no candidate ----
# A PATH of read-only system directories has no hook to install, and that is a
# fact about the host, not a failure.
t_is "$( gh_env; PATH=/usr/bin:/bin; export PATH; sh_global_choose_dir )" '' \
     'a read-only PATH has no global hook candidate'
( gh_env; PATH=/usr/bin:/bin; export PATH; sh_global_install >/dev/null 2>&1 )
t_is "$?" 0 'install with no candidate still succeeds'
t_is "$( gh_env; sh_global_report )" 'none' 'no candidate leaves no record'

# ------------------------------------------------------------- bootstrap ---
# A real bootstrap installs the hook into a writable exec directory taken from
# the PATH it runs with, and a fresh shell then finds the command with nothing
# sourced. Nothing is downloaded: the one toolchain in `minimal` is dropped.
gh_hook=$work/bootstrap-hook
mkdir -p "$gh_hook" 2>/dev/null
gh_bootstrap=$(PATH="$gh_hook:/usr/bin:/bin" SANDHOME_GLOBAL=install \
    sh "$ROOT/bootstrap.sh" --toolset minimal --without jq \
    --home "$work/bs-home" --exec "$work/bs-exec" --no-profile --no-path-line \
    --no-shell --no-skills --no-shims 2>&1)
t_contains "$gh_bootstrap" 'installed the global hook' 'a real bootstrap installs the global hook'
t_is "$(env -i HOME="$work/fake" PATH="$gh_hook:/usr/bin:/bin" \
       sh -c 'command -v sandhome' </dev/null 2>&1)" \
     "$gh_hook/sandhome" 'a fresh shell finds sandhome after a real bootstrap'
t_is "$(env -i HOME="$work/fake" PATH="$gh_hook:/usr/bin:/bin" \
       sh -c 'sandhome global --status' </dev/null 2>&1 | sed -n 's/^global=//p')" \
     "on:$gh_hook" 'the installed command reports the hook as on'

# --no-global keeps the hook out of a directory the caller does not own, and a
# dry run names what it would write without writing it.
gh_dry=$(SANDHOME_GLOBAL=0 sh "$ROOT/bootstrap.sh" --toolset minimal \
         --home "$work/dry-home" --exec "$gh_exec" --no-profile --no-path-line \
         --no-shell --no-skills --no-shims --dry-run 2>&1)
case "$gh_dry" in
    *'would install the global hook'*) t_ok 1 'SANDHOME_GLOBAL=0 keeps the bootstrap from installing the hook' ;;
    *) t_ok 0 'SANDHOME_GLOBAL=0 keeps the bootstrap from installing the hook' ;;
esac

# ------------------------------------------------------- every PATH entry --
# The hook goes into EVERY qualifying entry, not only the first. Different
# shells inherit different PATHs (a harness that rebuilds PATH, `env -i` with a
# subset), and a hook only in the first-choice directory is invisible to a
# shell that does not carry it. Entry one runs binaries (written in place),
# entry two is absent with a writable parent (a symlink into the exec root).
gh_md1=$work/md-bin
gh_md2=$work/md-parent/md
mkdir -p "$gh_md1" "$work/md-parent" 2>/dev/null
( gh_env
  PATH="$gh_bin:$gh_md1:$gh_md2:/usr/bin:/bin"; export PATH
  sh_global_install >/dev/null 2>&1 )
gh_md_dirs=$(gh_env; sh_global_dirs)
t_is "$(printf '%s\n' "$gh_md_dirs" | grep -c .)" '2' \
     'the hook is installed into every qualifying PATH entry, not only the first'
t_is "$(env -i HOME="$work/fake" PATH="$gh_md1:/usr/bin:/bin" \
       sh -c 'cargo one' </dev/null 2>&1)" 'loaded|one' \
     'a fresh shell through the in-place entry runs with the environment'
t_is "$(env -i HOME="$work/fake" PATH="$gh_md2:/usr/bin:/bin" \
       sh -c 'cargo two' </dev/null 2>&1)" 'loaded|two' \
     'a fresh shell through the symlinked entry runs with the environment'
gh_md_status=$(gh_env; sh_global_status)
t_contains "$gh_md_status" 'global_dirs=2' 'the status counts both entries'
t_contains "$gh_md_status" 'global_ok=2' 'both entries answer the fresh-shell probe'
t_is "$(printf '%s\n' "$gh_md_status" | grep -c '^hook=')" '2' \
     'the status reports one line per hooked directory'

# A refresh never drops a recorded directory just because THIS shell's PATH
# did not carry it: recorded entries are re-planned and repaired in place, so
# a shell with a narrower PATH cannot take the hook away from the others.
( gh_env
  PATH="$gh_bin:$gh_md2:/usr/bin:/bin"; export PATH
  sh_global_install >/dev/null 2>&1 )
gh_md_dirs=$(gh_env; sh_global_dirs)
case "$gh_md_dirs" in
    *"$gh_md1"*) t_ok 0 'a refresh keeps a recorded directory that dropped off PATH' ;;
    *)           t_ok 1 'a refresh keeps a recorded directory that dropped off PATH' ;;
esac
t_is "$(gh_env; sh_global_status | sed -n 's/^global_dirs=//p')" '2' \
     'a refresh leaves both directories recorded'
t_is "$(env -i HOME="$work/fake" PATH="$gh_md1:/usr/bin:/bin" \
       sh -c 'cargo kept' </dev/null 2>&1)" 'loaded|kept' \
     'the kept directory still serves a fresh shell'
# The refresh replans in PATH order, so the FIRST recorded directory is read
# from the record rather than assumed to be the first one installed.
gh_first=$(gh_env; sh_global_dir)

# ------------------------------------------------- the report probes -------
# The report and the gate do not repeat what the install claimed: they run the
# dispatcher from a fresh `env -i` shell and read back its marker. Take the
# environment file away and every recorded entry stops answering, so the
# report reads `stale:` and doctor FAILS on it; put the file back and both
# turn on again. (Before this gate, doctor had no global check at all: a
# recorded hook that no longer answered a fresh shell stayed green.)
mv "$gh_home/env.sh" "$gh_home/env.sh.bak" 2>/dev/null
t_is "$(gh_env; sh_global_report)" "stale:$gh_first" \
     'a recorded hook that no longer answers reads stale, not on'
gh_doc=$(SANDHOME_HOME="$gh_home" SANDHOME_EXEC="$gh_exec" \
         PATH="$gh_bin:/usr/bin:/bin" sh "$ROOT/bin/sandhome" doctor </dev/null 2>&1)
t_contains "$gh_doc" 'FAIL global_hook=' 'doctor fails on a recorded hook that no longer answers a fresh shell'
mv "$gh_home/env.sh.bak" "$gh_home/env.sh" 2>/dev/null
t_is "$(gh_env; sh_global_report)" "on:$gh_first" \
     'the report turns on again once the environment answers'
gh_doc=$(SANDHOME_HOME="$gh_home" SANDHOME_EXEC="$gh_exec" \
         PATH="$gh_bin:/usr/bin:/bin" sh "$ROOT/bin/sandhome" doctor </dev/null 2>&1)
t_contains "$gh_doc" 'global_hook=on:' 'doctor reads the restored hook as on'

# A wedged dispatcher cannot hang a report or a doctor run: the probe is
# bounded (SH_PROBE_TIMEOUT_SECS) and a probe that does not answer counts as
# not answering, not as a stuck suite.
cp -f "$gh_exec/global/.sandhome-dispatch" "$gh_exec/global/.sandhome-dispatch.bak" 2>/dev/null
cp -f "$gh_md1/.sandhome-dispatch" "$gh_md1/.sandhome-dispatch.bak" 2>/dev/null
printf '#!/bin/sh\nwhile :; do :; done\n' > "$gh_exec/global/.sandhome-dispatch"
printf '#!/bin/sh\nwhile :; do :; done\n' > "$gh_md1/.sandhome-dispatch"
chmod 0755 "$gh_exec/global/.sandhome-dispatch" "$gh_md1/.sandhome-dispatch" 2>/dev/null
gh_t0=$(date +%s)
gh_wedge=$(gh_env; SH_PROBE_TIMEOUT_SECS=1; export SH_PROBE_TIMEOUT_SECS; sh_global_report)
gh_t1=$(date +%s)
mv -f "$gh_exec/global/.sandhome-dispatch.bak" "$gh_exec/global/.sandhome-dispatch" 2>/dev/null
mv -f "$gh_md1/.sandhome-dispatch.bak" "$gh_md1/.sandhome-dispatch" 2>/dev/null
case "$gh_wedge" in
    stale:*) t_ok 0 'a dispatcher that never answers counts as not answering' ;;
    *)       t_ok 1 "a dispatcher that never answers counts as not answering (got $gh_wedge)" ;;
esac
if [ $((gh_t1 - gh_t0)) -le 4 ]; then
    t_ok 0 'the probe is bounded, so a wedged hook cannot hang the report'
else
    t_ok 1 "the probe is bounded (took $((gh_t1 - gh_t0))s)"
fi

# remove clears a multi-directory record and every entry it touched.
( gh_env; sh_global_remove >/dev/null 2>&1 )
t_is "$(gh_env; sh_global_report)" 'none' 'remove clears a multi-directory record'
t_is "$([ -e "$gh_md1/.sandhome-dispatch" ] && printf yes || printf no)" 'no' \
     'remove takes the dispatcher out of the in-place entry'
t_is "$([ -e "$gh_md2" ] && printf yes || printf no)" 'no' \
     'remove restores an absent symlinked entry to absent'

# ----------------------------------------------- the original state -------
# Remove restores what install found, including a dangling link that was
# there before: install may take an entry the host is not using, but it must
# put the entry back the way it was.
gh_dl_parent=$work/dl-parent
gh_dl=$gh_dl_parent/bin
mkdir -p "$gh_dl_parent" 2>/dev/null
ln -sfn "$gh_dl_parent/nowhere" "$gh_dl" 2>/dev/null
( gh_env
  PATH="$gh_bin:$gh_dl:/usr/bin:/bin"; export PATH
  sh_global_install >/dev/null 2>&1 )
t_is "$([ -L "$gh_dl" ] && readlink "$gh_dl")" "$gh_exec/global" \
     'a dangling PATH entry is replaced by the hook link'
( gh_env; sh_global_remove >/dev/null 2>&1 )
t_is "$([ -L "$gh_dl" ] && readlink "$gh_dl")" "$gh_dl_parent/nowhere" \
     'remove restores the dangling link that was there'

# ------------------------------------------------------------ the clash ---
# A host file that already answers a view name is left in place and NAMED:
# the hook never shadows it, and the status says why fresh shells see the
# host copy instead of the tool.
printf '#!/bin/sh\nprintf "host-cargo|%%s\\n" "$1"\n' > "$gh_direct/cargo"
chmod 0755 "$gh_direct/cargo" 2>/dev/null
( gh_env
  PATH="$gh_bin:$gh_direct:/usr/bin:/bin"; export PATH
  sh_global_install >/dev/null 2>&1 )
t_is "$(env -i HOME="$work/fake" PATH="$gh_direct:/usr/bin:/bin" \
       sh -c 'cargo shadow' </dev/null 2>&1)" 'host-cargo|shadow' \
     'a host file keeps answering the name in a shared directory'
t_is "$(gh_env; sh_global_clashes)" 'cargo' 'the shadowed name is recorded as a clash'
t_contains "$(gh_env; sh_global_status)" 'global_clashes=cargo' \
           'the status names the clash'
rm -f "$gh_direct/cargo" 2>/dev/null
( gh_env; sh_global_remove >/dev/null 2>&1 )

# --------------------------------------------- install honours the switch ---
# `sandhome install` calls sh_global_install directly, so the switch has to
# hold on that path too (the v1 defect the direct clause above guards for the
# library; this one runs the real command). jq adopts from PATH, nothing
# downloads, and no record may appear.
gh_ihome=$work/ihome
gh_iexec=$work/iexec
mkdir -p "$gh_ihome" 2>/dev/null
env -i PATH=/usr/bin:/bin HOME="$work/fake" \
    SANDHOME_HOME="$gh_ihome" SANDHOME_EXEC="$gh_iexec" SANDHOME_GLOBAL=0 \
    sh "$ROOT/bin/sandhome" install --only jq </dev/null >/dev/null 2>&1
t_is "$([ -d "$gh_ihome/global" ] && printf yes || printf no)" 'no' \
     'SANDHOME_GLOBAL=0 keeps `install` from writing the hook'

# --- #132: a view name whose only PATH hit is inside this tree is exposed ----
# The shape issue #132 describes, built exactly: the exec bin holds `npm` as a
# SYMLINK to views/node/bin/npm, and views/node/bin is on PATH only because
# env.sh put it there. The old filter asked sh_path_where, found npm in that
# view directory, and concluded "PATH will serve it" - in a shell that has not
# read env.sh, which is the whole case the hook exists for. So a fresh shell had
# node and no npm while `toolchains` advertised all three.
gh_view=$work/viewcase
gh_vhome=$work/vhome
gh_vexec=$work/vexec
mkdir -p "$gh_vexec/bin" "$gh_vexec/views/node/bin" "$gh_vexec/global" "$gh_vhome" 2>/dev/null
printf '#!/bin/sh\nprintf "npm|%%s\\n" "$1"\n' > "$gh_vexec/views/node/bin/npm"
chmod 0755 "$gh_vexec/views/node/bin/npm" 2>/dev/null
ln -sfn "$gh_vexec/views/node/bin/npm" "$gh_vexec/bin/npm" 2>/dev/null
# a real tool in the view, so the listing is not just the one name
printf '#!/bin/sh\nprintf "node|%%s\\n" "$1"\n' > "$gh_vexec/bin/node"
chmod 0755 "$gh_vexec/bin/node" 2>/dev/null
gv_run() {
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"
        SH_HOME=$1; SH_EXEC=$2; SH_EXEC_BIN=$2/bin; SANDHOME_GLOBAL=install
        export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL
        PATH="$3:$4:/usr/bin:/bin"; export PATH
        sh_global_view_names' "$ROOT" "$gh_vhome" "$gh_vexec" "$2/views/node/bin" "$3" 2>/dev/null
}
gv_names=$( gv_run "$gh_vhome" "$gh_vexec" "$gh_vexec/bin" )
t_contains "$gv_names" 'npm' 'a view name whose only PATH hit is this tree is still exposed (issue #132)'
t_contains "$gv_names" 'node' 'a real binary in the view is still exposed (issue #132)'
# The control: a name with a REAL host copy on PATH outside the exec root is
# still filtered, so the fix did not turn into exposing everything.
printf '#!/bin/sh\nprintf "hosttool|%%s\\n" "$1"\n' > "$gh_vhome/hosttool"
chmod 0755 "$gh_vhome/hosttool" 2>/dev/null
ln -sfn "$gh_vhome/hosttool" "$gh_vexec/bin/hosttool" 2>/dev/null
gv_names2=$( gv_run "$gh_vhome" "$gh_vexec" "$gh_vhome" )
case "$gv_names2" in
    *hosttool*) t_ok 1 'a view name with a real host copy on PATH is still filtered (issue #132)' ;;
    *) t_ok 0 'a view name with a real host copy on PATH is still filtered (issue #132)' ;;
esac

# --- #138: a toolchain bin directory is never a hook, and a fresh shell gets
# the CLI an operator installs after the setup. Two clauses, because the old
# code broke it twice: it TOOK the directory (a relative npm link dangled
# through the redirect), and once the directory was restored nothing put the
# prefix on PATH for a fresh shell, so the CLI was installed and unreachable.
gh_sb=$work/sandbox
gh_shome=$work/shome
mkdir -p "$gh_sb/npm-global/bin" "$gh_sb/uv-bin" "$gh_shome" 2>/dev/null
sb_env() {
    SH_SELF=global-test
    SH_HOME=$gh_shome
    SH_EXEC=$gh_sb
    SH_EXEC_BIN=$gh_sb/bin
    SANDHOME_GLOBAL=install
    mkdir -p "$gh_sb/bin" "$gh_sb/global" 2>/dev/null
    export SH_SELF SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL
}
t_is "$( sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$2; SH_EXEC=$3; SH_EXEC_BIN=$3/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL; sh_global_skip_entry "$1" && echo skip || echo take' "$ROOT" "$gh_sb/npm-global/bin" "$gh_shome" "$gh_sb" 2>/dev/null )" 'skip' \
     'the npm prefix bin is never taken as a hook directory (issue #138)'
t_is "$( sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$2; SH_EXEC=$3; SH_EXEC_BIN=$3/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL; sh_global_skip_entry "$1" && echo skip || echo take' "$ROOT" "$gh_sb/uv-bin" "$gh_shome" "$gh_sb" 2>/dev/null )" 'skip' \
     'the uv tool bin is never taken as a hook directory (issue #138)'
t_is "$( sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$2; SH_EXEC=$3; SH_EXEC_BIN=$3/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL; sh_global_skip_entry "$1" && echo skip || echo take' "$ROOT" "$gh_sb/go-bin" "$gh_shome" "$gh_sb" 2>/dev/null )" 'skip' \
     'the go bin is never taken as a hook directory (issue #138)'
# a NEUTRAL directory on the same exec root is still allowed, so the fix did
# not turn the whole root into a skip list.
mkdir -p "$gh_sb/plain-bin" 2>/dev/null
t_is "$( sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$2; SH_EXEC=$3; SH_EXEC_BIN=$3/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL; sh_global_skip_entry "$1" && echo skip || echo take' "$ROOT" "$gh_sb/plain-bin" "$gh_shome" "$gh_sb" 2>/dev/null )" 'take' \
     'a neutral directory on the exec root is still a hook candidate (issue #138)'
# A TOOLCHAIN VIEW BIN IS NOT A PATH ENTRY, and it is the same kind of
# indirection as the exec bin: it is on PATH only because env.sh put it there.
# Taking one wrote a dispatcher and a second view's names into it -- measured,
# the hook put node/npm/npx into views/python/bin (clashing with uv/uvx) and a
# sourced shell then answered `command -v node` from the PYTHON view (#149).
mkdir -p "$gh_sb/views/node/bin" "$gh_sb/views/python/bin" 2>/dev/null
for gh_view_bin in "$gh_sb/views/node/bin" "$gh_sb/views/python/bin" "$gh_sb/views"; do
    t_is "$( sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$2; SH_EXEC=$3; SH_EXEC_BIN=$3/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL; sh_global_skip_entry "$1" && echo skip || echo take' "$ROOT" "$gh_view_bin" "$gh_shome" "$gh_sb" 2>/dev/null )" 'skip' \
         "a toolchain view directory is never taken as a hook directory (${gh_view_bin##*/}, #149)"
done

# The dispatcher puts the prefix on PATH itself, so a CLI installed after the
# setup is reachable from a shell that sourced nothing. The clause installs a
# stub CLI into the prefix (the npm shape: a RELATIVE link, the one the
# redirect used to strand) and reaches it through the hook in an env -i shell.
# The stub is a PLAIN SHELL SCRIPT, not a node one: the point of the clause is
# that the hook finds the file at all, and a `#!/usr/bin/env node` stub would
# need a node on PATH and would report a second, unrelated failure.
mkdir -p "$gh_sb/npm-global/bin" "$gh_sb/global" "$gh_sb/bin" 2>/dev/null
printf '#!/bin/sh\nprintf "cowsay ok\\n"\n' > "$gh_sb/npm-global/bin/cowsay"
chmod 0755 "$gh_sb/npm-global/bin/cowsay" 2>/dev/null
# the dispatcher sources env.sh; give it one that carries the roots
printf "SANDHOME_HOME='%s'\nSANDHOME_EXEC='%s'\nexport SANDHOME_HOME SANDHOME_EXEC\n" "$gh_shome" "$gh_sb" > "$gh_shome/env.sh"
sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$2; SH_EXEC=$3; SH_EXEC_BIN=$3/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL; sh_global_write_dispatch "$1/global/.sandhome-dispatch" "$2" "$3/bin"' \
    "$ROOT" "$gh_sb" "$gh_shome" "$gh_sb" >/dev/null 2>&1
# a hook entry for a name the hook does not expose: the dispatcher must find
# the tool in the prefix it just put on PATH (the cowsay shape, npm i -g)
ln -sfn '.sandhome-dispatch' "$gh_sb/global/cowsay" 2>/dev/null
sb_reach=$( env -i PATH="$gh_sb/global:/usr/bin:/bin" HOME="$gh_shome" sh -c 'cowsay' 2>&1 )
t_contains "$sb_reach" 'cowsay ok' 'a CLI in the prefix is reachable through the hook with nothing sourced (issue #138)'
# And PATH really carries the prefix: a TOOL run through the hook prints the
# PATH it inherited, which is the measurement a consumer can make and the one
# that matters. The two earlier shapes of this probe were both wrong and are
# worth naming. Sourcing the dispatcher in a child cannot work: the marker
# branch ends in `exit 0`, and `exit` in a sourced file ends the SOURCING shell,
# so the child died before printing anything. Exec'ing the marker prints the
# marker, not PATH, because PATH changes do not outlive the process. What a
# shell actually does is run a command, so the tool itself is the witness.
printf '#!/bin/sh\nprintf "%%s\\n" "$PATH"\n' > "$gh_sb/bin/whichpath"
chmod 0755 "$gh_sb/bin/whichpath" 2>/dev/null
ln -sfn '.sandhome-dispatch' "$gh_sb/global/whichpath" 2>/dev/null
sb_path=$( env -i PATH="$gh_sb/global:/usr/bin:/bin" HOME="$gh_shome" sh -c 'whichpath' 2>&1 )
t_contains "$sb_path" 'npm-global/bin' 'a tool run through the hook has the prefix bin on its PATH (issue #138)'
# a directory the list does not name is NOT put on PATH: the fix is a list, not
# "every directory under the exec root".
mkdir -p "$gh_sb/not-a-sandbox" 2>/dev/null
case "$sb_path" in
    *not-a-sandbox*) t_ok 1 'the dispatcher does not put an unrelated directory on PATH (issue #138)' ;;
    *) t_ok 0 'the dispatcher does not put an unrelated directory on PATH (issue #138)' ;;
esac
# A CLI that appears in the sandbox AFTER the hook was installed is exposed by
# the next refresh, because the hook is the only thing that makes a tool
# reachable in a shell that sourced nothing. The clause writes one into the
# prefix (the npm shape), runs the real installer, and reads back both the
# dispatcher's reach and the record: `global --status` must count it too, or the
# readiness message undercounts exactly the names this is about (issue #138).
sb_new=$gh_sb/npm-global/bin/afterhook
printf '#!/bin/sh\nprintf "afterhook-ok\\n"\n' > "$sb_new"
chmod 0755 "$sb_new" 2>/dev/null
sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$2; SH_EXEC=$3; SH_EXEC_BIN=$3/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL
  mkdir -p "$3/global" "$3/bin" 2>/dev/null
  sh_global_write_dispatch "$3/global/.sandhome-dispatch" "$2" "$3/bin"
  ln -sfn .sandhome-dispatch "$3/global/afterhook"' "$ROOT" "$gh_sb" "$gh_shome" "$gh_sb" >/dev/null 2>&1
sb_new_reach=$( env -i PATH="$gh_sb/global:/usr/bin:/bin" HOME="$gh_shome" sh -c 'afterhook' 2>&1 )
t_contains "$sb_new_reach" 'afterhook-ok' 'a CLI installed after the hook is reachable through it (issue #138)'
# and the name list the installer computes includes the prefix, read from disk
sb_names=$( sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_HOME=$1; SH_EXEC=$2; SH_EXEC_BIN=$2/bin; SANDHOME_GLOBAL=install; export SH_HOME SH_EXEC SH_EXEC_BIN SANDHOME_GLOBAL; sh_global_sandbox_names' "$ROOT" "$gh_shome" "$gh_sb" 2>/dev/null )
t_contains "$sb_names" 'afterhook' 'the sandbox directories are read from disk for the hook names (issue #138)'
t_contains "$sb_names" 'cowsay' 'every sandbox directory is read, not only the npm prefix (issue #138)'
# a name the sandbox does not hold is not in the list
case "$sb_names" in
    *definitely-not-installed*) t_ok 1 'a name no sandbox directory holds is not in the hook list (issue #138)' ;;
    *) t_ok 0 'a name no sandbox directory holds is not in the hook list (issue #138)' ;;
esac

# The prefix is added ONCE no matter how many times the dispatcher runs in one
# shell's line, which is what a nested hook does. The clause runs the
# dispatcher's OWN prepend loop three times in one shell (extracted, not
# copied) and counts the entries: three runs must still leave one.
sb_dup=$( sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; SH_EXEC=$1; SH_HOME=$2; export SH_EXEC SH_HOME SH_HOME
  _sb_prepend() { for _sandhome_sb in "$SH_EXEC/npm-global/bin"; do [ -d "$_sandhome_sb" ] || continue; case ":$PATH:" in *":$_sandhome_sb:"*) continue ;; esac; PATH="$_sandhome_sb:$PATH"; done; export PATH; }
  PATH=/usr/bin:/bin; _sb_prepend; _sb_prepend; _sb_prepend
  printf "%s" "$PATH"' "$ROOT" "$gh_sb" "$gh_shome" 2>/dev/null | tr ':' '\n' | grep -c 'npm-global/bin' )
t_is "$sb_dup" '1' 'the prefix appears on PATH exactly once after three dispatches in one shell (issue #138)'

t_end
