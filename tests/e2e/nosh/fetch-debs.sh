#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Downloads the nosh 1.41 packages listed in debs.sha256 into a directory (default: debs/ beside this
# script), skipping files that already match their sha256 and retrying transient failures with a backoff.
# The author's repository is plain HTTP, so every file is verified before it is kept; NOSH_REPO overrides it.
# Usage: tests/e2e/nosh/fetch-debs.sh [directory]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dir=${1:-$here/debs}
repo=${NOSH_REPO:-http://debian.repository.jdebp.info/dists/stable/main/binary-amd64}
attempts=5

mkdir -p "$dir"
while read -r sum name; do
    if [ -f "$dir/$name" ] && echo "$sum  $name" | (cd "$dir" && sha256sum -c --status -); then
        echo "fetch-debs: $name present"
        continue
    fi
    n=1
    while :; do
        if curl -fsSL --connect-timeout 15 --max-time 300 -o "$dir/$name.part" "$repo/$name" \
            && echo "$sum  $name.part" | (cd "$dir" && sha256sum -c --status -); then
            mv "$dir/$name.part" "$dir/$name"
            echo "fetch-debs: $name downloaded"
            break
        fi
        rm -f "$dir/$name.part"
        if [ "$n" -ge "$attempts" ]; then
            echo "fetch-debs: $name failed after $attempts attempts" >&2
            exit 1
        fi
        sleep $((n * 5))
        n=$((n + 1))
    done
done <"$here/debs.sha256"
