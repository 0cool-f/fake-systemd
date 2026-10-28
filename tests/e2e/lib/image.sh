#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds an image only when its inputs changed. The image is tagged NAME:HASH, where HASH covers the
# Containerfile, the build args and every context file the Containerfile COPYs, and NAME points at it.
# IMAGE_CACHE_DIR, when set, holds a compressed tar per image that is loaded instead of building and
# written after a build. Builds are retried IMAGE_BUILD_ATTEMPTS times (default 3) with a backoff.
# Usage: tests/e2e/lib/image.sh [-f CONTAINERFILE] NAME CONTEXT [--build-arg KEY=VALUE]...   (CONTAINER_ENGINE overrides podman)
set -eu

engine=${CONTAINER_ENGINE:-podman}
attempts=${IMAGE_BUILD_ATTEMPTS:-3}
cache=${IMAGE_CACHE_DIR:-}

file=
if [ "${1:-}" = -f ]; then
    file=$2
    shift 2
fi
[ $# -ge 2 ] || { echo "usage: $0 [-f CONTAINERFILE] NAME CONTEXT [--build-arg KEY=VALUE]..." >&2; exit 2; }
name=$1
context=$(cd "$2" && pwd)
shift 2
file=${file:-$context/Containerfile}

args=
while [ $# -gt 0 ]; do
    [ "$1" = --build-arg ] && [ $# -ge 2 ] || { echo "image: unexpected argument: $1" >&2; exit 2; }
    args="$args
$2"
    shift 2
done

# Context paths the Containerfile COPYs or ADDs from the build context (not from another stage).
sources=$(awk '
    toupper($1) == "COPY" || toupper($1) == "ADD" {
        n = 0; local = 1
        for (i = 2; i <= NF; i++) {
            if ($i ~ /^--from=/) local = 0
            else if ($i !~ /^--/) paths[++n] = $i
        }
        if (local) for (i = 1; i < n; i++) print paths[i]
    }' "$file")

hash=$(
    {
        cat "$file"
        printf '%s\n' "$args"
        cd "$context"
        # Unquoted on purpose: a source may be a glob.
        for s in $sources; do
            # shellcheck disable=SC2086
            find $s -type f
        done | LC_ALL=C sort -u | while read -r f; do sha256sum "$f"; done
    } | sha256sum | cut -c1-16
)
ref=$name:$hash

if command -v zstd >/dev/null 2>&1; then
    ext=tar.zst
    compress='zstd -q -T0 -3'
    decompress='zstd -q -dc'
else
    ext=tar.gz
    compress='gzip -3'
    decompress='gzip -dc'
fi
tar_file=${cache:+$cache/$name-$hash.$ext}

save() {
    [ -n "$cache" ] || return 0
    mkdir -p "$cache"
    rm -f "$cache/$name"-*.tar.*
    "$engine" save "$ref" | $compress >"$tar_file.part"
    mv "$tar_file.part" "$tar_file"
    echo "image: $ref saved to $tar_file ($(du -h "$tar_file" | cut -f1))"
}

if "$engine" image inspect "$ref" >/dev/null 2>&1; then
    echo "image: $ref cached, skipping build"
    [ -z "$cache" ] || [ -f "$tar_file" ] || save
elif [ -n "$cache" ] && [ -f "$tar_file" ] && $decompress "$tar_file" | "$engine" load >/dev/null; then
    echo "image: $ref loaded from $tar_file, skipping build"
else
    log=$(mktemp)
    trap 'rm -f "$log"' EXIT
    set --
    for a in $args; do set -- "$@" --build-arg "$a"; done
    n=1
    until "$engine" build -q -t "$ref" -f "$file" "$@" "$context" >"$log" 2>&1; do
        tail -n 30 "$log" >&2
        [ "$n" -lt "$attempts" ] || { echo "image: $ref build failed after $attempts attempts" >&2; exit 1; }
        echo "image: $ref build failed, retrying in $((n * 20))s" >&2
        sleep $((n * 20))
        n=$((n + 1))
    done
    echo "image: $ref built"
    save
fi

"$engine" tag "$ref" "$name"
# Drop older builds of this image so local storage does not grow with every change.
"$engine" images --format '{{.Repository}}:{{.Tag}}' "$name" 2>/dev/null |
    grep -v -e ":$hash\$" -e ':latest$' | xargs -r "$engine" rmi >/dev/null 2>&1 || true
