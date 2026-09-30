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

# gh_env -> the two roots the library reads, for the subshells below.
gh_env() {
    SH_SELF=global-test
    SH_HOME=$gh_home
    SH_EXEC=$gh_exec
    SH_EXEC_BIN=$gh_bin
    export SH_SELF SH_HOME SH_EXEC SH_EXEC_BIN
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
    t_is "$([ -e "$gh_link" ] && printf yes || printf no)" 'no' 'remove takes the symlink away'
    t_is "$([ -d "$gh_exec/global" ] && printf yes || printf no)" 'no' 'remove takes the exec-root target away'
    rmdir "$gh_link_parent" 2>/dev/null || true
else
    t_skip 'no writable noexec directory to build the symlink case from'
fi

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

t_end
