#!/bin/sh
# End-to-end test of the dinit backend: builds the static binary, then drives a real dinit
# (system service manager, not PID 1) in a container through systemctl.
# Usage: tests/e2e/dinit/run.sh   (needs podman and the `fake-systemd-build` image)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

podman run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

podman build -q -t fake-systemd-e2e-dinit -f "$here/Containerfile" "$here" >/dev/null

exec podman run --rm \
    -v "$prefix/bin:/opt/fake-systemd:ro,Z" \
    -v "$here:/e2e:ro,Z" \
    -v "$root/tests/golden/dinit:/golden:ro,Z" \
    fake-systemd-e2e-dinit sh /e2e/inside.sh
