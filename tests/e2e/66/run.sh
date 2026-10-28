#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the 66 backend: builds the static binary, then drives a real 66 (0.9.1.2,
# built from source in the image) through systemctl in a container where `66 boot -c` is PID 1:
#   online   the lifecycle, dependencies, restart policies, oneshots, user services and timers
#   boot     the same container after a restart, which starts what was enabled
#   shutdown systemctl poweroff stops the services through 66, ExecStop= included
#   offline  no init runs, as in a chroot or a container build
# Usage: tests/e2e/66/run.sh   (needs rootless podman or CONTAINER_ENGINE=docker with SYS_ADMIN
# allowed, and the `fake-systemd-build` image)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

image=fake-systemd-e2e-66
"$here/../lib/image.sh" "$image" "$here"

out=$(mktemp -d)
name="fake-systemd-e2e-66-$$"
cleanup() {
    "$engine" rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$out"
}
trap cleanup EXIT INT TERM

# mounts  (the options that give a container the binary, the tests and what they compare with)
mounts() {
    echo "-v $prefix/bin:/opt/fake-systemd:ro,Z -v $here:/e2e:ro,Z -v $root/tests/golden/66:/golden:ro,Z -v $out:/out:Z"
}

# wait_booted  (66 as PID 1 has started its scandir)
wait_booted() {
    for _ in $(seq 1 100); do
        if "$engine" exec "$name" test -p /run/66/scandir/0/.66-scandir/control 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    return 1
}

status=0

echo "# setup: 66 as PID 1, online"
# shellcheck disable=SC2046
"$engine" run -d --name "$name" --cap-add SYS_ADMIN $(mounts) "$image" /usr/bin/66 boot -c >/dev/null
if wait_booted; then
    "$engine" exec "$name" sh /e2e/inside.sh online || status=1

    echo "# setup: 66 as PID 1, after a restart of the container"
    "$engine" restart -t 1 "$name" >/dev/null
    if wait_booted; then
        # The tree of the boot starts the enabled services a moment after the scandir is up.
        sleep 3
        "$engine" exec "$name" sh /e2e/inside.sh boot || status=1
    else
        echo "not ok - 66 did not boot again as PID 1"
        status=1
    fi

    echo "# setup: 66 as PID 1, shutdown"
    "$engine" exec "$name" systemctl poweroff >/dev/null 2>&1 || true
    waited=
    for _ in $(seq 1 100); do
        if [ -e "$out/e2e-shutdown-stop" ]; then waited=1; break; fi
        sleep 0.2
    done
    if [ -n "$waited" ]; then
        echo "ok - systemctl poweroff ran ExecStop= of an enabled service through 66"
    else
        echo "not ok - systemctl poweroff did not run ExecStop= of an enabled service"
        status=1
    fi
else
    echo "not ok - 66 did not boot as PID 1"
    "$engine" logs "$name" 2>&1 | tail -n 20
    status=1
fi
"$engine" rm -f "$name" >/dev/null 2>&1 || true

echo "# setup: no init running, offline"
# shellcheck disable=SC2046
"$engine" run --rm --init $(mounts) "$image" sh /e2e/inside.sh offline || status=1
exit $status
