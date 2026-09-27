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
for var in $(cat "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome \
                 "$ROOT"/tools/*.sh 2>/dev/null |
             grep -o 'SANDHOME_[A-Z0-9_]*' | sort -u); do
    readers=''
    for f in "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh "$ROOT"/bin/sandhome "$ROOT"/tools/*.sh; do
        [ -r "$f" ] || continue
        if grep -q "$var" "$f" 2>/dev/null; then
            readers="$readers ${f##*/}"
        fi
    done
    # The default is whatever the code assigns it, when it assigns one. Both
    # spellings are read: `: "${VAR:=value}"` in a library, and a plain
    # assignment in a script. A variable with no assignment is OFF, and saying
    # so is more use to a reader than an empty cell.
    def=$(grep -h "\"\?${var}\"?:=" "$ROOT"/lib/*.sh "$ROOT"/bootstrap.sh \
          "$ROOT"/bin/sandhome "$ROOT"/tools/*.sh 2>/dev/null |
          head -1 | sed 's/.*:="\?//; s/"\?$//' | cut -c1-40)
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
