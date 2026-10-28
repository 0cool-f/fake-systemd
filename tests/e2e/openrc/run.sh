#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the OpenRC backend: builds the static binary, then drives a real OpenRC
# (not PID 1) through systemctl in two containers:
#   alpine  the full suite on OpenRC 0.63 with its own start-stop-daemon and supervise-daemon
#   devuan  services without Restart= on OpenRC 0.45 with the start-stop-daemon of dpkg
# Usage: tests/e2e/openrc/run.sh [alpine|devuan]...   (needs podman, or CONTAINER_ENGINE=docker, and the
# `fake-systemd-build` image; both run without arguments)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

[ "$#" -gt 0 ] || set -- alpine devuan

status=0
for mode in "$@"; do
    case $mode in
        alpine) script=/e2e/inside.sh ;;
        devuan) script=/e2e/devuan/inside.sh ;;
        *) echo "unknown setup: $mode" >&2; exit 2 ;;
    esac
    echo "# setup: $mode"
    "$here/../lib/image.sh" "fake-systemd-e2e-openrc-$mode" "$here/$mode"
    # --init gives the container a PID 1 that reaps the daemons start-stop-daemon orphans.
    "$engine" run --rm --init \
        -v "$prefix/bin:/opt/fake-systemd:ro,Z" \
        -v "$here:/e2e:ro,Z" \
        -v "$root/tests/golden/openrc:/golden:ro,Z" \
        "fake-systemd-e2e-openrc-$mode" sh "$script" || status=1
done
exit $status
