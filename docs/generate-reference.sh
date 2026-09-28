#!/bin/sh
# generate-reference.sh - write docs/reference.md from the code.
#
# The reference is GENERATED, and `tests/docs.sh` fails when the committed file
# differs from what this produces. That is the whole point: a hand-maintained
# command reference is a document that is wrong within two releases, and an
# agent that types a flag it read there is an agent that loses a session.
#
# Every section below is extracted from the code. Nothing is transcribed.
# Run: sh docs/generate-reference.sh > docs/reference.md

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)

printf '# Reference\n\n'
printf 'GENERATED. Do not edit. `sh docs/generate-reference.sh > docs/reference.md`\n'
printf 'rewrites it, and `sh tests/docs.sh` fails when the two differ. Every line\n'
printf 'below is extracted from the code that implements it.\n\n'

# --- the commands bin/sandhome dispatches ------------------------------------
printf '## Commands\n\n'
printf '```\n'
sed -n '/^usage() {/,/^}/p' "$ROOT/bin/sandhome" 2>/dev/null |
    sed -n "/<<'USAGE'/,/^USAGE$/p" | sed '1d;$d'
printf '```\n\n'

# --- the flags bootstrap.sh accepts -----------------------------------------
printf '## bootstrap.sh flags\n\n'
printf '```\n'
sed -n '/^usage() {/,/^}/p' "$ROOT/bootstrap.sh" 2>/dev/null |
    sed -n "/<<'USAGE'/,/^USAGE$/p" | sed '1d;$d'
printf '```\n\n'

# --- the toolsets, in the order the parser resolves them --------------------
printf '## Toolsets\n\n'
printf '| name | toolchains |\n| --- | --- |\n'
sed -n '/^sh_toolset_names() {/,/^}/p' "$ROOT/bootstrap.sh" 2>/dev/null |
    sed -n 's/^ *\([a-z]*\)) *printf *.\(.*\);$/\1|\2/p' |
    while IFS='|' read -r name list; do
        [ -n "$name" ] || continue
        # The shell source holds a literal backslash-n inside the printf format;
        # it is a line break in the emitted list and nothing else.
        list=$(printf '%s' "$list" | sed "s/\\\\n' *;\$/ /; s/\\\\n/ /g; s/' *;\$//")
        list=$(printf '%s' "$list" | tr -s ' ' ' ' | sed 's/^ *//; s/ *$//')
        printf '| `%s` | %s |\n' "$name" "$list"
    done
printf '\n'

# --- the environment variables, and where each is read ----------------------
printf '## Environment variables\n\n'
printf '| variable | read by | default |\n| --- | --- | --- |\n'

# gen_default_of VAR -> the default the CODE gives VAR, or nothing.
#
# # STOP: THE EXTRACTOR IS A NAMED FUNCTION AND NOT A NESTED `sed` PIPE, AND THE
# PATTERN IS NOT `\?`. The old one-liner was
#     grep -h "\"\?${var}\"?:=" ... | head -1 | sed 's/.*:="\?//; s/"\?$//'
# and it answered the empty string for EVERY variable in the tree, because in a
# POSIX basic regular expression `\?` is a LITERAL QUESTION MARK, not "optional".
# The pattern therefore only matched a line containing `"?VAR"?:=`, and no line
# in this tree does. Only the plain `^ *VAR=` fallback below ever produced a
# value. The visible consequence was SANDHOME_MIN_EXEC_MB reported as "unset,
# and the feature is off until it is set" while the code read
# `: "${SANDHOME_MIN_EXEC_MB:=${SH_MIN_EXEC_MB:-128}}"` and used 128 - the
# generated table contradicting the generated usage block in the same file.
# `tests/docs.sh` could not see it, because that check compares the reference
# against THIS generator: a check that compares a document to the thing that
# produced it can only catch drift, never an extraction bug. There is now a
# second reader of the same facts in tests/unit.sh that does not go through here.
gen_default_of() {
    gd_var=$1
    gd_line=$(grep -h "$gd_var" "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh \
             "$ROOT"/bin/sandhome "$ROOT"/tools/*.sh 2>/dev/null |
             grep ':=' | head -1)
    if [ -z "$gd_line" ]; then
        gd_line=$(grep -h "^ *$gd_var=" "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh \
                 "$ROOT"/bin/sandhome "$ROOT"/tools/*.sh 2>/dev/null | head -1)
    fi
    [ -n "$gd_line" ] || return 0
    case "$gd_line" in
        *'${'*)
            # Everything after the LAST `:=` is the default expression.
            gd_rest=${gd_line##*:=}
            # Take the INNERMOST `${NAME:-default}` by hand, with parameter
            # expansion only. `: "${A:=${B:-128}}"` -> after `##*:=` is
            # `${B:-128}}`; but a three-level default nests twice more, so this
            # is a LOOP, not a single strip: while the remainder still opens a
            # `${`, drop that name and keep the inner default. A nested `sed`
            # with capture groups got this wrong under BRE, where `$` and `{`
            # are not the metacharacters the pattern assumed, and produced
            # `{SH_MIN_EXEC_MB:-128}}` - braces still on, a default that is not
            # a value.
            while :; do
                case "$gd_rest" in
                    '${'*)
                        # Drop `${NAME:-` in one step. `#*:-` is SHORTEST-prefix
                        # match, so it removes exactly `${NAME:-` and keeps the
                        # default; `%%:[-=]*` is longest-suffix and removes the
                        # default instead, which is how this printed the NAME.
                        # Three levels of nesting take three passes of the loop
                        # below, and a default with no `${` in it exits at once.
                        gd_rest=${gd_rest#\$\{}
                        case "$gd_rest" in
                            *:-*) gd_rest=${gd_rest#*:-} ;;
                        esac
                        ;;
                    *) break ;;
                esac
            done
            # # STOP: THE CLOSING QUOTE COMES OFF BEFORE THE BRACES, IN THAT
            # ORDER, OR A BRACE-TERMINATED DEFAULT IS NEVER REACHED. The source
            # line ends `: "${SANDHOME_MIN_EXEC_MB:=${SH_MIN_EXEC_MB:-128}}"`, so
            # after the `:=` the remainder is `${SH_MIN_EXEC_MB:-128}}"` - it ends
            # in a QUOTE, not a brace. A loop that trims trailing `}` from the
            # right therefore does nothing at all, because the rightmost
            # character is `"`, and the table printed `128}}"` for a variable the
            # code sets to 128. Trim the quote, then the braces.
            while :; do
                case "$gd_rest" in
                    *'"') gd_rest=${gd_rest%\"} ;;
                    *) break ;;
                esac
            done
            while :; do
                case "$gd_rest" in
                    *'}') gd_rest=${gd_rest%\}} ;;
                    *) break ;;
                esac
            done
            gd_rest=${gd_rest#\"}
            printf '%s' "$gd_rest" | cut -c1-40
            ;;
        *)
            gd_rest=${gd_line#*=}
            gd_rest=${gd_rest#\"}
            gd_rest=${gd_rest%\"}
            printf '%s' "$gd_rest" | cut -c1-40
            ;;
    esac
}

for var in $(cat "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome \
                 "$ROOT"/tools/*.sh 2>/dev/null |
             grep -o 'SANDHOME_[A-Z0-9_]*' | sort -u); do
    # A NAME THAT ENDS IN AN UNDERSCORE IS A FORMAT PREFIX, NOT A VARIABLE.
    # `sh_pin_name` prints `SANDHOME_SHA256_%s`, and the token scan sees
    # `SANDHOME_SHA256_` and writes a row for a variable nothing ever reads.
    # The per-name pins are listed explicitly by the `case` in sh_pin_for, and
    # the bare one is a real variable, so a trailing underscore is always an
    # artifact of a format string.
    case "$var" in
        *_ ) continue ;;
    esac
    readers=''
    for f in "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome "$ROOT"/tools/*.sh; do
        [ -r "$f" ] || continue
        if grep -q "$var" "$f" 2>/dev/null; then
            readers="$readers ${f##*/}"
        fi
    done
    # # STOP: THE PATTERN MATCHES THE REAL ASSIGNMENT, AND BRE HAS NO `\?`.
    # The extractor used `"\?${var}"\?:=`, where `\?` in a basic regular
    # expression is a LITERAL QUESTION MARK, not "optional". It therefore only
    # ever matched a line that literally contained `"?VAR"?:=`, which no line in
    # this tree does, so the `:=` branch never fired for any variable; only the
    # plain `^ *VAR=` fallback below ever produced a value. That is why
    # SANDHOME_MIN_EXEC_MB - assigned as `: "${SANDHOME_MIN_EXEC_MB:=
    # ${SH_MIN_EXEC_MB:-128}}"`, which is not at the start of a line and does
    # not end after the default - was reported as unset while the code used
    # 128. The pattern is now the two real spellings, and the default is taken
    # from the INNERMOST `${...:-...}` inside it.
    def=$(gen_default_of "$var")
    if [ -z "$def" ]; then
        def=$(grep -h "^ *${var}=" "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh \
              "$ROOT"/bin/sandhome "$ROOT"/tools/*.sh 2>/dev/null |
              head -1 | sed "s/^ *${var}=//; s/^\"//; s/\"$//" | cut -c1-40)
    fi
    [ -n "$def" ] || def='unset, and the feature is off until it is set'
    printf '| `%s` |%s | `%s` |\n' "$var" "$readers" "$def"
done
printf '\n'

# --- the errandsh variables -------------------------------------------------
printf '## errandsh variables\n\n'
printf '| variable | default |\n| --- | --- |\n'
for var in $(grep -o 'ERRANDSH_[A-Z]*' "$ROOT/shell/errandsh" 2>/dev/null | sort -u); do
    def=$(grep -h ":\?=\"\?${var}" "$ROOT/shell/errandsh" 2>/dev/null | head -1 |
          sed 's/^[^=]*=//; s/^"\?//; s/"\?$//' | cut -c1-50)
    [ -n "$def" ] || def='(unset)'
    printf '| `%s` | `%s` |\n' "$var" "$def"
done
printf '\n'

# --- the toolchains, from the modules themselves ----------------------------
printf '## Toolchains\n\n'
printf '| name | binaries on PATH | description |\n| --- | --- | --- |\n'
for m in "$ROOT"/tools/*.sh; do
    [ -r "$m" ] || continue
    name=${m##*/}; name=${name%.sh}
    bins=$(grep -h "^TC_${name}_BINS=" "$m" 2>/dev/null | head -1 |
           sed "s/^TC_${name}_BINS=//; s/^'//; s/'$//")
    desc=$(grep -h "^TC_${name}_DESC=" "$m" 2>/dev/null | head -1 |
           sed "s/^TC_${name}_DESC=//; s/^'//; s/'$//")
    [ -n "$desc" ] || desc='(no description declared)'
    [ -n "$bins" ] || bins='(via its own PATH fragment)'
    printf '| `%s` | `%s` | %s |\n' "$name" "$bins" "$desc"
done
printf '\n'

# --- the test files ---------------------------------------------------------
printf '## Tests\n\n'
printf '| file | what it checks |\n| --- | --- |\n'
for t in syntax unit space toolchain shims docs bootstrap errandsh-posix; do
    f="$ROOT/tests/$t.sh"
    [ -r "$f" ] || continue
    head_one=$(sed -n '3p' "$f" 2>/dev/null | sed 's/^# *//')
    [ -n "$head_one" ] || head_one=$(sed -n '2p' "$f" | sed 's/^# *//')
    printf '| `sh tests/%s.sh` | %s |\n' "$t" "$head_one"
done
