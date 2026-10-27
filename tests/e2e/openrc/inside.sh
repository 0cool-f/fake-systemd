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
# rcstate NAME CODE  (rc-service status exits with CODE: 0 started, 3 stopped, 32 crashed)
rcstate() { rc-service "$1" status >/dev/null 2>&1; [ $? -eq "$2" ]; }
count() { [ -e "$1" ] && wc -l <"$1" | tr -d ' '; }
as_tester() { setpriv --reuid=tester --regid=tester --init-groups env HOME=/home/tester XDG_RUNTIME_DIR=/run/user/1000 PATH="$PATH" "$@"; }
pidof_service() { cat "/run/openrc/options/$1/child_pid" 2>/dev/null || cat "/run/$1.pid"; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/lib/systemd/user /etc/default

# What booting does, without being PID 1: OpenRC runs a service only on a system it booted.
mkdir -p /run/openrc
touch /run/openrc/softlevel
openrc default >/tmp/openrc-default.log 2>&1
expect "openrc booted the default runlevel" 0 "default" rc-status -r
apk info -v | grep -E '^(openrc|setpriv)-[0-9]'
check "the default runlevel is empty" sh -c 'test -z "$(ls /etc/runlevels/default)"'

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
unit e2e-failer 'ExecStart=/bin/sh -c "exit 3"'

# --- Lifecycle ----------------------------------------------------------------------------
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
check "the script carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/init.d/e2e-sleeper
check "the script is an openrc-run script" sh -c 'head -n 1 /etc/init.d/e2e-sleeper | grep -qx "#!/sbin/openrc-run"'
check "the script passes sh -n" sh -n /etc/init.d/e2e-sleeper
check "the script is executable" test -x /etc/init.d/e2e-sleeper
check "the link points at the script" test "$(readlink /etc/runlevels/default/e2e-sleeper)" = /etc/init.d/e2e-sleeper
check "rc-update lists the service in the default runlevel" sh -c 'rc-update show | grep -q "e2e-sleeper | *default"'
check "OpenRC records the service as started" rcstate e2e-sleeper 0
check "a Restart=no service runs its executor under start-stop-daemon, with a pid file of its own" sh -c 'grep -q "^command_background=yes$" /etc/init.d/e2e-sleeper && grep -q -- "--log --record-exit" /etc/init.d/e2e-sleeper && kill -0 "$(cat /run/e2e-sleeper.fake-systemd.pid)"'
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "stopping an enabled service keeps its link" test -L /etc/runlevels/default/e2e-sleeper
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
first_pid=$(cat /run/e2e-sleeper.fake-systemd.pid)
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
check "restart started a new process" test "$(cat /run/e2e-sleeper.fake-systemd.pid)" != "$first_pid"
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service without a supervisor is crashed, which reads failed" 5 active e2e-sleeper failed
check "OpenRC records the death as crashed" rcstate e2e-sleeper 32
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
expect "start of a crashed service starts it again" 0 "" systemctl start e2e-sleeper
expect "the service is active again" 0 "active" systemctl is-active e2e-sleeper
expect "stop succeeds again" 0 "" systemctl stop e2e-sleeper
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
check "the link is removed" test ! -e /etc/runlevels/default/e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "daemon-reload succeeds against the running OpenRC" 0 "" systemctl daemon-reload

# --- Enabled at boot or not, independent of running ------------------------------------------
expect "enable --now of a service that was disabled" 0 "" systemctl enable --now e2e-sleeper
wait_for "service is active" 5 active e2e-sleeper active
expect "disable keeps a running service running" 0 "" systemctl disable e2e-sleeper
expect "the service is still active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
expect "start of a service that is not enabled" 0 "" systemctl start e2e-sleeper
expect "start does not enable" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable links the service for boot without starting it" 0 "" systemctl enable e2e-sleeper
expect "is-active answers inactive after enable" 3 "inactive" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled after enable" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "enable of an enabled service changes nothing" 0 "" systemctl enable e2e-sleeper
expect "disable removes the link" 0 "" systemctl disable e2e-sleeper
check "no link is left" test ! -e /etc/runlevels/default/e2e-sleeper
expect "enable --runtime persists, since OpenRC has no volatile runlevel" 0 "" systemctl enable --runtime e2e-sleeper
check "the link exists" test -L /etc/runlevels/default/e2e-sleeper
expect "disable removes it again" 0 "" systemctl disable e2e-sleeper

expect "a failing service starts" 0 "" systemctl start e2e-failer
wait_for "a service whose process exited with an error is failed" 5 active e2e-failer failed
expect "stop resets the failed state" 0 "" systemctl stop e2e-failer
expect "is-active answers inactive after reset" 3 "inactive" systemctl is-active e2e-failer
unit e2e-clean 'ExecStart=/bin/sh -c "echo e2e-clean-output; echo e2e-clean-error >&2; exit 0"'
expect "a service that ends cleanly starts" 0 "" systemctl start e2e-clean
wait_for "a clean exit reads inactive, whatever OpenRC records" 5 active e2e-clean inactive
check "OpenRC records the clean end as crashed, as it does every death without a supervisor" rcstate e2e-clean 32
check "the executor recorded the clean end" grep -q '^ok 0$' /run/fake-systemd/e2e-clean.service.exit
check "the executor recorded the failure of the failing service" sh -c 'systemctl start e2e-failer; sleep 1; grep -q "^failed 3$" /run/fake-systemd/e2e-failer.service.exit'
systemctl stop e2e-failer >/dev/null 2>&1
wait_for "stdout of a Restart=no service reached the uniform log" 5 grep -q e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current
wait_for "so did its stderr, through the same logger" 5 grep -q e2e-clean-error /var/log/fake-systemd/e2e-clean.service/current
expect "is-failed answers 1 for a service that ended cleanly" 1 "inactive" systemctl is-failed e2e-clean
expect "start of a service that ended cleanly runs it again" 0 "" systemctl start e2e-clean
wait_for "the second run was logged" 5 sh -c '[ "$(grep -c e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current)" -ge 2 ]'
expect "stop of a finished service succeeds" 0 "" systemctl stop e2e-clean

# --- Supervision and Restart= ---------------------------------------------------------------------
rm -f /tmp/e2e-rf.count /tmp/e2e-rno.count /tmp/e2e-giveup.count
unit e2e-always 'ExecStart=/bin/sleep 1000
Restart=always
RestartSec=1'
expect "a Restart=always service starts" 0 "" systemctl start e2e-always
check "the script runs it under supervise-daemon" grep -q "^supervisor=supervise-daemon$" /etc/init.d/e2e-always
check "RestartSec= became respawn_delay" grep -q "^respawn_delay=1$" /etc/init.d/e2e-always
wait_for "it is active" 5 active e2e-always active
old=$(pidof_service e2e-always)
kill -9 "$old"
wait_for "supervise-daemon respawns the killed process" 10 sh -c "[ \"\$(cat /run/openrc/options/e2e-always/child_pid)\" != $old ] && kill -0 \"\$(cat /run/openrc/options/e2e-always/child_pid)\""
expect "the respawned service is active" 0 "active" systemctl is-active e2e-always
expect "status shows the pid of the supervised process" 0 "Main PID: $(pidof_service e2e-always)" systemctl status e2e-always
expect "stop succeeds" 0 "" systemctl stop e2e-always
check "stop took the supervisor away" sh -c '! pgrep -f "[s]upervise-daemon e2e-always" >/dev/null'
unit e2e-rf 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rf.count; exit 1"
Restart=on-failure
RestartSec=1'
unit e2e-rno 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rno.count; exit 1"
Restart=no'
systemctl start e2e-rf >/dev/null 2>&1
systemctl start e2e-rno >/dev/null 2>&1
wait_for "Restart=on-failure restarts a failing service" 15 sh -c '[ "$(wc -l </tmp/e2e-rf.count)" -ge 3 ]'
sleep 2
check "Restart=no does not restart" test "$(count /tmp/e2e-rno.count)" = 1
wait_for "a service that keeps failing is given up on and reads failed" 40 active e2e-rf failed
check "OpenRC records the give-up as stopped with a failed marker" sh -c 'rc-service e2e-rf status >/dev/null 2>&1; [ $? -eq 3 ] && test -L /run/openrc/failed/e2e-rf'
expect "start of a service the supervisor gave up on starts it" 0 "" systemctl start e2e-rf
expect "stop resets the failed state" 0 "" systemctl stop e2e-rf
check "the failed marker is gone" test ! -e /run/openrc/failed/e2e-rf
expect "is-active answers inactive after reset" 3 "inactive" systemctl is-active e2e-rf
systemctl stop e2e-rno >/dev/null 2>&1

# --- Executor: ExecStartPre= and EnvironmentFile= ------------------------------------------------
echo "E2E_VAR=hello" >/etc/default/e2e-pre
unit e2e-pre 'EnvironmentFile=/etc/default/e2e-pre
ExecStartPre=/bin/touch /tmp/e2e-pre-ran
ExecStart=/bin/sh -c "env >/tmp/e2e-pre-env; exec sleep 1000"'
expect "a unit with ExecStartPre= starts" 0 "" systemctl start e2e-pre
check "the script goes through the executor" grep -q -- "--exec e2e-pre.service" /etc/init.d/e2e-pre
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
wait_for "executor service is active" 5 active e2e-pre active
check "the main process is the one the executor recorded" sh -c 'grep -q sleep /proc/$(cut -d" " -f1 /run/fake-systemd/e2e-pre.service.pid)/cmdline'
expect "stop succeeds" 0 "" systemctl stop e2e-pre

# --- ExecStop= runs before the process is terminated, ExecStopPost= after it ended ---------------
unit e2e-hooks 'ExecStart=/bin/sleep 1000
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-stop-alive"
ExecStopPost=/bin/touch /tmp/e2e-post-ran'
expect "a unit with stop hooks starts" 0 "" systemctl start e2e-hooks
wait_for "it runs" 5 rcstate e2e-hooks 0
check "the executor stays resident to run ExecStop= on SIGTERM" grep -q -- "--stop-on-signal" /etc/init.d/e2e-hooks
check "stop_post runs ExecStopPost= through the executor" grep -q -- "--phase stop-post" /etc/init.d/e2e-hooks
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the service process was alive" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran" test -e /tmp/e2e-post-ran
expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-hooks
rm -f /tmp/e2e-stop-alive /tmp/e2e-post-ran
systemctl enable --now e2e-hooks >/dev/null 2>&1
wait_for "the enabled service runs" 5 rcstate e2e-hooks 0
openrc nonetwork >/dev/null 2>&1
check "leaving the runlevel stopped the service through ExecStop=, as a shutdown does" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran on the runlevel change" test -e /tmp/e2e-post-ran
openrc default >/dev/null 2>&1
wait_for "returning to the default runlevel started it again" 10 rcstate e2e-hooks 0
systemctl disable e2e-hooks >/dev/null 2>&1
systemctl stop e2e-hooks >/dev/null 2>&1

# --- Type=forking ----------------------------------------------------------------------------------
unit e2e-fork 'Type=forking
PIDFile=/run/e2e-fork.pid
ExecStart=/usr/local/bin/e2e-forker'
expect "a forking unit starts" 0 "" systemctl start e2e-fork
check "a forking Restart=no unit with a pid file goes through the executor, which follows it" sh -c 'grep -q -- "--exec e2e-fork.service --log --record-exit" /etc/init.d/e2e-fork'
wait_for "the daemon is active" 5 active e2e-fork active
check "the pid is a live daemon" sh -c 'kill -0 "$(cat /run/e2e-fork.pid)"'
daemon=$(cat /run/e2e-fork.pid 2>/dev/null)
expect "stop of a forking unit succeeds" 0 "" systemctl stop e2e-fork
wait_for "the forked daemon is gone" 5 sh -c "! kill -0 $daemon"
unit e2e-fork2 'Type=forking
PIDFile=/run/e2e-fork.pid
ExecStart=/usr/local/bin/e2e-forker
Restart=on-failure'
expect "a supervised forking unit starts" 0 "" systemctl start e2e-fork2
check "it goes through the executor, which follows the pid file" grep -q -- "--exec e2e-fork2.service" /etc/init.d/e2e-fork2
wait_for "the executor follows the daemon" 5 active e2e-fork2 active
daemon=$(cat /run/e2e-fork.pid 2>/dev/null)
expect "stop succeeds" 0 "" systemctl stop e2e-fork2
wait_for "the forked daemon is gone" 5 sh -c "! kill -0 $daemon"

# --- Dependency closure --------------------------------------------------------------------------
unit e2e-b 'ExecStart=/bin/sleep 1000'
printf '[Unit]\nDescription=Requires b\nRequires=e2e-b.service\nAfter=e2e-b.service\n\n[Service]\nExecStart=/bin/sleep 1000\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-a.service
expect "enable --now of a unit with Requires= succeeds" 0 "" systemctl enable --now e2e-a
check "the required unit is a need of the script" sh -c 'grep -q "^	need e2e-b$" /etc/init.d/e2e-a'
check "the required unit is not enabled" test ! -e /etc/runlevels/default/e2e-b
check "OpenRC started the required service as a dependency" rcstate e2e-b 0
expect "the required unit is active" 0 "active" systemctl is-active e2e-b
expect "the required unit is not enabled" 1 "disabled" systemctl is-enabled e2e-b
systemctl stop e2e-a >/dev/null 2>&1
systemctl stop e2e-b >/dev/null 2>&1
systemctl disable e2e-a >/dev/null 2>&1
rm -f /usr/lib/systemd/system/e2e-a.service
expect "daemon-reload collects the dependency of a removed unit" 0 "" systemctl daemon-reload
check "the dependency's script is removed" test ! -e /etc/init.d/e2e-b

# --- Templates -----------------------------------------------------------------------------------
printf '[Service]\nExecStart=/bin/sh -c "echo %%i >/tmp/e2e-tpl-%%i; exec sleep 1000"\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-tpl@.service
expect "a template instance starts" 0 "" systemctl start e2e-tpl@one
check "the instance is a script named with a dot" test -e /etc/init.d/e2e-tpl.one
wait_for "OpenRC runs the instance" 5 rcstate e2e-tpl.one 0
wait_for "the instance saw its name" 5 grep -q '^one$' /tmp/e2e-tpl-one
expect "stop of the instance succeeds" 0 "" systemctl stop e2e-tpl@one

# --- Oneshot -------------------------------------------------------------------------------------
rm -f /tmp/e2e-once-count
unit e2e-once 'Type=oneshot
ExecStart=/bin/sh -c "echo x >>/tmp/e2e-once-count; echo e2e-once-output"'
expect "a oneshot starts" 0 "" systemctl start e2e-once
check "the oneshot ran" test "$(count /tmp/e2e-once-count)" = 1
expect "a finished oneshot is inactive" 3 "inactive" systemctl is-active e2e-once
check "OpenRC still records it as started, so that its dependents stay satisfied" rcstate e2e-once 0
expect "a second start runs it again" 0 "" systemctl start e2e-once
check "the oneshot ran twice" test "$(count /tmp/e2e-once-count)" = 2
check "its output reached the uniform log" grep -q e2e-once-output /var/log/fake-systemd/e2e-once.service/current
check "no stale pid file of the executor is left" test ! -e /run/fake-systemd/e2e-once.service.pid
expect "stop of a finished oneshot succeeds" 0 "" systemctl stop e2e-once
unit e2e-onefail 'Type=oneshot
ExecStart=/bin/sh -c "exit 4"'
expect "a failing oneshot fails the start" 1 "" systemctl start e2e-onefail
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
unit e2e-signals 'ExecStart=/usr/local/bin/e2e-signals
Restart=always
RestartSec=1'
expect "a signal-handling service starts" 0 "" systemctl start e2e-signals
wait_for "it runs" 5 rcstate e2e-signals 0
expect "kill -s HUP signals the service" 0 "" systemctl kill -s HUP e2e-signals
wait_for "the service got SIGHUP" 5 test -e /tmp/e2e-hup
expect "kill -s WINCH signals the service" 0 "" systemctl kill -s WINCH e2e-signals
wait_for "the service got SIGWINCH" 5 test -e /tmp/e2e-winch
wait_for "the service output reached the uniform log through the logger pipe" 5 grep -q e2e-hello-from-the-service /var/log/fake-systemd/e2e-signals.service/current
check "log lines carry an ISO 8601 timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+[+-][0-9:]+ e2e-hello' /var/log/fake-systemd/e2e-signals.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-hello-from-the-service" journalctl -u e2e-signals.service --no-pager
expect "stop succeeds" 0 "" systemctl stop e2e-signals

# --- A service the system already has -------------------------------------------------------------
cat >/etc/init.d/e2e-nat <<'X'
#!/sbin/openrc-run
extra_started_commands="reload"
supervisor=supervise-daemon
command=/bin/sleep
command_args="1000"
reload() { touch /tmp/e2e-nat-reload; }
X
chmod 755 /etc/init.d/e2e-nat
unit e2e-nat 'ExecStart=/bin/sleep 1000'
expect "enable --now uses the native service" 0 "" systemctl enable --now e2e-nat
check "nothing was generated over the native service" sh -c '! grep -q "Generated automatically" /etc/init.d/e2e-nat'
wait_for "the native service runs" 10 rcstate e2e-nat 0
expect "reload of a native service goes through rc-service" 0 "" systemctl reload e2e-nat
check "the native reload function ran" test -e /tmp/e2e-nat-reload
expect "status of a native service reports its supervised pid" 0 "Main PID" systemctl status e2e-nat
expect "disable and stop the native service" 0 "" sh -c 'systemctl disable e2e-nat && systemctl stop e2e-nat'
rm -f /etc/init.d/e2e-nat

# --- Generated scripts are valid openrc-run scripts ------------------------------------------------
for f in /golden/*.openrc; do
    n=$(basename "$f" .openrc)
    cp "$f" "/etc/init.d/golden-$n"
    chmod 755 "/etc/init.d/golden-$n"
    check "golden $n passes sh -n" sh -n "/etc/init.d/golden-$n"
    check "golden $n loads in openrc-run" rc-service "golden-$n" describe
done
rm -f /etc/init.d/golden-*

# --- An account only the system libc resolves: command_user applies its groups -------------------
echo "svc-directory:x:1500:1500::/home/svc:/bin/sh" >>/etc/passwd
echo "svc-directory:x:1500:" >>/etc/group
echo "e2eextra:x:1501:svc-directory" >>/etc/group
printf '#!/bin/sh\nid >/tmp/e2e-ldap-id\necho e2e-ldap-line\nexec sleep 1000\n' >/usr/bin/dirsync
chmod 755 /usr/bin/dirsync
check "the golden script for such an account uses command_user" grep -q '^command_user=svc-directory$' /golden/user-ldap.openrc
cp /golden/user-ldap.openrc /etc/init.d/e2e-ldap
chmod 755 /etc/init.d/e2e-ldap
check "the account has no entry the executor reads in the golden fixture, so the script is native" grep -q '^command=/usr/bin/dirsync$' /etc/init.d/e2e-ldap
expect "the script starts as the account" 0 "" rc-service e2e-ldap start
wait_for "the daemon ran" 5 test -s /tmp/e2e-ldap-id
check "the account has its primary group" grep -q 'uid=1500(svc-directory) gid=1500(svc-directory)' /tmp/e2e-ldap-id
check "the account has its supplementary group" grep -q '1501(e2eextra)' /tmp/e2e-ldap-id
check "the log directory belongs to the account, whose logger writes in it" sh -c 'test "$(stat -c %U /var/log/fake-systemd/user-ldap.service)" = svc-directory'
wait_for "the logger running as the account wrote the line" 5 grep -q e2e-ldap-line /var/log/fake-systemd/user-ldap.service/current
check "supervise-daemon runs it" rcstate e2e-ldap 0
rc-service e2e-ldap stop >/dev/null 2>&1
rm -f /etc/init.d/e2e-ldap

# --- Timeouts and network targets ----------------------------------------------------------------
cat >/usr/local/bin/e2e-stubborn <<'X'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-stubborn
unit e2e-stubborn 'ExecStart=/usr/local/bin/e2e-stubborn
TimeoutStopSec=2'
expect "the stubborn service starts" 0 "" systemctl start e2e-stubborn
check "the stop timeout, plus the grace of the executor, is the retry schedule" grep -q "^retry=TERM/12/KILL/5$" /etc/init.d/e2e-stubborn
wait_for "the stubborn service runs" 5 rcstate e2e-stubborn 0
began=$(date +%s)
expect "stop kills a service that ignores TERM after TimeoutStopSec=" 0 "" systemctl stop e2e-stubborn
check "it did not wait for the default of 90 seconds" test $(($(date +%s) - began)) -lt 30
expect "the stubborn service is gone" 3 "" systemctl is-active e2e-stubborn
check "the process of the stubborn service is gone, not left behind by the executor" sh -c '! pgrep -f "[s]h /usr/local/bin/e2e-stubborn" >/dev/null'
printf '[Unit]\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nExecStart=/bin/sleep 1000\n' >/usr/lib/systemd/system/e2e-net.service
expect "a unit that waits for the network starts" 0 "" systemctl start e2e-net
check "the network targets became soft dependencies on the virtual services" sh -c 'grep -q "^	use net network-online$" /etc/init.d/e2e-net'
wait_for "OpenRC runs it" 5 rcstate e2e-net 0
systemctl stop e2e-net >/dev/null 2>&1

# --- Environment, working directory, umask and limits natively ---------------------------------------
cat >/usr/local/bin/e2e-env <<'X'
#!/bin/sh
{ echo "FOO=$FOO"; echo "BAR=$BAR"; pwd; umask; ulimit -n; } >/tmp/e2e-env.out
exec sleep 1000
X
chmod 755 /usr/local/bin/e2e-env
mkdir -p /srv/e2e
unit e2e-env 'Environment=FOO=1 "BAR=two words"
WorkingDirectory=/srv/e2e
UMask=0027
LimitNOFILE=1234
ExecStart=/usr/local/bin/e2e-env
Nice=5
Restart=always'
expect "a unit with native settings starts" 0 "" systemctl start e2e-env
check "the script is native, with no executor" sh -c '! grep -q "^command=.*fake-systemd" /etc/init.d/e2e-env && grep -q "^command=/usr/local/bin/e2e-env$" /etc/init.d/e2e-env'
wait_for "the service wrote its view" 5 test -s /tmp/e2e-env.out
check "Environment= reached the service" sh -c 'grep -qx "FOO=1" /tmp/e2e-env.out && grep -qx "BAR=two words" /tmp/e2e-env.out'
check "WorkingDirectory= applied" grep -qx /srv/e2e /tmp/e2e-env.out
check "UMask= applied" grep -qx 0027 /tmp/e2e-env.out
check "LimitNOFILE= applied through rc_ulimit" grep -qx 1234 /tmp/e2e-env.out
check "Nice= applied" sh -c 'test "$(cut -d" " -f19 /proc/$(cat /run/openrc/options/e2e-env/child_pid)/stat)" = 5'
expect "stop succeeds" 0 "" systemctl stop e2e-env

# --- Timers: built-in runner as an OpenRC service ------------------------------------------------
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
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/openrc/index
check "the runner service runs the timer runner" grep -q '^command_args="--timers"$' /etc/init.d/fake-systemd-timers
check "the runner is enabled at boot" test -L /etc/runlevels/default/fake-systemd-timers
wait_for "OpenRC started the runner" 10 rcstate fake-systemd-timers 0
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "status shows the trigger" 0 "Trigger:" systemctl status e2e-tick.timer
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-tick.timer
expect "is-active answers active" 0 "active" systemctl is-active e2e-tick.timer
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
wait_for "a signal made the running runner load the new timer" 30 sh -c 'grep -q e2e-tock-output /var/log/fake-systemd/e2e-tock.service/current'
expect "daemon-reload keeps the runner going" 0 "" systemctl daemon-reload
expect "disable of one timer keeps the runner" 0 "" systemctl disable e2e-tick.timer
check "the runner unit stays while a built-in timer is left" test -e /etc/systemd/system/fake-systemd-timers.service
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tock.timer
check "the runner unit is removed" test ! -e /etc/systemd/system/fake-systemd-timers.service
check "the runner script is removed" test ! -e /etc/init.d/fake-systemd-timers
check "the runner is no longer enabled at boot" test ! -e /etc/runlevels/default/fake-systemd-timers
wait_for "the runner is stopped" 10 sh -c '! pgrep -f "[f]ake-systemd --timers" >/dev/null'

# --- User services in an OpenRC user session, as the user service of openrc-user starts one ------------
echo "tester:x:1000:1000::/home/tester:/bin/sh" >>/etc/passwd
echo "tester:x:1000:" >>/etc/group
mkdir -p /home/tester /run/user/1000
chown 1000:1000 /home/tester /run/user/1000
chmod 700 /run/user/1000
check "the user service of OpenRC is installed" test -e /etc/init.d/user
as_tester sh /usr/libexec/rc/sh/openrc-user.sh start 3>/dev/null >/tmp/openrc-user.log 2>&1
check "a user session of OpenRC is up" test -e /run/user/1000/openrc/softlevel
cat >/usr/lib/systemd/user/e2e-user.service <<'X'
[Service]
ExecStart=/bin/sleep 1000
Restart=on-failure

[Install]
WantedBy=default.target
X
expect "user enable --now succeeds" 0 "" as_tester systemctl --user enable --now e2e-user
check "the user script is generated in the personal directory" test -e /home/tester/.config/rc/init.d/e2e-user
check "the user link is in the runlevels of the user" test "$(readlink /home/tester/.config/rc/runlevels/default/e2e-user)" = /home/tester/.config/rc/init.d/e2e-user
wait_for "the session's OpenRC runs the service" 10 sh -c 'as_tester() { setpriv --reuid=tester --regid=tester --init-groups env HOME=/home/tester XDG_RUNTIME_DIR=/run/user/1000 PATH="$PATH" "$@"; }; as_tester rc-service --user e2e-user status'
expect "user is-active answers active" 0 "active" as_tester systemctl --user is-active e2e-user
check "the user service runs as the user" sh -c 'test "$(stat -c %U /proc/$(cat /run/user/1000/openrc/options/e2e-user/child_pid))" = tester'
wait_for "the user logger writes below the state directory" 5 test -d /home/tester/.local/state/fake-systemd/log/e2e-user.service
expect "user stop succeeds" 0 "" as_tester systemctl --user stop e2e-user
expect "user disable succeeds" 0 "" as_tester systemctl --user disable e2e-user
check "the user link is removed" test ! -e /home/tester/.config/rc/runlevels/default/e2e-user

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
