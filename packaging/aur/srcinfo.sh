#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Writes .SRCINFO for the PKGBUILD in DIR, using makepkg as a non-root user in the fake-systemd-aur image.
# Usage: packaging/aur/srcinfo.sh DIR   (CONTAINER_ENGINE overrides podman)
set -eu

[ $# -eq 1 ] || { echo "usage: $0 DIR" >&2; exit 2; }
engine=${CONTAINER_ENGINE:-podman}
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "$1" && pwd)

"$engine" build -q -t fake-systemd-aur -f "$here/Containerfile" "$here" >/dev/null
chmod a+rwx "$dir"
chmod a+r "$dir/PKGBUILD"
"$engine" run --rm -v "$dir:/pkg:Z" fake-systemd-aur \
    su builder -c 'cd /pkg && makepkg --printsrcinfo' >"$dir/.SRCINFO"
