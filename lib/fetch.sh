#!/bin/sh
# fetch.sh - one download path, one checksum path, one unpack path. Sourced.
#
# NOTE: WHAT A RUN-TIME DIGEST PROVES IS TRANSPORT, NOT AUTHORSHIP. Where the
# expected digest comes from the same release as the bytes, whoever could replace
# one could replace the other. It is still the right check for a mirror that
# truncates a download; `SANDHOME_SHA256` adds the stronger pinned check back for
# a caller who holds the value.

# sh_fetch URL DEST -> 0 on a complete download. curl, then wget, then BSD fetch.
sh_fetch() {
    sh_f_url=$1
    sh_f_dest=$2
    if sh_have curl; then
        curl -fSL --retry 3 --retry-delay 2 -o "$sh_f_dest" "$sh_f_url"
        return $?
    fi
    if sh_have wget; then
        wget -q -O "$sh_f_dest" "$sh_f_url"
        return $?
    fi
    if sh_have fetch; then
        fetch -q -o "$sh_f_dest" "$sh_f_url"
        return $?
    fi
    sh_warn 'no curl, wget or fetch is present, so nothing can be downloaded'
    return 1
}

# sh_redirect_target URL -> the URL a redirect lands on. This is how a `latest`
# release names its tag without parsing JSON anywhere.
sh_redirect_target() {
    if sh_have curl; then
        curl -fsSL -o /dev/null -w '%{url_effective}' "$1" 2>/dev/null
        return 0
    fi
    if sh_have wget; then
        # wget --spider prints the chain; the last Location is the target.
        wget -q -S --spider "$1" 2>&1 | {
            sh_rt_last=''
            while read -r sh_rt_line; do
                case "$sh_rt_line" in
                    Location:*) sh_rt_last=$(sh_trim "${sh_rt_line#Location:}") ;;
                esac
            done
            printf '%s' "$sh_rt_last"
        }
        return 0
    fi
    printf ''
}

# sh_github_latest_tag OWNER/REPO -> the tag the `latest` release points at, or
# nothing. The redirect is what names the tag without parsing JSON anywhere.
# STOP: `${url##*/tag/}` AND NOT `${url##*/}`: a tag that itself contains a slash
# (`release/1.2`) is returned whole, where the short form would truncate it.
sh_github_latest_tag() {
    sh_glt_url=$(sh_redirect_target "https://github.com/$1/releases/latest")
    case "$sh_glt_url" in
        */releases/tag/*) printf '%s' "${sh_glt_url##*/releases/tag/}" ;;
        */tag/*)          printf '%s' "${sh_glt_url##*/tag/}" ;;
        *)                printf '' ;;
    esac
}

# sh_sha256_which -> the name of the tool that will take a digest here, or
# nothing. It is asked BEFORE the digest is taken so the report can name it.
sh_sha256_which() {
    if sh_have sha256sum; then printf 'sha256sum'; return 0; fi
    if sh_have sha256;    then printf 'sha256';    return 0; fi
    if sh_have shasum;    then printf 'shasum';    return 0; fi
    if sh_have openssl;   then printf 'openssl';   return 0; fi
    if sh_have python3;  then printf 'python3';   return 0; fi
    if sh_have node;     then printf 'node';      return 0; fi
    printf ''
}

# sh_sha256 FILE -> the lowercase hex digest, or nothing when no tool can take
# it. Five candidates, and every one is absent somewhere: sha256sum is coreutils,
# a BSD base has `sha256`, a minimal image may have only openssl, and python3
# arrives with the toolchain rather than before it.
sh_sha256() {
    if sh_have sha256sum; then sh_first_word sha256sum "$1"; return 0; fi
    if sh_have sha256;    then sha256 -q "$1" 2>/dev/null; return 0; fi
    if sh_have shasum;    then sh_first_word shasum -a 256 "$1"; return 0; fi
    if sh_have openssl;   then sh_first_word openssl dgst -sha256 -r "$1"; return 0; fi
    if sh_have python3; then
        python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null
        return 0
    fi
    if sh_have node; then
        node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "$1"
        return 0
    fi
    printf ''
}

# -------------------------------------------------------------- pinned digests --
# THE PIN IS PER DOWNLOAD, AND ONE VARIABLE CANNOT PIN A TOOLSET.
#
# `SANDHOME_SHA256` was documented as "pin a sha256 for every download this run
# makes" and it was passed to EVERY download, so a `cli` toolset (three
# downloads) could only ever match the first one: the other two were compared
# against a digest belonging to a different file and failed with a message that
# blamed the mirror. The result was ORDER-DEPENDENT, which is how a reader knows
# a check is broken rather than strict. It also silently discarded the digests
# go.dev and nodejs.org publish, because those modules pass the published value
# through the SAME third argument.
#
# There is one pin per download, resolved in this order:
#   1. SANDHOME_SHA256_<name>   the toolchain name, upper-cased (JQ, RIPGREP)
#   2. SANDHOME_SHA256_<file>   the URL's last path segment, upper-cased and
#                               stripped of its extension (JQ-LINUX-AMD64,
#                               UV-X86_64-UNKNOWN-LINUX-GNU)
#   3. the EXPECTED argument the caller passed, i.e. a digest the PUBLISHER
#      published beside the bytes
#   4. SANDHOME_SHA256          the bare value, which is a DEFAULT and not an
#                               override: it applies only where nothing more
#                               specific was found
#
# Rule 3 above rule 4 is the load-bearing one. A caller who sets
# SANDHOME_SHA256 to pin one download no longer silently disables go.dev's own
# digest for another, which was the worst part of the old behaviour: a stronger
# check quietly turned off by a weaker one. See docs/decisions/pinning.md.

# sh_pin_name NAME -> the environment variable that pins NAME, upper-cased.
sh_pin_name() { printf 'SANDHOME_SHA256_%s' "$(sh_upper "$1")"; }

# sh_pin_key URL -> the upper-cased basename of URL with its extension removed.
# `jq-linux-amd64` and `uv-x86_64-unknown-linux-gnu.tar.gz` both answer as
# themselves, so a caller can pin a URL-only asset with no toolchain name.
#
# # STOP: THE BASENAME IS CUT BY HAND AND NOT WITH `${url##*/}`, BECAUSE THE
# PATTERN IS GLOB SYNTAX AND AN URL IS NOT A GLOB. `${1##*/}` on
# `https://x/jq-linux-amd64?a=1` finds no `/` after the last one it matches and
# answers the WHOLE URL, and the pin key it then built was
# `HTTPS://X/JQ-LINUX-AMD64?A=1`. A query string has to come off before the
# extension does, or a key for `...tar.gz?token=abc` kept its `?token`. Both
# were measured against this function before the walk below replaced the
# arithmetic.
sh_pin_key() {
    sh_pk_all=$1
    sh_pk_all=${sh_pk_all%%\?*}
    sh_pk_all=${sh_pk_all%%\#*}
    sh_pk_last=''
    sh_pk_rest=$sh_pk_all
    while :; do
        case "$sh_pk_rest" in
            */*) sh_pk_last=${sh_pk_rest%%/*}
                 sh_pk_rest=${sh_pk_rest#*/} ;;
            *)   sh_pk_last=$sh_pk_rest
                 break ;;
        esac
    done
    sh_pk_last=${sh_pk_last%.*}
    # # STOP: THE KEY IS UPPER-CASED WITH ITS HYPHENS KEPT, AND THE `case` IN
    # sh_pin_for HAS AN ARM FOR EACH SPELLING. The first design underscored the
    # key as well, and then the `case` arms were written with hyphens and never
    # matched; the second underscored the arms and they never matched either.
    # The key is what a FILE is called and keeps the file's own hyphens; the
    # variable is what a CALLER can spell in POSIX sh and cannot hold a hyphen.
    # The two are joined by the arms, and tests/unit.sh checks both spellings
    # answer for the same URL so they cannot drift apart again.
    printf '%s' "$(sh_upper "$sh_pk_last")"
}

# sh_pin_for URL [NAME] [PUBLISHED] -> the digest this URL must match, or
# nothing. Nothing is a real answer: it means the download is hashed and printed
# with no value to compare against, which is what happens for the five modules
# whose publisher does not publish a digest this can read.
#
# # STOP: THE LOOKUP IS A `case` AND NOT `eval`, BECAUSE A DERIVED VARIABLE NAME
# CANNOT BE AN INDIRECT REFERENCE IN POSIX SH, AND A NAME BUILT FROM AN URL
# CANNOT BE WRITTEN AT ALL. `eval "x=\${$var:-}"` is the only indirect read
# POSIX sh has, and it is a `case` pattern or a COMMAND as soon as the name
# contains a hyphen, a `*` or a `/`. Both happened here:
#   SANDHOME_SHA256_JQ-LINUX-AMD64=bbb  -> dash: SANDHOME_SHA256_JQ-LINUX-AMD64: not found
#   eval with a key built from an url  -> Bad substitution
# The names this has to read are a CLOSED SET: seven toolchain names and a dozen
# asset basenames, all written below. Naming them makes the lookup a `case` over
# literals, so no URL is ever spliced into a command, and a new toolchain that
# wants a name pin adds one line here. `sh_pin_names` prints the list and
# tests/unit.sh checks it against the modules, so the two cannot drift.
sh_pin_for() {
    sh_pf_url=$1
    sh_pf_name=${2:-}
    sh_pf_published=${3:-}
    if [ -n "$sh_pf_name" ]; then
        case "$sh_pf_name" in
            fd)      [ -n "${SANDHOME_SHA256_FD:-}" ] && { printf '%s' "$SANDHOME_SHA256_FD"; return 0; } ;;
            go)      [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
            jq)      [ -n "${SANDHOME_SHA256_JQ:-}" ] && { printf '%s' "$SANDHOME_SHA256_JQ"; return 0; } ;;
            node)    [ -n "${SANDHOME_SHA256_NODE:-}" ] && { printf '%s' "$SANDHOME_SHA256_NODE"; return 0; } ;;
            python)  [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
            ripgrep) [ -n "${SANDHOME_SHA256_RIPGREP:-}" ] && { printf '%s' "$SANDHOME_SHA256_RIPGREP"; return 0; } ;;
            rust)    [ -n "${SANDHOME_SHA256_RUST:-}" ] && { printf '%s' "$SANDHOME_SHA256_RUST"; return 0; } ;;
        esac
    fi
    case "$(sh_pin_key "$sh_pf_url")" in
        FD)      [ -n "${SANDHOME_SHA256_FD:-}" ] && { printf '%s' "$SANDHOME_SHA256_FD"; return 0; } ;;
        FD-V*)   [ -n "${SANDHOME_SHA256_FD:-}" ] && { printf '%s' "$SANDHOME_SHA256_FD"; return 0; } ;;
        GO)      [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
        GO1)     [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
        GO-*)    [ -n "${SANDHOME_SHA256_GO:-}" ] && { printf '%s' "$SANDHOME_SHA256_GO"; return 0; } ;;
        JQ)      [ -n "${SANDHOME_SHA256_JQ:-}" ] && { printf '%s' "$SANDHOME_SHA256_JQ"; return 0; } ;;
        # # STOP: THE ASSET-NAMED ARMS COME BEFORE THE WILDCARD, BECAUSE `case`
        # TAKES THE FIRST MATCH AND `JQ-LINUX-*` SWALLOWS `JQ-LINUX-AMD64`. An
        # asset-specific pin placed after its own wildcard never runs, which is
        # what made the first version of this arm silently answer the
        # toolchain-named pin instead and the clause below pass for the wrong
        # reason on a machine that had both set.
        #
        # AN ASSET-NAMED PIN HAS ITS OWN LITERAL ARM, AND ITS NAME USES
        # UNDERSCORES. jq ships a different binary per platform from the same
        # module, so `SANDHOME_SHA256_JQ` is ambiguous between `jq-linux-amd64`
        # and `jq-linux-arm64`, and a caller pinning one for a given machine has
        # no way to name the other. The arm reads the variable spelled after the
        # asset - and that spelling is underscored, because a POSIX sh
        # ASSIGNMENT CANNOT HOLD A HYPHEN IN ITS NAME AT ALL:
        #   SANDHOME_SHA256_JQ-LINUX-AMD64=bbb   ->  dash: not found
        # The hyphen form was the first design here and it was unusable: the
        # caller could not set it, and the `case` arm that read it could never
        # see a value. The key still has hyphens because it is DERIVED from a
        # file name; only the VARIABLE is spelled with underscores.
        JQ_LINUX_AMD64) [ -n "${SANDHOME_SHA256_JQ_LINUX_AMD64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_LINUX_AMD64}"; return 0; } ;;
        JQ_LINUX_ARM64) [ -n "${SANDHOME_SHA256_JQ_LINUX_ARM64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_LINUX_ARM64}"; return 0; } ;;
        JQ_MACOS_AMD64) [ -n "${SANDHOME_SHA256_JQ_MACOS_AMD64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_MACOS_AMD64}"; return 0; } ;;
        # The HYPHENATED key, matched by translating it, so a file called
        # `jq-linux-amd64` and a variable called JQ_LINUX_AMD64 are the same
        # question asked two ways.
        JQ-LINUX-*) [ -n "${SANDHOME_SHA256_JQ_LINUX_AMD64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_LINUX_AMD64}"; return 0; } ;;
        JQ-MACOS-*) [ -n "${SANDHOME_SHA256_JQ_MACOS_AMD64:-}" ] && { printf '%s' "${SANDHOME_SHA256_JQ_MACOS_AMD64}"; return 0; } ;;
        NODE)    [ -n "${SANDHOME_SHA256_NODE:-}" ] && { printf '%s' "$SANDHOME_SHA256_NODE"; return 0; } ;;
        NODE-V*) [ -n "${SANDHOME_SHA256_NODE:-}" ] && { printf '%s' "$SANDHOME_SHA256_NODE"; return 0; } ;;
        PYTHON)  [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
        RIPGREP) [ -n "${SANDHOME_SHA256_RIPGREP:-}" ] && { printf '%s' "$SANDHOME_SHA256_RIPGREP"; return 0; } ;;
        RIPGREP-*) [ -n "${SANDHOME_SHA256_RIPGREP:-}" ] && { printf '%s' "$SANDHOME_SHA256_RIPGREP"; return 0; } ;;
        RUSTUP-*) [ -n "${SANDHOME_SHA256_RUST:-}" ] && { printf '%s' "$SANDHOME_SHA256_RUST"; return 0; } ;;
        UV)      [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
        UV-*)    [ -n "${SANDHOME_SHA256_PYTHON:-}" ] && { printf '%s' "$SANDHOME_SHA256_PYTHON"; return 0; } ;;
    esac
    # # NOTE: THE BARE VALUE IS A DEFAULT AND NOT AN OVERRIDE, AND THE ORDER
    # IS THE WHOLE FIX. It used to be `${SANDHOME_SHA256:-$published}` in every
    # module, so a caller who set it to pin ONE download silently replaced the
    # digest go.dev publishes for a DIFFERENT one. Measured: with
    # SANDHOME_SHA256 set, the go module compared go.dev's tarball against the
    # caller's value and failed with a message naming the mirror. A weaker check
    # the caller set for something else had disabled a stronger one.
    if [ -n "$sh_pf_published" ]; then
        printf '%s' "$sh_pf_published"
        return 0
    fi
    if [ -n "${SANDHOME_SHA256:-}" ]; then
        printf '%s' "$SANDHOME_SHA256"
        return 0
    fi
    printf ''
}

# sh_pin_names -> every toolchain name a `SANDHOME_SHA256_<NAME>` pin answers to.
# Printed so tests/unit.sh can require one entry per module in tools/, which is
# what keeps the closed `case` above from going stale when a module is added.
sh_pin_names() { printf ' fd go jq node python ripgrep rust\n'; }

# sh_pin_from URL [NAME] [PUBLISHED] -> the NAME of the pin that answered for
# this URL, or nothing. The provenance line in the report names it, because a
# caller holding four pins needs to know which of them a given download was held
# to, and "the release" when the value came from SANDHOME_SHA256_RIPGREP is a
# claim that is false in the only direction that matters.
sh_pin_from() {
    sh_pfr_url=$1
    sh_pfr_name=${2:-}
    sh_pfr_published=${3:-}
    sh_pfr_pin=$(sh_pin_for "$sh_pfr_url" "$sh_pfr_name" "$sh_pfr_published")
    [ -n "$sh_pfr_pin" ] || return 0
    if [ -n "$sh_pfr_name" ]; then
        # # STOP: THE NAME IS CHECKED AGAINST sh_pin_names BEFORE IT BECOMES A
        # VARIABLE NAME, BECAUSE AN ARBITRARY STRING IS NOT A SAFE NAME TO eval.
        # `sh_pin_from "https://x/go.tar.gz" go` built `SANDHOME_SHA256_GO` and
        # read it, which was fine; the same call with a name that is not a
        # toolchain built a name no one had set and dash answered "Bad
        # substitution" from inside the eval. The closed list is the same one
        # sh_pin_for's `case` uses, so the two cannot disagree about what a name
        # is.
        case " $(sh_pin_names) " in
            *" $sh_pfr_name "*)
                sh_pfr_var="SANDHOME_SHA256_$(sh_upper "$sh_pfr_name")"
                # shellcheck disable=SC1090
                eval "sh_pfr_had=\${$sh_pfr_var:-}"
                if [ "$sh_pfr_had" = "$sh_pfr_pin" ]; then
                    printf '%s' "$sh_pfr_var"
                    return 0
                fi
                ;;
        esac
    fi
    # Not the toolchain-named pin: it came from an asset-named pin, the bare
    # value, or the publisher. Each is one more `case` over literals, and the
    # report reads whichever answers.
    sh_pfr_key=$(sh_pin_key "$sh_pfr_url")
    # Hyphen to underscore with the shell, not with sed: this library is loaded
    # on userlands that carry no sed, and a helper that reaches for one dies on
    # the machines the tool exists for.
    sh_pfr_under=''
    sh_pfr_rest=$sh_pfr_key
    while [ -n "$sh_pfr_rest" ]; do
        sh_pfr_c=${sh_pfr_rest%"${sh_pfr_rest#?}"}
        sh_pfr_rest=${sh_pfr_rest#?}
        if [ "$sh_pfr_c" = '-' ]; then
            sh_pfr_under="${sh_pfr_under}_"
        else
            sh_pfr_under="$sh_pfr_under$sh_pfr_c"
        fi
    done
    sh_pfr_var_asset="SANDHOME_SHA256_$sh_pfr_under"
    # # STOP: AN ASSET VAR IS ONLY READ WHEN IT IS A VALID IDENTIFIER. The key is
    # a FILE name, so it can carry a dot: `go.tar.gz` yields the key `GO.TAR`,
    # the underscored asset variable is `SANDHOME_SHA256_GO.TAR`, and
    # `eval "x=\${SANDHOME_SHA256_GO.TAR:-}"` is not a parameter expansion at
    # all - dash answers "Bad substitution" and the whole provenance lookup dies
    # on any URL whose asset name has more than one extension. The `case` below
    # is the same test the shell performs, written out, and the empty answer it
    # produces is correct: there is no variable by that name.
    case "$sh_pfr_var_asset" in
        *[!A-Za-z0-9_]*) sh_pfr_var_asset='' ;;
    esac
    if [ -n "$sh_pfr_var_asset" ]; then
        # shellcheck disable=SC1090
        eval "sh_pfr_had_asset=\${$sh_pfr_var_asset:-}"
        if [ "$sh_pfr_had_asset" = "$sh_pfr_pin" ]; then
            printf '%s' "$sh_pfr_var_asset"
            return 0
        fi
    fi
    if [ -n "${SANDHOME_SHA256:-}" ] && [ "$SANDHOME_SHA256" = "$sh_pfr_pin" ]; then
        printf 'SANDHOME_SHA256'
        return 0
    fi
    # # STOP: THE PUBLISHED CHECK COMES AFTER THE BARE ONE, OR A CALLER WHO SET
    # BOTH IS TOLD THE WRONG SOURCE. `sh_pin_for` ranks the bare default BELOW a
    # published digest, and `sh_pin_from` has to rank them the same way, or the
    # report names one and the resolver used the other - which is a check whose
    # provenance is false in the one direction that matters.
    if [ -n "$sh_pfr_published" ] && [ "$sh_pfr_published" = "$sh_pfr_pin" ]; then
        printf 'the published digest'
        return 0
    fi
    printf ''
}

# sh_fetch_verified URL DEST [EXPECTED_SHA256] -> fetch and, when a digest tool
# is present, prove the bytes. A missing digest tool is reported, not ignored:
# `SANDHOME_REQUIRE_DIGEST=1` turns that into a refusal.
sh_fetch_verified() {
    sh_fv_url=$1
    sh_fv_dest=$2
    # # STOP: EVERY OPERAND IS BRACED, BECAUSE `set -u` IS A RUNTIME ABORT AND NOT
    # A LINT WARNING. Three shapes of this line were live at once. `X=the
    # release` with an unquoted value is word-split by dash into a command:
    # `dash -uc 'x=the release; echo "[$x]"'` prints "release: not found",
    # leaves x UNSET, and the next reader dies with "sh: 134: sh_fv_from:
    # parameter not set". Because `sh_step` is a printf to stderr, that
    # expansion failure EXITS THE PROCESS, so the caller's
    # `if ! sh_fetch_verified ...` never sees a status at all and the install
    # dies mid-run with no env.sh written. shellcheck does not flag it: it is a
    # dash runtime behaviour, so the guard has to be an EXECUTED clause.
    # Pinned in tests/unit.sh.
    sh_fv_expected=${3:-}
    [ -n "$sh_fv_expected" ] || sh_fv_expected=''
    if ! sh_fetch "$sh_fv_url" "$sh_fv_dest"; then
        return 1
    fi
    sh_fv_tool=$(sh_sha256_which)
    sh_fv_actual=$(sh_sha256 "$sh_fv_dest")
    if [ -z "$sh_fv_actual" ]; then
        if [ "${SANDHOME_REQUIRE_DIGEST:-0}" = 1 ]; then
            sh_fail "no sha256 tool is present, and SANDHOME_REQUIRE_DIGEST is set; refusing $sh_fv_url"
            return 1
        fi
        sh_warn "no sha256 tool is present, so $sh_fv_url could not be verified"
        return 0
    fi
    # # NOTE: THE REPORT NAMES THE TOOL THAT ANSWERED AND WHERE THE EXPECTED
    # DIGEST CAME FROM. Both were claimed by the documentation and neither was
    # true: the line said "matches the release digest" even when the value had
    # been pinned by the caller, and it never said which of sha256sum, sha256,
    # shasum, openssl, python3 or node produced the hash. A digest check whose
    # provenance is invisible is a check nobody can reproduce.
    #
    # # STOP: THE PROVENANCE IS THE PIN THAT ANSWERED, AND IT IS READ FROM THE
    # EXPECTED VALUE RATHER THAN GUESSED FROM WHICH VARIABLES ARE SET. A first
    # version said "SANDHOME_SHA256" whenever the bare variable was non-empty,
    # which is true for a run with four pins and false about every one of them:
    # the download was held to SANDHOME_SHA256_RIPGREP and the report named
    # SANDHOME_SHA256. A provenance that cannot be wrong is not a provenance.
    sh_fv_from='the release'
    sh_fv_pinned_by=$(sh_pin_from "$sh_fv_url" '' "$sh_fv_expected")
    if [ -n "$sh_fv_pinned_by" ]; then
        sh_fv_from="$sh_fv_pinned_by (pinned by the caller)"
    fi
    if [ -z "$sh_fv_expected" ]; then
        sh_step "sha256 $sh_fv_actual (taken with $sh_fv_tool; no digest to compare against)"
        return 0
    fi
    if [ "$sh_fv_actual" != "$sh_fv_expected" ]; then
        sh_fail "$sh_fv_url does not match the expected sha256 (got $sh_fv_actual with $sh_fv_tool, wanted $sh_fv_expected)"
        return 1
    fi
    sh_step "sha256 matches the value from $sh_fv_from (taken with $sh_fv_tool)"
    return 0
}

# sh_untar TARBALL DEST -> unpack .tar.gz, .tgz, .tar.xz, .txz, .tar.zst or .zip
# by reading the file, not the URL. A tar that cannot read the compression is
# reported rather than half-unpacking.
sh_untar() {
    sh_ut_file=$1
    sh_ut_dest=$2
    mkdir -p "$sh_ut_dest" 2>/dev/null || return 1
    case "$sh_ut_file" in
        *.zip)
            if sh_have unzip; then
                unzip -q -o "$sh_ut_file" -d "$sh_ut_dest"
                return $?
            fi
            if sh_have python3; then
                python3 -c 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$sh_ut_file" "$sh_ut_dest"
                return $?
            fi
            sh_warn 'a .zip arrived and neither unzip nor python3 can open it'
            return 1
            ;;
    esac
    sh_ut_flags=''
    case "$sh_ut_file" in
        *.tar.gz|*.tgz) sh_ut_flags='-xzf' ;;
        *.tar.xz|*.txz) sh_ut_flags='-xJf' ;;
        *.tar.zst|*.tzst)
            if sh_have zstd; then
                sh_ut_flags='--zstd -xvf'
            else
                sh_warn 'a zstd tarball arrived and no zstd is present'
                return 1
            fi
            ;;
        *.tar.bz2|*.tbz|*.tbz2)
            if sh_have bzip2; then
                sh_ut_flags='-xjf'
            else
                sh_warn 'a bzip2 tarball arrived and no bzip2 is present'
                return 1
            fi
            ;;
        *.tar) sh_ut_flags='-xf' ;;
        *)
            sh_ut_flags='-xf'
            ;;
    esac
    # shellcheck disable=SC2086
    tar $sh_ut_flags "$sh_ut_file" -C "$sh_ut_dest"
    return $?
}

# sh_fetch_unpack URL DEST_DIR -> download to the home staging area, unpack, and
# answer the one top-level directory the archive made in MODULE_UNPACK_DIR. A
# tarball that makes several top-level entries is reported, because guessing
# which one is the toolchain is how a wrong tree gets moved into place.
sh_fetch_unpack() {
    sh_fu_url=$1
    sh_fu_dest=$2
    sh_fu_stage=${SH_HOME_TMP:-${TMPDIR:-/tmp}}
    mkdir -p "$sh_fu_stage" 2>/dev/null || return 1
    sh_fu_tmp="$sh_fu_stage/.fetch.$$"
    rm -rf "$sh_fu_tmp" 2>/dev/null
    mkdir -p "$sh_fu_tmp" 2>/dev/null || return 1
    sh_fu_file="$sh_fu_tmp/${sh_fu_url##*/}"
    if ! sh_fetch_verified "$sh_fu_url" "$sh_fu_file" "$(sh_pin_for "$sh_fu_url")"; then
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    sh_fu_out="$sh_fu_tmp/out"
    if ! sh_untar "$sh_fu_file" "$sh_fu_out"; then
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    # Count the top-level entries without `ls | wc`.
    sh_fu_n=0
    sh_fu_one=''
    for sh_fu_e in "$sh_fu_out"/* "$sh_fu_out"/.[!.]*; do
        [ -e "$sh_fu_e" ] || continue
        sh_fu_n=$((sh_fu_n + 1))
        sh_fu_one=$sh_fu_e
    done
    if [ "$sh_fu_n" -eq 0 ]; then
        sh_warn "the archive from $sh_fu_url unpacked nothing"
        rm -rf "$sh_fu_tmp" 2>/dev/null
        return 1
    fi
    # The parent of DEST without dirname, which a minimal userland lacks.
    case "$sh_fu_dest" in
        */*) mkdir -p "${sh_fu_dest%/*}" 2>/dev/null || true ;;
    esac
    if [ "$sh_fu_n" -eq 1 ] && [ -d "$sh_fu_one" ]; then
        rm -rf "$sh_fu_dest" 2>/dev/null
        mv "$sh_fu_one" "$sh_fu_dest" || { rm -rf "$sh_fu_tmp" 2>/dev/null; return 1; }
    else
        rm -rf "$sh_fu_dest" 2>/dev/null
        mv "$sh_fu_out" "$sh_fu_dest" || { rm -rf "$sh_fu_tmp" 2>/dev/null; return 1; }
    fi
    rm -rf "$sh_fu_tmp" 2>/dev/null
    return 0
}
