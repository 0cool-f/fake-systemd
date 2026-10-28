#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the BusyBox init backend: builds the static binary, then drives BusyBox 1.37.0
# as PID 1 (init, runsvdir, runsv and sv built from the release tarball) through systemctl in two
# setups, each online, after a restart of the container, at shutdown, and offline:
#   runsv    the inittab starts runsvdir, and the services are runit service directories
#   inittab  the inittab starts no runsvdir, and the services are init scripts it runs
# Usage: tests/e2e/busybox/run.sh [runsv|inittab]...   (needs podman, or CONTAINER_ENGINE=docker, and the
# `fake-systemd-build` image; both setups run without arguments)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

image=fake-systemd-e2e-busybox
"$here/../lib/image.sh" "$image" "$here"

[ "$#" -gt 0 ] || set -- runsv inittab

out=$(mktemp -d)
name="fake-systemd-e2e-busybox-$$"
cleanup() {
    "$engine" rm -f "$name" >/dev/null 2>&1 || true
    rm -rf "$out"
}
trap cleanup EXIT INT TERM

# mounts  (the options that give a container the binary, the tests and what they compare with)
mounts() {
    echo "-v $prefix/bin:/opt/fake-systemd:ro,Z -v $here:/e2e:ro,Z -v $root/tests/golden/$1:/golden:ro,Z -v $root/tests/corpus:/corpus:ro,Z -v $out:/out:Z"
}

# wait_up  (BusyBox init runs, and runsvdir where the inittab starts it)
wait_up() {
    for _ in $(seq 1 100); do
        if [ "$("$engine" exec "$name" readlink /proc/1/exe 2>/dev/null)" = /bin/busybox ] &&
            { [ "$1" != runsv ] || "$engine" exec "$name" sh -c "ps | grep -q \"[r]unsvdir\"" >/dev/null 2>&1; }; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

status=0
for setup in "$@"; do
    case $setup in
        runsv) golden=busybox-runsv ;;
        inittab) golden=busybox-inittab ;;
        *) echo "unknown setup: $setup" >&2; exit 2 ;;
    esac
    rm -rf "${out:?}"/*

    echo "# setup: $setup, BusyBox init running"
    # The inittab of the image starts nothing; `runsv` adds the runsvdir entry before init reads it.
    boot='[ "$SETUP" != runsv ] || grep -q runsvdir /etc/inittab || echo "::respawn:/bin/runsvdir /var/service" >>/etc/inittab; exec /sbin/init'
    # shellcheck disable=SC2046
    "$engine" run -d --name "$name" -e "SETUP=$setup" $(mounts "$golden") "$image" sh -c "$boot" >/dev/null
    if wait_up "$setup"; then
        "$engine" exec "$name" sh /e2e/inside.sh "$setup" online || status=1

        echo "# setup: $setup, after a restart of the container"
        "$engine" restart -t 2 "$name" >/dev/null
        if wait_up "$setup"; then
            "$engine" exec "$name" sh /e2e/inside.sh "$setup" boot || status=1
        else
            echo "not ok - init did not boot again as PID 1"
            status=1
        fi

        echo "# setup: $setup, shutdown"
        "$engine" exec "$name" systemctl poweroff >/dev/null 2>&1 || true
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
        echo "not ok - BusyBox init did not start as PID 1"
        "$engine" logs "$name" 2>&1 | tail -n 20
        status=1
    fi
    "$engine" rm -f "$name" >/dev/null 2>&1 || true

    echo "# setup: $setup, no init running, offline"
    offline='[ "$SETUP" != runsv ] || echo "::respawn:/bin/runsvdir /var/service" >>/etc/inittab; exec sh /e2e/inside.sh "$SETUP" offline'
    # shellcheck disable=SC2046
    "$engine" run --rm --init -e "SETUP=$setup" $(mounts "$golden") "$image" sh -c "$offline" || status=1
done
exit $status
