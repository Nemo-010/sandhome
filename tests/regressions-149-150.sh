#!/bin/sh
# tests/regressions-149-150.sh - one clause for each defect fixed in the round
# that closed issues #149 and #150, and for the review findings the rogue
# PR #148 left behind.
#
# WHY A FILE OF ITS OWN. The #141-#147 clauses live in regressions-141-147.sh;
# this file holds the explicit-root round (#149) and the go launch-mode round
# (#150), plus the five review findings against PR #148 itself: the dead
# collapse condition, the divergent dispatcher lists, the ptrace gate that
# read an absent answer as working, the space tags that named paths gc never
# touches, and the mirror that read SH_EXEC while the tree works from
# SANDHOME_EXEC.
#
# The clauses are BEHAVIOURAL where a cheap isolated call can ask the question.
# Each names the mechanism, fails against the tree as it stood when filed, and
# holds after. The two end-to-end proofs (a real --exec bootstrap and a real
# go build) live in consumer-proof/, because they need a network and room.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space env fetch toolchain shim report; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT; SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin regressions-149-150

tmp=$(t_exec_tmpdir sandhome-regr-149-150)
sh_regr_tmp=$tmp
trap 'rm -rf "$sh_regr_tmp"' EXIT

# --- #149: the collapse reads the plan, not the caller's variable -----------
# bin/sandhome binds SANDHOME_EXEC from SH_EXEC at every entry point, so a
# condition on SANDHOME_EXEC being empty never fires: the collapse went dead
# for the ordinary no-root case and every payload was copied needlessly.
# SH_EXEC = SH_HOME is the plan saying there is no separate root.
mkdir -p "$tmp/col/home/toolchains" "$tmp/col/home/views" "$tmp/col/exec/views"
col_case() {
    SH_HOME="$tmp/col/home" SH_EXEC="$1" SH_HOME_EXEC="$2" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/space.sh"; if [ "$SH_HOME_EXEC" = yes ] && [ "$SH_EXEC" = "$SH_HOME" ]; then printf collapse; else printf split; fi' \
        "$ROOT" 2>/dev/null
}
t_is "$(col_case "$tmp/col/home" yes)" 'collapse' 'an exec-capable home with no separate root still collapses (#149)'
t_is "$(col_case "$tmp/col/exec" yes)" 'split' 'a named exec root is not collapsed into the home (#149)'
t_is "$(col_case "$tmp/col/exec" no)" 'split' 'a noexec home never collapses (#149)'

# --- #149: space reports where payloads actually are --------------------------
# The plan says where things should go; payloads= says where they are, read
# off disk, so the two answers cannot disagree again.
mkdir -p "$tmp/pl/home/toolchains/jq/bin" "$tmp/pl/home/toolchains/ripgrep/bin" \
         "$tmp/pl/exec/views/jq" "$tmp/pl/exec/bin" "$tmp/pl/home/tmp"
# Only a real payload counts: the gate checks the module's declared binaries,
# so an empty directory or an auxiliary seed is not a collapse.
printf 'x\n' > "$tmp/pl/home/toolchains/jq/bin/jq" 2>/dev/null
printf 'x\n' > "$tmp/pl/home/toolchains/ripgrep/bin/rg" 2>/dev/null
t_is "$(SH_HOME="$tmp/pl/home" SH_HOME_TOOLCHAINS="$tmp/pl/home/toolchains" SH_EXEC="$tmp/pl/exec" SH_EXEC_VIEWS="$tmp/pl/exec/views" sh_space_payloads 2>/dev/null)" \
    'both' 'payloads=both when one view is on the exec root and one is not (#149)'
mkdir -p "$tmp/pl2/home/toolchains/jq/bin" "$tmp/pl2/exec/views" "$tmp/pl2/exec/bin" "$tmp/pl2/home/tmp"
printf 'x\n' > "$tmp/pl2/home/toolchains/jq/bin/jq" 2>/dev/null
t_is "$(SH_HOME="$tmp/pl2/home" SH_HOME_TOOLCHAINS="$tmp/pl2/home/toolchains" SH_EXEC="$tmp/pl2/exec" SH_EXEC_VIEWS="$tmp/pl2/exec/views" sh_space_payloads 2>/dev/null)" \
    'home' 'payloads=home when no view reached the exec root (#149)'
mkdir -p "$tmp/pl3/home/toolchains/jq/bin" "$tmp/pl3/exec/views/jq" "$tmp/pl3/exec/bin" "$tmp/pl3/home/tmp"
printf 'x\n' > "$tmp/pl3/home/toolchains/jq/bin/jq" 2>/dev/null
t_is "$(SH_HOME="$tmp/pl3/home" SH_HOME_TOOLCHAINS="$tmp/pl3/home/toolchains" SH_EXEC="$tmp/pl3/exec" SH_EXEC_VIEWS="$tmp/pl3/exec/views" sh_space_payloads 2>/dev/null)" \
    'exec' 'payloads=exec when every view is on the exec root (#149)'
mkdir -p "$tmp/pl4/home/toolchains" "$tmp/pl4/exec/views" "$tmp/pl4/exec/bin" "$tmp/pl4/home/tmp"
t_is "$(SH_HOME="$tmp/pl4/home" SH_HOME_TOOLCHAINS="$tmp/pl4/home/toolchains" SH_EXEC="$tmp/pl4/exec" SH_EXEC_VIEWS="$tmp/pl4/exec/views" sh_space_payloads 2>/dev/null)" \
    'none' 'payloads=none when nothing is installed (#149)'
# An auxiliary seed is not a payload: the npm tree tc_node_ensure_npm fetches
# for an adopted node has no declared node binary, so it is not counted and
# cannot fail the split gate on its own.
mkdir -p "$tmp/pl5/home/toolchains/node/npm/bin" "$tmp/pl5/exec/views" "$tmp/pl5/exec/bin" "$tmp/pl5/home/tmp"
printf 'x\n' > "$tmp/pl5/home/toolchains/node/npm/bin/npm-cli.js" 2>/dev/null
t_is "$(SH_HOME="$tmp/pl5/home" SH_HOME_TOOLCHAINS="$tmp/pl5/home/toolchains" SH_EXEC="$tmp/pl5/exec" SH_EXEC_VIEWS="$tmp/pl5/exec/views" sh_space_payloads 2>/dev/null)" \
    'none' 'an adopted npm seed is not counted as a payload (#149)'
t_is "$(SH_HOME="$tmp/pl3/home" SH_HOME_TOOLCHAINS="$tmp/pl3/home/toolchains" SH_EXEC="$tmp/pl3/exec" SH_EXEC_VIEWS="$tmp/pl3/exec/views" SH_HOME_EXEC=yes SH_EXEC_CHOSEN_REASON=explicit SH_EXEC_BIN="$tmp/pl3/exec/bin" sh_space_report 2>/dev/null | sed -n 's/^payloads=//p')" \
    'exec' 'the space report carries payloads= (#149)'

# --- #149: doctor fails a split the caller asked for and did not get ---------
# When the exec root was explicitly named and differs from the home, every
# installed payload must have its view on the exec root. Driven through
# sh_doctor itself so both directions are seen.
split_doctor_case() {
    dh="$tmp/sd/home"; de="$tmp/sd/exec"
    mkdir -p "$dh/toolchains/jq/bin" "$de/bin" "$de/views" "$dh/tmp" 2>/dev/null
    # A real payload, not an empty directory: the gate counts only what the
    # module's declared binaries prove is installed, so an auxiliary seed
    # (the npm tree tc_node_ensure_npm fetches for an adopted node) is not a
    # collapse. jq declares bin/jq.
    printf 'x\n' > "$dh/toolchains/jq/bin/jq" 2>/dev/null
    if [ "$1" = with-view ]; then mkdir -p "$de/views/jq" 2>/dev/null; fi
    printf 'SANDHOME_HOME=%s\nSANDHOME_EXEC=%s\n' "$dh" "$de" > "$dh/env.sh" 2>/dev/null
    SH_HOME="$dh" SH_EXEC="$de" SH_EXEC_BIN="$de/bin" SH_HOME_TOOLCHAINS="$dh/toolchains" \
    SH_EXEC_VIEWS="$de/views" SH_HOME_TMP="$dh/tmp" SH_HOME_EXEC=no SH_EXEC_CHOSEN_REASON=explicit \
    SANDHOME_HOME="$dh" SANDHOME_EXEC="$de" SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/env.sh"; . "$0/lib/toolchain.sh"; . "$0/lib/shim.sh"; . "$0/lib/report.sh"
               sh_doctor 2>/dev/null | sed -n "s/^[^ ]*  *split_views=//p"' \
        "$ROOT" 2>/dev/null | head -1
}
case "$(split_doctor_case without-view)" in
    explicit:*) t_ok 0 'doctor fails an explicit split whose view never reached the exec root (#149)' ;;
    *) t_ok 1 "doctor fails an explicit split whose view never reached the exec root (#149; got: $(split_doctor_case without-view))" ;;
esac
case "$(split_doctor_case with-view)" in
    ok) t_ok 0 'doctor passes an explicit split whose views are on the exec root (control, #149)' ;;
    *) t_ok 1 "doctor passes an explicit split whose views are on the exec root (control, #149; got: $(split_doctor_case with-view))" ;;
esac

# --- review 2: every sandbox directory resolves through the hook -------------
# The dispatcher had three copies of the sandbox-directory list and they
# disagreed: the linker linked a `cargo install` CLI while the fallback lookup
# omitted cargo-install/bin, so the hook exposed a name it could not resolve.
# Both halves are generated from sh_global_sandbox_dirs now; this clause is
# the contract, measured with a CLI in each directory.
mkdir -p "$tmp/dgsb/exec/bin" "$tmp/dgsb/home" "$tmp/dgsb/hook" "$tmp/dgsb/home/tmp"
for dgsb_rel in uv-bin npm-global/bin go-bin cargo-install/bin; do
    mkdir -p "$tmp/dgsb/exec/$dgsb_rel" 2>/dev/null
    # Two directories end in bin, so the name is built from the whole relative
    # path rather than the basename, or the second overwrites the first and
    # the clause measures its own fixture.
    # Two directories end in bin, so the name carries the parent directory too, or
    # the second overwrites the first and the clause measures its own fixture.
    # A read loop is the wrong tool here: without a trailing newline some
    # shells run zero iterations and the name comes back empty, which then
    # passes the resolve check vacuously. Parameter expansion is exact.
    dgsb_safe=$dgsb_rel
    case "$dgsb_safe" in
        */*) dgsb_safe=${dgsb_safe%%/*}-${dgsb_safe##*/} ;;
    esac
    dgsb_name="dgsb-$dgsb_safe"
    printf '#!/bin/sh\necho %s\n' "$dgsb_name" > "$tmp/dgsb/exec/$dgsb_rel/$dgsb_name" 2>/dev/null
    chmod 0755 "$tmp/dgsb/exec/$dgsb_rel/$dgsb_name" 2>/dev/null
done
SH_HOME="$tmp/dgsb/home" SH_EXEC="$tmp/dgsb/exec" SH_EXEC_BIN="$tmp/dgsb/exec/bin" SH_REPO_DIR="$ROOT" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_global_write_dispatch "$1" "$2" "$3"' \
    "$ROOT" "$tmp/dgsb/hook/.sandhome-dispatch" "$tmp/dgsb/home" "$tmp/dgsb/exec/bin" >/dev/null 2>&1
for dgsb_rel in uv-bin npm-global/bin go-bin cargo-install/bin; do
    dgsb_safe=$dgsb_rel
    case "$dgsb_safe" in
        */*) dgsb_safe=${dgsb_safe%%/*}-${dgsb_safe##*/} ;;
    esac
    dgsb_name="dgsb-$dgsb_safe"
    ln -sf .sandhome-dispatch "$tmp/dgsb/hook/$dgsb_name" 2>/dev/null
    dgsb_out=$(env -i PATH="$tmp/dgsb/hook:/usr/bin:/bin" HOME="$tmp/dgsb/home" SANDHOME_EXEC="$tmp/dgsb/exec" \
        sh -c "$dgsb_name" 2>&1 | head -1)
    if [ "$dgsb_out" = "$dgsb_name" ]; then
        t_ok 0 "a CLI in $dgsb_rel resolves through the hook (#142)"
    else
        t_ok 1 "a CLI in $dgsb_rel resolves through the hook (#142; got: $dgsb_out)"
    fi
done
# The installer literal inside the dispatcher must name the same directories
# the function names, or the next sandbox directory repeats this defect.
for dgsb_rel in $(sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_global_sandbox_dirs' "$ROOT" 2>/dev/null); do
    case "$(cat "$tmp/dgsb/hook/.sandhome-dispatch" 2>/dev/null)" in
        *"$dgsb_rel"*) t_ok 0 "the generated dispatcher names $dgsb_rel (#142)" ;;
        *) t_ok 1 "the generated dispatcher names $dgsb_rel (#142)" ;;
    esac
done

# --- review 3: the sanitizer workaround covers every unmeasured answer -------
# The probe returns yes, no, partial or unknown; the gate used to skip on an
# empty answer, so a host the probe never ran on silently lost the workaround.
asan_body() {
    SH_HOME="$tmp/as" SH_EXEC="$tmp/as-exec" SH_REPO_DIR="$ROOT" SH_PTRACE="$1" \
        SANDHOME_ASAN="$2" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_env_body' "$ROOT" 2>/dev/null
}
case "$(asan_body no on)" in
    *'ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"'*) t_ok 0 'env.sh disables leak checking when ptrace=no (#144)' ;;
    *) t_ok 1 'env.sh disables leak checking when ptrace=no (#144)' ;;
esac
case "$(asan_body yes on)" in
    *'detect_leaks=0'*) t_ok 1 'env.sh leaves leak checking on when ptrace=yes (#144)' ;;
    *) t_ok 0 'env.sh leaves leak checking on when ptrace=yes (#144)' ;;
esac
case "$(asan_body '' on)" in
    *'detect_leaks=0'*) t_ok 0 'env.sh applies the workaround when the probe never ran (#144)' ;;
    *) t_ok 1 'env.sh applies the workaround when the probe never ran (#144)' ;;
esac
case "$(asan_body unknown on)" in
    *'detect_leaks=0'*) t_ok 0 'env.sh applies the workaround when ptrace=unknown (#144)' ;;
    *) t_ok 1 'env.sh applies the workaround when ptrace=unknown (#144)' ;;
esac
case "$(asan_body no off)" in
    *'detect_leaks=0'*) t_ok 1 'SANDHOME_ASAN=off restores leak checking (#144)' ;;
    *) t_ok 0 'SANDHOME_ASAN=off restores leak checking (#144)' ;;
esac
case "$(asan_body no on)" in
    *"SANDHOME_PTRACE='no'"*) t_ok 0 'env.sh records the ptrace answer (#144)' ;;
    *) t_ok 1 'env.sh records the ptrace answer (#144)' ;;
esac

# --- review 4: the tags name what gc actually does -----------------------------
# gc clears $SH_EXEC/cache, $SH_EXEC/tmp and either .staging; the tag named
# $SH_EXEC/staging, which this tree never creates, so a real .staging entry
# read as yours while gc removes it.
mkdir -p "$tmp/sl4/exec/.staging" "$tmp/sl4/exec/cache" "$tmp/sl4/exec/go-bin" "$tmp/sl4/home/tmp"
head -c 4096 /dev/zero > "$tmp/sl4/exec/.staging/f" 2>/dev/null
head -c 4096 /dev/zero > "$tmp/sl4/exec/cache/f" 2>/dev/null
head -c 4096 /dev/zero > "$tmp/sl4/exec/go-bin/tool" 2>/dev/null
sl4_out=$(SH_HOME="$tmp/sl4/home" SH_EXEC="$tmp/sl4/exec" sh_space_largest 10 2>/dev/null)
case "$sl4_out" in
    *"$tmp/sl4/exec/.staging"*'(reclaim)'*) t_ok 0 'space --largest tags .staging as reclaim (#141)' ;;
    *) t_ok 1 "space --largest tags .staging as reclaim (#141; got: $sl4_out)" ;;
esac
case "$sl4_out" in
    *"$tmp/sl4/exec/cache"*'(reclaim)'*) t_ok 0 'space --largest tags cache as reclaim (#141)' ;;
    *) t_ok 1 "space --largest tags cache as reclaim (#141; got: $sl4_out)" ;;
esac
case "$sl4_out" in
    *"$tmp/sl4/exec/go-bin"*'(sandhome)'*) t_ok 0 'space --largest tags go-bin as sandhome: owned, gc keeps it (#141)' ;;
    *) t_ok 1 "space --largest tags go-bin as sandhome: owned, gc keeps it (#141; got: $sl4_out)" ;;
esac

# --- review 5: the mirror is written through SANDHOME_EXEC alone --------------
# bin/sandhome binds SANDHOME_EXEC from SH_EXEC at every entry point, and the
# dispatcher, env.sh and the plan all work from the bound name; only the mirror
# and the launcher reads took ${SH_EXEC:-}. A caller holding the bound name got
# an early return 0, so the mirror was silently not written.
mkdir -p "$tmp/mir2/exec/bin" "$tmp/mir2/home" "$tmp/mir2/repo/lib" "$tmp/mir2/repo/bin"
printf 'REVIEW marker\n' > "$tmp/mir2/repo/lib/common.sh"
printf '#!/bin/sh\n' > "$tmp/mir2/repo/bin/sandhome"
SH_HOME="$tmp/mir2/home" SANDHOME_EXEC="$tmp/mir2/exec" SH_REPO_DIR="$tmp/mir2/repo" \
    sh -c '. "$0/lib/common.sh"; . "$0/lib/env.sh"; sh_exec_install_launchers' "$ROOT" >/dev/null 2>&1
if [ -r "$tmp/mir2/exec/.sandhome-lib/lib/common.sh" ] && \
   grep -q 'REVIEW marker' "$tmp/mir2/exec/.sandhome-lib/lib/common.sh" 2>/dev/null; then
    t_ok 0 'the mirror is written when only SANDHOME_EXEC is set (#147)'
else
    t_ok 1 'the mirror is written when only SANDHOME_EXEC is set (#147)'
fi

# --- #150: go is a real copy in a launch-mode view -----------------------------
# The memexec view gives a tool the anonymous /memfd path as its process
# image. go derives GOROOT from its own executable and forks its own tools out
# of pkg/tool/, so a launcher copy answers `go version` (the whole probe) and
# then fails every build. Five modules declare tc_<name>_copy_bins for this;
# go declared none (issue #77 recurring).
case "$(sh -c '. "$0/lib/common.sh"; . "$0/lib/space.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/go.sh"; sh_toolchain_root() { printf "%s" "/root/$1"; }; tc_go_copy_bins' "$ROOT" 2>/dev/null)" in
    *go/bin/go*) t_ok 0 'go declares the go launcher as a real copy in the view (#150)' ;;
    *) t_ok 1 'go declares the go launcher as a real copy in the view (#150)' ;;
esac
# The declaration is tested, not this host's tree: globbing a fixture root
# finds nothing, and the clause would then measure the machine, not the module.
case "$(sed -n '/^tc_go_copy_bins()/,/^}/p' "$ROOT/tools/go.sh" 2>/dev/null)" in
    *'go/pkg/tool'*) t_ok 0 'go declares the compiler tools it forks as real copies (#150)' ;;
    *) t_ok 1 'go declares the compiler tools it forks as real copies (#150)' ;;
esac
# The probe must be able to fail, which is #77 ask 2. `go version` is the one
# subcommand that cannot fail on this defect. `go version` may appear in the
# comment explaining why it is wrong; only a bare `go version` as the command
# is a failure.
go_probe=$(sed -n '/^tc_go_probe()/,/^}/p' "$ROOT/tools/go.sh" 2>/dev/null)
case "$go_probe" in
    *'go env GOROOT'*) t_ok 0 'the go probe exercises GOROOT, not just --version (#150)' ;;
    *) t_ok 1 'the go probe exercises GOROOT, not just --version (#150)' ;;
esac
case "$go_probe" in
    *'sh_have go && go version'*) t_ok 1 'the go probe no longer accepts a bare version (#150)' ;;
    *) t_ok 0 'the go probe no longer accepts a bare version (#150)' ;;
esac

# --- #146: a kept archive is reused without touching the network -------------
# A second `--extra` used to re-download the 63MB archive it already held,
# because reuse needed a recorded pin and codeberg publishes no digest; with
# the network down the run then died holding only deleted bytes. The recorded
# tag beside the archive now answers which release it holds: the same tag
# extracts locally, a corrupt one falls through to a fresh fetch, and a failed
# tag resolution proceeds on the recorded release and says so. No network in
# any of these clauses: the tag resolver and the fetcher are stubbed, so a
# fetch attempt fails the clause instead of hanging it.
if command -v tar >/dev/null 2>&1 && command -v xz >/dev/null 2>&1; then
    mkdir -p "$tmp/qu/fake/qemu-linux-x86_64-test/bin" "$tmp/qu/qemuuser" 2>/dev/null
    printf '#!/bin/sh\necho emu\n' > "$tmp/qu/fake/qemu-linux-x86_64-test/bin/qemu-x86_64" 2>/dev/null
    printf '#!/bin/sh\necho emu\n' > "$tmp/qu/fake/qemu-linux-x86_64-test/bin/qemu-aarch64" 2>/dev/null
    chmod 0755 "$tmp/qu/fake/qemu-linux-x86_64-test/bin/"* 2>/dev/null
    ( cd "$tmp/qu/fake" && tar -cJf "$tmp/qu/pack.tar.xz" qemu-linux-x86_64-test 2>/dev/null ) || true
    if [ -f "$tmp/qu/pack.tar.xz" ]; then
        # Same recorded release: local extract, no fetch, both guests land.
        rm -rf "$tmp/qu/qemuuser"; mkdir -p "$tmp/qu/qemuuser"
        cp "$tmp/qu/pack.tar.xz" "$tmp/qu/qemuuser/qu.tar.xz" 2>/dev/null
        printf '%s' '11.1.1.1 qemu-linux-x86_64' > "$tmp/qu/qemuuser/qu.tag" 2>/dev/null
        : > "$tmp/qu/fetches"
        qu_out=$(SH_HOME_TOOLCHAINS="$tmp/qu" SH_KERNEL=Linux SH_ARCH=x86_64 \
            SH_HOME="$tmp/qu" SH_EXEC="$tmp/qu-exec" SH_EXEC_BIN="$tmp/qu-exec/bin" \
            SANDHOME_QEMUUSER_EXTRA=aarch64 QU_TAG='11.1.1.1' QU_FETCH_CALLS="$tmp/qu/fetches" \
            sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"
                tc_qemuuser_tag() { printf "%s" "$QU_TAG"; }
                sh_fetch_verified() { printf x >> "$QU_FETCH_CALLS"; return 1; }
                : > "$QU_FETCH_CALLS"
                if tc_qemuuser_install >/dev/null 2>&1; then printf install-ok; else printf install-fail; fi' \
            "$ROOT" 2>/dev/null)
        t_is "$qu_out" 'install-ok' 'a kept archive of the recorded release installs with no fetch (#146)'
        t_is "$(cat "$tmp/qu/fetches" 2>/dev/null | wc -c | tr -d ' ')" '0' 'the recorded release costs zero fetch calls (#146)'
        if [ -x "$tmp/qu/qemuuser/bin/qemu-aarch64" ] && [ -x "$tmp/qu/qemuuser/bin/qemu-x86_64" ]; then
            t_ok 0 'the local extract lands host and extra guests (#146)'
        else
            t_ok 1 'the local extract lands host and extra guests (#146)'
        fi
        # Tag resolution down, archive kept: proceed on the recorded release.
        : > "$tmp/qu/fetches"
        qu_out2=$(SH_HOME_TOOLCHAINS="$tmp/qu" SH_KERNEL=Linux SH_ARCH=x86_64 \
            SH_HOME="$tmp/qu" SH_EXEC="$tmp/qu-exec" SH_EXEC_BIN="$tmp/qu-exec/bin" \
            SANDHOME_QEMUUSER_EXTRA=aarch64 QU_FETCH_CALLS="$tmp/qu/fetches" \
            sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"
                tc_qemuuser_tag() { return 1; }
                sh_fetch_verified() { printf x >> "$QU_FETCH_CALLS"; return 1; }
                : > "$QU_FETCH_CALLS"
                if tc_qemuuser_install >/dev/null 2>&1; then printf install-ok; else printf install-fail; fi' \
            "$ROOT" 2>/dev/null)
        t_is "$qu_out2" 'install-ok' 'a failed tag resolution falls back to the kept archive (#146)'
        t_is "$(cat "$tmp/qu/fetches" 2>/dev/null | wc -c | tr -d ' ')" '0' 'the fallback costs zero fetch calls (#146)'
        # Corrupt kept archive: falls through to a fetch, which fails here.
        printf 'not an archive\n' > "$tmp/qu/qemuuser/qu.tar.xz" 2>/dev/null
        : > "$tmp/qu/fetches"
        qu_out3=$(SH_HOME_TOOLCHAINS="$tmp/qu" SH_KERNEL=Linux SH_ARCH=x86_64 \
            SH_HOME="$tmp/qu" SH_EXEC="$tmp/qu-exec" SH_EXEC_BIN="$tmp/qu-exec/bin" \
            SANDHOME_QEMUUSER_EXTRA=aarch64 QU_TAG='11.1.1.1' QU_FETCH_CALLS="$tmp/qu/fetches" \
            sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"
                tc_qemuuser_tag() { printf "%s" "$QU_TAG"; }
                sh_fetch_verified() { printf x >> "$QU_FETCH_CALLS"; return 1; }
                : > "$QU_FETCH_CALLS"
                if tc_qemuuser_install >/dev/null 2>&1; then printf install-ok; else printf install-fail; fi' \
            "$ROOT" 2>/dev/null)
        t_is "$qu_out3" 'install-fail' 'a corrupt kept archive falls through to a fetch, not a silent success (#146)'
        case "$(cat "$tmp/qu/fetches" 2>/dev/null)" in
            ?*) t_ok 0 'the corrupt archive triggered a fetch attempt (#146)' ;;
            *) t_ok 1 'the corrupt archive triggered a fetch attempt (#146)' ;;
        esac
        # A moved tag discards the kept bytes and fetches the new release.
        printf '%s' '10.9.9.9 qemu-linux-x86_64' > "$tmp/qu/qemuuser/qu.tag" 2>/dev/null
        cp "$tmp/qu/pack.tar.xz" "$tmp/qu/qemuuser/qu.tar.xz" 2>/dev/null
        : > "$tmp/qu/fetches"
        qu_out4=$(SH_HOME_TOOLCHAINS="$tmp/qu" SH_KERNEL=Linux SH_ARCH=x86_64 \
            SH_HOME="$tmp/qu" SH_EXEC="$tmp/qu-exec" SH_EXEC_BIN="$tmp/qu-exec/bin" \
            SANDHOME_QEMUUSER_EXTRA=aarch64 QU_TAG='11.1.1.1' QU_FETCH_CALLS="$tmp/qu/fetches" \
            sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"
                tc_qemuuser_tag() { printf "%s" "$QU_TAG"; }
                sh_fetch_verified() { printf x >> "$QU_FETCH_CALLS"; return 1; }
                : > "$QU_FETCH_CALLS"
                if tc_qemuuser_install >/dev/null 2>&1; then printf install-ok; else printf install-fail; fi' \
            "$ROOT" 2>/dev/null)
        t_is "$qu_out4" 'install-fail' 'a moved tag does not reuse the old bytes (#146)'
        case "$(cat "$tmp/qu/fetches" 2>/dev/null)" in
            ?*) t_ok 0 'the moved tag triggered a fetch attempt (#146)' ;;
            *) t_ok 1 'the moved tag triggered a fetch attempt (#146)' ;;
esac
        # No archive and no tag resolution: fail without touching the network.
        rm -rf "$tmp/qu/qemuuser"; mkdir -p "$tmp/qu/qemuuser"
        : > "$tmp/qu/fetches"
        qu_out5=$(SH_HOME_TOOLCHAINS="$tmp/qu" SH_KERNEL=Linux SH_ARCH=x86_64 \
            SH_HOME="$tmp/qu" SH_EXEC="$tmp/qu-exec" SH_EXEC_BIN="$tmp/qu-exec/bin" \
            SANDHOME_QEMUUSER_EXTRA=aarch64 QU_FETCH_CALLS="$tmp/qu/fetches" \
            sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/toolchain.sh"; . "$0/tools/qemuuser.sh"
                tc_qemuuser_tag() { return 1; }
                sh_fetch_verified() { printf x >> "$QU_FETCH_CALLS"; return 1; }
                : > "$QU_FETCH_CALLS"
                if tc_qemuuser_install >/dev/null 2>&1; then printf install-ok; else printf install-fail; fi' \
            "$ROOT" 2>/dev/null)
        t_is "$qu_out5" 'install-fail' 'no archive and no tag resolution fails instead of installing nothing (#146)'
    else
        t_skip 'tar+xz could not pack the qemu fixture here (#146)'
    fi
else
    t_skip 'no tar+xz here, so the qemu reuse clauses cannot run (#146)'
fi
# The node fragment points both caches at the exec root; this gate fails while
# either points elsewhere, so the fragment cannot rot back to the home default.
# --- #143: doctor checks the browser caches when node is wanted ---------------
# The node fragment points both caches at the exec root; this gate fails while
# either points elsewhere, so the fragment cannot rot back to the home default.
browser_doctor_case() {
    dh="$tmp/bd/home"; de="$tmp/bd/exec"
    mkdir -p "$dh" "$de/bin" "$de/views" "$dh/tmp" 2>/dev/null
    printf '#!/bin/sh\nexit 0\n' > "$de/bin/sandhome" 2>/dev/null
    printf 'SANDHOME_HOME=%s\nSANDHOME_EXEC=%s\nSANDHOME_WANTED_TOOLCHAINS=%s\n' "$dh" "$de" "$1" > "$dh/env.sh" 2>/dev/null
    SH_HOME="$dh" SH_EXEC="$de" SH_EXEC_BIN="$de/bin" SH_HOME_TOOLCHAINS="$dh/toolchains" \
    SH_EXEC_VIEWS="$de/views" SH_HOME_TMP="$dh/tmp" SH_HOME_EXEC=no \
    SANDHOME_HOME="$dh" SANDHOME_EXEC="$de" PUPPETEER_CACHE_DIR="$2" PLAYWRIGHT_BROWSERS_PATH="$3" \
    SH_LIB_DIR="$ROOT/lib" SH_REPO_DIR="$ROOT" \
        sh -c '. "$0/lib/common.sh"; . "$0/lib/detect.sh"; . "$0/lib/space.sh"; . "$0/lib/fetch.sh"; . "$0/lib/env.sh"; . "$0/lib/toolchain.sh"; . "$0/lib/shim.sh"; . "$0/lib/report.sh"
               sh_doctor 2>/dev/null | grep -E "PUPPETEER_CACHE_DIR|PLAYWRIGHT_BROWSERS_PATH"' \
        "$ROOT" 2>/dev/null | head -2
}
if [ -z "$(browser_doctor_case 'node' "$tmp/bd/exec/puppeteer" "$tmp/bd/exec/ms-playwright")" ]; then
    t_ok 0 'doctor passes browser caches pointed at the exec root (control, #143)'
else
    t_ok 1 'doctor passes browser caches pointed at the exec root (control, #143)'
fi
case "$(browser_doctor_case 'node' '' '')" in
    *PUPPETEER_CACHE_DIR*) t_ok 0 'doctor fails a node setup whose browser cache points at the home (#143)' ;;
    *) t_ok 1 'doctor fails a node setup whose browser cache points at the home (#143)' ;;
esac
case "$(browser_doctor_case 'jq' '' '')" in
    *PUPPETEER_CACHE_DIR*) t_ok 1 'doctor ignores browser caches when node is not wanted (control, #143)' ;;
    *) t_ok 0 'doctor ignores browser caches when node is not wanted (control, #143)' ;;
esac

t_end
