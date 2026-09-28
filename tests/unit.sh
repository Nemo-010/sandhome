#!/bin/sh
# tests/unit.sh - the pure helpers, the ones whose correctness does not need a
# machine. A helper exercised only through a full bootstrap is a helper whose bug
# arrives disguised as a bootstrap failure.
#
# Exit 2 when the library cannot be loaded.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space fetch env toolchain; do
    [ -r "$ROOT/lib/$m.sh" ] || { echo "unit: no lib/$m.sh" >&2; exit 2; }
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_REPO_DIR=$ROOT
SH_LIB_DIR=$ROOT/lib
export SH_REPO_DIR SH_LIB_DIR

t_begin unit

# sh_ref_default VAR FILE -> the default the reference's table records for VAR,
# or the empty string. It reads the committed FILE and never runs the generator,
# which is the whole point: tests/docs.sh already compares the two, so a clause
# that used the generator too would agree with it by construction. The value is
# taken with parameter expansion rather than with cut or awk, because this file
# runs on a userland that may carry neither.
sh_ref_default() {
    sh_rd_var=$1
    sh_rd_file=$2
    sh_rd_want="| \`$sh_rd_var\` |"
    sh_rd_got=''
    while IFS= read -r sh_rd_line || [ -n "$sh_rd_line" ]; do
        case "$sh_rd_line" in
            "$sh_rd_want"*)
                sh_rd_got=${sh_rd_line##*| \`}
                sh_rd_got=${sh_rd_got%\` |*}
                break
                ;;
        esac
    done < "$sh_rd_file"
    printf '%s' "$sh_rd_got"
}

t_is "$(sh_split_on ',' 'a,b,c')" 'a b c' 'split_on replaces commas'
t_is "$(sh_split_on '/@' '@scope/pkg')" ' scope pkg' 'split_on takes several separators'
t_is "$(sh_split_on ',' '')" '' 'split_on of an empty string is empty'

t_ok "$(sh_in_list b 'a,b,c'; echo $?)" 'split list membership: b' 
sh_in_list b 'a,b,c' && t_ok 0 'in_list finds a comma-separated member' || t_ok 1 'in_list finds a comma-separated member'
sh_in_list z 'a b c' && t_ok 1 'in_list rejects an absent member' || t_ok 0 'in_list rejects an absent member'
sh_in_list b 'a|b|c' && t_ok 0 'in_list finds a pipe-separated member' || t_ok 1 'in_list finds a pipe-separated member'

t_is "$(sh_trim '   padded   ')" 'padded' 'trim removes surrounding blanks'

t_is "$(sh_json_escape 'a"b')" 'a\"b' 'json_escape escapes a quote'
t_is "$(sh_json_escape 'a\b')" 'a\\b' 'json_escape escapes a backslash'
# NOTE: EVERY CONTROL CHARACTER ESCAPES, AND THE RESULT PARSES. The escaper had a
# literal tab in one case arm and none at all for a newline or a carriage
# return, so a version string carrying one of them - a toolchain's first line of
# output goes through here - emitted a raw control byte and produced a JSON
# object no parser accepts. The tempting fix, `nl=$(printf '\n')`, is itself
# wrong: command substitution strips a trailing newline, so the variable is
# empty and the arm can never match. These assert the escaping itself and then
# assert that a document built from it is parseable, which is the property the
# report depends on.
t_is "$(sh_json_escape "$(printf 'a\tb')")" 'a\tb' 'json_escape escapes a tab'
t_is "$(sh_json_escape "$(printf 'a\nb')")" 'a\nb' 'json_escape escapes a newline'
t_is "$(sh_json_escape "$(printf 'a\rb')")" 'a\rb' 'json_escape escapes a carriage return'
for ctl in t n r; do
    doc=$(printf '{"v":"%s"}' "$(sh_json_escape "$(printf "x${ctl}y")")")
    if command -v jq >/dev/null 2>&1; then
        if printf '%s' "$doc" | jq -e . >/dev/null 2>&1; then
            t_ok 0 "a document carrying a $ctl parses as JSON"
        else
            t_ok 1 "a document carrying a $ctl parses as JSON ($doc)"
        fi
    else
        t_skip 'no jq to parse the JSON with'
    fi
done

t_is "$(sh_first_line printf 'one\ntwo\n')" 'one' 'first_line takes the first line'
t_is "$(sh_first_word printf 'one two three\n')" 'one' 'first_word takes the first word'
# STOP: NO TRAILING NEWLINE. `read` fails at EOF there and the answer was dropped.
t_is "$(sh_first_line printf 'one')" 'one' 'first_line answers without a trailing newline'
t_is "$(sh_first_word printf 'go1.27.1')" 'go1.27.1' 'first_word answers without a trailing newline'

# The arch spellings, because a wrong one is a 404 that reads as a network error.
SH_ARCH=x86_64;  t_is "$(sh_arch_go)"   amd64 'arch_go x86_64 -> amd64'
SH_ARCH=aarch64; t_is "$(sh_arch_node)" arm64 'arch_node aarch64 -> arm64'
SH_ARCH=x86_64; SH_KERNEL=Linux; SH_LIBC=glibc
t_is "$(sh_arch_rust)" 'x86_64-unknown-linux-gnu' 'arch_rust x86_64 glibc'
SH_LIBC=musl
t_is "$(sh_arch_rust)" 'x86_64-unknown-linux-musl' 'arch_rust x86_64 musl'

sh_detect_all
t_ok "$([ -n "$SH_KERNEL" ] && [ -n "$SH_ARCH" ] && [ -n "$SH_LIBC" ]; echo $?)" 'detect_all fills the basics'
t_ok "$(case "$SH_PRIVILEGE" in root|sudo|none) echo 0 ;; *) echo 1 ;; esac)" 'privilege is three-valued'

# free_mb answers a number for a directory that exists and nothing for one that
# does not; a wrong answer here makes the space plan choose a full root.
free=$(sh_free_mb /tmp)
case "$free" in
    ''|*[!0-9]*) t_ok 1 "free_mb /tmp is numeric (got '$free')" ;;
    *)           t_ok 0 "free_mb /tmp is numeric" ;;
esac
t_is "$(sh_free_mb /nonexistent-sandhome-path)" '' 'free_mb of a missing path is empty'

# is_exec_file: a shared object must NOT be copied onto the exec root. This is
# the measurement the whole split rests on, so it is asserted directly.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-unit.XXXXXX")
: > "$tmp/data.txt"
printf '#!/bin/sh\nexit 0\n' > "$tmp/run.sh"; chmod 0755 "$tmp/run.sh"
: > "$tmp/libfoo.so"; chmod 0755 "$tmp/libfoo.so"
sh_is_exec_file "$tmp/run.sh" && t_ok 0 'is_exec_file accepts an executable' || t_ok 1 'is_exec_file accepts an executable'
sh_is_exec_file "$tmp/data.txt" && t_ok 1 'is_exec_file rejects a data file' || t_ok 0 'is_exec_file rejects a data file'
sh_is_exec_file "$tmp/libfoo.so" && t_ok 1 'is_exec_file rejects a shared object' || t_ok 0 'is_exec_file rejects a shared object'

# sh_sq_quote: every path written into env.sh passes through this. A home with
# an apostrophe or a space in it must survive being written and read back.
t_is "$(sh_sq_quote /a/b)" "'/a/b'" 'sq_quote wraps a plain path'
t_is "$(sh_sq_quote "/a b/c")" "'/a b/c'" 'sq_quote keeps a space inside the quotes'
t_is "$(sh_sq_quote "/a'b/c")" "'/a'\\''b/c'" 'sq_quote escapes an apostrophe'
q=$(sh_sq_quote "/a'b c")
t_is "$(sh -c "printf '%s' $q")" "/a'b c" 'the quoted form reads back byte for byte'

# sh_dirname without dirname (issue #16). dirname semantics for bare names:
# `${x%/*}` alone leaves them unchanged where dirname answers `.`.
t_is "$(sh_dirname /a/b/c)" '/a/b' 'dirname of a nested path is its parent'
t_is "$(sh_dirname /a/b/.shim-build.123)" '/a/b' 'dirname of the shim error path is its parent'
t_is "$(sh_dirname .sandhome-build.123)" '.' 'dirname of a bare filename is dot'
t_is "$(sh_dirname /)" '/' 'dirname of root stays root'
t_is "$(sh_dirname /a)" '/' 'dirname of a top-level entry is root'
# The shim build must succeed with no dirname on PATH: the fallback used to
# degrade the mkdir target to `.` and swallow it with 2>/dev/null || true.
nd_bin="$tmp/nodirname-bin"
mkdir -p "$nd_bin"
for nd_t in sh dash cc gcc as ld chmod cp mv rm mkdir cat uname id; do
    if command -v "$nd_t" >/dev/null 2>&1; then
        ln -sf "$(command -v "$nd_t")" "$nd_bin/$nd_t" 2>/dev/null || true
    fi
done
if [ -x "$nd_bin/cc" ] || [ -x "$nd_bin/gcc" ]; then
    cat > "$tmp/nd-run.sh" <<EOF
. "$ROOT/lib/common.sh"
. "$ROOT/lib/shim.sh"
mkdir -p "\$SH_HOME_TMP"
sh_shim_build fakepty "$ROOT/shims/fakepty.c"
EOF
    nd_out=$(PATH="$nd_bin" SH_HOME="$tmp/ndhome" SH_HOME_TMP="$tmp/ndhome/tmp" SH_PTY=no SH_PASSWD=yes sh "$tmp/nd-run.sh" 2>&1)
    nd_rc=$?
    t_is "$nd_rc" 0 'shim build succeeds with dirname off PATH'
    case "$nd_out" in
        *'built '*) t_ok 0 'shim build reports the built object with dirname off PATH' ;;
        *) t_ok 1 "shim build reports the built object with dirname off PATH ($nd_out)" ;;
    esac
else
    t_skip 'no compiler to drive the dirname-less shim build'
fi

# sh_lex_normalize: the mirrored-symlink rule rests on it, so a wrong answer here
# is a symlink pointing at the wrong file in every exec view.
t_is "$(sh_lex_normalize /a/b/../c)" '/a/c' 'lex_normalize resolves a parent'
t_is "$(sh_lex_normalize /a/./b/)" '/a/b' 'lex_normalize drops dots and a trailing slash'
t_is "$(sh_lex_normalize /a/b/../../..)" '/' 'lex_normalize clamps above the root'
t_is "$(sh_lex_normalize a/b/../c)" 'a/c' 'lex_normalize keeps a relative path relative'
t_is "$(sh_lex_normalize ../x/y)" '../x/y' 'lex_normalize keeps a leading parent in a relative path'
t_is "$(sh_lex_normalize /src/lib/tool/../tool/main.js)" '/src/lib/tool/main.js' 'the npm target normalizes inside its tree'

# The env file itself: source it in a child that starts with the variables
# unset, and read the paths back out. This is the defect a home with a space
# would have caused, so it is asserted through the generated bytes.
SH_HOME="/tmp/sandhome env's home"; SH_EXEC='/tmp/sandhome exec'
out=$(sh_env_body)
t_is "$(sh -c "$out
printf '%s' \"\$SANDHOME_HOME\"")" "$SH_HOME" 'env.sh round-trips a home with a space and an apostrophe'
t_is "$(sh -c "$out
printf '%s' \"\$SANDHOME_EXEC\"")" "$SH_EXEC" 'env.sh round-trips the exec root'
mkdir -p "$SH_HOME"
printf 'SH_PROFILE_OK=yes\n' > "$SH_HOME/profile.sh"
t_is "$(sh -c "$(sh_profile_source_line)
printf '%s' \"\$SH_PROFILE_OK\"")" 'yes' 'the profile source line reads a profile from a path with an apostrophe'

# The version parsers, run against local files so they are tested offline. Both
# were wrong once in the same direction: the first line was taken where the
# format does not put the answer on the first line.
. "$ROOT/tools/go.sh"
. "$ROOT/tools/node.sh"
SH_HOME_TMP=$tmp; export SH_HOME_TMP
gov_file="$tmp/go-version.txt"
printf 'go1.27.1\ntime 2026-08-28T16:20:06Z\n' > "$gov_file"
t_is "$(SANDHOME_GO_VERSION_URL="file://$gov_file" tc_go_version_latest)" 'go1.27.1' \
    'go resolves the version from the first line'
nidx_file="$tmp/index.json"
printf '[\n{"version":"v26.10.0","date":"2026-09-21"},\n{"version":"v24.0.0","date":"2025-01-01"}\n]\n' > "$nidx_file"
t_is "$(SANDHOME_NODE_INDEX_URL="file://$nidx_file" tc_node_latest_tag)" 'v26.10.0' \
    'node resolves the newest version, which is not on the first line'
# STOP: THE DIGEST IS LISTED IN dl/?mode=json AND NOT AT <file>.sha256, which is an
# HTML page. The source tarball's entry must not answer for the archive's.
gojson_file="$tmp/dl.json"
cat > "$gojson_file" <<'JSON'
[
 {
  "version": "go1.27.1",
  "files": [
   {
    "filename": "go1.27.1.src.tar.gz",
    "sha256": "aaa"
   },
   {
    "filename": "go1.27.1.linux-amd64.tar.gz",
    "sha256": "63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445"
   }
  ]
 }
]
JSON
t_is "$(tc_go_sha_from "$gojson_file" go1.27.1.linux-amd64.tar.gz)" \
    '63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445' \
    'go finds the archive digest, not the source digest'
t_is "$(tc_go_sha_from "$gojson_file" absent.tar.gz)" '' 'go answers nothing for a filename not listed'

# NOTE: THE DIGEST PARSER DOES NOT DEPEND ON THE FORMATTING. It used to set a flag on
# the line carrying "filename" and read the sha256 from a LATER line, so it
# worked only against go.dev's pretty-printed JSON. A compact document - one
# release per line, or any proxy that minifies - returned nothing, and the
# caller then passed an EMPTY expected digest, so the download went unchecked.
# Measured here: the compact form below answered nothing before the fix.
printf '[{"filename":"go1.27.1.linux-amd64.tar.gz","sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}]' > "$tmp/compact.json"
t_is "$(tc_go_sha_from "$tmp/compact.json" go1.27.1.linux-amd64.tar.gz)" 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
    'go reads the digest out of a compact one-line document'
printf '[{"filename":"a.tar.gz","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"filename":"b.tar.gz","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]' > "$tmp/many.json"
t_is "$(tc_go_sha_from "$tmp/many.json" a.tar.gz)" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 'go reads the first of two inline entries'
t_is "$(tc_go_sha_from "$tmp/many.json" b.tar.gz)" 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'go reads the second of two inline entries'

# NOTE: THE FILE READERS CARRY OUT A LAST LINE WITH NO NEWLINE. `while read` drops
# it and exits before the body has seen it, so a one-line document came back as
# the empty string and every parser built on it found nothing.
printf '[{"a":1}]' > "$tmp/nonewline.json"
t_is "$(sh_read_file_spaces "$tmp/nonewline.json")" '[{"a":1}] ' \
    'a one-line file with no trailing newline is read whole'
printf 'a\nb' > "$tmp/partial.json"
t_is "$(sh_read_file_spaces "$tmp/partial.json")" 'a b ' \
    'a final line with no trailing newline is carried out of the loop'
printf 'a\nb\n' > "$tmp/full.json"
t_is "$(sh_read_file_spaces "$tmp/full.json")" 'a b ' \
    'a newline-terminated file is read the same way'
t_is "$(sh_read_file "$tmp/partial.json")" 'ab' 'read_file joins the lines without a separator'

# # STOP: sh_upper IS A HELPER AND NOT `tr`, BECAUSE THE USERLANDS THIS TOOL
# RUNS ON CARRY NO tr. The pin resolver below builds environment-variable names
# out of it, and a version that shelled out to `tr` died on exactly the machine
# it was written for. It is also the one helper in this file that is not a
# single parameter expansion, so it is the one a reader can check by hand.
t_is "$(sh_upper jq)" 'JQ' 'upper folds a short name'
t_is "$(sh_upper 'Mixed_Case-9')" 'MIXED_CASE-9' 'upper leaves everything but a-z alone'
t_is "$(sh_upper '')" '' 'upper of nothing is nothing'
t_is "$(sh_upper a)Z" 'AZ' 'upper maps the first and last of the alphabet'
t_is "$(sh_upper abcxyz)" 'ABCXYZ' 'upper maps a whole word'

# --------------------------------------------------------------- digest pins --
# # STOP: ONE DIGEST FOR EVERY DOWNLOAD CANNOT PIN A TOOLSET. SANDHOME_SHA256
# was documented as "pin a sha256 for every download this run makes" and was
# passed to EVERY download, so a `cli` toolset - three downloads - could only
# ever match the first one and failed the other two with a message blaming the
# mirror. The result was ORDER-DEPENDENT, which is how a reader knows a check
# is broken rather than strict. A pin is now resolved per download.
JQ_URL='https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64'
RG_URL='https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz'
GO_URL='https://go.dev/dl/go1.27.1.linux-amd64.tar.gz'

t_is "$(SANDHOME_SHA256_JQ=pinjq sh_pin_for "$JQ_URL" jq)" 'pinjq' \
    'a jq pin answers for a jq download'
t_is "$(SANDHOME_SHA256_JQ=pinjq sh_pin_for "$RG_URL" ripgrep)" '' \
    'a jq pin does not answer for a ripgrep download'
t_is "$(SANDHOME_SHA256=one sh_pin_for "$RG_URL" ripgrep)" 'one' \
    'the bare value is a default that applies where nothing more specific is'
t_is "$(SANDHOME_SHA256_JQ=pinjq SANDHOME_SHA256=one sh_pin_for "$JQ_URL" jq)" 'pinjq' \
    'a named pin beats the bare default'
# THE LOAD-BEARING ORDER: a digest the PUBLISHER published outranks the bare
# value, so setting SANDHOME_SHA256 to pin one download no longer silently
# disables go.dev's own digest for another. That was the worst of the old
# behaviour - a weaker check the caller set for something else had turned off a
# stronger one - and it is a NO-OP in the wrong direction.
t_is "$(SANDHOME_SHA256=one sh_pin_for "$GO_URL" go published)" 'published' \
    'a published digest beats the bare default'
t_is "$(SANDHOME_SHA256=one SANDHOME_SHA256_GO=mine sh_pin_for "$GO_URL" go published)" 'mine' \
    'a caller pin beats the published digest'
t_is "$(sh_pin_for "$GO_URL" go)" '' 'no pin and no published digest answers nothing'

# # STOP: THE PIN KEY IS CUT BY HAND, BECAUSE `${url##*/}` IS GLOB SYNTAX AND AN
# URL IS NOT A GLOB. It answered the WHOLE URL for `https://x/jq?a=1` - there is
# no `/` after the last one it matches - so the key it built was
# `HTTPS://X/JQ?A=1`, and a query string has to come off before the extension.
t_is "$(sh_pin_key "$JQ_URL")" 'JQ-LINUX-AMD64' 'the pin key is the last path segment, upper-cased'
t_is "$(sh_pin_key 'https://x/uv.tar.gz?t=abc')" 'UV.TAR' 'a query string does not survive into the key'
t_is "$(sh_pin_key 'https://x/rustup-init')" 'RUSTUP-INIT' 'a file with no extension keeps its name'
# # STOP: THE LOOKUP IS A `case` AND NOT `eval`. `eval "x=\${$var:-}"` is the only
# indirect read POSIX sh has, and it is a command as soon as the name holds a
# hyphen, an asterisk or a slash. Both of those were produced here before the
# `case` replaced the arithmetic: `SANDHOME_SHA256_JQ-LINUX-AMD64=bbb` printed
# "not found" and a key built from an url printed "Bad substitution".
# # STOP: A POSIX sh ASSIGNMENT CANNOT HOLD A HYPHEN IN ITS NAME, SO THE
# VARIABLE IS UNDERSCORED WHILE THE KEY KEEPS THE FILE'S HYPHENS. The first
# design spelled the variable `SANDHOME_SHA256_JQ-LINUX-AMD64`, which a caller
# cannot set at all - `dash: SANDHOME_SHA256_JQ-LINUX-AMD64=bbb: not found` -
# so the arm that read it could never see a value. Both spellings are checked
# here because a key that stops matching its arm fails silently, answering
# nothing rather than something wrong.
t_is "$(SANDHOME_SHA256_JQ_LINUX_AMD64=pinasset sh_pin_for "$JQ_URL" jq)" 'pinasset' \
    'a pin named for a url asset is readable, which an eval-built name was not'
t_is "$(SANDHOME_SHA256_JQ_LINUX_AMD64=pinasset sh_pin_for "$JQ_URL" jq '')" 'pinasset' \
    'the asset pin answers even when the module passes no name'
t_is "$(SANDHOME_SHA256_JQ=bytool sh_pin_for "$JQ_URL" jq)" 'bytool' \
    'the toolchain-named pin still answers for the same url'
# # STOP: A PIN FOR ONE ASSET NEVER ANSWERS FOR ANOTHER, INCLUDING A DIFFERENT
# ARCHITECTURE OF THE SAME TOOL. The arms used to be `JQ-LINUX-*` reading
# SANDHOME_SHA256_JQ_LINUX_AMD64, so a caller who pinned the amd64 jq binary had
# that digest applied to the arm64 download on an arm64 machine. It is a check
# that passes for the wrong bytes, which is worse than no check because it looks
# like a check. Measured before the fix:
#   SANDHOME_SHA256_JQ_LINUX_AMD64=amd64digest
#   sh_pin_for https://x/jq-linux-arm64   ->  amd64digest
t_is "$(SANDHOME_SHA256_JQ_LINUX_AMD64=amd64d sh_pin_for 'https://x/jq-linux-arm64' jq)" '' \
    'an amd64 asset pin does not answer for the arm64 download'
t_is "$(SANDHOME_SHA256_JQ_LINUX_AMD64=amd64d sh_pin_for 'https://x/jq-macos-amd64' jq)" '' \
    'a linux asset pin does not answer for the macos download'
t_is "$(SANDHOME_SHA256_JQ_LINUX_ARM64=arm64d sh_pin_for 'https://x/jq-linux-arm64' jq)" 'arm64d' \
    'the arm64 asset pin answers for the arm64 download'
# And the wildcard arms that were doing the bleeding are gone entirely: a
# version with them reads the wrong variable for a differently-named asset.
t_is "$(SANDHOME_SHA256_JQ_LINUX_AMD64=amd64d sh_pin_for 'https://x/jq-linux-i386' jq)" '' \
    'an amd64 asset pin does not answer for the i386 download' 
t_is "$(sh_pin_names | tr -s ' \n' ' ')" ' fd go jq node python ripgrep rust ' \
    'the pin-name list is the shape the clause above assumes'

# EVERY MODULE HAS A PIN NAME, so a new toolchain cannot be added without one.
missing_pins=''
for m in "$ROOT"/tools/*.sh; do
    [ -r "$m" ] || continue
    mname=${m##*/}; mname=${mname%.sh}
    case " $(sh_pin_names) " in
        *" $mname "*) ;;
        *) missing_pins="$missing_pins $mname" ;;
    esac
done
t_is "$missing_pins" '' 'every toolchain module has a SANDHOME_SHA256_<name> pin'

# # STOP: THE PROVENANCE LINE IS NAMED AND QUOTED, BECAUSE AN UNQUOTED VALUE WITH
# A SPACE IN IT IS WORD-SPLIT BY dash INTO A COMMAND. `sh_fv_from=the release`
# printed "release: not found", left the variable UNSET, and killed the run at
# the next expansion with "sh: 134: sh_fv_from: parameter not set" - inside a
# printf, so it EXITED the process and the caller never saw a status at all.
# It is a dash RUNTIME behaviour: shellcheck does not flag it, so the guard has
# to be an executed clause. The whole of sh_fetch_verified is driven below
# through a local file under `set -u`, which is the only way to see this.
printf 'payload\n' > "$tmp/pin-target"
REAL_SHA=$(sha256sum "$tmp/pin-target" 2>/dev/null | cut -d' ' -f1)
if [ -n "$REAL_SHA" ]; then
    if ( . ./lib/common.sh; . ./lib/fetch.sh
          sh_fetch_verified "file://$tmp/pin-target" "$tmp/pin-dest" "$REAL_SHA" ) 2>"$tmp/fv-err"; then
        t_ok 0 'sh_fetch_verified returns 0 when the digest matches'
    else
        t_ok 1 "sh_fetch_verified returns 0 when the digest matches ($(cat "$tmp/fv-err"))"
    fi
    if ( . ./lib/common.sh; . ./lib/fetch.sh
          sh_fetch_verified "file://$tmp/pin-target" "$tmp/pin-dest2" \
          0000000000000000000000000000000000000000000000000000000000000000 ) 2>/dev/null; then
        t_ok 1 'a mismatched digest is refused'
    else
        t_ok 0 'a mismatched digest is refused'
    fi
    # The provenance line must survive the trip through `set -u` without
    # aborting, and must name the pin that answered rather than the string
    # "the release" when a pin answered.
    # curl writes a progress meter to stderr that would swamp the line, so the
    # fetcher is stubbed to a copy: what is under test is the DIGEST step, not
    # the transport, and sh_fetch_verified's own message is what is read.
    mkdir -p "$tmp/stub"
    # The real invocation is `curl -fSL --retry 3 --retry-delay 2 -o DEST URL`,
    # so the stub reads to -o, takes DEST, then copies URL to it. A one-liner
    # lost the URL to a shift and reported "cannot stat pin-dest3", which reads
    # like a failure of the thing under test and is not one.
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' 'if [ "${1:-}" = "--version" ]; then echo "curl stub"; exit 0; fi'
        printf '%s\n' 'while [ "$#" -gt 0 ] && [ "$1" != "-o" ]; do shift; done'
        printf '%s\n' '[ "$1" = "-o" ] || exit 1'
        printf '%s\n' 'shift'
        printf '%s\n' 'sh_stub_dest=$1'
        printf '%s\n' 'shift'
        printf '%s\n' 'sh_stub_src=$1'
        printf '%s\n' 'case "$sh_stub_src" in file://*) sh_stub_src=${sh_stub_src#file://} ;; esac'
        printf '%s\n' 'cp "$sh_stub_src" "$sh_stub_dest"'
    } > "$tmp/stub/curl"
    chmod +x "$tmp/stub/curl"
    fv_out=$( cd "$ROOT" && PATH="$tmp/stub:$PATH" SANDHOME_SHA256_JQ=$REAL_SHA sh -uc '
        . ./lib/common.sh
        . ./lib/fetch.sh
        sh_fetch_verified "file://'"$tmp"'/pin-target" "'"$tmp"'/pin-dest3" \
            "$(sh_pin_for "file://'"$tmp"'/pin-target" jq)" 2>&1' 2>/dev/null )
    # The URL here is a `file://` one whose asset key is PIN-TARGET, so the
    # pin that answers is neither the bare value nor a toolchain name; what the
    # line must NOT say is "the release", which is a false provenance for a
    # value the caller supplied.
    case "$fv_out" in
        *'the release'*) t_ok 1 'the digest step does not claim the release when a pin answered' ;;
        *) t_ok 0 'the digest step names the pin that answered, not the release' ;;
    esac
    case "$fv_out" in
        *'parameter not set'*) t_ok 1 'the digest step aborts under set -u' ;;
        *) t_ok 0 'the digest step does not abort under set -u' ;;
    esac
    # And with no pin at all, the provenance is the release, quoted and intact.
    fv_out2=$( cd "$ROOT" && PATH="$tmp/stub:$PATH" sh -uc '
        . ./lib/common.sh
        . ./lib/fetch.sh
        sh_fetch_verified "file://'"$tmp"'/pin-target" "'"$tmp"'/pin-dest4" 2>&1' 2>/dev/null )
    # With no pin at all there is nothing to compare against, so the line says
    # exactly that and never claims a match it did not make.
    case "$fv_out2" in
        *'no digest to compare against'*) t_ok 0 'with no pin the digest step says so plainly' ;;
        *) t_ok 1 "with no pin the digest step says so plainly (got: $fv_out2)" ;;
    esac
else
    t_skip 'no sha256 tool to check a digest with'
fi

# -------------------------------------------------- downloader probes --
# Issues #3 (capability probe, not PATH), #7 (provider-named prerequisite),
# #9 (probe by running, not by resolving). A downloader that resolves and
# then rejects its flags is the defect; the probe runs --version/--help.
mkdir -p "$tmp/dl"
cat > "$tmp/dl/curl" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "curl stub"; exit 0; fi
while [ "$#" -gt 0 ] && [ "$1" != "-o" ]; do shift; done
[ "$1" = "-o" ] || exit 1
shift
sh_stub_dest=$1
shift
sh_stub_src=$1
case "$sh_stub_src" in file://*) sh_stub_src=${sh_stub_src#file://} ;; esac
cp "$sh_stub_src" "$sh_stub_dest"
STUB
chmod +x "$tmp/dl/curl"
cat > "$tmp/dl/broken" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$tmp/dl/broken"
if ( PATH="$tmp/dl:$PATH" sh_tool_runs curl --version ) 2>/dev/null; then
    t_ok 0 'a downloader that answers --version probes as usable'
else
    t_ok 1 'a downloader that answers --version probes as usable'
fi
if ( PATH="$tmp/dl:$PATH" sh_tool_runs broken --version ) 2>/dev/null; then
    t_ok 1 'a binary that fails its probe is not a usable downloader'
else
    t_ok 0 'a binary that fails its probe is not a usable downloader'
fi
# Flavor follows the literal in --help output.
cat > "$tmp/dl/wget" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then echo "BusyBox v1.36 wget"; exit 0; fi
exit 0
STUB
chmod +x "$tmp/dl/wget"
t_is "$(PATH="$tmp/dl:$PATH" sh_wget_flavor)" 'busybox' 'wget --help naming BusyBox probes as busybox'
cat > "$tmp/dl/wget" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then echo "GNU Wget 1.21"; exit 0; fi
exit 0
STUB
chmod +x "$tmp/dl/wget"
t_is "$(PATH="$tmp/dl:$PATH" sh_wget_flavor)" 'gnu' 'wget --help naming GNU probes as gnu'
# Fallthrough: a curl that exists but fails must not block wget. The failing
# curl comes first on PATH; the working wget copies a file:// fixture.
printf 'fallthrough-bytes\n' > "$tmp/dl/src.txt"
cat > "$tmp/dl/curl" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "curl stub"; exit 0; fi
exit 1
STUB
chmod +x "$tmp/dl/curl"
cat > "$tmp/dl/wget" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then echo "GNU Wget 1.21"; exit 0; fi
while [ "$#" -gt 0 ] && [ "$1" != "-O" ]; do shift; done
[ "$1" = "-O" ] || exit 1
shift
dest=$1
shift
src=$1
case "$src" in file://*) src=${src#file://} ;; esac
cp "$src" "$dest"
STUB
chmod +x "$tmp/dl/wget"
rm -f "$tmp/dl/got.txt"
if PATH="$tmp/dl:$PATH" sh_fetch "file://$tmp/dl/src.txt" "$tmp/dl/got.txt" 2>/dev/null; then
    if [ -r "$tmp/dl/got.txt" ]; then
        t_ok 0 'sh_fetch falls through a failing curl to a working wget'
    else
        t_ok 1 'sh_fetch falls through a failing curl to a working wget (no bytes)'
    fi
else
    t_ok 1 'sh_fetch falls through a failing curl to a working wget (non-zero)'
fi
# Success names its route (issue #13): the line is what a later failure is
# diagnosed against.
route_out=$(PATH="$tmp/dl:$PATH" sh_fetch "file://$tmp/dl/src.txt" "$tmp/dl/got2.txt" 2>&1)
case "$route_out" in
    *'Downloaded from: '*) t_ok 0 'a successful fetch names the route it came from' ;;
    *) t_ok 1 "a successful fetch names the route it came from ($route_out)" ;;
esac
# The provider hint names the install (issue #7) instead of failing part-way.
SH_PROVIDER=apt
t_is "$(sh_downloader_hint)" 'apt-get install curl' 'the downloader hint names the apt install line'
SH_PROVIDER=bogus-provider
t_is "$(sh_downloader_hint)" '' 'an unknown provider yields no hint rather than a wrong one'
sh_detect_all >/dev/null 2>&1 || true
# Preflight (issue #5): with no downloader the install is refused up front
# with the provider line, rather than failing part-way through a download.
mkdir -p "$tmp/no-dl"
for nd_tool in sh dash mkdir rm cat; do
    if command -v "$nd_tool" >/dev/null 2>&1; then
        ln -sf "$(command -v "$nd_tool")" "$tmp/no-dl/$nd_tool" 2>/dev/null || true
    fi
done
if PATH="$tmp/no-dl" SH_PROVIDER=apt sh_toolchain_preflight jq 2>/dev/null; then
    t_ok 1 'preflight refuses an install with no downloader'
else
    t_ok 0 'preflight refuses an install with no downloader'
fi
pf_out=$(PATH="$tmp/no-dl" SH_PROVIDER=apt SH_EXEC= SH_EXEC_BIN= sh_toolchain_preflight jq 2>&1)
case "$pf_out" in
    *'apt-get install curl'*) t_ok 0 'the preflight refusal names the provider install line' ;;
    *) t_ok 1 "the preflight refusal names the provider install line ($pf_out)" ;;
esac
sh_detect_all >/dev/null 2>&1 || true

# ------------------------------------------------------- DoH gate --
# Issue #6: off unless asked; only curl exit 6 twice counts; the retry pins
# the resolver by IP literal. All clauses below run offline with stubs.
t_is "$(sh_doh_host_of 'https://1.1.1.1/dns-query')" '1.1.1.1' 'the DoH host of an IP literal is the address'
t_is "$(sh_doh_host_of 'https://dns.example.com/dns-query')" 'dns.example.com' 'the DoH host of a named URL is the name'
if sh_doh_pinned 'https://1.1.1.1/dns-query'; then
    t_ok 0 'an IP-literal DoH URL counts as pinned'
else
    t_ok 1 'an IP-literal DoH URL counts as pinned'
fi
if sh_doh_pinned 'https://dns.example.com/dns-query'; then
    t_ok 1 'a hostname DoH URL does not count as pinned'
else
    t_ok 0 'a hostname DoH URL does not count as pinned'
fi
# Off unless asked: with no URL the retry refuses without touching the net.
if SANDHOME_DOH_URL= sh_fetch_via_doh "file://$tmp/dl/src.txt" "$tmp/dl/doh-off.txt" 2>/dev/null; then
    t_ok 1 'the DoH retry is off when SANDHOME_DOH_URL is unset'
else
    t_ok 0 'the DoH retry is off when SANDHOME_DOH_URL is unset'
fi
# The resolver gate: exit 6 twice passes, anything else refuses. Stub curl
# answers --version/--help and exits with a canned code for fetches.
mkdir -p "$tmp/doh6" "$tmp/doh7"
cat > "$tmp/doh6/curl" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "curl stub"; exit 0; fi
if [ "${1:-}" = "--help" ]; then echo "--doh-url"; exit 0; fi
exit 6
STUB
chmod +x "$tmp/doh6/curl"
cat > "$tmp/doh7/curl" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "curl stub"; exit 0; fi
if [ "${1:-}" = "--help" ]; then echo "--doh-url"; exit 0; fi
exit 7
STUB
chmod +x "$tmp/doh7/curl"
if PATH="$tmp/doh6:$PATH" SANDHOME_DOH_CANARY='https://canary.invalid' sh_resolver_failed_twice 2>/dev/null; then
    t_ok 0 'two curl exit-6 probes confirm a resolver failure'
else
    t_ok 1 'two curl exit-6 probes confirm a resolver failure'
fi
if PATH="$tmp/doh7:$PATH" SANDHOME_DOH_CANARY='https://canary.invalid' sh_resolver_failed_twice 2>/dev/null; then
    t_ok 1 'a non-6 exit refuses the resolver-failure gate'
else
    t_ok 0 'a non-6 exit refuses the resolver-failure gate'
fi
# A curl without --doh-url support refuses even with the gate passing.
mkdir -p "$tmp/dohnodoh"
cat > "$tmp/dohnodoh/curl" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then echo "curl stub"; exit 0; fi
if [ "${1:-}" = "--help" ]; then echo "no doh here"; exit 0; fi
exit 6
STUB
chmod +x "$tmp/dohnodoh/curl"
if PATH="$tmp/dohnodoh:$PATH" SANDHOME_DOH_URL='https://1.1.1.1/dns-query' SANDHOME_DOH_CANARY='https://canary.invalid' sh_fetch_via_doh "file://$tmp/dl/src.txt" "$tmp/dl/doh-nodoh.txt" 2>/dev/null; then
    t_ok 1 'a curl without --doh-url refuses the DoH retry'
else
    t_ok 0 'a curl without --doh-url refuses the DoH retry'
fi
sh_detect_all >/dev/null 2>&1 || true

# -------------------------------------------- manifest shapes --
# Issue #10: every manifest field shape-validated, records dropped on any
# failure; length counted and class matched, no {64} quantifier. Issues #4
# and #17: unverified bytes never occupy the final name; md5 refused.
hex_good=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445
if sh_is_hex64 "$hex_good"; then
    t_ok 0 'a 64-char hex digest validates'
else
    t_ok 1 'a 64-char hex digest validates'
fi
if sh_is_hex64 abc; then
    t_ok 1 'a short digest does not validate'
else
    t_ok 0 'a short digest does not validate'
fi
if sh_is_hex64 ''; then
    t_ok 1 'an empty digest does not validate'
else
    t_ok 0 'an empty digest does not validate'
fi
if sh_is_hex64 zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz; then
    t_ok 1 'a non-hex 64-char string does not validate'
else
    t_ok 0 'a non-hex 64-char string does not validate'
fi
if sh_is_digits 12345; then
    t_ok 0 'an all-digit size validates'
else
    t_ok 1 'an all-digit size validates'
fi
if sh_is_digits 12a45; then
    t_ok 1 'a size with a letter does not validate'
else
    t_ok 0 'a size with a letter does not validate'
fi
if sh_digest_matches actual 'actual other'; then
    t_ok 0 'a digest matching one of two accepted values verifies'
else
    t_ok 1 'a digest matching one of two accepted values verifies'
fi
if sh_digest_matches actual 'other values'; then
    t_ok 1 'a digest matching none of the accepted values is refused'
else
    t_ok 0 'a digest matching none of the accepted values is refused'
fi
if sh_expected_wellformed d41d8cd98f00b204e9800998ecf8427e 2>/dev/null; then
    t_ok 1 'a 32-char md5-length pin is refused'
else
    t_ok 0 'a 32-char md5-length pin is refused'
fi
md5_out=$(sh_expected_wellformed d41d8cd98f00b204e9800998ecf8427e 2>&1)
case "$md5_out" in
    *md5*) t_ok 0 'the md5 refusal names md5' ;;
    *) t_ok 1 "the md5 refusal names md5 ($md5_out)" ;;
esac
# Atomicity: a mismatched digest leaves NO file at the destination and no
# temp beside it; the failed bytes never occupied the final name.
printf 'atomic-payload\n' > "$tmp/atomic-src"
REALA=$(sha256sum "$tmp/atomic-src" 2>/dev/null | cut -d' ' -f1)
if [ -n "$REALA" ]; then
    rm -f "$tmp/atomic-dest"
    rm -f "$tmp"/atomic-dest.tmp.*
    if ( cd "$ROOT" && PATH="$tmp/stub:$PATH" sh_fetch_verified "file://$tmp/atomic-src" "$tmp/atomic-dest" 0000000000000000000000000000000000000000000000000000000000000000 ) 2>/dev/null; then
        t_ok 1 'atomic: a mismatched digest is refused'
    else
        t_ok 0 'atomic: a mismatched digest is refused'
    fi
    if [ -e "$tmp/atomic-dest" ]; then
        t_ok 1 'atomic: the destination is absent after a mismatch'
    else
        t_ok 0 'atomic: the destination is absent after a mismatch'
    fi
    if ls "$tmp"/atomic-dest.tmp.* >/dev/null 2>&1; then
        t_ok 1 'atomic: no temp file is left beside the destination'
    else
        t_ok 0 'atomic: no temp file is left beside the destination'
    fi
    if ( cd "$ROOT" && PATH="$tmp/stub:$PATH" sh_fetch_verified "file://$tmp/atomic-src" "$tmp/atomic-dest2" "$REALA" ) 2>/dev/null; then
        if [ -r "$tmp/atomic-dest2" ]; then
            t_ok 0 'atomic: verified bytes are renamed into place'
        else
            t_ok 1 'atomic: verified bytes are renamed into place (absent)'
        fi
    else
        t_ok 1 'atomic: verified bytes are renamed into place (non-zero)'
    fi
else
    t_skip 'no sha256 tool for the atomicity clauses'
fi
# A publisher digest that is not hex64 is dropped at parse time.
printf '[{"filename":"go1.27.1.linux-amd64.tar.gz","sha256":"not-a-digest"}]' > "$tmp/baddigest.json"
t_is "$(tc_go_sha_from "$tmp/baddigest.json" go1.27.1.linux-amd64.tar.gz)" '' 'a non-hex publisher digest is dropped, not compared'
# # STOP: os-release IS READ FROM BOTH PLACES, AND /usr/lib IS NOT A THOUGHT.
# On a merged-/usr distribution /etc/os-release is a SYMLINK into /usr/lib, and
# an image that ships the file without the symlink - a container that bind-mounts
# it, a minimal rootfs - answered `unknown` on the first line of every report.
# Measured on the machine this was fixed on, whose /usr/lib/os-release says
# ID="void" and whose /etc/os-release does not exist.
t_ok "$( [ -n "$(sh_do_read_id /usr/lib/os-release 2>/dev/null)" ] && echo 0 || echo 1 )" \
    'the ID in /usr/lib/os-release is readable when /etc/os-release is absent'
t_is "$(sh_do_read_id "$tmp/no-such-release")" '' 'a missing os-release reads as nothing'
printf 'ID=quoted-value\nPATH=/tmp/evil\nLD_PRELOAD=/tmp/evil.so\nIFS=:\n' > "$tmp/rel"
t_is "$(sh_do_read_id "$tmp/rel")" 'quoted-value' 'ID is read with its quotes removed'
# The file is DATA and is not sourced, so a distribution whose os-release
# carries a PATH= cannot rewrite the process that read it. IFS and LD_PRELOAD
# are checked alongside it because the old code sourced the file, and a single
# `PATH=` clause would still have passed against a reader that let the rest
# through - which is the half of the claim nobody writes the test for.
#
# # STOP: THE READER RUNS IN THE CURRENT SHELL AND NOT IN A SUBSHELL, BECAUSE A
# SUBSHELL CANNOT SEE THE DAMAGE AND THE CLAUSE WAS THEREFORE VACUOUS. The
# first version wrapped the call in `( ... )` and compared PATH afterwards; a
# sourcing reader changed PATH inside that subshell, the subshell exited, and
# the parent saw nothing. Planted and measured:
#   . "$sh_do_file"; sh_do_id=$(...)   ->  unit: 90 run, 0 failed   (plant seen)
# The three values are saved and RESTORED around the call, so a defect is
# observed rather than absorbed, and the file is one whose assignments are
# visible only to a process that sourced it.
os_path_before=$PATH
os_ifs_before=${IFS:-}
os_preload_before=${LD_PRELOAD:-}
sh_do_read_id "$tmp/rel" >/dev/null
t_is "$PATH" "$os_path_before" 'reading an os-release does not rewrite PATH'
t_is "${IFS:-}" "$os_ifs_before" 'reading an os-release does not rewrite IFS'
t_is "${LD_PRELOAD:-}" "$os_preload_before" 'reading an os-release does not set LD_PRELOAD'
# And the damage is restored so the rest of this file runs on a sane PATH.
PATH=$os_path_before
IFS=$os_ifs_before
LD_PRELOAD=$os_preload_before
export PATH

# ------------------------------------------- the reference, read independently --
# # STOP: THIS IS THE SECOND READER, AND IT EXISTS BECAUSE tests/docs.sh CANNOT
# SEE AN EXTRACTION BUG. That check compares docs/reference.md against what
# docs/generate-reference.sh produces, so the generator is the authority: if the
# generator is wrong, the file is wrong and the two agree, and the suite is
# green. SANDHOME_MIN_EXEC_MB was exactly that - the code read
# `: "${SANDHOME_MIN_EXEC_MB:=${SH_MIN_EXEC_MB:-128}}"`, the reference said
# "unset, and the feature is off until it is set", and the two halves of the
# same generated file contradicted each other while every clause passed.
#
# The check below does NOT go through the generator. It reads the default off the
# LIVE process - space.sh is already sourced, so this is the value a caller
# actually gets - and compares that against the committed table. It is a second
# measurement of the same fact by a different route, and it is the only kind of
# check that can fail when the file and its producer are wrong together.
ref="$ROOT/docs/reference.md"
t_ok "$([ -r "$ref" ]; echo $?)" 'the reference is readable'
if [ -r "$ref" ]; then
    t_is "$SANDHOME_MIN_EXEC_MB" '128' 'the code default for SANDHOME_MIN_EXEC_MB is 128'
    ref_min=$(sh_ref_default SANDHOME_MIN_EXEC_MB "$ref")
    t_is "$ref_min" "$SANDHOME_MIN_EXEC_MB" \
        'the reference agrees with the running code on SANDHOME_MIN_EXEC_MB'
    t_is "$(sh_ref_default SANDHOME_NO_REFETCH "$ref")" '1' \
        'the reference agrees with the code on SANDHOME_NO_REFETCH'
    t_is "$(sh_ref_default SANDHOME_PROFILE "$ref")" '1' \
        'the reference agrees with the code on SANDHOME_PROFILE'
    # The contradiction that was live is inside ONE file, so a reader sees both
    # halves at once: the usage block states a default and the table said unset.
    # The two are compared against each other as well as against the code.
    if grep -q 'SANDHOME_MIN_EXEC_MB  free megabytes' "$ref" 2>/dev/null; then
        case "$ref_min" in
            *'unset, and the feature is off'*)
                t_ok 1 'the usage block and the table agree about SANDHOME_MIN_EXEC_MB' ;;
            *)
                t_ok 0 'the usage block and the table agree about SANDHOME_MIN_EXEC_MB' ;;
        esac
    else
        t_ok 0 'the usage block states a default for SANDHOME_MIN_EXEC_MB'
    fi
fi

rm -rf "$tmp"
t_end
