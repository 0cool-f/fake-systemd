#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the finit backend: builds the static binary, then drives a real finit through
# systemctl in rootless containers on Debian 13:
#   online   finit as PID 1 (the default runlevel 2)
#   offline  no init runs, as in a chroot or a container build
# Usage: tests/e2e/finit/run.sh   (needs podman, or CONTAINER_ENGINE=docker, and the `fake-systemd-build` image)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

image=fake-systemd-e2e-finit
"$here/../lib/image.sh" "$image" "$here"

out=$(mktemp -d)
cid=
cleanup() {
    [ -z "$cid" ] || "$engine" rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$out"
}
trap cleanup EXIT INT TERM

# mounts  (the options that give a container the binary, the tests, the goldens and a directory the host reads)
mounts() {
    echo "-v $prefix/bin:/opt/fake-systemd:ro,Z -v $here:/e2e:ro,Z -v $root/tests/golden/finit:/golden:ro,Z -v $root/tests/corpus:/corpus:ro,Z -v $out:/out:Z"
}

status=0

echo "# setup: finit as PID 1"
# shellcheck disable=SC2046
cid=$("$engine" run -d --entrypoint /usr/sbin/finit $(mounts) "$image")
up=
for _ in $(seq 1 100); do
    if "$engine" exec "$cid" sh -c 'initctl -q status keventd' >/dev/null 2>&1; then up=1; break; fi
    sleep 0.2
done
if [ -n "$up" ]; then
    "$engine" exec "$cid" sh /e2e/inside.sh online || status=1
    # A shutdown stops the services, ExecStop= included.
    "$engine" exec "$cid" systemctl poweroff >/dev/null 2>&1 || true
    waited=
    for _ in $(seq 1 100); do
        if [ -e "$out/e2e-shutdown-stop" ]; then waited=1; break; fi
        sleep 0.2
    done
    if [ -n "$waited" ]; then
        echo "ok - systemctl poweroff ran ExecStop= of an enabled service"
    else
        echo "not ok - systemctl poweroff did not run ExecStop= of an enabled service"
        status=1
    fi
else
    echo "not ok - finit did not come up as PID 1"
    "$engine" logs "$cid" 2>&1 | tail -n 20
    status=1
fi
"$engine" rm -f "$cid" >/dev/null 2>&1 || true
cid=

echo "# setup: no init running"
# shellcheck disable=SC2046
"$engine" run --rm --init $(mounts) "$image" sh /e2e/inside.sh offline || status=1
exit $status
