#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the nosh backend: builds the static binary, then drives the real unit converter
# and service manager of nosh through systemctl in a rootless container on Debian 13. The service
# manager runs as a daemon of the container, not under system-manager as PID 1. The control groups
# the converted run scripts move into are not available to a rootless container, so the test gives
# the container a private tmpfs where the scripts find them (needs the SYS_ADMIN capability of the
# user namespace). The same script also runs where no service manager runs.
# Usage: tests/e2e/nosh/run.sh   (needs podman, or CONTAINER_ENGINE=docker, and the `fake-systemd-build` image)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

image=fake-systemd-e2e-nosh
"$engine" build -q -t "$image" -f "$here/Containerfile" "$here" >/dev/null

# --init gives the container a PID 1 that reaps the processes the manager orphans.
status=0
for mode in offline online; do
    echo "# setup: $mode"
    "$engine" run --rm --init --cap-add SYS_ADMIN \
        -v "$prefix/bin:/opt/fake-systemd:ro,Z" \
        -v "$here:/e2e:ro,Z" \
        -v "$root/tests/golden/nosh:/golden:ro,Z" \
        -v "$root/tests/corpus:/corpus:ro,Z" \
        "$image" sh /e2e/inside.sh "$mode" || status=1
done
exit $status
