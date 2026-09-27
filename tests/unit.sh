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
printf '[{"filename":"go1.27.1.linux-amd64.tar.gz","sha256":"compact-digest"}]' > "$tmp/compact.json"
t_is "$(tc_go_sha_from "$tmp/compact.json" go1.27.1.linux-amd64.tar.gz)" 'compact-digest' \
    'go reads the digest out of a compact one-line document'
printf '[{"filename":"a.tar.gz","sha256":"h1"},{"filename":"b.tar.gz","sha256":"h2"}]' > "$tmp/many.json"
t_is "$(tc_go_sha_from "$tmp/many.json" a.tar.gz)" 'h1' 'go reads the first of two inline entries'
t_is "$(tc_go_sha_from "$tmp/many.json" b.tar.gz)" 'h2' 'go reads the second of two inline entries'

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

rm -rf "$tmp"
t_end
