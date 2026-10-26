#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the procd backend: builds the static binary, then drives the init scripts of
# OpenWrt 25.12.5 (procd, ubus, rc.common) through systemctl in containers:
#   online   procd as PID 1, booted by /sbin/init as on a router; the shutdown stops the
#            services through the stop links of /etc/rc.d, ExecStop= included
#   boot     the same container started again: what was enabled runs without a systemctl
#   offline  no init, as in a chroot or a container build
# Usage: tests/e2e/procd/run.sh   (needs podman, or CONTAINER_ENGINE=docker, and the
# `fake-systemd-build` image)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix-procd"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix-procd

out=$(mktemp -d)
cid=
cleanup() {
    [ -z "$cid" ] || "$engine" rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$out"
}
trap cleanup EXIT INT TERM

# wait_booted  (procd as PID 1 has started the services of the boot: ubusd answers)
wait_booted() {
    for _ in $(seq 1 100); do
        if "$engine" exec "$cid" ubus list service >/dev/null 2>&1; then return 0; fi
        sleep 0.3
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

image=fake-systemd-e2e-procd
if ! "$engine" build -q -t "$image" -f "$here/Containerfile" "$here" >"$out/build.log" 2>&1; then
    tail -n 30 "$out/build.log"
    exit 1
fi
chmod 777 "$out"

status=0
echo "# setup: OpenWrt, procd running"
cid=$("$engine" run -d -v "$prefix/bin:/opt/fake-systemd:ro,Z" -v "$here:/e2e:ro,Z" -v "$root/tests/golden/procd:/golden:ro,Z" -v "$root/tests/corpus:/corpus:ro,Z" -v "$out:/out:Z" "$image" /sbin/init)
if wait_booted; then
    "$engine" exec "$cid" sh /e2e/inside.sh online || status=1
    # A shutdown runs the stop links, ExecStop= included, for the service that was only started
    # by hand and for the requirement of another one as well.
    "$engine" exec "$cid" systemctl poweroff >/dev/null 2>&1 || true
    if wait_for_file "$out/marks" && sleep 8 && [ "$(grep -c -E '^(boot-stop|dep-stop|remain-stop|manual-stop)$' "$out/marks")" -eq 4 ]; then
        echo "ok - systemctl poweroff ran ExecStop= of every service through the stop links"
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
    echo "# setup: OpenWrt, the container started again"
    "$engine" stop -t 1 "$cid" >/dev/null 2>&1 || true
    "$engine" start "$cid" >/dev/null
    if wait_booted; then
        "$engine" exec "$cid" sh /e2e/inside.sh boot || status=1
    else
        echo "not ok - procd did not boot again"
        status=1
    fi
else
    echo "not ok - procd did not boot as PID 1"
    "$engine" logs "$cid" 2>&1 | tail -n 20
    status=1
fi
"$engine" rm -f "$cid" >/dev/null 2>&1 || true
cid=

echo "# setup: OpenWrt, no init running"
"$engine" run --rm --init -v "$prefix/bin:/opt/fake-systemd:ro,Z" -v "$here:/e2e:ro,Z" -v "$root/tests/golden/procd:/golden:ro,Z" -v "$root/tests/corpus:/corpus:ro,Z" -v "$out:/out:Z" "$image" sh /e2e/inside.sh offline || status=1
exit $status
