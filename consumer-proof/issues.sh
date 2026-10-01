#!/bin/sh
# issues.sh TREE LABEL HOMEDIR EXECDIR [--stamp] -- reproduce every one of the
# nine open reports against TREE, in the shape each report claims, and print
# one line per report with the command and what it answered.
#
# Run twice: once against the pristine tree (failing-before), once against the
# fix (passing-after). The launch-style fixture is opt-in (`--stamp`) because it
# is a hand-made view; without it a run on a host whose seccomp filter blocks
# memfd_create measures copy mode, and says so in its own header.
set -u
TREE=$1
LABEL=$2
HOMEDIR=$3
EXECDIR=$4
STAMP=${5:-}
H=$HOMEDIR
E=$EXECDIR
RIG=/workspace/tri/$LABEL
W=$RIG/wsbin
P="$H/bin:$W:/usr/local/bin:/usr/bin:/bin"
LOG=$RIG/issues.log
mkdir -p "$W" 2>/dev/null
: > "$LOG"

fresh()  { env -i HOME="$H" PATH="$P" "$@" </dev/null 2>&1; }
freshenv() { env -i HOME="$H" PATH="$P" http_proxy="$http_proxy" https_proxy="$https_proxy" no_proxy="$no_proxy" "$@" </dev/null 2>&1; }
fs()     { fresh sh -c "$1"; }
lg()     { fresh bash -lc "$1"; }
line()   { printf '%s\n' "$*" | tee -a "$LOG"; }
show()   { printf '   $ %s\n' "$*" | tee -a "$LOG"; }
out()    { "$@" 2>&1 | sed 's/^/   | /' | tee -a "$LOG"; }
fsfile() { fresh sh -c "$1" > "$RIG/.o" 2>&1; sed 's/^/   | /' "$RIG/.o" | tee -a "$LOG"; }

line "### $LABEL: reproducing #131-#139 against $TREE"
line "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
line "roots: home=$H exec=$E"
line "install: $(grep -E '^view=' "$RIG/bootstrap.log" 2>/dev/null | head -1) $(grep -E '^memexec=' "$RIG/bootstrap.log" 2>/dev/null | head -1)"
# restamp, applied per section below rather than once, because #139 needs the
# real copy back afterwards.
stamp_views() {
    [ "$STAMP" = --stamp ] || return 0
    for f in "$E"/views/*/bin/*; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        cp -f "$E/bin/sandhome-memexec" "$f" 2>/dev/null && chmod 0755 "$f" 2>/dev/null
    done
    return 0
}
unstamp_views() {
    [ "$STAMP" = --stamp ] || return 0
    ( cd "$TREE" && env -i HOME="$H" PATH="$P" \
        http_proxy="$http_proxy" https_proxy="$https_proxy" no_proxy="$no_proxy" \
        sh "$TREE/bootstrap.sh" --toolset none --only node --exec "$E" ) >>"$RIG/bootstrap.log" 2>&1
    return 0
}

# ------------------------------------------------------------------ #131
line ""
line "#131 a non-interactive login shell resolves exec/bin before the env is loaded"
stamp_views
show "bash -lc 'jq --version'"
out lg 'jq --version'
show "bash -lc 'echo \$SANDHOME_EXEC' (did the login shell load the environment?)"
out lg 'printf "%s\n" "${SANDHOME_EXEC:-UNSET}"'
show "bash -lc 'node --version'"
out lg 'node --version'
unstamp_views
show "sh -c 'jq --version' (non-login: no profile, the hook only)"
out fs 'jq --version'

# ------------------------------------------------------------------ #132
line ""
line "#132 the global hook must expose every tool the view advertises"
out fs 'for t in node npm npx; do printf "  %-5s %s\n" "$t" "$(command -v "$t" 2>/dev/null || echo NONE)"; done'
out fs 'npm --version'

# ------------------------------------------------------------------ #133
line ""
line "#133 the bake in exec/bin/sandhome must survive install and repair"
if [ -x "$E/bin/sandhome" ]; then
    b1=$(grep -c "^SH_BAKED_REPO_DIR='/" "$E/bin/sandhome" 2>/dev/null)
    line "   baked repo lines right after the bootstrap: $b1"
    fs 'sandhome repair jq' >/dev/null 2>&1
    b2=$(grep -c "^SH_BAKED_REPO_DIR='/" "$E/bin/sandhome" 2>/dev/null)
    line "   after 'sandhome repair jq':  $b2"
    fs 'sandhome install jq' >/dev/null 2>&1
    b3=$(grep -c "^SH_BAKED_REPO_DIR='/" "$E/bin/sandhome" 2>/dev/null)
    line "   after 'sandhome install jq': $b3"
    show "env -i \$SANDHOME_EXEC/bin/sandhome doctor  (no HOME, no PATH, no environment)"
    env -i "$E/bin/sandhome" doctor </dev/null 2>&1 | tail -2 | sed 's/^/   | /' | tee -a "$LOG"
    env -i "$E/bin/sandhome" doctor </dev/null >/dev/null 2>&1; line "   rc=$?"
    show "the same with the CHECKOUT GONE, which is what the pointers cannot survive"
    if [ -n "${SANDHOME_RIG_CLONE:-}" ] && [ -d "$SANDHOME_RIG_CLONE" ]; then
        mv "$SANDHOME_RIG_CLONE" "$SANDHOME_RIG_CLONE.gone.$$" 2>/dev/null
        env -i "$E/bin/sandhome" doctor </dev/null 2>&1 | tail -2 | sed 's/^/   | /' | tee -a "$LOG"
        env -i "$E/bin/sandhome" doctor </dev/null >/dev/null 2>&1; line "   rc=$?"
        mv "$SANDHOME_RIG_CLONE.gone.$$" "$SANDHOME_RIG_CLONE" 2>/dev/null
    else
        line "   (no clone recorded for this rig; skipped)"
    fi
fi

# ------------------------------------------------------------------ #134
line ""
line "#134 the skills: the setup installs them, so the document must say so and the check is a command"
line "   ~/.agents/skills: $(ls "$H"/.agents/skills/*/SKILL.md 2>/dev/null | wc -l) SKILL.md files"
show "sandhome skills"
fsfile 'sandhome skills'
line "   hand-written curl lines in ROUTE.md step 2: $(grep -c 'curl -fsSL https://raw.githubusercontent.com/talaria0101/sandhome/main/skills' "$TREE/ROUTE.md") (the documented --no-skills fallback, kept on purpose)"
t_contains_ro=$(grep -c 'The setup already installed them' "$TREE/ROUTE.md" 2>/dev/null)
line "   ROUTE.md leads with the fact instead: $([ "$t_contains_ro" -gt 0 ] && echo yes || echo no)"

# ------------------------------------------------------------------ #135
line ""
line "#135 rust: TC_rust_BINS must name rustc, and a fresh shell must get it"
line "   $(grep -E '^TC_rust_BINS=' "$TREE/tools/rust.sh")"
show "sandhome install rust   (the fix's own regression: the toolchain is installed)"
freshenv sh -c 'sandhome install rust >/dev/null 2>&1; for t in cargo rustc rustdoc cargo-fmt; do printf "  %-11s %s\n" "$t" "$(command -v "$t" 2>/dev/null || echo NONE)"; done' > "$RIG/.o135" 2>&1
sed 's/^/   | /' "$RIG/.o135" | tee -a "$LOG"
show "rustc --version from a shell that sourced nothing"
fsfile 'rustc --version'

# ------------------------------------------------------------------ #136
line ""
line "#136 a bare sandhome on a POSIX shell"
for sh_ in dash sh bash; do
    command -v $sh_ >/dev/null 2>&1 || continue
    show "$sh_ bin/sandhome   (no arguments)"
    env -i HOME="$H" PATH="$P" "$sh_" "$TREE/bin/sandhome" </dev/null 2>&1 | head -2 | sed 's/^/   | /' | tee -a "$LOG"
    env -i HOME="$H" PATH="$P" "$sh_" "$TREE/bin/sandhome" </dev/null >/dev/null 2>&1
    line "   rc=$?"
    show "$sh_ bin/sandhome help doctor   (the page for one command)"
    env -i HOME="$H" PATH="$P" "$sh_" "$TREE/bin/sandhome" help doctor </dev/null 2>&1 | head -1 | sed 's/^/   | /' | tee -a "$LOG"
    env -i HOME="$H" PATH="$P" "$sh_" "$TREE/bin/sandhome" help doctor </dev/null >/dev/null 2>&1
    line "   rc=$?"
done

# ------------------------------------------------------------------ #137
line ""
line "#137 sandhome project: the node half, and the exit status"
rm -rf "$E/projects/p137" "$E/projects/p137b" 2>/dev/null
show "sandhome project p137 --no-link  (a fresh shell with the hook, nothing sourced)"
out fs 'cd /tmp && sandhome project p137 --no-link'
line "   package.json exists: $([ -f "$E/projects/p137/package.json" ] && echo yes || echo NO)"
out fs 'cd /tmp && sandhome project p137b --no-link >/dev/null 2>&1; printf "exit status: %s\n" "$?"'

# ------------------------------------------------------------------ #138
line ""
line "#138 npm install -g: the prefix bin must stay a real directory"
# The prefix lives under SANDHOME_EXEC, which a fresh shell has no variable
# for, so every fact here is read from a tool the hook dispatches (whose
# environment is loaded) or from the recorded root on disk.
fsfile 'node -e "
  const fs=require(\"fs\"), p=require(\"path\");
  const b=p.join(process.env.SANDHOME_EXEC,\"npm-global\",\"bin\");
  let s=null; try { s=fs.readlinkSync(b); } catch (e) {}
  console.log(\"  \"+b);
  console.log(\"  is a real directory: \"+(s===null));
  if (s) console.log(\"  is a symlink to: \"+s);
"'
show "npm install -g cowsay (through the hook, with the prefix on PATH)"
freshenv sh -c 'sandhome exec --shell "npm install -g cowsay" 2>&1 | tail -2; export PATH=$SANDHOME_EXEC/npm-global/bin:$PATH; printf "  which: %s\n" "$(command -v cowsay || echo NONE)"; cowsay --version 2>&1' > "$RIG/.o138b" 2>&1
sed 's/^/   | /' "$RIG/.o138b" | tee -a "$LOG"
show "control: the same link in a REAL bin directory, same shell, same PATH shape"
rm -rf "$RIG/npmctl" 2>/dev/null; mkdir -p "$RIG/npmctl/bin" 2>/dev/null
cp -rL "$E/npm-global/lib" "$RIG/npmctl/lib" 2>/dev/null
( cd "$RIG/npmctl/bin" && ln -sfn ../lib/node_modules/cowsay/cli.js cowsay ) 2>/dev/null
freshenv sh -c 'export PATH='"$RIG"'/npmctl/bin:$PATH; printf "  which: %s\n" "$(command -v cowsay || echo NONE)"; cowsay --version 2>&1' > "$RIG/.o138ctl" 2>&1
sed 's/^/   | /' "$RIG/.o138ctl" | tee -a "$LOG"
show "a CLI installed after the setup, from a shell that sourced NOTHING"
fsfile 'command -v cowsay; cowsay --version 2>&1'
show "and after ONE refresh, which is how the hook learns a CLI it did not ship with"
fsfile 'sandhome global >/dev/null 2>&1; command -v cowsay; cowsay --version 2>&1'
fsfile 'node -e "
  const fs=require(\"fs\"), p=require(\"path\");
  const b=p.join(process.env.SANDHOME_EXEC,\"npm-global\",\"bin\",\"cowsay\");
  let t=null; try { t=fs.readlinkSync(b); } catch (e) {}
  console.log(\"  the link npm wrote: \"+(t||\"(none)\"));
  try { fs.accessSync(b, fs.X_OK); console.log(\"  runnable: yes\"); }
  catch (e) { console.log(\"  runnable: NO (\"+e.code+\")\"); }
"'

# ------------------------------------------------------------------ #139
line ""
line "#139 a runtime that spawns itself"
fsfile 'node -e "console.log(process.execPath)"'
show "node -e 'spawnSync(process.execPath)'"
fsfile 'node -e "const r=require(\"child_process\").spawnSync(process.execPath,[\"-e\",\"0\"]); console.log(\"status=\"+r.status+\" error=\"+(r.error&&r.error.code))"'
line "   doctor has a spawn check: $(grep -c '_spawn' "$TREE/lib/report.sh") clause(s)"
line "   node is a real copy in the view: $(grep -c 'bin/node' "$TREE/tools/node.sh") declaration(s)"
show "doctor, from a shell that sourced nothing"
fsfile 'sandhome doctor 2>&1 | grep -E "_spawn|doctor_failures"'
if [ "$STAMP" = --stamp ]; then
    line "   (now the launch-mode fixture, to show what the real copy protects against)"
    stamp_views
    fsfile 'node -e "console.log(process.execPath)"'
    fsfile 'node -e "const r=require(\"child_process\").spawnSync(process.execPath,[\"-e\",\"0\"]); console.log(\"status=\"+r.status+\" error=\"+(r.error&&r.error.code))"'
    show "doctor with the view stamped: the gate must FAIL, and name the fix"
    fsfile 'sandhome doctor 2>&1 | grep -E "_spawn|doctor_failures"'
    unstamp_views
    show "doctor again, with the real copy restored"
    fsfile 'sandhome doctor 2>&1 | grep -E "_spawn|doctor_failures"'
fi

line ""
line "### end $LABEL"