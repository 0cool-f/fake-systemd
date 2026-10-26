#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the Shepherd backend: builds the static binary, then drives a real shepherd
# through systemctl in a rootless container on Debian 13. Shepherd runs as a daemon of the container,
# not as PID 1: its control socket is what shows it. The same script also runs where no daemon runs,
# as in a chroot or a container build.
# Usage: tests/e2e/shepherd/run.sh   (needs podman, or CONTAINER_ENGINE=docker, and the `fake-systemd-build` image)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

image=fake-systemd-e2e-shepherd
"$engine" build -q -t "$image" -f "$here/Containerfile" "$here" >/dev/null

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT INT TERM

# --init gives the container a PID 1 that reaps the processes the daemon orphans.
status=0
for mode in offline online; do
    echo "# setup: $mode"
    "$engine" run --rm --init \
        -v "$prefix/bin:/opt/fake-systemd:ro,Z" \
        -v "$here:/e2e:ro,Z" \
        -v "$root/tests/golden/shepherd:/golden:ro,Z" \
        -v "$out:/out:Z" \
        "$image" sh /e2e/inside.sh "$mode" || status=1
done
exit $status
