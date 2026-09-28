#!/bin/sh
# tests/fetch.sh - the sharded/streaming fetch, driven end to end without a
# network. A local `curl` function stands in for the server so the real range
# arithmetic, part naming, size check, stream digest and stream unpack all run.
#
# NOTE: THE SERVER IS A FUNCTION, NOT A LISTENING SOCKET. This sandbox denies
# bind(), so a local http.server cannot start; shadowing curl exercises the same
# code path with no socket and no dependency on a network stack.

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$HERE/.." && pwd)
. "$HERE/lib.sh"

for m in common detect space fetch; do
    # shellcheck source=/dev/null
    . "$ROOT/lib/$m.sh"
done
SH_SELF=fetchtest
export SH_SELF

if ! command -v sha256sum >/dev/null 2>&1; then
    echo 'fetch: no sha256sum' >&2
    exit 2
fi

t_begin fetch

work=$(mktemp -d "${TMPDIR:-/tmp}/sandhome-fetch.XXXXXX")
trap 'rm -rf "$work"' EXIT
SH_HOME_TMP="$work/home-tmp"
export SH_HOME_TMP
mkdir -p "$work/srv" "$SH_HOME_TMP"

# Fixtures: a 3MB blob and a tar.gz of small files.
head -c 3145728 /dev/urandom > "$work/srv/blob.bin"
mkdir -p "$work/src/sub"
printf 'stream unpack\n' > "$work/src/sub/a.txt"
head -c 2097152 /dev/urandom > "$work/src/sub/big.bin"
tar -czf "$work/srv/arch.tgz" -C "$work/src" .
mkdir -p "$work/zipsrc"
printf 'zip payload\n' > "$work/zipsrc/z.txt"
head -c 1200000 /dev/urandom > "$work/zipsrc/z.bin"
if command -v zip >/dev/null 2>&1; then
    ( cd "$work/zipsrc" && zip -q -r "$work/srv/arch.zip" . ) 2>/dev/null || true
elif command -v python3 >/dev/null 2>&1; then
    ( cd "$work/zipsrc" && ZOUT="$work/srv/arch.zip" python3 -c 'import zipfile,os
z=zipfile.ZipFile(os.environ["ZOUT"],"w",zipfile.ZIP_DEFLATED)
for r,d,fs in os.walk("."):
    for f in fs:
        p=os.path.join(r,f); z.write(p,os.path.relpath(p,"."))' ) 2>/dev/null || true
fi

# # STOP: THE STUB IS a curl THAT SERVES RANGES FROM $work/srv. It answers
# --version (sh_downloader_ok probes for it), -I (HEAD, with Content-Length),
# -r a-b (206 with the requested slice), and a plain GET. The URL's basename
# names the file, so one stub serves several fixtures.
curl() {
    sh_t_o=''; sh_t_range=''; sh_t_url=''; sh_t_head=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) printf 'curl 8.fake\n'; return 0 ;;
            -o) sh_t_o=$2; shift 2 ;;
            -r) sh_t_range=$2; shift 2 ;;
            -D) shift 2 ;;
            --retry|--retry-delay|--max-time|--connect-timeout|--doh-url) shift 2 ;;
            -*) case "$1" in *I*) sh_t_head=1 ;; esac; shift ;;
            *) sh_t_url=$1; shift ;;
        esac
    done
    sh_t_path="$work/srv/${sh_t_url##*/}"
    [ -r "$sh_t_path" ] || return 22
    if [ "$sh_t_head" = 1 ]; then
        # A redirect contributes its own Content-Length first; the real one is
        # last, and the parser must take the last.
        printf 'HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n'
        printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "$(wc -c < "$sh_t_path")"
        return 0
    fi
    if [ -n "$sh_t_range" ]; then
        sh_t_s=${sh_t_range%%-*}; sh_t_e=${sh_t_range#*-}
        tail -c "+$((sh_t_s + 1))" "$sh_t_path" | head -c "$((sh_t_e - sh_t_s + 1))" > "$sh_t_o"
        return 0
    fi
    cat "$sh_t_path" > "$sh_t_o"
    return 0
}

SANDHOME_FETCH_CHUNK_MB=1
export SANDHOME_FETCH_CHUNK_MB

st=$(sh_url_content_length http://x/blob.bin)
t_is "$st" "$(wc -c < "$work/srv/blob.bin")" 'the size is read from the final Content-Length of a redirect chain'

d="$work/stream"
if sh_fetch_stream http://x/blob.bin "$d" >/dev/null 2>&1; then
    t_ok 0 'a 3MB fetch with a 1MB chunk succeeds'
else
    t_ok 1 'a 3MB fetch with a 1MB chunk succeeds'
fi
n=0
for p in "$d"/part.*; do [ -e "$p" ] || continue; n=$((n + 1)); done
t_is "$n" 3 'the fetch is split into three ranges'
t_is "$(sh_stream_size "$d")" "$(wc -c < "$work/srv/blob.bin")" 'the parts reassemble to the full size'
t_is "$(sh_stream_sha256 "$d")" "$(sha256sum "$work/srv/blob.bin" | cut -d' ' -f1)" 'the stream digest matches the file digest'
t_is "$(sh_stream_cat "$d" | wc -c)" "$(wc -c < "$work/srv/blob.bin")" 'sh_stream_cat yields every byte once'

want=$(sha256sum "$work/srv/arch.tgz" | cut -d' ' -f1)
if sh_fetch_verified_stream http://x/arch.tgz "$work/good" "$want" >/dev/null 2>&1; then
    t_ok 0 'a stream with the right digest verifies'
else
    t_ok 1 'a stream with the right digest verifies'
fi
mkdir -p "$work/out"
if sh_stream_untar "$work/good" "$work/out" >/dev/null 2>&1 && cmp -s "$work/src/sub/big.bin" "$work/out/sub/big.bin"; then
    t_ok 0 'a sharded tar.gz unpacks from the stream and the bytes match'
else
    t_ok 1 'a sharded tar.gz unpacks from the stream and the bytes match'
fi

if sh_fetch_verified_stream http://x/arch.tgz "$work/bad" 0000000000000000000000000000000000000000000000000000000000000000 >/dev/null 2>&1; then
    t_ok 1 'a stream with the wrong digest is refused'
else
    t_ok 0 'a stream with the wrong digest is refused'
fi
[ -d "$work/bad" ] && t_ok 1 'refused bytes are removed' || t_ok 0 'refused bytes are removed'

# A zip under the limit still unpacks (it is materialised first).
if [ -r "$work/srv/arch.zip" ] && ( command -v unzip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 ); then
    if sh_fetch_unpack http://x/arch.zip "$work/zipout" >/dev/null 2>&1 && [ -r "$work/zipout/z.txt" ]; then
        t_ok 0 'a small zip unpacks through the streaming path'
    else
        t_ok 1 'a small zip unpacks through the streaming path'
    fi
else
    t_skip 'zip unpack (no unzip/python3 or fixture)'
fi

# A zip bigger than the file-size limit is refused by name, not half-read.
if [ -r "$work/srv/arch.zip" ]; then
    got=$( ( sh_fsize_cap_bytes() { printf 1000000; }; sh_fetch_stream http://x/arch.zip "$work/bigzip" >/dev/null 2>&1
             mkdir -p "$work/bigout"
             sh_stream_untar "$work/bigzip" "$work/bigout" >/dev/null 2>&1; printf '%s' "$?" ) )
    t_is "$got" 1 'a zip above the file-size limit is refused'
else
    t_skip 'zip limit refusal (no fixture)'
fi

# The chunk never exceeds the cap: with a fake 1,000,000-byte cap it drops to
# 750,000, so a part cannot touch the limit.
got=$( sh_fsize_cap_bytes() { printf 1000000; }; sh_fetch_chunk_bytes )
t_is "$got" 750000 'the chunk is capped at three quarters of the file-size limit'

r=$(sh_fetch_ranges 10 4)
t_is "$r" '000000 0 3
000001 4 7
000002 8 9' 'ranges tile the total with an inclusive end'
t_is "$(sh_fetch_ranges 5 100)" '000000 0 4' 'one range covers a total under the chunk'

t_end
