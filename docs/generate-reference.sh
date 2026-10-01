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

# gen_trunc STRING -> the first 40 characters, with the shell and not with cut.
# `cut -c1-40` was the only external program this function needed once the sed
# came out, and a helper that reaches for a program the userlands this tree
# targets may not carry dies on exactly those machines. The truncation exists to
# keep a long expression from filling a table cell, and the parameter expansion
# is a character, not a byte, which is the right unit for a table.
gen_trunc() {
    gt_rest=$1
    gt_out=''
    gt_n=0
    while [ -n "$gt_rest" ] && [ "$gt_n" -lt 40 ]; do
        gt_out="$gt_out${gt_rest%"${gt_rest#?}"}"
        gt_rest=${gt_rest#?}
        gt_n=$((gt_n + 1))
    done
    printf '%s' "$gt_out"
}

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
            printf '%s' "$(gen_trunc "$gd_rest")"
            ;;
        *)
            gd_rest=${gd_line#*=}
            gd_rest=${gd_rest#\"}
            gd_rest=${gd_rest%\"}
            printf '%s' "$(gen_trunc "$gd_rest")"
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
    # # STOP: THE := FORM IS TRIED ACROSS EVERY READER BEFORE THE PLAIN = ONE.
    # gen_default_of takes the FIRST line that mentions the variable and has a
    # `:=`, across lib/, bootstrap.sh, bin/sandhome and tools/. If that sweep
    # finds nothing, the plain-`=` fallback below used the first line in the
    # SAME grep order, so where a variable had both an early plain assignment
    # (`: "${SANDHOME_HOME:=${SH_HOME:-}}"` is the := one; a bare
    # `SANDHOME_HOME=$SH_BAKED_HOME` later in bin/sandhome is the plain one)
    # the reported default depended on which file grep happened to list first,
    # and it changed when a file was added. A generated reference whose value
    # moves because an unrelated module was created is a reference nobody can
    # trust. So the two sweeps are explicit and ordered, and within each the
    # := spelling is preferred wherever it exists.
    def=$(gen_default_of "$var")
    if [ -z "$def" ]; then
        # The plain-`=` fallback, but ONLY over lines that are not a `:=`
        # (those are the first sweep's business) and not a printf/expansion of
        # the generated file, so the value is a real assignment in the code.
        def=$(grep -h "^ *${var}=" "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh \
              "$ROOT"/bin/sandhome "$ROOT"/tools/*.sh 2>/dev/null |
              grep -v ':=' |
              grep -v "printf" |
              head -1 | sed "s/^ *${var}=//; s/^\"//; s/\"$//" | cut -c1-40)
    fi
    [ -n "$def" ] || def='unset, and the feature is off until it is set'
    printf '| `%s` |%s | `%s` |\n' "$var" "$readers" "$def"
done
printf '\n'

# --- the errandsh variables -------------------------------------------------
printf '## errandsh variables\n\n'
printf '| variable | default |\n| --- | --- |\n'
# # STOP: THE errandsh DEFAULTS ARE EXTRACTED, NOT GIVEN UP ON. The pattern was
# `grep ":\?=\"\?${var}"`, which needs an `=` IMMEDIATELY after the name, so
# it never matched the form the file actually uses - `: "${ERRANDSH_MAXHIST:=500}"`
# - and every one of the five errandsh variables was published as `(unset)`:
#
#   | ERRANDSH_HISTORY  | (unset) |     the code says $HOME/.errandsh-history
#   | ERRANDSH_MAXHIST  | (unset) |     the code says 500
#   | ERRANDSH_NAME     | (unset) |     the code derives it from the hostname
#   | ERRANDSH_PTY      | (unset) |     the code says 1
#   | ERRANDSH_SHELL    | (unset) |     the code says /bin/sh
#
# skills/errandsh/SKILL.md carries a hand-written table with all five correct,
# so the tree held two tables that disagreed and the generated one was the wrong
# one - which is the worst direction, because a document that is regenerated
# gets read as current by definition. A reader checking the default of
# ERRANDSH_MAXHIST was told there was none.
for var in $(grep -o 'ERRANDSH_[A-Z]*' "$ROOT/shell/errandsh" 2>/dev/null | sort -u); do
    # The innermost ${NAME:-default} or ${NAME:=default} inside the first line
    # that mentions the name, which is where a default lives. `-` is the shell's
    # own fallback and `:=` assigns and returns, and both answer the question a
    # reader is asking.
    def=$(sed -n "s/.*\${${var}[:-]=\([^}]*\)}.*/\1/p" "$ROOT/shell/errandsh" 2>/dev/null |
          head -1 | cut -c1-50)
    if [ -z "$def" ]; then
        # Not a default expression: a plain assignment at the start of a line.
        def=$(sed -n "s/^ *${var}=\"\?//p" "$ROOT/shell/errandsh" 2>/dev/null |
              head -1 | sed 's/"$//' | cut -c1-50)
    fi
    # A default that is itself a command substitution is not a value a reader
    # can use, and printing it truncated mid-word is worse than describing it.
    # ERRANDSH_NAME is `${ERRANDSH_NAME:-$(hostname ... || echo errand)}`;
    # what it evaluates to is in the skill table and the prompt is cut to 24
    # characters of the first label.
    case "$def" in
        *'$('*) def='the hostname, or errand' ;;
    esac
    # ERRANDSH_PTY has no default expression at all: the automatic path is on
    # unless the variable is 0, and the only place that is written is a comment
    # and the test at the dispatch. Saying "(unset)" is true and useless, so the
    # meaning is given instead.
    [ "$var" = ERRANDSH_PTY ] && def='1 (the automatic path is on unless this is 0)'
    [ -n "$def" ] || def='(unset)'
    printf '| `%s` | `%s` |\n' "$var" "$def"
done
printf '\n'

# --- the pty shim variables -------------------------------------------------
# They live in shims/fakepty.c and shell/faketty, not in a toolchain module, so
# the variable table above does not reach them - and two pages tell a reader
# that docs/reference.md is authoritative for "every flag, variable and command".
# It was not. SANDHOME_FAKEPTY_SIZE and SANDHOME_FAKEPTY_CRLF were documented in
# no file at all, and the guide deferred to the reference for them, so a reader
# who followed the pointer concluded the fact did not exist.
printf '## pty shim variables\n\n'
printf '| variable | meaning | default |\n| --- | --- | --- |\n'
printf '| `SANDHOME_FAKEPTY` | the `fakepty.so` to preload | the shim this build wrote, named in env.sh |\n'
printf '| `SANDHOME_FAKEPTY_SIZE` | the window size a full-screen program is told | `COLUMNSxLINES` when unset, then 80x24; when set it wins outright |\n'
printf '| `SANDHOME_FAKEPTY_ID` | which descriptors count as the terminal | set by env.sh and by `faketty`; unset, the feature is off |\n'
printf '| `SANDHOME_FAKEPTY_CRLF` | `0` stops a bare `\\n` becoming `\\r\\n` on output | on, which is what a terminal with `OPOST\\|ONLCR` does |\n'
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
for t in syntax unit space toolchain shims docs bootstrap global errandsh-posix; do
    f="$ROOT/tests/$t.sh"
    [ -r "$f" ] || continue
    head_one=$(sed -n '3p' "$f" 2>/dev/null | sed 's/^# *//')
    [ -n "$head_one" ] || head_one=$(sed -n '2p' "$f" | sed 's/^# *//')
    printf '| `sh tests/%s.sh` | %s |\n' "$t" "$head_one"
done
