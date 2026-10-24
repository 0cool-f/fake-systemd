#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds the release tarballs locally, renders the PKGBUILD against them via file://, then runs
# makepkg and namcap as a non-root user in the fake-systemd-aur image. Needs the `fake-systemd-build` image.
# Usage: packaging/aur/test.sh   (CONTAINER_ENGINE overrides podman)
set -eu

engine=${CONTAINER_ENGINE:-podman}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$root/.zig-cache/aur-test
version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$root/build.zig.zon")

rm -rf "${work:?}"
mkdir -p "$work/dist" "$work/pkg"
for target in x86_64-linux-musl aarch64-linux-musl; do
    "$root/packaging/build-tarball.sh" "$target" "$work/dist"
done

sum() { sha256sum "$work/dist/fake-systemd-$version-$1.tar.gz" | cut -d' ' -f1; }
VERSION=$version OWNER=local MAINTAINER='Local Test <test@example.invalid>' \
    SHA256_X86_64=$(sum x86_64-linux-musl) SHA256_AARCH64=$(sum aarch64-linux-musl) \
    BASE_URL=file:///dist "$here/render.sh" >"$work/pkg/PKGBUILD"

"$here/srcinfo.sh" "$work/pkg"
cat "$work/pkg/.SRCINFO"

"$engine" build -q -t fake-systemd-aur -f "$here/Containerfile" "$here" >/dev/null
chmod -R a+rX "$work"
"$engine" run --rm -v "$work/dist:/dist:ro,Z" -v "$work/pkg:/pkg:Z" fake-systemd-aur sh -eu -c '
    trap "chown -R root:root /pkg" EXIT
    chmod a+rwx /pkg
    su builder -c "cd /pkg && makepkg -f --nodeps --nocolor"
    cd /pkg
    echo "== namcap PKGBUILD"
    namcap PKGBUILD
    echo "== namcap package"
    namcap ./*.pkg.tar.zst
    echo "== package contents"
    bsdtar -tvf ./*.pkg.tar.zst
'
