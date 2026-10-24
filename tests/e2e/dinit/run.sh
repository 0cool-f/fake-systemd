#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the dinit backend: builds the static binary, then drives a real dinit
# (system service manager, not PID 1) in a container through systemctl.
# Usage: tests/e2e/dinit/run.sh   (needs podman, or CONTAINER_ENGINE=docker, and the `fake-systemd-build` image)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

"$engine" build -q -t fake-systemd-e2e-dinit -f "$here/Containerfile" "$here" >/dev/null

exec "$engine" run --rm \
    -v "$prefix/bin:/opt/fake-systemd:ro,Z" \
    -v "$here:/e2e:ro,Z" \
    -v "$root/tests/golden/dinit:/golden:ro,Z" \
    fake-systemd-e2e-dinit sh /e2e/inside.sh
