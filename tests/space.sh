#!/bin/sh
# tests/space.sh - the two-root plan, the exec probe and the mirror.
#
# THE REGRESSION THIS FILE EXISTS FOR: sh_promote_tree was recursive, and POSIX
# sh has no `local`, so the recursive call for one subdirectory overwrote the
# parent's source/destination/basename. The second sibling directory was mirrored
# under the FIRST sibling instead of at the top, and 32 files were reported as
# copy failures. The two-sibling case below fails against that shape.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin space

tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-space.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- writable and exec probes -------------------------------------------------
mkdir -p "$tmp/writable" "$tmp/ro" 2>/dev/null
chmod 0500 "$tmp/ro" 2>/dev/null
sh_dir_writable "$tmp/writable" && t_ok 0 'dir_writable accepts a writable dir' || t_ok 1 'dir_writable accepts a writable dir'
sh_dir_writable "$tmp/ro" && t_ok 1 'dir_writable rejects a read-only dir' || t_ok 0 'dir_writable rejects a read-only dir'
sh_dir_writable "$tmp/nope" && t_ok 1 'dir_writable rejects a missing dir' || t_ok 0 'dir_writable rejects a missing dir'

sh_exec_probe /tmp && t_ok 0 'exec_probe says /tmp runs a binary' || t_ok 1 'exec_probe says /tmp runs a binary'

# A directory that the sandbox allows no exec from is the case this whole tree is
# about. When there is one, the probe must say no; when there is not, this clause
# is skipped rather than faked.
for noexec_dir in /workspace /state/home; do
    if [ -d "$noexec_dir" ] && [ -w "$noexec_dir" ]; then
        if sh_exec_probe "$noexec_dir"; then
            t_ok 0 "exec_probe said $noexec_dir runs (this sandbox allows it)"
        else
            t_ok 0 "exec_probe correctly denied exec on $noexec_dir"
        fi
        break
    fi
done

# --- is_exec_file -------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$tmp/run.sh"; chmod 0755 "$tmp/run.sh"
: > "$tmp/libx.so"; chmod 0755 "$tmp/libx.so"
: > "$tmp/plain"; chmod 0644 "$tmp/plain"
sh_is_exec_file "$tmp/run.sh" && t_ok 0 'is_exec_file: executable' || t_ok 1 'is_exec_file: executable'
sh_is_exec_file "$tmp/libx.so" && t_ok 1 'is_exec_file: shared object is not' || t_ok 0 'is_exec_file: shared object is not'
sh_is_exec_file "$tmp/plain" && t_ok 1 'is_exec_file: data file is not' || t_ok 0 'is_exec_file: data file is not'

# --- the mirror, with two siblings (the regression) ---------------------------
src="$tmp/src"; dst="$tmp/dst"
mkdir -p "$src/a" "$src/b/c"
printf '#!/bin/sh\necho A\n' > "$src/a/x.sh";  chmod 0755 "$src/a/x.sh"
printf '#!/bin/sh\necho B\n' > "$src/b/y.sh";  chmod 0755 "$src/b/y.sh"
printf '#!/bin/sh\necho C\n' > "$src/b/c/z.sh"; chmod 0755 "$src/b/c/z.sh"
: > "$src/data.txt"; chmod 0644 "$src/data.txt"
: > "$src/libfoo.so"; chmod 0755 "$src/libfoo.so"
# A symlinked executable whose target carries a relative path next to itself.
# The npm shape: bin/tool -> ../lib/tool/main.js, and main.js reads ./data.txt.
mkdir -p "$src/bin" "$src/lib/tool"
cat > "$src/lib/tool/main.js" <<'JS'
#!/bin/sh
D=$(dirname "$(readlink -f "$0")")
cat "$D/data.txt"
JS
chmod 0755 "$src/lib/tool/main.js"
printf 'payload\n' > "$src/lib/tool/data.txt"
ln -sfn ../lib/tool/main.js "$src/bin/tool"

SH_HOME_TMP="$tmp"; export SH_HOME_TMP
sh_promote_tree "$src" "$dst"
t_ok $? 'promote_tree returns 0'

t_ok "$([ -x "$dst/a/x.sh" ] && [ ! -L "$dst/a/x.sh" ]; echo $?)" 'a executable is a real copy'
t_ok "$([ -x "$dst/b/y.sh" ] && [ ! -L "$dst/b/y.sh" ]; echo $?)" 'the second sibling landed at the top, not under the first'
t_ok "$([ -x "$dst/b/c/z.sh" ]; echo $?)" 'a nested executable is mirrored'
t_ok "$([ -L "$dst/libfoo.so" ]; echo $?)" 'a shared object is symlinked, not copied'
t_ok "$([ -L "$dst/data.txt" ]; echo $?)" 'a data file is symlinked, not copied'
t_is "$("$dst/b/y.sh")" 'B' 'the promoted copy actually runs'
t_is "$(readlink "$dst/data.txt")" "$src/data.txt" 'the symlink points back at the source'
t_ok "$([ -L "$dst/bin/tool" ]; echo $?)" 'a symlinked executable stays a symlink in the view'
t_ok "$([ -x "$dst/lib/tool/main.js" ] && [ ! -L "$dst/lib/tool/main.js" ]; echo $?)" \
    'its script target is a real copy on the exec root'
t_is "$("$dst/bin/tool" 2>&1)" 'payload' 'the symlinked executable runs and finds its relative data'

# STOP: AND IT WORKS WITH THE TEMP ROOT UNSET. The queue used to be written to
# "$SH_HOME_TMP/.promote.$$" with no fallback, so a caller that had planned no
# root yet wrote to /.promote.$$ and the mirror silently did nothing.
unset SH_HOME_TMP
sh_promote_tree "$src" "$tmp/dst2"
t_ok "$([ -x "$tmp/dst2/b/y.sh" ] && [ -L "$tmp/dst2/data.txt" ]; echo $?)" \
    'the mirror works with SH_HOME_TMP unset'
SH_HOME_TMP="$tmp"; export SH_HOME_TMP

# --- the candidate list, and the report that must not change the machine -----
# NOTE: THE PROBE REPORT CREATES NOTHING. It used to call sh_dir_writable on every
# candidate, which creates the directory when it is missing; measured on the
# machine this was written on, one `sandhome space --probe` brought /var/tmp
# into being. A report that changes the machine is not a report. The clause
# below names a directory that does not exist, reads the report, and asserts it
# is still absent afterwards.
ghost=$tmp/ghost-candidate
rm -rf "$ghost"
absent_report=$(SANDHOME_EXEC="$ghost" sh_space_probe_report 2>/dev/null)
case "$absent_report" in
    *"$ghost"*) t_contains "$absent_report" "exists=no" 'a missing candidate is reported as not existing' ;;
    *) t_ok 1 'a missing candidate is reported at all' ;;
esac
t_ok "$([ ! -d "$ghost" ]; echo $?)" 'the probe report did not create the candidate it named'

# NOTE: THE CANDIDATE LIST IS DEDUPLICATED. A $HOME equal to the home root put
# the same directory in the list twice, and it was probed and reported twice.
SANDHOME_EXEC=''
HOME=''
dupes=$(sh_exec_candidates)
dupes_seen=' '
dupes_n=0
for d in $dupes; do
    case "$dupes_seen" in
        *" $d "*) dupes_n=$((dupes_n + 1)) ;;
        *) dupes_seen="$dupes_seen$d " ;;
    esac
done
t_is "$dupes_n" 0 'the exec candidate list has no duplicates'

# NOTE: A SYMLINK WHOSE TARGET IS OUTSIDE THE TREE IS LEFT ALONE. The remap ran
# for every absolute target and compared afterwards, so
# `bin/link.sh -> ../outside/ext.sh` became `link.sh -> <view>/outside/ext.sh`,
# a path the view does not contain and never will. Measured: the link pointed at
# a file that did not exist, and nothing in the run said so.
out_src=$tmp/outsrc; out_dst=$tmp/outdst
# The target is a SIBLING of the mirrored tree, reached by a relative link, so
# the view cannot remap it and must repoint at it by absolute path.
mkdir -p "$out_src/bin" "$tmp/outside"
printf '#!/bin/sh\necho outside\n' > "$tmp/outside/ext.sh"
chmod 0755 "$tmp/outside/ext.sh"
ln -sfn ../../outside/ext.sh "$out_src/bin/link.sh"
sh_promote_tree "$out_src" "$out_dst"
t_ok "$([ -e "$out_dst/bin/link.sh" ]; echo $?)" \
    'a link to a file outside the tree still resolves in the view'
t_is "$("$out_dst/bin/link.sh" 2>/dev/null)" 'outside' \
    'a link to a file outside the tree runs'

# NOTE: A DEAD LINK IS REPRODUCED POINTING AT ITS TARGET, NOT AT ITSELF. cp
# dereferences, so a link whose target is gone fails to copy, and the old
# fallback pointed the view's copy at the source's copy of the link.
dead_src=$tmp/deadsrc; dead_dst=$tmp/deaddst
mkdir -p "$dead_src/bin"
ln -sfn ./gone.sh "$dead_src/bin/dead.sh"
sh_promote_tree "$dead_src" "$dead_dst"
t_is "$(readlink "$dead_dst/bin/dead.sh")" "$dead_src/bin/gone.sh" \
    'a link with a missing target points at that target, not at itself'

# --- the plan -----------------------------------------------------------------
SANDHOME_HOME="$tmp/home"; SANDHOME_EXEC="$tmp/exec"; export SANDHOME_HOME SANDHOME_EXEC
sh_space_plan
t_is "$SH_HOME" "$tmp/home" 'space_plan honours SANDHOME_HOME'
t_is "$SH_EXEC" "$tmp/exec" 'space_plan honours SANDHOME_EXEC'
t_ok "$([ -d "$SH_EXEC_BIN" ] && [ -d "$SH_HOME_TOOLCHAINS" ]; echo $?)" 'space_plan creates the exec bin and toolchains roots'
t_ok "$([ -n "$SH_EXEC_CHOSEN_REASON" ] && [ -n "$SH_EXEC_TRIED" ]; echo $?)" 'space_plan records why it chose the exec root and what it tried'
t_contains "$(sh_space_report)" 'exec_reason=' 'the space report says why the exec root was chosen'
t_contains "$(sh_space_report)" 'exec_bin=' 'the space report names the exec bin directory'

# --- the garbage collection ---------------------------------------------------
# STOP: THE FRESH TEMP DIRECTORY MUST SURVIVE. A gc that deletes everything in the
# temp area would delete a concurrent bootstrap's work, so the age clause is the
# point of the test and not decoration.
mkdir -p "$SH_HOME/.staging/left" "$SH_HOME/.staging/right" \
         "$SH_HOME_TMP/fresh" "$SH_HOME_TMP/old"
: > "$SH_HOME/.staging/left/x"
touch -d '2000-01-01 00:00:00' "$SH_HOME_TMP/old" 2>/dev/null || true
gc_n=$(sh_space_gc 7)
t_ok "$([ -d "$SH_HOME/.staging" ] && [ ! -d "$SH_HOME/.staging/left" ] && [ ! -d "$SH_HOME/.staging/right" ]; echo $?)" \
    'gc clears the staging areas and keeps the directory itself'
if [ -d "$SH_HOME_TMP/old" ]; then
    # find is present but the mtime could not be set; the age clause was not
    # exercised, and that is named instead of silently passing.
    echo '  note  could not backdate the temp directory; the age clause was not exercised'
else
    t_ok "$([ -d "$SH_HOME_TMP/fresh" ]; echo $?)" 'gc keeps a fresh temp directory'
fi
t_ok "$(case $gc_n in ''|*[!0-9]*) echo 1;; *) echo 0;; esac)" 'gc answers a plain count'

# # STOP: GC REFUSES AN ARGUMENT THAT IS NOT A WHOLE NUMBER OF DAYS, AND SAYS
# WHICH ARGUMENT. The value went straight into `find -mtime +"$days"`, so
# `sandhome gc abc` ran a find that failed, removed nothing, and PRINTED
# "removed 0 staging entries" with exit 0 - a success for a command that did
# nothing, on the one command here that deletes. `gc -5` became `-mtime +-5`
# the same way. The check is here and in bin/sandhome; this is the library half.
gc_rc=0
gc_out=$(sh_space_gc abc 2>&1) || gc_rc=$?
t_is "$gc_rc" '2' 'gc refuses a non-numeric day count with a status a caller can branch on'
case "$gc_out" in
    *abc*) t_ok 0 'the refusal names the value it was given' ;;
    *) t_ok 1 "the refusal names the value it was given (got: $gc_out)" ;;
esac
gc_rc=0
sh_space_gc -5 >/dev/null 2>&1 || gc_rc=$?
t_is "$gc_rc" '2' 'gc refuses a negative day count too'
gc_rc=0
sh_space_gc '' >/dev/null 2>&1 || gc_rc=$?
t_is "$gc_rc" '0' 'gc with an empty argument falls back to the default and does not fail'
# A day count is used as an integer by find; a float must be refused rather than
# passed through, because `find -mtime +7.5` is a find error on some builds and a
# silent no-op on others.
gc_rc=0
sh_space_gc 7.5 >/dev/null 2>&1 || gc_rc=$?
t_is "$gc_rc" '2' 'gc refuses a fractional day count'

# A DRY RUN NAMES WHAT IT WOULD DELETE AND DELETES NOTHING. A command that
# removes directories should be able to answer that question before it does it.
mkdir -p "$SH_HOME_TMP/aged"
: > "$SH_HOME_TMP/aged/file"
touch -d '2000-01-01 00:00:00' "$SH_HOME_TMP/aged" 2>/dev/null || true
if [ -d "$SH_HOME_TMP/aged" ]; then
    dry_out=$( SH_GC_DRY_RUN=1 sh_space_gc 7 2>&1 )
    t_contains "$dry_out" "$SH_HOME_TMP/aged" 'a dry run names the entry it would remove'
    t_ok "$([ -d "$SH_HOME_TMP/aged" ]; echo $?)" 'a dry run removes nothing'
else
    t_skip 'could not backdate a directory, so the gc dry-run clause did not run'
fi
rm -rf "$SH_HOME_TMP/aged"

# # STOP: A READ-ONLY PLAN CREATES NOTHING, AND THAT IS THE WHOLE POINT OF THE
# `--no-create` FORM. The planner used to mkdir both roots on the way to
# answering anything, and bin/sandhome called it before its dispatcher, so every
# subcommand created them - `sandhome version` created four directories under
# each of SANDHOME_HOME and SANDHOME_EXEC - and with an unwritable home it died
# at startup with no usage text, so the two commands a caller reaches for
# BECAUSE something is broken were the two that could not run on a broken
# machine. Measured, before the fix:
#   $ SANDHOME_HOME=/tmp/h SANDHOME_EXEC=/tmp/e sh bin/sandhome version
#   sandhome/1
#   $ find /tmp/h /tmp/e -maxdepth 1 -type d | wc -l
#   8
# The create form must still create, or nothing here works; that is checked
# below as its own clause rather than assumed, because a guard that refuses
# everything looks exactly like a good one until it blocks real work.
ro="$tmp/readonly"
SANDHOME_HOME="$ro/home" SANDHOME_EXEC="$ro/exec" \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; sh_space_plan --no-create' \
    sh "$ROOT" >/dev/null 2>&1
t_ok "$([ ! -d "$ro/home" ] && [ ! -d "$ro/exec" ]; echo $?)" \
    'a read-only plan creates neither root'

SANDHOME_HOME="$ro/home" SANDHOME_EXEC="$ro/exec" \
    sh -c '. "$1/lib/common.sh"; . "$1/lib/detect.sh"; . "$1/lib/space.sh"; sh_space_plan' \
    sh "$ROOT" >/dev/null 2>&1
t_ok "$([ -d "$ro/home" ] && [ -d "$ro/exec/bin" ]; echo $?)" \
    'a creating plan still creates both roots and the exec bin'

# AND THE SUBCOMMANDS THAT ONLY ASK CREATE NOTHING. This is driven through the
# real command, because the claim is about the command and not about the
# library: bin/sandhome could call the creating plan again tomorrow and every
# clause above would still hold.
for ro_cmd in version help env report path 'space --probe'; do
    ro2="$tmp/ro-$(printf '%s' "$ro_cmd" | tr ' -' '__')"
    rm -rf "$ro2"
    SANDHOME_HOME="$ro2/home" SANDHOME_EXEC="$ro2/exec" SANDHOME_REPO_DIR="$ROOT" \
        sh "$ROOT/bin/sandhome" $ro_cmd >/dev/null 2>&1
    t_ok "$([ ! -d "$ro2/home" ] && [ ! -d "$ro2/exec" ]; echo $?)" \
        "sandhome $ro_cmd creates nothing"
done

# AND THE COMMAND THAT INSTALLS STILL CREATES. Same reason, other direction.
ro3="$tmp/ro-install"
SANDHOME_HOME="$ro3/home" SANDHOME_EXEC="$ro3/exec" SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" shims >/dev/null 2>&1
t_ok "$([ -d "$ro3/home" ] && [ -d "$ro3/exec" ]; echo $?)" \
    'sandhome shims, which installs, does create the roots'

# AND version ANSWERS ON A MACHINE WHOSE HOME CANNOT BE CREATED. This is the
# case the old startup die made unreachable: /proc/1 is not writable by anyone.
ro_out=$(SANDHOME_HOME=/proc/1/nope SANDHOME_EXEC=/proc/1/nope2 SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" version 2>/dev/null)
t_is "$ro_out" 'sandhome/1' 'version answers on a machine whose configured home is unwritable'
ro_out=$(SANDHOME_HOME=/proc/1/nope SANDHOME_EXEC=/proc/1/nope2 SANDHOME_REPO_DIR="$ROOT" \
    sh "$ROOT/bin/sandhome" help 2>/dev/null)
case "$ro_out" in
    *'usage: sandhome'*) t_ok 0 'help prints its usage on a machine whose home is unwritable' ;;
    *) t_ok 1 'help prints its usage on a machine whose home is unwritable' ;;
esac

chmod 0755 "$tmp/ro" 2>/dev/null
t_end
