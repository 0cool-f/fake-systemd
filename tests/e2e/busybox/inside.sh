#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh runsv|inittab online|boot|offline
#   runsv    the inittab starts runsvdir: the services are runit service directories under BusyBox's
#            runsvdir, runsv and sv
#   inittab  the inittab starts no runsvdir: the services are init scripts that the inittab runs
#   online   BusyBox init is PID 1 and the lifecycle is driven through systemctl
#   boot     the same container after a restart: what was enabled has been started by the boot
#   offline  no init runs, as in a chroot or a container build
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
setup=${1:?}
phase=${2:?}
passed=0
failed=0

ok() { passed=$((passed + 1)); echo "ok $((passed + failed)) - $1"; }
fail() { failed=$((failed + 1)); echo "not ok $((passed + failed)) - $1"; shift; for l in "$@"; do echo "#   $l"; done; }

# expect DESC EXPECTED_RC EXPECTED_STDOUT_SUBSTRING COMMAND...
expect() {
    desc=$1 want_rc=$2 want_out=$3
    shift 3
    out=$("$@" 2>/tmp/stderr)
    rc=$?
    err=$(cat /tmp/stderr)
    if [ "$rc" != "$want_rc" ]; then
        fail "$desc" "command: $*" "exit $rc, wanted $want_rc" "stdout: $out" "stderr: $err"
    elif [ -n "$want_out" ] && ! printf '%s' "$out" | grep -qF -- "$want_out"; then
        fail "$desc" "command: $*" "stdout does not contain: $want_out" "stdout: $out" "stderr: $err"
    else
        ok "$desc"
    fi
}

# check DESC COMMAND...  (succeeds when the command exits 0)
check() {
    desc=$1
    shift
    if "$@" >/tmp/check.out 2>&1; then ok "$desc"; else fail "$desc" "command: $*" "$(cat /tmp/check.out)"; fi
}

# refute DESC COMMAND...  (succeeds when the command fails)
refute() {
    desc=$1
    shift
    if "$@" >/tmp/check.out 2>&1; then fail "$desc" "command succeeded: $*"; else ok "$desc"; fi
}

# wait_for DESC SECONDS COMMAND...  (polls until the command succeeds)
wait_for() {
    desc=$1 secs=$2
    shift 2
    i=0
    while [ $i -lt $((secs * 10)) ]; do
        if "$@" >/dev/null 2>&1; then ok "$desc"; return; fi
        sleep 0.1
        i=$((i + 1))
    done
    fail "$desc" "timed out after ${secs}s: $*"
}

# active NAME STATE  (systemctl is-active prints STATE)
active() { systemctl is-active "$1" | grep -q "^$2\$"; }
count() { [ -e "$1" ] && wc -l <"$1" | tr -d ' '; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/local/bin
echo "# $(busybox | head -n 1)"

# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=End-to-end %s\n\n[Service]\n%s\n\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }

scan=/var/service
if [ "$setup" = runsv ]; then
    # svrun NAME  (the runsv of BusyBox runs the service)
    svrun() { sv status "$scan/$1" 2>/dev/null | grep -q '^run: '; }
    svpid() { sv status "$scan/$1" | sed -n 's/^run: [^:]*: (pid \([0-9]*\)).*/\1/p'; }
else
    # svrun NAME  (the script says the service runs)
    svrun() { /etc/init.d/"$1" status >/dev/null 2>&1; }
    svpid() { cut -d" " -f1 "/run/fake-systemd/$1.service.pid" 2>/dev/null; }
fi

if [ "$phase" = offline ]; then
    # --- No init runs: a chroot or a container build -------------------------------------------
    check "PID 1 is not BusyBox init" sh -c 'test "$(readlink /proc/1/exe)" != /bin/busybox'
    expect "the backend is BusyBox init, found from /sbin/init" 0 "backend: busybox" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    if [ "$setup" = runsv ]; then
        check "the service directory was generated" grep -q "^# Generated automatically by fake-systemd" /etc/sv/e2e-off/run
        check "the link is in the directory runsvdir scans" test -L $scan/e2e-off
    else
        check "the script was generated" grep -q "^# Generated automatically by fake-systemd" /etc/init.d/e2e-off
        check "the inittab lists it for the boot" grep -q '^::wait:/etc/init.d/e2e-off start$' /etc/inittab
        check "and for the shutdown" grep -q '^::shutdown:/etc/init.d/e2e-off stop$' /etc/inittab
    fi
    expect "start offline only says so" 0 "" systemctl start e2e-off
    refute "nothing was started" pgrep -f "[s]leep 1000"
    expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-off
    expect "daemon-reload offline succeeds" 0 "" systemctl daemon-reload
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off

    # A root that is not the running one: the files are written there, and nothing is run.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/etc/init.d $r/etc/sv $r/var/service $r/usr/bin $r/sbin
    ln -s /bin/busybox $r/sbin/init
    cp /etc/inittab $r/etc/inittab
    if [ "$setup" = runsv ]; then echo '::respawn:/bin/runsvdir /var/service' >>$r/etc/inittab; fi
    cp /bin/true $r/usr/bin/true
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root succeeds" 0 "" env FAKE_SYSTEMD_INIT=busybox systemctl --root=$r enable e2e-root
    if [ "$setup" = runsv ]; then
        check "the link is in the other root" test -L $r$scan/e2e-root
    else
        check "the inittab of the other root lists the script" grep -q '^::wait:/etc/init.d/e2e-root start$' $r/etc/inittab
        check "the inittab of the running root is as it was" sh -c '! grep -q e2e-root /etc/inittab'
    fi
    expect "is-enabled in the other root answers enabled" 0 "enabled" env FAKE_SYSTEMD_INIT=busybox systemctl --root=$r is-enabled e2e-root
    expect "disable in the other root succeeds" 0 "" env FAKE_SYSTEMD_INIT=busybox systemctl --root=$r disable e2e-root
    expect "is-enabled in the other root answers disabled" 1 "disabled" env FAKE_SYSTEMD_INIT=busybox systemctl --root=$r is-enabled e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

if [ "$phase" = boot ]; then
    # --- After a restart of the container: init booted and started what was enabled -------------
    check "PID 1 is BusyBox init" sh -c 'test "$(readlink /proc/1/exe)" = /bin/busybox'
    expect "the backend is BusyBox init" 0 "backend: busybox" systemctl --version
    wait_for "a service enabled before is active" 20 active e2e-boot active
    expect "it is still enabled" 0 "enabled" systemctl is-enabled e2e-boot
    wait_for "its output reached the uniform log" 5 grep -q e2e-boot-hello /var/log/fake-systemd/e2e-boot.service/current
    if [ "$setup" = inittab ]; then
        wait_for "a service whose requirement was enabled with it is active" 20 active e2e-dep-b active
        wait_for "the requirement is active" 5 active e2e-dep-a active
        expect "what was disabled did not start" 3 "inactive" systemctl is-active e2e-never
        expect "a oneshot with RemainAfterExit= ran at the boot" 0 "active" systemctl is-active e2e-boot-once
    fi
    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- BusyBox init is PID 1 --------------------------------------------------------------------------
check "PID 1 is BusyBox init" sh -c 'test "$(readlink /proc/1/exe)" = /bin/busybox'
expect "the backend is BusyBox init" 0 "backend: busybox" systemctl --version
if [ "$setup" = runsv ]; then
    check "runsvdir runs under init" sh -c 'ps | grep -q "[r]unsvdir"'
    mkdir -p /usr/lib/systemd/system
fi

# --- Lifecycle -------------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sh -c "echo e2e-hello; exec sleep 1000"'
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
if [ "$setup" = runsv ]; then
    check "run carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/sv/e2e-sleeper/run
    for f in run finish log/run; do check "$f passes sh -n" sh -n /etc/sv/e2e-sleeper/$f; done
    check "the link points at the service directory" test "$(readlink $scan/e2e-sleeper)" = /etc/sv/e2e-sleeper
    wait_for "BusyBox runsv supervises the service" 15 svrun e2e-sleeper
    check "the logger runs next to the service" sh -c "sv status $scan/e2e-sleeper | grep -q '; run: log:'"
else
    check "the script carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/init.d/e2e-sleeper
    check "the script passes sh -n" sh -n /etc/init.d/e2e-sleeper
    check "the inittab lists the script" grep -q '^::wait:/etc/init.d/e2e-sleeper start$' /etc/inittab
    check "the block is delimited" sh -c 'grep -qx "# BEGIN fake-systemd" /etc/inittab && grep -qx "# END fake-systemd" /etc/inittab'
    check "the entries of the system are untouched" grep -q '^::ctrlaltdel:/sbin/reboot$' /etc/inittab
    wait_for "the script reports the service running" 5 svrun e2e-sleeper
fi
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
wait_for "the output of the service reached the uniform log" 5 grep -q e2e-hello /var/log/fake-systemd/e2e-sleeper.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-hello" journalctl -u e2e-sleeper.service --no-pager
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
expect "stopping an enabled service keeps it enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
first_pid=$(svpid e2e-sleeper)
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
pid_changed() { new=$(svpid "$1"); [ -n "$new" ] && [ "$new" != "$2" ]; }
wait_for "restart started a new process" 10 pid_changed e2e-sleeper "$first_pid"
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service without Restart= is failed" 10 active e2e-sleeper failed
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
expect "start of a failed service starts it again" 0 "" systemctl start e2e-sleeper
expect "the service is active again" 0 "active" systemctl is-active e2e-sleeper
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
if [ "$setup" = runsv ]; then
    check "the link is kept while the service runs, with down" sh -c "test -L $scan/e2e-sleeper && test -e /etc/sv/e2e-sleeper/down"
else
    check "the inittab no longer lists the script" sh -c '! grep -q e2e-sleeper /etc/inittab'
fi
expect "a disabled service keeps running until it is stopped" 0 "active" systemctl is-active e2e-sleeper
expect "stop succeeds again" 0 "" systemctl stop e2e-sleeper
expect "daemon-reload succeeds against the running init" 0 "" systemctl daemon-reload

# --- Restart= ----------------------------------------------------------------------------------------
rm -f /tmp/e2e-rf.count /tmp/e2e-rclean.count /tmp/e2e-rno.count
unit e2e-rf 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rf.count; exit 1"
Restart=on-failure
RestartSec=2'
unit e2e-rclean 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rclean.count; exit 0"
Restart=on-failure'
unit e2e-rno 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rno.count; exit 1"
Restart=no'
systemctl start e2e-rf >/dev/null 2>&1
systemctl start e2e-rclean >/dev/null 2>&1
systemctl start e2e-rno >/dev/null 2>&1
sleep 3
if [ "$setup" = runsv ]; then
    wait_for "Restart=on-failure restarts a failing service" 20 sh -c '[ "$(wc -l </tmp/e2e-rf.count)" -ge 2 ]'
    check "Restart=on-failure does not restart a clean exit" test "$(count /tmp/e2e-rclean.count)" = 1
    check "Restart=no does not restart" test "$(count /tmp/e2e-rno.count)" = 1
    expect "a service that exited cleanly is inactive" 3 "inactive" systemctl is-active e2e-rclean
    expect "a failed service without a restart is failed" 3 "failed" systemctl is-active e2e-rno
    systemctl stop e2e-rf e2e-rno >/dev/null 2>&1
else
    check "a script runs the service once: nothing supervises it" test "$(count /tmp/e2e-rf.count)" = 1
    expect "a service that exited with an error is failed" 3 "failed" systemctl is-active e2e-rf
    expect "a service that exited cleanly is inactive" 3 "inactive" systemctl is-active e2e-rclean
    systemctl stop e2e-rf e2e-rno >/dev/null 2>&1
fi

# --- Oneshots ----------------------------------------------------------------------------------------------
unit e2e-once 'Type=oneshot
ExecStart=/bin/sh -c "echo e2e-once-output; touch /tmp/e2e-once-ran"'
expect "a oneshot starts" 0 "" systemctl start e2e-once
check "the oneshot ran" test -e /tmp/e2e-once-ran
expect "a finished oneshot is inactive" 3 "inactive" systemctl is-active e2e-once
unit e2e-remain 'Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/touch /tmp/e2e-remain-start
ExecStop=/bin/touch /tmp/e2e-remain-stop'
expect "a oneshot with RemainAfterExit= starts" 0 "" systemctl start e2e-remain
check "its command ran" test -e /tmp/e2e-remain-start
expect "it stays active after the command exited" 0 "active" systemctl is-active e2e-remain
expect "stop runs ExecStop=" 0 "" systemctl stop e2e-remain
check "ExecStop= of the oneshot ran" test -e /tmp/e2e-remain-stop
expect "it is inactive after stop" 3 "inactive" systemctl is-active e2e-remain
unit e2e-bad 'Type=oneshot
ExecStart=/bin/sh -c "exit 7"'
if [ "$setup" = runsv ]; then
    # runsv has run the command and finish has recorded how it ended, which the runit backend takes for a start that happened.
    expect "start of a failing oneshot returns once runsv saw it end" 0 "" systemctl start e2e-bad
    wait_for "it reads failed" 5 active e2e-bad failed
else
    expect "a oneshot that fails makes start fail" 1 "" systemctl start e2e-bad
fi
expect "stop of a failed oneshot succeeds" 0 "" systemctl stop e2e-bad

# --- Executor: ExecStartPre=, EnvironmentFile=, ExecStop= and ExecStopPost= -----------------------------
echo "E2E_VAR=hello" >/etc/e2e-pre.env
unit e2e-pre 'EnvironmentFile=/etc/e2e-pre.env
ExecStartPre=/bin/touch /tmp/e2e-pre-ran
ExecStart=/bin/sh -c "env >/tmp/e2e-pre-env; exec sleep 1000"
ExecStop=/bin/touch /tmp/e2e-stop-ran
ExecStopPost=/bin/touch /tmp/e2e-post-ran'
expect "a unit that needs the executor starts" 0 "" systemctl start e2e-pre
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
expect "stop succeeds" 0 "" systemctl stop e2e-pre
check "ExecStop= ran" test -e /tmp/e2e-stop-ran
wait_for "ExecStopPost= ran" 5 test -e /tmp/e2e-post-ran
cat >/usr/local/bin/e2e-stubborn <<'X'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-stubborn
unit e2e-stubborn 'ExecStart=/usr/local/bin/e2e-stubborn
TimeoutStopSec=2'
expect "a service that ignores TERM starts" 0 "" systemctl start e2e-stubborn
began=$(date +%s)
expect "stop kills it after TimeoutStopSec=" 0 "" systemctl stop e2e-stubborn
check "it did not wait for the default of 90 seconds" test $(($(date +%s) - began)) -lt 30
expect "it is gone" 3 "" systemctl is-active e2e-stubborn

# --- Signals and reload ---------------------------------------------------------------------------------
cat >/usr/local/bin/e2e-signals <<'X'
#!/bin/sh
trap 'touch /tmp/e2e-hup' HUP
trap 'touch /tmp/e2e-usr1' USR1
trap 'touch /tmp/e2e-winch' WINCH
while :; do sleep 0.2; done
X
chmod 755 /usr/local/bin/e2e-signals
unit e2e-signals 'ExecStart=/usr/local/bin/e2e-signals
ExecReload=/bin/sh -c "echo $MAINPID >/tmp/e2e-reload-pid"'
expect "a signal-handling service starts" 0 "" systemctl start e2e-signals
wait_for "it runs" 10 svrun e2e-signals
expect "kill -s HUP signals the service" 0 "" systemctl kill -s HUP e2e-signals
wait_for "the service got SIGHUP" 5 test -e /tmp/e2e-hup
expect "kill -s USR1 signals the service" 0 "" systemctl kill -s SIGUSR1 e2e-signals
wait_for "the service got SIGUSR1" 5 test -e /tmp/e2e-usr1
expect "kill -s WINCH signals the service" 0 "" systemctl kill -s WINCH e2e-signals
wait_for "the service got SIGWINCH" 5 test -e /tmp/e2e-winch
expect "reload runs ExecReload=" 0 "" systemctl reload e2e-signals
wait_for "ExecReload= got the main pid" 5 sh -c 'test -s /tmp/e2e-reload-pid'
expect "stop succeeds" 0 "" systemctl stop e2e-signals

# --- Dependencies --------------------------------------------------------------------------------------------
# Only runsvdir starts a requirement with the service that needs it, through sv; init scripts have the
# order of the inittab, which the boot section below checks.
if [ "$setup" = runsv ]; then
    unit e2e-dep-a 'ExecStart=/bin/sh -c "echo e2e-dep-a >>/tmp/e2e-order-log; exec sleep 1000"'
    printf '[Unit]\nDescription=Requires a\nRequires=e2e-dep-a.service\nAfter=e2e-dep-a.service\n\n[Service]\nExecStart=/bin/sh -c "echo e2e-dep-b >>/tmp/e2e-order-log; exec sleep 1000"\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-dep-b.service
    expect "start of a unit starts what it requires" 0 "" systemctl start e2e-dep-b
    wait_for "the requirement is active" 15 active e2e-dep-a active
    expect "the unit is active" 0 "active" systemctl is-active e2e-dep-b
    check "the requirement started first" sh -c '[ "$(head -n 1 /tmp/e2e-order-log)" = e2e-dep-a ]'
    check "the requirement is linked with down, not enabled" sh -c "test -L $scan/e2e-dep-a && test -e /etc/sv/e2e-dep-a/down"
    expect "stop succeeds" 0 "" systemctl stop e2e-dep-b
    systemctl stop e2e-dep-a >/dev/null 2>&1
fi

# --- Instances --------------------------------------------------------------------------------------------------
printf '[Service]\nExecStart=/bin/sh -c "echo %%i >/tmp/e2e-tpl-%%i; exec sleep 1000"\n\n[Install]\nWantedBy=multi-user.target\n' >'/usr/lib/systemd/system/e2e-tpl@.service'
expect "an instance starts" 0 "" systemctl start e2e-tpl@one
wait_for "the instance saw its name" 10 grep -q '^one$' /tmp/e2e-tpl-one
expect "stop of the instance succeeds" 0 "" systemctl stop e2e-tpl@one

# --- Generated files are valid for the shell of BusyBox ------------------------------------------------------------
mkdir -p /tmp/golden-split
if [ "$setup" = runsv ]; then
    for f in /golden/*.runsv; do
        n=$(basename "$f" .runsv)
        mkdir -p "/tmp/golden-split/$n"
        awk -v dir="/tmp/golden-split/$n" '/^=== /{ p = $2; gsub("/", "_", p); out = dir "/" p; next } { print > out }' "$f"
        for s in "/tmp/golden-split/$n"/*; do
            check "golden $n/$(basename "$s") passes sh -n" sh -n "$s"
        done
    done
else
    for f in /golden/*.initd; do
        check "golden $(basename "$f" .initd) passes sh -n" sh -n "$f"
    done
fi

# --- User services are refused with the reason ------------------------------------------------------------------
printf '[Service]\nExecStart=/bin/sleep 1000\n[Install]\nWantedBy=default.target\n' >/usr/lib/systemd/user/e2e-user.service 2>/dev/null || { mkdir -p /usr/lib/systemd/user; printf '[Service]\nExecStart=/bin/sleep 1000\n[Install]\nWantedBy=default.target\n' >/usr/lib/systemd/user/e2e-user.service; }
expect "a user service is refused" 1 "" systemctl --user enable e2e-user

# --- A runsvdir on another directory ------------------------------------------------------------------------------
# The services are served from the directory the first runsvdir entry scans, and sv, which looks in
# /var/service, is told where the generated run scripts that start requirements find them.
if [ "$setup" = runsv ]; then
    mkdir -p /etc/service-alt
    sed -i '1i ::respawn:/bin/runsvdir /etc/service-alt' /etc/inittab
    kill -HUP 1
    wait_for "init started the second runsvdir" 10 sh -c 'ps | grep -q "[r]unsvdir /etc/service-alt"'
    unit e2e-alt-a 'ExecStart=/bin/sleep 1000'
    printf '[Unit]\nRequires=e2e-alt-a.service\n\n[Service]\nExecStart=/bin/sleep 1000\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-alt-b.service
    expect "a unit is enabled and started on the other directory" 0 "" systemctl enable --now e2e-alt-b
    check "the link is in the directory the inittab names" test -L /etc/service-alt/e2e-alt-b
    check "run tells sv where the services are" grep -q '^export SVDIR=/etc/service-alt$' /etc/sv/e2e-alt-b/run
    wait_for "the requirement was started through sv" 20 active e2e-alt-a active
    expect "the unit is active" 0 "active" systemctl is-active e2e-alt-b
    expect "stop succeeds" 0 "" systemctl stop e2e-alt-b
    systemctl stop e2e-alt-a >/dev/null 2>&1
    systemctl disable e2e-alt-b >/dev/null 2>&1
    sed -i '1d' /etc/inittab
    kill -HUP 1
fi

# --- Timers: the built-in runner is a service of this init ---------------------------------------------------------
cat >/usr/lib/systemd/system/e2e-tick.service <<'X'
[Unit]
Description=Timer job

[Service]
Type=oneshot
ExecStart=/bin/echo e2e-tick-output
X
cat >/usr/lib/systemd/system/e2e-tick.timer <<'X'
[Unit]
Description=Every five seconds

[Timer]
OnCalendar=*:*:0/5

[Install]
WantedBy=timers.target
X
expect "enable of a timer with a seconds calendar succeeds" 0 "" systemctl enable e2e-tick.timer
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/busybox/index
wait_for "the timer fired at least twice" 40 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tick.timer
check "the runner unit is removed" test ! -e /etc/systemd/system/fake-systemd-timers.service

# --- What the boot starts and the shutdown stops -------------------------------------------------------------------
unit e2e-boot 'ExecStart=/bin/sh -c "echo e2e-boot-hello; exec sleep 1000"'
expect "a service is enabled without being started" 0 "" systemctl enable e2e-boot
expect "it is inactive" 3 "inactive" systemctl is-active e2e-boot
if [ "$setup" = inittab ]; then
    printf '[Unit]\nDescription=a\n[Service]\nExecStart=/bin/sleep 1000\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-dep-a.service
    printf '[Unit]\nDescription=b\nRequires=e2e-dep-a.service\nAfter=e2e-dep-a.service\n[Service]\nExecStart=/bin/sleep 1000\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-dep-b.service
    expect "a unit is enabled with what it requires" 0 "" systemctl enable e2e-dep-b
    expect "the requirement is enabled with it" 0 "enabled" systemctl is-enabled e2e-dep-a
    check "the requirement is listed first" sh -c 'grep -n "e2e-dep" /etc/inittab | head -n 2 | tr "\n" " " | grep -q "e2e-dep-a start.*e2e-dep-b start"'
    check "the stops are listed in the reverse order" sh -c 'grep "^::shutdown:" /etc/inittab | grep e2e-dep | head -n 2 | tr "\n" " " | grep -q "e2e-dep-b stop.*e2e-dep-a stop"'
    unit e2e-never 'ExecStart=/bin/sleep 1000'
    unit e2e-boot-once 'Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/touch /tmp/e2e-boot-once-ran'
    expect "a oneshot is enabled" 0 "" systemctl enable e2e-boot-once
fi
printf '[Unit]\nDescription=Stopped at shutdown\n[Service]\nExecStart=/bin/sleep 1000\nExecStop=/bin/touch /out/e2e-shutdown-stop\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-shutdown.service
expect "a service with ExecStop= is enabled and started for the shutdown" 0 "" systemctl enable --now e2e-shutdown

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
