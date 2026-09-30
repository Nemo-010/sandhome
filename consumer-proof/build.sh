#!/bin/sh
# build.sh TREE RIG HOMEDIR EXECDIR [TOOLSET] [EXTRA...]
# Consumer-shaped install. HOMEDIR on a noexec root and EXECDIR on a roomy
# exec-capable root is the split shape this tree exists for. The only network
# help is the session's own egress, which a real sandbox has by other means.
set -u
TREE=$1
RIG=$2
HOMEDIR=$3
EXECDIR=$4
TOOLSET=${5:-developer}
shift 5 2>/dev/null || shift $#
rm -rf "$RIG" "$HOMEDIR" "$EXECDIR"
mkdir -p "$HOMEDIR" "$RIG/wsbin" 2>/dev/null
P="$HOMEDIR/bin:$RIG/wsbin:/usr/local/bin:/usr/bin:/bin"
( cd "$TREE" && env -i \
    HOME="$HOMEDIR" \
    PATH="$P" \
    TMPDIR=/tmp \
    http_proxy="$http_proxy" https_proxy="$https_proxy" no_proxy="$no_proxy" \
    sh bootstrap.sh --toolset "$TOOLSET" --exec "$EXECDIR" "$@" ) > "$RIG/bootstrap.log" 2>&1
rc=$?
printf 'bootstrap rc=%s (log: %s)\n' "$rc" "$RIG/bootstrap.log"
grep -E '^(view|memexec|global|failures)=' "$RIG/bootstrap.log" 2>/dev/null
exit $rc