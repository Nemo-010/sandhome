#!/bin/sh
# perl, the interpreter autoconf, automake and ./configure need. It is on
# nearly every base image, so this module exists to give the project toolset a
# name for it rather than to download one: adoption is the common path and the
# install leg is a clearly-named refusal that points at the base image.
# (issue #123: perl was adopted with no catalog entry, so a base without it
# failed with no way to install it by name.)
TC_perl_DESC='perl, the interpreter autoconf and ./configure need (adopted)'
TC_perl_BINS='perl'
TC_perl_EXEC_MB=8

tc_perl_exec_mb() {
    printf '8'
}

tc_perl_probe() {
    sh_have perl && perl -e 'exit 0' >/dev/null 2>&1
}

tc_perl_install() {
    # A portable perl is a multi-hundred-megabyte build with its own test
    # suite; no sandbox builds one to get a configure script running. When the
    # base has none, the honest answer is the base package, named by platform,
    # not a half-built local copy that then fails every XS module.
    if sh_have apt-get; then
        sh_warn 'no perl here; install it from your base image (apt-get install -y perl)'
    elif sh_have apk; then
        sh_warn 'no perl here; install it from your base image (apk add perl)'
    elif sh_have dnf || sh_have yum; then
        sh_warn 'no perl here; install it from your base image (dnf install -y perl)'
    else
        sh_warn 'no perl here; install perl from your base image'
    fi
    return 1
}

tc_perl_env() {
    return 0
}

tc_perl_version() {
    sh_have perl && perl -e 'print $];' 2>/dev/null
}

tc_perl_adopted() {
    sh_pl_which=$(sh_path_where perl)
    [ -n "$sh_pl_which" ] || return 0
    printf '%s' "${sh_pl_which%/*}"
}
