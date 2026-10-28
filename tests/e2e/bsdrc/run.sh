#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the BSD-style rc backend: builds the static binary, then drives the rc
# scripts of Slackware 15.0 through systemctl in containers:
#   online   sysvinit 3.01 as PID 1 with the boot scripts of the release; the services that
#            fake-systemd enabled are started by rc.local, and the shutdown stops them through
#            rc.local_shutdown
#   boot     the same container started again: what was enabled runs without a systemctl
#   offline  no init, as in a chroot or a container build
# Usage: tests/e2e/bsdrc/run.sh   (needs podman, or CONTAINER_ENGINE=docker, and the
# `fake-systemd-build` image)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix-bsdrc"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix-bsdrc

out=$(mktemp -d)
cid=
cleanup() {
    [ -z "$cid" ] || "$engine" rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$out"
}
trap cleanup EXIT INT TERM

# wait_runlevel  (sysvinit as PID 1 has entered runlevel 3)
wait_runlevel() {
    for _ in $(seq 1 150); do
        if [ "$("$engine" exec "$cid" runlevel 2>/dev/null)" = "N 3" ]; then return 0; fi
        sleep 0.2
    done
    return 1
}

# wait_for_file PATH  (the file exists on the host)
wait_for_file() {
    for _ in $(seq 1 100); do
        if [ -e "$1" ]; then return 0; fi
        sleep 0.2
    done
    return 1
}

image=fake-systemd-e2e-bsdrc
"$here/../lib/image.sh" "$image" "$here"
chmod 777 "$out"

status=0
echo "# setup: Slackware, init running"
cid=$("$engine" run -d -v "$prefix/bin:/opt/fake-systemd:ro,Z" -v "$here:/e2e:ro,Z" -v "$root/tests/golden/bsdrc:/golden:ro,Z" -v "$root/tests/corpus:/corpus:ro,Z" -v "$out:/out:Z" "$image" /sbin/init)
if wait_runlevel; then
    "$engine" exec "$cid" sh /e2e/inside.sh online || status=1
    # A shutdown stops the services through rc.local_shutdown, ExecStop= included, the service
    # that was only started by hand and the requirement of another one among them.
    "$engine" exec "$cid" systemctl poweroff >/dev/null 2>&1 || true
    if wait_for_file "$out/marks" && sleep 6 && [ "$(grep -c -E '^(boot-stop|dep-stop|remain-stop|manual-stop)$' "$out/marks")" -eq 4 ]; then
        echo "ok - systemctl poweroff ran ExecStop= of every service through rc.local_shutdown"
    else
        echo "not ok - systemctl poweroff did not run ExecStop= of every service"
        sed 's/^/#   /' "$out/marks" || true
        status=1
    fi
    if [ "$(grep -E '^(boot-stop|dep-stop)$' "$out/marks" | tr '\n' ' ')" = "boot-stop dep-stop " ]; then
        echo "ok - the service stopped before its requirement"
    else
        echo "not ok - the stop order of a service and its requirement is wrong"
        status=1
    fi
    echo "# setup: Slackware, the container started again"
    "$engine" stop -t 1 "$cid" >/dev/null 2>&1 || true
    "$engine" start "$cid" >/dev/null
    if wait_runlevel; then
        "$engine" exec "$cid" sh /e2e/inside.sh boot || status=1
    else
        echo "not ok - sysvinit did not reach runlevel 3 again"
        status=1
    fi
else
    echo "not ok - sysvinit did not reach runlevel 3 as PID 1"
    "$engine" logs "$cid" 2>&1 | tail -n 20
    status=1
fi
"$engine" rm -f "$cid" >/dev/null 2>&1 || true
cid=

echo "# setup: Slackware, no init running"
"$engine" run --rm --init -v "$prefix/bin:/opt/fake-systemd:ro,Z" -v "$here:/e2e:ro,Z" -v "$root/tests/golden/bsdrc:/golden:ro,Z" -v "$root/tests/corpus:/corpus:ro,Z" -v "$out:/out:Z" "$image" sh /e2e/inside.sh offline || status=1
exit $status
