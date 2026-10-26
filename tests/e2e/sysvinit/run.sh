#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# End-to-end test of the sysvinit backend: builds the static binary, then drives real init scripts
# and the real tools of each family through systemctl in containers:
#   devuan  sysvinit as PID 1 on Devuan 5 (sysvinit 3.06, insserv 1.24, dpkg start-stop-daemon)
#   debian  sysvinit as PID 1 on Debian 13 (sysvinit 3.14, insserv 1.26)
#   redhat  chkconfig and the init scripts library on Rocky Linux 10 (chkconfig 1.30), whose init is
#           systemd and so cannot run: a process named init with the control socket of sysvinit
#           stands in for it
#   redhat9 the same on Rocky Linux 9 (chkconfig 1.24)
# Each setup also runs offline, as in a chroot or a container build, where no init runs.
# Usage: tests/e2e/sysvinit/run.sh [devuan|debian|redhat|redhat9]...   (needs podman, or CONTAINER_ENGINE=docker,
# and the `fake-systemd-build` image; all four run without arguments)
set -eu

engine=${CONTAINER_ENGINE:-podman}

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
prefix="$root/.zig-cache/e2e-prefix"

"$engine" run --rm -v "$root:/src:Z" -w /src fake-systemd-build \
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe --prefix .zig-cache/e2e-prefix

[ "$#" -gt 0 ] || set -- devuan debian redhat redhat9

out=$(mktemp -d)
cid=
cleanup() {
    [ -z "$cid" ] || "$engine" rm -f "$cid" >/dev/null 2>&1 || true
    rm -rf "$out"
}
trap cleanup EXIT INT TERM

# mounts SETUP  (the options that give a container the binary, the tests and what they compare with)
mounts() {
    family=debian
    case $1 in redhat | redhat9) family=redhat ;; esac
    echo "-v $prefix/bin:/opt/fake-systemd:ro,Z -v $here:/e2e:ro,Z -v $root/tests/golden/sysvinit-$family:/golden:ro,Z -v $root/tests/corpus:/corpus:ro,Z -v $out:/out:Z"
}

# wait_runlevel  (sysvinit as PID 1 has entered runlevel 2)
wait_runlevel() {
    for _ in $(seq 1 100); do
        if [ "$("$engine" exec "$cid" runlevel 2>/dev/null)" = "N 2" ]; then return 0; fi
        sleep 0.2
    done
    return 1
}

status=0
for mode in "$@"; do
    case $mode in
        devuan | debian | redhat | redhat9) ;;
        *) echo "unknown setup: $mode" >&2; exit 2 ;;
    esac
    image="fake-systemd-e2e-sysvinit-$mode"
    "$engine" build -q -t "$image" -f "$here/$mode/Containerfile" "$here/$mode" >/dev/null
    rm -rf "${out:?}"/*

    echo "# setup: $mode, init running"
    if [ "$mode" = redhat ] || [ "$mode" = redhat9 ]; then
        # shellcheck disable=SC2046
        cid=$("$engine" run -d --entrypoint /usr/local/sbin/init $(mounts "$mode") "$image" -c 'while :; do sleep 1; done')
        "$engine" exec "$cid" sh /e2e/inside.sh "$mode" online || status=1
    else
        # shellcheck disable=SC2046
        cid=$("$engine" run -d $(mounts "$mode") "$image" sh -c 'cp /e2e/inittab /etc/inittab && exec /sbin/init')
        if wait_runlevel; then
            "$engine" exec "$cid" sh /e2e/inside.sh "$mode" online || status=1
            # A shutdown stops the services through the stop links of runlevel 0, ExecStop= included.
            "$engine" exec "$cid" systemctl poweroff >/dev/null 2>&1 || true
            waited=
            for _ in $(seq 1 100); do
                if [ -e "$out/e2e-shutdown-stop" ]; then waited=1; break; fi
                sleep 0.2
            done
            if [ -n "$waited" ]; then
                echo "ok - systemctl poweroff ran ExecStop= of an enabled service through the stop link of runlevel 0"
            else
                echo "not ok - systemctl poweroff did not run ExecStop= of an enabled service"
                status=1
            fi
        else
            echo "not ok - sysvinit did not reach runlevel 2 as PID 1"
            "$engine" logs "$cid" 2>&1 | tail -n 20
            status=1
        fi
    fi
    "$engine" rm -f "$cid" >/dev/null 2>&1 || true
    cid=

    echo "# setup: $mode, no init running"
    # shellcheck disable=SC2046
    "$engine" run --rm --init $(mounts "$mode") "$image" sh /e2e/inside.sh "$mode" offline || status=1
done
exit $status
