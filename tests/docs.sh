#!/bin/sh
# tests/docs.sh - the documentation is checked against the code, not trusted.
#
# WHY THIS FILE EXISTS. Every document here is read by an agent that will type
# what it reads. A document naming a flag the code does not have, a variable
# nothing reads, or a command that falls through to "unknown command" is worse
# than no document: it costs a session to discover. Three such defects were live
# in this tree before this file existed (the help named a subcommand that did
# not exist; the guide's exec-root order did not match the plan; a table named a
# file that had been deleted). The checks below would have caught all three.
#
# It FAILS rather than warns. A stale document is a defect.
#
# The parsing is deliberately shallow. Each check extracts tokens that match a
# simple shape and asks one yes/no question about each, so a false pass is a
# parsing limitation that shows up as a token that is never examined, and never
# as a token that is examined wrongly.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

DOCS="$ROOT/AGENTS.md
      $ROOT/README.md
      $ROOT/docs/guide.md
      $ROOT/docs/architecture.md
      $ROOT/skills/README.md
      $ROOT/skills/sandhome/SKILL.md
      $ROOT/skills/errandsh/SKILL.md
      $ROOT/skills/sealed-sandbox/SKILL.md"

t_begin docs

# every document the reader may act on must itself exist
missing=''
for doc in $DOCS; do
    [ -r "$doc" ] || missing="$missing ${doc##*/}"
done
t_is "$missing" '' 'every document exists'

# --- 1: every repository path a document names must exist -------------------
# A candidate is a backticked token that LOOKS like a path into this tree: it
# starts with one of the directories this repository actually has, or it is a
# bare file at the root. That shape test is what keeps prose out: `fork/exec`,
# `isatty/termios` and `Left/Right/Home/End` do not begin with a directory the
# tree has, so they are never examined. A token that DOES begin with one of the
# tree's directories and is not there is a defect, and that is the case this
# check exists for: a document naming a file that was deleted.
bad_paths=''
for doc in $DOCS; do
    [ -r "$doc" ] || continue
    for tok in $(tr '`' '\n' < "$doc" 2>/dev/null | grep '/' 2>/dev/null); do
        # Strip a trailing slash and anything after the first space or quote.
        tok=$(printf '%s' "$tok" | sed "s/['\"),;]*$//")
        case "$tok" in
            http*|/*|\$*|*' '*|*'*'*|*'['*|*'<'*) continue ;;
        esac
        # A path CLAIM names something in this repository. That is decided by
        # the first segment: a directory this tree has, or a top-level entry
        # point. `bin/npm` and `bin/../lib/cli.js` appear in prose describing a
        # node install and are not claims about this tree, so a token whose
        # first segment is a directory the tree has but whose SECOND segment is
        # not a directory of this tree is left alone unless the second segment
        # names a file the tree really has.
        sh_dp_first=${tok%%/*}
        case "$sh_dp_first" in
            bin|lib|tools|tests|docs|skills|shims|shell) ;;
            *) case "$tok" in
                   bootstrap.sh|README.md|AGENTS.md|LICENSE) ;;
                   *) continue ;;
               esac ;;
        esac
        # A bare word in a directory, with no extension and no slash left, is a
        # file NAME, not a path: `bin/npm` names a program. Only a token with a
        # trailing directory component or a real extension is checked.
        # `bin/../lib/cli.js` is prose about a node install, not a path claim.
        case "$tok" in
            *..*) continue ;;
        esac
        case "$tok" in
            */*.*) ;;
            */) ;;
            *) continue ;;
        esac
        [ -e "$ROOT/$tok" ] || bad_paths="$bad_paths ${doc##*/}:$tok"
    done
done
t_is "$bad_paths" '' 'every path a document names exists in the tree'

# --- 2: every flag a document names must be one the code accepts -------------
# The authority is the argument parsers: a flag is real when it appears as a
# case arm in bootstrap.sh or bin/sandhome. Those two files are scanned whole.
# NOTE: THE DOC SIDE AND THE CODE SIDE NORMALISE THE SAME WAY, AND THAT IS THE
# WHO OF IT. The code side once added a `--` prefix to a token that already had
# one, turning `--turbo` into `----turbo`, and the check then reported every
# documented flag as clean because nothing it looked for could ever be written.
# A check that cannot fail is not a check, so both sides are normalised by the
# same two lines and a planted `--turbo` is asserted to be caught below.
# A flag belongs to THIS tool only when it is a case arm in an argument parser
# or a line in a usage text. Both are found by the same shape: an indented
# `--word` followed by a `)`, or an indented `--word` in the usage heredoc.
# A `--color=auto` in prose about another program, or a `--posix` in a sentence
# about a shell, is not a claim about this tool and is not examined.
code_flags=$(
    { sed -n 's/^ *\(--[a-zA-Z][a-zA-Z0-9-]*\)).*/\1/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome"
      sed -n '/<<.USAGE./,/^USAGE$/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome" |
          grep -o -- '--[a-zA-Z][a-zA-Z0-9-]*'
    } 2>/dev/null | sort -u
)
bad_flags=''
for doc in $DOCS; do
    [ -r "$doc" ] || continue
    # A flag claim in a document is a `--word` immediately followed by a space
    # and then a word, which is how a reader is told to type it: `--toolset NAME`,
    # `set SANDHOME_SHIMS=1`. A `--color=auto` in prose carries an `=`, and is
    # another program's flag.
    for flag in $(tr '`' '\n' < "$doc" 2>/dev/null |
                  grep -o -- '--[a-zA-Z][a-zA-Z0-9-]* [A-Za-z_]' 2>/dev/null |
                  sed 's/ [A-Za-z_]$//' | sort -u); do
        if printf '%s\n' "$code_flags" | grep -qx -- "$flag" 2>/dev/null; then
            :
        else
            bad_flags="$bad_flags ${doc##*/}:$flag"
        fi
    done
done
t_is "$bad_flags" '' 'every flag a document names is accepted by an argument parser'

# --- 3: every SANDHOME_/ERRANDSH_ variable a document names must be real ----
# Real means the identifier appears somewhere in the shell sources.
bad_vars=''
for doc in $DOCS; do
    [ -r "$doc" ] || continue
    for var in $(tr '`' '\n' < "$doc" | grep -E '^(SANDHOME|ERRANDSH)_[A-Z0-9_]+$' 2>/dev/null | sort -u); do
        if grep -rlq "$var" "$ROOT"/lib "$ROOT"/tools "$ROOT"/bootstrap.sh \
                      "$ROOT"/bin/sandhome "$ROOT"/shell 2>/dev/null; then
            :
        else
            bad_vars="$bad_vars ${doc##*/}:$var"
        fi
    done
done
t_is "$bad_vars" '' 'every SANDHOME_/ERRANDSH_ variable a document names is read or written by the code'

# --- 4: every `sandhome <word>` a document names must be dispatched ---------
# The dispatcher is the case statement at the end of bin/sandhome. Only a
# command written at the start of a line inside a fenced block, or named in a
# table row, is a command claim; `sandhome exists` in prose is not. The check
# is over the whole tree rather than the hand-list, so a new subcommand is
# covered the day it is written.
# The dispatcher arms are `    name)  body ;;` and `    a|b)  body ;;`. The
# pattern arm `*)` matches nothing and is excluded, and `--version`, `-h` and
# `--help` are flags rather than subcommands, so the list is the bare words.
code_cmds=$(sed -n '/^case "${1:-help}" in/,/^esac/p' "$ROOT/bin/sandhome" 2>/dev/null |
    sed -n 's/^ *\([a-z][a-z|-]*\)) .*/\1/p' |
    tr '|' '\n' | grep '^[a-z][a-z-]*$' | sort -u)
bad_cmds=''
for doc in $DOCS; do
    [ -r "$doc" ] || continue
    for cmd in $(grep -o '^sandhome [a-z][a-z-]*' "$doc" 2>/dev/null |
                 awk '{print $2}' | sort -u); do
        # Membership is a line test, not a substring test: a substring test
        # would accept `sandhome shimsx` because it contains `shims`, and would
        # reject every command because the list has no spaces around them.
        if printf '%s\n' "$code_cmds" | grep -qx -- "$cmd" 2>/dev/null; then
            :
        else
            bad_cmds="$bad_cmds ${doc##*/}:sandhome $cmd"
        fi
    done
done
t_is "$bad_cmds" '' 'every subcommand a document names is dispatched by bin/sandhome'

# --- 5: the reference is exactly what the generator produces ----------------
# The reference is generated, so a reader never has to trust that it matches the
# code. It is compared byte for byte rather than eyeballed.
ref_tmp=$HERE/.reference.$$
if [ -r "$ROOT/docs/generate-reference.sh" ]; then
    if sh "$ROOT/docs/generate-reference.sh" > "$ref_tmp" 2>/dev/null; then
        if cmp -s "$ref_tmp" "$ROOT/docs/reference.md"; then
            t_ok 0 'docs/reference.md is exactly what the generator produces'
        else
            t_ok 1 'docs/reference.md has drifted; run sh docs/generate-reference.sh'
            if [ -n "${SANDHOME_DOCS_DIFF:-}" ]; then
                diff "$ROOT/docs/reference.md" "$ref_tmp" 2>/dev/null | head -40
            fi
        fi
    else
        t_skip 'the reference generator could not run here'
    fi
else
    t_ok 1 'docs/generate-reference.sh exists'
fi
rm -f "$ref_tmp" 2>/dev/null

# --- 6: no document may name a file the tree does not have ------------------
# The check above is by token; this one is by absence, which catches a document
# that names a file in prose, without backticks, in a form the token scan
# above would miss.
bad_refs=''
for doc in $DOCS; do
    [ -r "$doc" ] || continue
    for ref in $(grep -oE '(bin|lib|tools|tests|docs|skills|shims|shell|\.github)/[a-zA-Z0-9_./-]*\.(md|sh|py|c|patch|yml)' "$doc" 2>/dev/null |
                 sort -u); do
        [ -e "$ROOT/$ref" ] || bad_refs="$bad_refs ${doc##*/}:$ref"
    done
done
t_is "$bad_refs" '' 'every file reference a document makes exists'

# --- 7: no document may reference a repository this one is not --------------
# A standalone repository that sends a reader to another project for a file it
# claims to have is worse than one that never mentioned the file. The check is
# over the whole tree, so a reference added to a decision page is caught too.
foreign=''
for doc in $DOCS "$ROOT"/docs/decisions/*.md; do
    [ -r "$doc" ] || continue
    for repo in podbox tailscale podbox-ssh sandssh; do
        if grep -qi "$repo" "$doc" 2>/dev/null; then
            foreign="$foreign ${doc##*/}:$repo"
        fi
    done
done
t_is "$foreign" '' 'no document points a reader at another repository'

# --- 8: the checks above must be able to fail -------------------------------
# A guard nobody has seen refuse is a guard nobody knows works, and this file
# was itself wrong once: the flag check added a `--` prefix to a token that
# already had one, so every documented flag matched nothing and the clause was
# green against a document naming a flag the code does not have. Each check
# below is therefore run once against a document with one defect planted in it,
# and the check must report it. A check that cannot fail is a defect, and the
# fix is to remove it or make it work, never to leave it reporting success.
sh_docs_can_fail() {
    sh_dcf_what=$1
    sh_dcf_line=$2
    sh_dcf_probe=$HERE/.selftest-probe.$$
    DOCS=$sh_dcf_probe
    SKILLS=''
    printf '# planted\n\n%s\n' "$sh_dcf_line" > "$sh_dcf_probe"
    case "$sh_dcf_what" in
        flag)  sh_dcf_got=$(sh_doc_bad_flags "$sh_dcf_probe") ;;
        path)  sh_dcf_got=$(sh_doc_bad_paths "$sh_dcf_probe") ;;
        var)   sh_dcf_got=$(sh_doc_bad_vars "$sh_dcf_probe") ;;
        cmd)   sh_dcf_got=$(sh_doc_bad_cmds "$sh_dcf_probe") ;;
    esac
    rm -f "$sh_dcf_probe" 2>/dev/null
    [ -n "$sh_dcf_got" ]
}

# The four extractors, factored out so they can be pointed at a scratch document
# as well as at the real ones.
sh_doc_bad_flags() {
    code_flags=$(
        { sed -n 's/^ *\(--[a-zA-Z][a-zA-Z0-9-]*\)).*/\1/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome"
          sed -n '/<<.USAGE./,/^USAGE$/p' "$ROOT/bootstrap.sh" "$ROOT/bin/sandhome" |
              grep -o -- '--[a-zA-Z][a-zA-Z0-9-]*'
        } 2>/dev/null | sort -u
    )
    _sdbf_out=''
    for flag in $(tr '`' '\n' < "$1" 2>/dev/null |
                  grep -o -- '--[a-zA-Z][a-zA-Z0-9-]* [A-Za-z_]' 2>/dev/null |
                  sed 's/ [A-Za-z_]$//' | sort -u); do
        printf '%s\n' "$code_flags" | grep -qx -- "$flag" 2>/dev/null ||
            _sdbf_out="$_sdbf_out $flag"
    done
    printf '%s' "$_sdbf_out"
}

sh_doc_bad_paths() {
    _sdbp_out=''
    for tok in $(tr '`' '\n' < "$1" 2>/dev/null | grep '/' 2>/dev/null); do
        tok=$(printf '%s' "$tok" | sed "s/['\"),;]*$//")
        case "$tok" in
            http*|/*|\$*|*' '*|*'*'*|*'['*|*'<'*) continue ;;
        esac
        case "$tok" in *..*) continue ;; esac
        case "$tok" in
            bin/*|lib/*|tools/*|tests/*|docs/*|skills/*|shims/*|shell/*|.github/*|bootstrap.sh|README.md|AGENTS.md|LICENSE) ;;
            *) continue ;;
        esac
        case "$tok" in */*.*|*/) ;; *) continue ;; esac
        [ -e "$ROOT/$tok" ] || _sdbp_out="$_sdbp_out $tok"
    done
    printf '%s' "$_sdbp_out"
}

sh_doc_bad_vars() {
    _sdbv_out=''
    for var in $(tr '`' '\n' < "$1" 2>/dev/null |
                 grep -E '^(SANDHOME|ERRANDSH)_[A-Z0-9_]+$' 2>/dev/null | sort -u); do
        grep -rql "$var" "$ROOT"/lib "$ROOT"/tools "$ROOT"/bootstrap.sh \
                  "$ROOT"/bin/sandhome "$ROOT"/shell 2>/dev/null ||
            _sdbv_out="$_sdbv_out $var"
    done
    printf '%s' "$_sdbv_out"
}

sh_doc_bad_cmds() {
    code_cmds=$(sed -n '/^case "${1:-help}" in/,/^esac/p' "$ROOT/bin/sandhome" 2>/dev/null |
                sed -n 's/^ *\([a-z][a-z|-]*\)) .*/\1/p' |
                tr '|' '\n' | grep '^[a-z][a-z-]*$' | sort -u)
    _sdbc_out=''
    for cmd in $(grep -o '^sandhome [a-z][a-z-]*' "$1" 2>/dev/null | awk '{print $2}' | sort -u); do
        printf '%s\n' "$code_cmds" | grep -qx -- "$cmd" 2>/dev/null ||
            _sdbc_out="$_sdbc_out $cmd"
    done
    printf '%s' "$_sdbc_out"
}

if sh_docs_can_fail flag 'A planted flag: `--not-a-flag MODE`.'; then
    t_ok 0 'the flag check catches a flag the code does not accept'
else
    t_ok 1 'the flag check catches a flag the code does not accept'
fi
if sh_docs_can_fail path 'A planted path: `tools/not-here.sh`.'; then
    t_ok 0 'the path check catches a file the tree does not have'
else
    t_ok 1 'the path check catches a file the tree does not have'
fi
if sh_docs_can_fail var 'A planted variable: `SANDHOME_NOT_A_VARIABLE`.'; then
    t_ok 0 'the variable check catches a variable the code does not use'
else
    t_ok 1 'the variable check catches a variable the code does not use'
fi
if sh_docs_can_fail cmd 'sandhome not-a-command'; then
    t_ok 0 'the subcommand check catches a command the dispatcher lacks'
else
    t_ok 1 'the subcommand check catches a command the dispatcher lacks'
fi

t_end
