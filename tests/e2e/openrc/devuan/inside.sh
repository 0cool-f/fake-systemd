#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside the Devuan container started by run.sh: services without Restart= on an OpenRC
# whose start-stop-daemon is the one of dpkg, which has no output redirection and no OpenRC user switch.
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
passed=0
failed=0
ok() { passed=$((passed + 1)); echo "ok $((passed + failed)) - $1"; }
fail() { failed=$((failed + 1)); echo "not ok $((passed + failed)) - $1"; }
check() { desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
wait_for() {
    desc=$1 secs=$2
    shift 2
    i=0
    while [ $i -lt $((secs * 10)) ]; do
        if "$@" >/dev/null 2>&1; then ok "$desc"; return; fi
        sleep 0.1
        i=$((i + 1))
    done
    fail "$desc"
}
active() { [ "$(systemctl is-active "$1")" = "$2" ]; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /run/openrc
touch /run/openrc/softlevel
openrc default >/dev/null 2>&1
echo "# OpenRC $(cat /usr/lib/rc/version), $(/sbin/start-stop-daemon --version | head -n 1)"
check "start-stop-daemon is the one of dpkg, which has no --stdout" sh -c '! /sbin/start-stop-daemon --help 2>&1 | grep -q -- --stdout'
useradd -u 1500 -m svc
groupadd -g 1600 extra
usermod -aG extra svc

unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }
unit d-sleep 'ExecStart=/bin/sleep 1000'
unit d-user 'User=svc
ExecStart=/bin/sh -c "id > /tmp/d-user-id; echo d-user-line; exec sleep 1000"'
unit d-clean 'ExecStart=/bin/sh -c "echo d-clean-line; exit 0"'
unit d-fail 'ExecStart=/bin/sh -c "exit 3"'
unit d-hook 'ExecStart=/bin/sleep 1001
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/d-stop-alive"'
unit d-stub 'ExecStart=/bin/sh -c "trap \"\" TERM; while :; do sleep 1; done"
TimeoutStopSec=2'
for s in d-sleep d-user d-clean d-fail d-hook d-stub; do
    check "enable --now $s succeeds" systemctl enable --now "$s"
done
wait_for "a Restart=no service is active" 5 active d-sleep active
wait_for "the service of an account runs as it, with its groups" 5 grep -q 'uid=1500(svc).*1600(extra)' /tmp/d-user-id
wait_for "a clean exit reads inactive" 5 active d-clean inactive
wait_for "a failing exit reads failed" 5 active d-fail failed
wait_for "the output reached the uniform log" 5 grep -q d-user-line /var/log/fake-systemd/d-user.service/current
check "so did that of a service that ended" grep -q d-clean-line /var/log/fake-systemd/d-clean.service/current
check "kill signals the main process" systemctl kill -s KILL d-sleep
wait_for "a killed service reads failed although OpenRC records it as started" 5 active d-sleep failed
check "stop of a dead service succeeds" systemctl stop d-sleep
check "it reads inactive afterwards" active d-sleep inactive
check "start of a stopped service runs it again" systemctl start d-sleep
wait_for "it is active again" 5 active d-sleep active
check "stop succeeds" systemctl stop d-sleep
check "stop runs ExecStop= while the process lives" sh -c 'systemctl stop d-hook && test -e /tmp/d-stop-alive'
began=$(date +%s)
check "stop kills a service that ignores TERM" systemctl stop d-stub
check "it did not take the default of 90 seconds" test $(($(date +%s) - began)) -lt 30
check "nothing of it is left" sh -c '! pgrep -f "[s]h -c trap" >/dev/null'
for s in d-user d-clean d-fail; do systemctl stop "$s" >/dev/null 2>&1; done
check "disable removes the link" sh -c 'systemctl disable d-sleep && test ! -e /etc/runlevels/default/d-sleep'

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
