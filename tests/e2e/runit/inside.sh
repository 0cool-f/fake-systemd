#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside the container started by run.sh.
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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
svrun() { sv status "$1" | grep -q '^run:'; }
count() { [ -e "$1" ] && wc -l <"$1" | tr -d ' '; }
as_tester() { chpst -u tester env HOME=/home/tester PATH="$PATH" "$@"; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/lib/systemd/user /etc/default /etc/sv /etc/runit/runsvdir/default /run/runit/runsvdir

# What /etc/runit/2 of Void does, without being PID 1.
ln -sfn default /etc/runit/runsvdir/current
ln -sfn /etc/runit/runsvdir/current /run/runit/runsvdir/current
env - PATH=/usr/bin:/usr/sbin runsvdir -P /run/runit/runsvdir/current 'log: ....' >/tmp/runsvdir.log 2>&1 &
wait_for "runsvdir is up" 5 pgrep -x runsvdir
xbps-query -l | grep -E ' (runit|util-linux)-' | sed 's/^ii //; s/  .*//'
readlink /var/service

cat >/usr/local/bin/e2e-signals <<'X'
#!/bin/sh
trap 'touch /tmp/e2e-hup' HUP
trap 'touch /tmp/e2e-winch' WINCH
echo e2e-hello-from-the-service
while :; do sleep 0.2; done
X
cat >/usr/local/bin/e2e-forker <<'X'
#!/bin/sh
sleep 1000 >/dev/null 2>&1 &
echo $! >/run/e2e-fork.pid
X
chmod 755 /usr/local/bin/e2e-signals /usr/local/bin/e2e-forker

# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() {
    printf '[Unit]\nDescription=End-to-end %s\n\n[Service]\n%s\n\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"
}
unit e2e-sleeper 'ExecStart=/bin/sleep 1000'
unit e2e-failer 'ExecStart=/bin/sh -c "exit 3"
Restart=no'

# --- Lifecycle ----------------------------------------------------------------------------
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
check "run carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/sv/e2e-sleeper/run
check "log/run feeds the uniform logger" grep -q "^exec /usr/bin/fake-systemd --log e2e-sleeper.service$" /etc/sv/e2e-sleeper/log/run
for f in run finish log/run; do check "$f passes sh -n" sh -n /etc/sv/e2e-sleeper/$f; done
check "the link points at the service directory" test "$(readlink /etc/runit/runsvdir/default/e2e-sleeper)" = /etc/sv/e2e-sleeper
wait_for "runsv supervises the service" 10 svrun e2e-sleeper
check "the logger runs next to the service" sh -c 'sv status e2e-sleeper | grep -q "; run: log:"'
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "stopping an enabled service keeps its link" test -L /etc/runit/runsvdir/default/e2e-sleeper
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
expect "a restarted Restart=no service is running again" 0 "active" systemctl is-active e2e-sleeper
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service without Restart= is failed" 5 active e2e-sleeper failed
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
check "finish recorded the end" grep -q "^failed -1 9$" /etc/sv/e2e-sleeper/supervise/exit-status
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
check "the link is removed" test ! -e /etc/runit/runsvdir/default/e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "daemon-reload succeeds against the running runsvdir" 0 "" systemctl daemon-reload

# --- Enabled at boot or not, independent of running ------------------------------------------
expect "enable --now of a service that was disabled" 0 "" systemctl enable --now e2e-sleeper
wait_for "service is active" 5 active e2e-sleeper active
expect "disable keeps a running service running" 0 "" systemctl disable e2e-sleeper
check "disable of a running service writes down and keeps the link" sh -c 'test -e /etc/sv/e2e-sleeper/down && test -L /etc/runit/runsvdir/default/e2e-sleeper'
expect "the service is still active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
check "stop keeps the idle link of a service that is not enabled" sh -c 'test -L /etc/runit/runsvdir/default/e2e-sleeper && test -e /etc/sv/e2e-sleeper/down'
expect "start of a service that is not enabled" 0 "" systemctl start e2e-sleeper
wait_for "it runs" 5 svrun e2e-sleeper
expect "start does not enable" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable links the service for boot" 0 "" systemctl enable e2e-sleeper
check "enable removed down" test ! -e /etc/sv/e2e-sleeper/down
expect "is-enabled answers enabled after enable" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "disable of a service that is not running removes the link" 0 "" systemctl disable e2e-sleeper
check "no link is left" test ! -e /etc/runit/runsvdir/default/e2e-sleeper
unit e2e-boot 'ExecStart=/bin/sleep 1000'
expect "enable of a service runsvdir has not seen" 0 "" systemctl enable e2e-boot
wait_for "runsvdir starts an enabled service at its next scan" 10 active e2e-boot active
expect "disable keeps it running" 0 "" systemctl disable e2e-boot
expect "it is still active" 0 "active" systemctl is-active e2e-boot
expect "stop succeeds" 0 "" systemctl stop e2e-boot
expect "disable of the stopped service removes its link" 0 "" systemctl disable e2e-boot
check "no link is left" test ! -e /etc/runit/runsvdir/default/e2e-boot

expect "a failing service starts" 0 "" systemctl start e2e-failer
wait_for "a service whose process exited with an error is failed" 5 active e2e-failer failed
expect "stop resets the failed state" 0 "" systemctl stop e2e-failer
expect "is-active answers inactive after reset" 3 "inactive" systemctl is-active e2e-failer

# --- Executor: ExecStartPre= and EnvironmentFile= ------------------------------------------------
echo "E2E_VAR=hello" >/etc/default/e2e-pre
unit e2e-pre 'EnvironmentFile=/etc/default/e2e-pre
ExecStartPre=/bin/touch /tmp/e2e-pre-ran
ExecStart=/bin/sh -c "env >/tmp/e2e-pre-env; exec sleep 1000"'
expect "a unit with ExecStartPre= starts" 0 "" systemctl start e2e-pre
check "run goes through the executor" grep -q "^exec /usr/bin/fake-systemd --exec e2e-pre.service$" /etc/sv/e2e-pre/run
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
wait_for "executor service is active" 5 active e2e-pre active
check "the executor became the service process" sh -c 'grep -q sleep /proc/$(cat /etc/sv/e2e-pre/supervise/pid)/cmdline'
expect "stop succeeds" 0 "" systemctl stop e2e-pre

# --- ExecStop= runs before the process is terminated, ExecStopPost= after it ended ---------------
unit e2e-hooks 'ExecStart=/bin/sleep 1000
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-stop-alive"
ExecStopPost=/bin/touch /tmp/e2e-post-ran'
expect "a unit with stop hooks starts" 0 "" systemctl start e2e-hooks
wait_for "it runs" 5 svrun e2e-hooks
check "control/t holds the ExecStop= step" grep -q -- "--phase stop-main" /etc/sv/e2e-hooks/control/t
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the service process was alive" test -e /tmp/e2e-stop-alive
wait_for "ExecStopPost= ran" 5 test -e /tmp/e2e-post-ran
expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-hooks
unit e2e-post 'ExecStart=/bin/sh -c "exit 1"
ExecStopPost=/bin/touch /tmp/e2e-post-crash'
expect "start of a service that exits at once" 0 "" systemctl start e2e-post
wait_for "ExecStopPost= ran after the process exited by itself" 5 test -e /tmp/e2e-post-crash
systemctl stop e2e-post >/dev/null 2>&1

# --- Type=forking through the executor -----------------------------------------------------------
unit e2e-fork 'Type=forking
PIDFile=/run/e2e-fork.pid
ExecStart=/usr/local/bin/e2e-forker'
expect "a forking unit starts" 0 "" systemctl start e2e-fork
wait_for "the executor follows the daemon" 5 active e2e-fork active
check "the followed pid is a live daemon" sh -c 'kill -0 "$(cat /run/e2e-fork.pid)"'
daemon=$(cat /run/e2e-fork.pid 2>/dev/null)
expect "stop of a forking unit succeeds" 0 "" systemctl stop e2e-fork
wait_for "the forked daemon is gone" 5 sh -c "! kill -0 $daemon"

# --- Dependency closure --------------------------------------------------------------------------
unit e2e-b 'ExecStart=/bin/sleep 1000'
printf '[Unit]\nDescription=Requires b\nRequires=e2e-b.service\nAfter=e2e-b.service\n\n[Service]\nExecStart=/bin/sleep 1000\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-a.service
expect "enable --now of a unit with Requires= succeeds" 0 "" systemctl enable --now e2e-a
check "the required unit is started from run" grep -q "^sv start e2e-b || exit 1$" /etc/sv/e2e-a/run
check "the required unit is linked with down, not enabled" sh -c 'test -L /etc/runit/runsvdir/default/e2e-b && test -e /etc/sv/e2e-b/down'
wait_for "sv start brought the required service up" 10 svrun e2e-b
expect "the required unit is active" 0 "active" systemctl is-active e2e-b
expect "the required unit is not enabled" 1 "disabled" systemctl is-enabled e2e-b
systemctl stop e2e-a >/dev/null 2>&1
systemctl stop e2e-b >/dev/null 2>&1
systemctl disable e2e-a >/dev/null 2>&1
rm -f /usr/lib/systemd/system/e2e-a.service
expect "daemon-reload collects the dependency of a removed unit" 0 "" systemctl daemon-reload
check "the dependency's service files are removed" test ! -e /etc/sv/e2e-b/run
check "the dependency's link is removed" test ! -e /etc/runit/runsvdir/default/e2e-b

# --- Templates -----------------------------------------------------------------------------------
printf '[Service]\nExecStart=/bin/sh -c "echo %%i >/tmp/e2e-tpl-%%i; exec sleep 1000"\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-tpl@.service
expect "a template instance starts" 0 "" systemctl start e2e-tpl@one
check "the instance is a service directory named with @" test -e /etc/sv/e2e-tpl@one/run
wait_for "runsv accepts the @ in the name" 5 svrun e2e-tpl@one
wait_for "the instance saw its name" 5 grep -q '^one$' /tmp/e2e-tpl-one
expect "stop of the instance succeeds" 0 "" systemctl stop e2e-tpl@one

# --- Restart= ------------------------------------------------------------------------------------
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
wait_for "Restart=on-failure restarts a failing service" 15 sh -c '[ "$(wc -l </tmp/e2e-rf.count)" -ge 2 ]'
sleep 3
check "Restart=on-failure does not restart a clean exit" test "$(count /tmp/e2e-rclean.count)" = 1
check "Restart=no does not restart" test "$(count /tmp/e2e-rno.count)" = 1
expect "a service that exited cleanly is inactive" 3 "inactive" systemctl is-active e2e-rclean
systemctl stop e2e-rf >/dev/null 2>&1

# --- Oneshot -------------------------------------------------------------------------------------
unit e2e-once 'Type=oneshot
ExecStart=/bin/touch /tmp/e2e-once-ran'
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

# --- Signals and logs ----------------------------------------------------------------------------
unit e2e-signals 'ExecStart=/usr/local/bin/e2e-signals'
expect "a signal-handling service starts" 0 "" systemctl start e2e-signals
wait_for "it runs" 5 svrun e2e-signals
expect "kill -s HUP goes through sv hup" 0 "" systemctl kill -s HUP e2e-signals
wait_for "the service got SIGHUP" 5 test -e /tmp/e2e-hup
expect "kill -s WINCH, which sv cannot send, goes through kill" 0 "" systemctl kill -s WINCH e2e-signals
wait_for "the service got SIGWINCH" 5 test -e /tmp/e2e-winch
wait_for "the service output reached the uniform log" 5 grep -q e2e-hello-from-the-service /var/log/fake-systemd/e2e-signals.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-hello-from-the-service" journalctl -u e2e-signals.service --no-pager
expect "stop succeeds" 0 "" systemctl stop e2e-signals

# --- A service the system already has -------------------------------------------------------------
mkdir -p /etc/sv/e2e-nat
printf '#!/bin/sh\nexec 2>&1\nexec chpst -n 0 /bin/sleep 1000\n' >/etc/sv/e2e-nat/run
chmod 755 /etc/sv/e2e-nat/run
unit e2e-nat 'ExecStart=/bin/sleep 1000'
expect "enable --now uses the native service" 0 "" systemctl enable --now e2e-nat
check "nothing was generated over the native service" sh -c '! grep -q "Generated automatically" /etc/sv/e2e-nat/run && test ! -e /etc/sv/e2e-nat/finish'
wait_for "the native service runs" 10 svrun e2e-nat
expect "reload of a native service goes through sv" 0 "" systemctl reload e2e-nat
expect "disable and stop the native service" 0 "" sh -c 'systemctl disable e2e-nat && systemctl stop e2e-nat'

# --- Generated services are valid shell -----------------------------------------------------------
mkdir -p /tmp/golden-split
for f in /golden/*.runit; do
    n=$(basename "$f" .runit)
    mkdir -p "/tmp/golden-split/$n"
    awk -v dir="/tmp/golden-split/$n" '/^=== /{ p = $2; gsub("/", "_", p); out = dir "/" p; next } { print > out }' "$f"
    for s in "/tmp/golden-split/$n"/*; do
        check "golden $n/$(basename "$s") passes sh -n" sh -n "$s"
    done
done

# --- An account only the system libc resolves: run switches with setpriv and the groups follow ---
echo "svc-directory:x:1500:1500::/home/svc:/bin/sh" >>/etc/passwd
echo "svc-directory:x:1500:" >>/etc/group
echo "e2eextra:x:1501:svc-directory" >>/etc/group
printf '#!/bin/sh\nid >/tmp/e2e-ldap-id\nexec sleep 1000\n' >/usr/bin/dirsync
chmod 755 /usr/bin/dirsync
check "the golden service for such an account uses setpriv" grep -q '^exec /usr/bin/setpriv --reuid=svc-directory --regid="$(id -g -- svc-directory)" --init-groups ' /tmp/golden-split/user-ldap/run
mkdir -p /etc/sv/e2e-ldap
cp /tmp/golden-split/user-ldap/run /etc/sv/e2e-ldap/run
chmod 755 /etc/sv/e2e-ldap/run
ln -s /etc/sv/e2e-ldap /var/service/e2e-ldap
wait_for "the generated run script starts as the account" 12 test -s /tmp/e2e-ldap-id
check "the account has its primary group" grep -q 'uid=1500(svc-directory) gid=1500(svc-directory)' /tmp/e2e-ldap-id
check "the account has its supplementary group" grep -q '1501(e2eextra)' /tmp/e2e-ldap-id
sv stop e2e-ldap >/dev/null 2>&1
rm /var/service/e2e-ldap

# --- Timeouts and network providers ---------------------------------------------------------------
cat >/usr/local/bin/e2e-stubborn <<'X'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-stubborn
unit e2e-stubborn 'ExecStart=/usr/local/bin/e2e-stubborn
TimeoutStopSec=2'
expect "the stubborn service starts" 0 "" systemctl start e2e-stubborn
check "the stop timeout is recorded in run" grep -q '^# sv waits: stop=2$' /etc/sv/e2e-stubborn/run
wait_for "the stubborn service runs" 10 svrun e2e-stubborn
began=$(date +%s)
expect "stop kills a service that ignores TERM after TimeoutStopSec=" 0 "" systemctl stop e2e-stubborn
check "it did not wait for the default of 90 seconds" test $(($(date +%s) - began)) -lt 30
expect "the stubborn service is gone" 3 "" systemctl is-active e2e-stubborn
mkdir -p /etc/sv/dhcpcd
printf '#!/bin/sh\nexec sleep 1000\n' >/etc/sv/dhcpcd/run
chmod 755 /etc/sv/dhcpcd/run
ln -s /etc/sv/dhcpcd /etc/runit/runsvdir/default/dhcpcd
printf '#!/bin/sh\nexec sleep 1000\n' >/usr/local/bin/e2e-net-svc
chmod 755 /usr/local/bin/e2e-net-svc
printf '[Unit]\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nExecStart=/usr/local/bin/e2e-net-svc\n' >/usr/lib/systemd/system/e2e-net.service
expect "a unit that waits for the network starts" 0 "" systemctl start e2e-net
check "the enabled network provider became a soft dependency" grep -q '^sv start dhcpcd$' /etc/sv/e2e-net/run
wait_for "starting the unit started the provider" 10 svrun dhcpcd
systemctl stop e2e-net >/dev/null 2>&1
sv stop dhcpcd >/dev/null 2>&1
rm /etc/runit/runsvdir/default/dhcpcd

# --- Timers: built-in runner as a runit service --------------------------------------------------
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
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/runit/index
check "the runner service runs the timer runner" grep -q "^exec /usr/bin/fake-systemd --timers$" /etc/sv/fake-systemd-timers/run
check "the runner is enabled at boot" test -L /etc/runit/runsvdir/default/fake-systemd-timers
wait_for "runsv started the runner" 10 svrun fake-systemd-timers
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "status shows the trigger" 0 "Trigger:" systemctl status e2e-tick.timer
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-tick.timer
expect "is-active answers active" 0 "active" systemctl is-active e2e-tick.timer
check "the index records the run" grep -q "^timer.e2e-tick.timer.builtin.*success$" /var/lib/fake-systemd/runit/index
cat >/usr/lib/systemd/system/e2e-tock.service <<'X'
[Service]
Type=oneshot
ExecStart=/bin/echo e2e-tock-output
X
cat >/usr/lib/systemd/system/e2e-tock.timer <<'X'
[Timer]
OnCalendar=*:*:0/5

[Install]
WantedBy=timers.target
X
expect "a second timer is enabled while the runner is up" 0 "" systemctl enable e2e-tock.timer
wait_for "sv hup made the running runner load the new timer" 30 sh -c 'grep -q e2e-tock-output /var/log/fake-systemd/e2e-tock.service/current'
expect "daemon-reload keeps the runner going" 0 "" systemctl daemon-reload
expect "disable of one timer keeps the runner" 0 "" systemctl disable e2e-tick.timer
check "the runner unit stays while a built-in timer is left" test -e /etc/systemd/system/fake-systemd-timers.service
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tock.timer
check "the runner unit is removed" test ! -e /etc/systemd/system/fake-systemd-timers.service
check "the runner service files are removed" test ! -e /etc/sv/fake-systemd-timers/run
check "the runner is no longer enabled at boot" test ! -e /etc/runit/runsvdir/default/fake-systemd-timers
wait_for "runsvdir stopped the runner" 10 sh -c '! sv status fake-systemd-timers 2>/dev/null | grep -q "^run:"'

# --- User services on a per-user runsvdir, as turnstile runs it ----------------------------------
echo "tester:x:1000:1000::/home/tester:/bin/sh" >>/etc/passwd
echo "tester:x:1000:" >>/etc/group
mkdir -p /home/tester/.config/service /usr/libexec/turnstile /etc/turnstile
chown -R 1000:1000 /home/tester
printf '#!/bin/sh\n' >/usr/libexec/turnstile/runit
echo "backend = runit" >/etc/turnstile/turnstiled.conf
chpst -u tester env - PATH=/usr/bin:/usr/sbin HOME=/home/tester runsvdir -P /home/tester/.config/service 'log: ....' >/tmp/user-runsvdir.log 2>&1 &
cat >/usr/lib/systemd/user/e2e-user.service <<'X'
[Service]
ExecStart=/bin/sleep 1000

[Install]
WantedBy=default.target
X
expect "user enable --now succeeds" 0 "" as_tester systemctl --user enable --now e2e-user
check "the user service is generated in the personal directory" test -e /home/tester/.config/sv/e2e-user/run
check "the user service is linked into the user's runsvdir" test "$(readlink /home/tester/.config/service/e2e-user)" = /home/tester/.config/sv/e2e-user
wait_for "the user's runsv runs the service" 10 sh -c 'chpst -u tester sv status /home/tester/.config/service/e2e-user | grep -q "^run:"'
expect "user is-active answers active" 0 "active" as_tester systemctl --user is-active e2e-user
wait_for "the user logger writes below the state directory" 5 test -d /home/tester/.local/state/fake-systemd/log/e2e-user.service
expect "user stop succeeds" 0 "" as_tester systemctl --user stop e2e-user
expect "user disable succeeds" 0 "" as_tester systemctl --user disable e2e-user
check "the user link is removed" test ! -e /home/tester/.config/service/e2e-user

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
