#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the release tarball fake-systemd-<version>-<target>.tar.gz in the `fake-systemd-build` image.
# Usage: packaging/build-tarball.sh TARGET OUTDIR   (CONTAINER_ENGINE overrides podman)
set -eu

[ $# -eq 2 ] || { echo "usage: $0 TARGET OUTDIR" >&2; exit 2; }
target=$1
out=$2
engine=${CONTAINER_ENGINE:-podman}
root=$(cd "$(dirname "$0")/.." && pwd)

version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root/build.zig.zon")
[ -n "$version" ] || { echo "no version in build.zig.zon" >&2; exit 1; }
name=fake-systemd-$version-$target
epoch=${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct 2>/dev/null || echo 0)}

work=$root/.zig-cache/release
rm -rf "${work:?}/$target" "${work:?}/$name"
mkdir -p "$work" "$out"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget="$target" -Doptimize=ReleaseSmall --prefix ".zig-cache/release/$target"

mkdir "$work/$name"
cp -P "$work/$target/bin/fake-systemd" "$work/$target/bin/systemctl" "$work/$target/bin/journalctl" "$work/$name/"
cp "$root/LICENSE" "$root/README.md" "$work/$name/"

out=$(cd "$out" && pwd)
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -C "$work" -cf - "$name" |
    gzip -9n >"$out/$name.tar.gz"
echo "$out/$name.tar.gz"
