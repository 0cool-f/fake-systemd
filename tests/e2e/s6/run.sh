#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the s6-rc and s6 backends: builds the static binary, then drives a real
# s6-svscan (not PID 1) and s6-rc through systemctl in three setups:
#   artix      s6-rc with the s6 frontend and its repository (Artix)
#   alpine-rc  s6-rc compiled from source directories (Alpine)
#   alpine-s6  s6 without s6-rc, services linked into the scan directory (Alpine)
# Usage: tests/e2e/s6/run.sh [artix|alpine-rc|alpine-s6]...   (needs podman, or CONTAINER_ENGINE=docker,
# and the `fake-systemd-build` image; every setup runs without arguments)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

[ "$#" -gt 0 ] || set -- artix alpine-rc alpine-s6

status=0
for mode in "$@"; do
    case $mode in
        artix) image=artix golden=s6-rc ;;
        alpine-rc) image=alpine golden=s6-rc ;;
        alpine-s6) image=alpine golden=s6 ;;
        *) echo "unknown setup: $mode" >&2; exit 2 ;;
    esac
    echo "# setup: $mode"
    "$engine" build -q -t "fake-systemd-e2e-s6-$image" -f "$here/$image/Containerfile" "$here/$image" >/dev/null
    "$engine" run --rm -e "E2E_MODE=$mode" \
        -v "$prefix/bin:/opt/fake-systemd:ro,Z" \
        -v "$here:/e2e:ro,Z" \
        -v "$root/tests/golden/$golden:/golden:ro,Z" \
        "fake-systemd-e2e-s6-$image" sh /e2e/inside.sh || status=1
done
exit $status
