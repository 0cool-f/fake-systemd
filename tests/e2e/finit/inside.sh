#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh online|offline
# `online` runs with finit as PID 1, `offline` where no init runs, as in a chroot or a container build.
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
mode=$1
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

# is_pid VALUE  (a number above 1)
is_pid() { case $1 in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 1 ]; }
# alive PID, gone PID, changed PID OTHER  (an empty or non-numeric value fails instead of passing)
alive() { is_pid "$1" && kill -0 "$1" 2>/dev/null; }
gone() { is_pid "$1" && ! kill -0 "$1" 2>/dev/null; }
changed() { is_pid "$1" && is_pid "$2" && [ "$1" != "$2" ]; }

# active NAME STATE  (systemctl is-active prints STATE)
active() { systemctl is-active "$1" | grep -q "^$2\$"; }
# fstate NAME STATE  (the word `initctl status` prints in its Status line)
fstate() { initctl -p status "$1" 2>/dev/null | sed -n 's/^ *Status : \([a-z]*\).*/\1/p' | grep -qx "$2"; }
# fpid NAME  (the process id `initctl status` prints)
fpid() { initctl -p status "$1" 2>/dev/null | sed -n 's/^ *PID : \([0-9]*\)$/\1/p'; }
# cmdline NAME  (the command line of the main process of the service)
cmdline() { tr "\0" " " <"/proc/$(fpid "$1")/cmdline"; }
# cmdline_has NAME TEXT  (the command line of the main process contains TEXT)
cmdline_has() { cmdline "$1" | grep -q "$2"; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/local/bin
echo "# $(dpkg-query -W -f='${Package} ${Version} ' finit util-linux)"

# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }
# unitx NAME UNITLINES BODY  (a service unit with lines in its [Unit] section)
unitx() { printf '[Unit]\nDescription=%s\n%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" "$3" >"/usr/lib/systemd/system/$1.service"; }

if [ "$mode" = offline ]; then
    # --- No init runs: a chroot or a container build ---------------------------------------------
    check "PID 1 is not finit" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" != finit'
    expect "the backend is finit, found from its tools" 0 "finit" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    check "the file was generated" grep -q "^# Generated automatically by fake-systemd" /etc/finit.d/available/e2e-off.conf
    check "the link is in enabled/" sh -c 'test "$(readlink /etc/finit.d/enabled/e2e-off.conf)" = ../available/e2e-off.conf'
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    expect "start offline only says so" 0 "" systemctl start e2e-off
    check "nothing was started" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
    expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-off
    expect "daemon-reload offline succeeds" 0 "" systemctl daemon-reload
    expect "enable --now offline enables and starts nothing" 0 "" systemctl enable --now e2e-off
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off
    check "the generated file stays" test -e /etc/finit.d/available/e2e-off.conf

    # The dependencies a service waits for are enabled with it.
    unit e2e-base 'ExecStart=/bin/sleep 1000'
    unitx e2e-top 'Requires=e2e-base.service' 'ExecStart=/bin/sleep 1000'
    expect "enable of a service with Requires=" 0 "" systemctl enable e2e-top
    check "the stanza waits for the running state of its dependency" grep -q '<service/e2e-base/running>' /etc/finit.d/available/e2e-top.conf
    check "the dependency is enabled with it" test -L /etc/finit.d/enabled/e2e-base.conf

    # A root that is not the running one: nothing is called, links are relative.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/etc/finit.d $r/usr/bin $r/usr/sbin
    cp /etc/os-release $r/etc/os-release
    cp /bin/true $r/usr/bin/true
    : >$r/usr/sbin/finit
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root succeeds" 0 "" env FAKE_SYSTEMD_INIT=finit systemctl --root=$r enable e2e-root
    check "the file is in the other root" grep -q "^# Generated automatically by fake-systemd" $r/etc/finit.d/available/e2e-root.conf
    check "the link resolves inside that root" test -e $r/etc/finit.d/enabled/e2e-root.conf
    check "nothing was written to the running root" test ! -e /etc/finit.d/available/e2e-root.conf
    expect "is-enabled in the other root answers enabled" 0 "enabled" env FAKE_SYSTEMD_INIT=finit systemctl --root=$r is-enabled e2e-root
    expect "disable in the other root succeeds" 0 "" env FAKE_SYSTEMD_INIT=finit systemctl --root=$r disable e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- An init is running ---------------------------------------------------------------------------
check "PID 1 is finit" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" = finit'
expect "the backend is finit" 0 "finit" systemctl --version
echo "# $(initctl -V | head -n 1)"

# --- Lifecycle -----------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sleep 1000'
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
check "the file carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/finit.d/available/e2e-sleeper.conf
check "the stanza is a finit service of runlevels 2 to 5" grep -q '^service \[2345\] name:e2e-sleeper ' /etc/finit.d/available/e2e-sleeper.conf
check "the link is in enabled/" test -L /etc/finit.d/enabled/e2e-sleeper.conf
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
check "finit runs the service" fstate e2e-sleeper running
check "the service came from the enabled link, not from the volatile directory" test ! -e /run/finit/system/e2e-sleeper.conf
expect "status shows the main process" 0 "Main PID" systemctl status e2e-sleeper
check "status shows the pid finit has" sh -c "systemctl status e2e-sleeper | grep -q 'Main PID: $(fpid e2e-sleeper)'"
check "the main process is the unit command, after the executor replaced itself" cmdline_has e2e-sleeper "sleep 1000"
first_pid=$(fpid e2e-sleeper)
check "the service has a pid" is_pid "$first_pid"
expect "restart succeeds" 0 "" systemctl restart e2e-sleeper
wait_for "restart started a new process" 5 sh -c "p=\$(initctl -p status e2e-sleeper | sed -n 's/^ *PID : \(.*\)/\1/p'); [ -n \"\$p\" ] && [ \"\$p\" != 0 ] && [ \"\$p\" != $first_pid ]"
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
expect "start of a running service succeeds" 0 "" systemctl start e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "finit reports it stopped" fstate e2e-sleeper stopped
check "no process is left" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
check "stopping an enabled service keeps its link" test -L /etc/finit.d/enabled/e2e-sleeper.conf
expect "start of a stopped service" 0 "" systemctl start e2e-sleeper
expect "disable keeps a running service running" 0 "" systemctl disable e2e-sleeper
expect "the service is still active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
check "the link is gone" test ! -e /etc/finit.d/enabled/e2e-sleeper.conf
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable of a disabled service turns the link back" 0 "" systemctl enable e2e-sleeper
expect "is-active answers inactive after enable" 3 "inactive" systemctl is-active e2e-sleeper

# --- A service that is started without being enabled is loaded for the time it runs ---------------
unit e2e-adhoc 'ExecStart=/bin/sleep 1003'
check "finit does not know the service before" sh -c '! initctl -q status e2e-adhoc'
expect "start of a service that was never enabled" 0 "" systemctl start e2e-adhoc
expect "it is active" 0 "active" systemctl is-active e2e-adhoc
check "it was loaded through the volatile directory" test -L /run/finit/system/e2e-adhoc.conf
expect "it is not enabled" 1 "disabled" systemctl is-enabled e2e-adhoc
expect "stop succeeds" 0 "" systemctl stop e2e-adhoc
check "stop unloaded it again" sh -c '! initctl -q status e2e-adhoc'
check "the volatile link is gone" test ! -e /run/finit/system/e2e-adhoc.conf

# --- Exit states ----------------------------------------------------------------------------------
unit e2e-failer 'ExecStart=/bin/sh -c "echo e2e-failer-line; exit 3"'
unit e2e-clean 'ExecStart=/bin/sh -c "echo e2e-clean-output; echo e2e-clean-error >&2; sleep 0.5"'
expect "a service that exits with an error starts" 0 "" systemctl start e2e-failer
wait_for "it reads failed" 5 active e2e-failer failed
expect "is-failed answers 0" 0 "failed" systemctl is-failed e2e-failer
expect "stop resets the failed state" 0 "" systemctl stop e2e-failer
expect "is-active answers inactive after reset" 3 "inactive" systemctl is-active e2e-failer
expect "a service that ends cleanly starts" 0 "" systemctl start e2e-clean
wait_for "a clean exit reads inactive" 5 active e2e-clean inactive
expect "is-failed answers 1 for a clean exit" 1 "inactive" systemctl is-failed e2e-clean
wait_for "stdout reached the uniform log" 5 grep -q e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current
wait_for "so did stderr" 5 grep -q e2e-clean-error /var/log/fake-systemd/e2e-clean.service/current
check "log lines carry an ISO 8601 timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+[+-][0-9:]+ e2e-clean' /var/log/fake-systemd/e2e-clean.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-clean-output" journalctl -u e2e-clean.service --no-pager
expect "stop of a finished service succeeds" 0 "" systemctl stop e2e-clean
unit e2e-killed 'ExecStart=/bin/sleep 1004'
expect "start of a service to kill" 0 "" systemctl start e2e-killed
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-killed
wait_for "a service killed by a signal reads failed" 5 active e2e-killed failed
expect "stop resets it" 0 "" systemctl stop e2e-killed
expect "start of a killed service starts it again" 0 "" systemctl start e2e-killed
expect "it is active again" 0 "active" systemctl is-active e2e-killed
expect "stop succeeds" 0 "" systemctl stop e2e-killed

# --- Restart= is the restart of finit ---------------------------------------------------------------
unit e2e-always 'ExecStart=/bin/sleep 1005
Restart=always
RestartSec=1'
expect "a Restart=always service starts" 0 "" systemctl start e2e-always
check "the stanza restarts without a limit" grep -q ' restart:always restart_sec:1 ' /etc/finit.d/available/e2e-always.conf
old=$(fpid e2e-always)
check "the service has a pid" is_pid "$old"
expect "kill of the main process" 0 "" systemctl kill -s KILL e2e-always
wait_for "finit restarted it with a new process" 10 sh -c "p=\$(initctl -p status e2e-always | sed -n 's/^ *PID : \(.*\)/\1/p'); [ -n \"\$p\" ] && [ \"\$p\" != 0 ] && [ \"\$p\" != $old ]"
expect "it is active again" 0 "active" systemctl is-active e2e-always
expect "stop succeeds" 0 "" systemctl stop e2e-always

# --- Executor: ExecStartPre=, EnvironmentFile= and variable expansion --------------------------------
echo 'E2E_VAR=hello' >/etc/e2e-env
cat >/usr/local/bin/e2e-pre <<'X'
#!/bin/sh
echo "$1" >/tmp/e2e-pre-arg
env >/tmp/e2e-pre-env
exec sleep 1006
X
chmod 755 /usr/local/bin/e2e-pre
unit e2e-pre 'EnvironmentFile=/etc/e2e-env
Environment=E2E_OTHER=two
ExecStartPre=/bin/touch /tmp/e2e-pre-ran
ExecStart=/usr/local/bin/e2e-pre ${E2E_VAR}-${E2E_OTHER}'
expect "a unit with ExecStartPre= starts" 0 "" systemctl start e2e-pre
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
wait_for "variables expand in the command" 5 grep -qx 'hello-two' /tmp/e2e-pre-arg
expect "stop succeeds" 0 "" systemctl stop e2e-pre

# --- ExecStop= runs before the process is terminated, ExecStopPost= after it ended --------------------
unit e2e-hooks 'ExecStart=/bin/sleep 1007
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-stop-alive"
ExecStopPost=/bin/touch /tmp/e2e-post-ran
RuntimeDirectory=e2e-hooks'
expect "a unit with stop hooks starts" 0 "" systemctl start e2e-hooks
check "the stanza stays resident to run ExecStop= on the signal of finit" grep -q -- "--stop-on-signal" /etc/finit.d/available/e2e-hooks.conf
check "the stanza names the script that runs after the stop" grep -q ' post:/etc/finit.d/available/e2e-hooks.stop-post ' /etc/finit.d/available/e2e-hooks.conf
check "the runtime directory exists while it runs" test -d /run/e2e-hooks
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the service process was alive" test -e /tmp/e2e-stop-alive
wait_for "ExecStopPost= ran after the stop" 5 test -e /tmp/e2e-post-ran
wait_for "the runtime directory was removed" 5 test ! -e /run/e2e-hooks
rm -f /tmp/e2e-stop-alive /tmp/e2e-post-ran
expect "start again" 0 "" systemctl start e2e-hooks
expect "initctl stop runs the same stop" 0 "" initctl stop e2e-hooks
wait_for "ExecStop= ran for initctl too" 5 test -e /tmp/e2e-stop-alive
wait_for "ExecStopPost= ran for initctl too" 5 test -e /tmp/e2e-post-ran
expect "stop of the loaded service unloads it" 0 "" systemctl stop e2e-hooks

# --- Type=forking: start returns once the executor has recorded the daemon ---------------------------------------
cat >/usr/local/bin/e2e-slowforker <<'X'
#!/bin/sh
rm -f /run/e2e-slowfork.pid
sleep 1004 </dev/null >/dev/null 2>&1 &
pid=$!
sleep 2
echo $pid >/run/e2e-slowfork.pid
X
chmod 755 /usr/local/bin/e2e-slowforker
unit e2e-slowfork 'Type=forking
PIDFile=/run/e2e-slowfork.pid
ExecStart=/usr/local/bin/e2e-slowforker'
expect "a forking unit whose daemon is slow starts" 0 "" systemctl start e2e-slowfork
check "start returned after the pid file was written" test -s /run/e2e-slowfork.pid
expect "it reads active" 0 "active" systemctl is-active e2e-slowfork
daemon=$(cat /run/e2e-slowfork.pid 2>/dev/null)
check "the slow daemon is alive" alive "$daemon"
rm -f /run/e2e-slowfork.pid
expect "restart of it succeeds" 0 "" systemctl restart e2e-slowfork
check "restart returned after the pid file was written" test -s /run/e2e-slowfork.pid
check "restart started another daemon" changed "$(cat /run/e2e-slowfork.pid 2>/dev/null)" "$daemon"
wait_for "the daemon of the first start is gone" 5 gone "$daemon"
daemon=$(cat /run/e2e-slowfork.pid 2>/dev/null)
expect "stop of it succeeds" 0 "" systemctl stop e2e-slowfork
wait_for "the slow daemon is gone" 5 gone "$daemon"

# --- Reload runs ExecReload= through the executor ------------------------------------------------------
unit e2e-reload 'ExecStart=/bin/sleep 1008
ExecReload=/bin/touch /tmp/e2e-reload-ran'
expect "start of a service with ExecReload=" 0 "" systemctl start e2e-reload
expect "reload succeeds" 0 "" systemctl reload e2e-reload
check "ExecReload= ran" test -e /tmp/e2e-reload-ran
expect "the service was not restarted" 0 "active" systemctl is-active e2e-reload
expect "stop succeeds" 0 "" systemctl stop e2e-reload

# --- Oneshots are tasks ------------------------------------------------------------------------------
printf '[Unit]\nDescription=oneshot\n[Service]\nType=oneshot\nExecStart=/bin/sh -c "echo oneshot-out; touch /tmp/e2e-oneshot-ran"\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-oneshot.service
printf '[Unit]\nDescription=remain\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-remain.service
printf '[Unit]\nDescription=badshot\n[Service]\nType=oneshot\nExecStart=/bin/false\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-badshot.service
expect "a oneshot runs and start waits for it" 0 "" systemctl start e2e-oneshot
check "the stanza is a task" grep -q '^task \[2345\] name:e2e-oneshot ' /etc/finit.d/available/e2e-oneshot.conf
check "the command ran" test -e /tmp/e2e-oneshot-ran
expect "a oneshot without RemainAfterExit= is inactive after it ran" 3 "inactive" systemctl is-active e2e-oneshot
rm -f /tmp/e2e-oneshot-ran
expect "start runs it again" 0 "" systemctl start e2e-oneshot
check "the command ran again" test -e /tmp/e2e-oneshot-ran
wait_for "its output reached the log" 5 grep -q oneshot-out /var/log/fake-systemd/e2e-oneshot.service/current
expect "a oneshot with RemainAfterExit= starts" 0 "" systemctl start e2e-remain
expect "it stays active" 0 "active" systemctl is-active e2e-remain
expect "a failing oneshot fails the start" 1 "" systemctl start e2e-badshot
expect "and reads failed" 3 "failed" systemctl is-active e2e-badshot

# --- Dependencies are conditions --------------------------------------------------------------------
unit e2e-dep 'ExecStart=/bin/sleep 1009'
unitx e2e-main 'Requires=e2e-dep.service
After=e2e-dep.service' 'ExecStart=/bin/sleep 1010'
expect "start of a service with Requires=" 0 "" systemctl start e2e-main
check "the stanza waits for the running state of its dependency" grep -q '<service/e2e-dep/running>' /etc/finit.d/available/e2e-main.conf
expect "the dependency was started with it" 0 "active" systemctl is-active e2e-dep
expect "the service is active" 0 "active" systemctl is-active e2e-main
expect "stop of the dependency" 0 "" systemctl stop e2e-dep
wait_for "the service that needs it stops with it" 10 sh -c '! pgrep -f "[s]leep 1010" >/dev/null'
expect "stop of the service succeeds" 0 "" systemctl stop e2e-main

# --- Accounts: the executor resolves them and applies their groups --------------------------------------
useradd -M -s /usr/sbin/nologin e2eapp
groupadd e2egrp
usermod -a -G e2egrp e2eapp
unit e2e-user 'User=e2eapp
ExecStart=/bin/sh -c "id -un >/tmp/e2e-user-name; id -Gn >/tmp/e2e-user-groups; exec sleep 1011"'
expect "a service with User= starts" 0 "" systemctl start e2e-user
check "the stanza has no @user: the executor switches" sh -c '! grep -q " @" /etc/finit.d/available/e2e-user.conf'
wait_for "it runs as the account" 5 grep -qx e2eapp /tmp/e2e-user-name
wait_for "with the groups of the account" 5 grep -qw e2egrp /tmp/e2e-user-groups
expect "stop succeeds" 0 "" systemctl stop e2e-user

# --- An account only the system libc knows (LDAP, sssd) is given to the executor as numeric ids -----------
mkdir -p /var/lib/extrausers
echo 'ldaplike:x:2500:2500:ldap like:/:/usr/sbin/nologin' >/var/lib/extrausers/passwd
printf 'ldapgrp:x:2500:\nldapsup:x:2600:ldaplike\n' >/var/lib/extrausers/group
: >/var/lib/extrausers/shadow
sed -i 's/^passwd:.*/passwd: files extrausers/; s/^group:.*/group: files extrausers/' /etc/nsswitch.conf
unit e2e-ldap 'User=ldaplike
ExecStart=/bin/sh -c "id -un >/tmp/e2e-ldap-name; id -gn >/tmp/e2e-ldap-group; id -Gn >/tmp/e2e-ldap-groups; exec sleep 1018"
ExecReload=/bin/sh -c "id -un >/tmp/e2e-ldap-reload"'
expect "a service whose account is not in /etc/passwd starts" 0 "" systemctl start e2e-ldap
check "the file runs the executor through a script that looks the ids of the account up" grep -q -- '--uid "$(id -u -- ldaplike)"' /etc/finit.d/available/e2e-ldap.exec
wait_for "it runs as the account" 5 grep -qx ldaplike /tmp/e2e-ldap-name
wait_for "with its primary group" 5 grep -qx ldapgrp /tmp/e2e-ldap-group
wait_for "and its supplementary groups" 5 grep -qw ldapsup /tmp/e2e-ldap-groups
expect "reload carries the same ids" 0 "" systemctl reload e2e-ldap
wait_for "ExecReload= ran as the account" 5 grep -qx ldaplike /tmp/e2e-ldap-reload
expect "stop succeeds" 0 "" systemctl stop e2e-ldap

# --- A timer job of that account runs as the account, and the unit settings cannot steer the executor ------
printf '[Unit]\nDescription=e2e-ldap-job\n[Service]\nType=oneshot\nUser=ldaplike\nExecStart=/bin/sh -c "id -un >/tmp/e2e-ldap-job"\n' >/usr/lib/systemd/system/e2e-ldap-job.service
printf '[Timer]\nOnCalendar=daily\n' >/usr/lib/systemd/system/e2e-ldap-job.timer
expect "a timer job of an account only the system libc knows runs" 0 "" fake-systemd --run-job e2e-ldap-job.service --timer e2e-ldap-job.timer
check "as that account, not as root" grep -qx ldaplike /tmp/e2e-ldap-job
unit e2e-dash 'User=-r
ExecStart=/bin/sleep 1019'
expect "a User= that starts with a dash is refused" 1 "" systemctl enable e2e-dash
check "no stanza was generated for it" sh -c '! test -e /etc/finit.d/available/e2e-dash.conf'
unit e2e-takeover 'ExecStart=/bin/true
StateDirectory=fake-systemd/finit'
expect "a unit cannot take over the state of fake-systemd" 238 "" fake-systemd --exec e2e-takeover.service

# --- Native services win --------------------------------------------------------------------------------
printf '#!/bin/sh\nexec sleep 1012\n' >/usr/local/bin/e2e-nat
chmod 755 /usr/local/bin/e2e-nat
printf 'service [2345] name:e2enative /usr/local/bin/e2e-nat -- native\n' >/etc/finit.d/available/e2enative.conf
printf '[Unit]\nDescription=native twin\n[Service]\nExecStart=/usr/local/bin/e2e-nat\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2enative.service
expect "enable uses the native service" 0 "" systemctl enable e2enative
check "nothing was generated" sh -c '! grep -q "Generated automatically" /etc/finit.d/available/e2enative.conf'
check "the native file is linked" test -L /etc/finit.d/enabled/e2enative.conf
expect "start uses the identity of the native service" 0 "" systemctl start e2enative
expect "it is active" 0 "active" systemctl is-active e2enative
expect "stop succeeds" 0 "" systemctl stop e2enative

# --- Templates --------------------------------------------------------------------------------------------
printf '[Unit]\nDescription=template %%i\n[Service]\nExecStart=/bin/sleep 1013\n[Install]\nWantedBy=multi-user.target\n' >'/usr/lib/systemd/system/e2e-tpl@.service'
expect "an instance starts" 0 "" systemctl start e2e-tpl@one.service
check "it is a service named name-instance" grep -q 'name:e2e-tpl-one ' /etc/finit.d/available/e2e-tpl-one.conf
expect "it is active" 0 "active" systemctl is-active e2e-tpl@one.service
expect "stop succeeds" 0 "" systemctl stop e2e-tpl@one.service

# --- daemon-reload and regeneration ----------------------------------------------------------------------
unit e2e-regen 'ExecStart=/bin/sleep 1014'
expect "enable --now of a service to change" 0 "" systemctl enable --now e2e-regen
check "it runs the first command" cmdline_has e2e-regen "sleep 1014"
unit e2e-regen 'ExecStart=/bin/sleep 1015'
expect "daemon-reload regenerates the file and has finit read it" 0 "" systemctl daemon-reload
check "the file has the new command through the executor" grep -q 'e2e-regen.service' /etc/finit.d/available/e2e-regen.conf
expect "restart picks the change up" 0 "" systemctl restart e2e-regen
wait_for "the service runs the new command" 5 cmdline_has e2e-regen "sleep 1015"
expect "disable --now stops and disables" 0 "" systemctl disable --now e2e-regen
expect "it is inactive" 3 "inactive" systemctl is-active e2e-regen

# --- Timers: the built-in runner is a finit service ------------------------------------------------------
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
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/finit/index
check "the runner unit is translated like any unit" grep -q ' --exec fake-systemd-timers.service ' /etc/finit.d/available/fake-systemd-timers.conf
check "the runner is enabled at boot" test -L /etc/finit.d/enabled/fake-systemd-timers.conf
wait_for "finit runs the runner" 10 fstate fake-systemd-timers running
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "is-active answers active for the timer" 0 "active" systemctl is-active e2e-tick.timer
expect "disable of the timer succeeds" 0 "" systemctl disable e2e-tick.timer
expect "the runner is stopped when no timer needs it" 3 "inactive" systemctl is-active fake-systemd-timers

# --- The goldens of the corpus are what finit reads --------------------------------------------------------
for g in /golden/*.finit; do
    awk -v dir=/etc/finit.d/available '
        /^=== / { if (out) close(out); out = dir "/" $2; next }
        { print > out }
    ' "$g"
done
chmod 755 /etc/finit.d/available/*.stop-post /etc/finit.d/available/*.exec
names=
for g in /golden/*.finit; do
    n=$(basename "$g" .finit)
    # The units are not installed, so the services are loaded but not started.
    sed -i "s/^\(service\|task\) \[2345\]/\1 [2345] manual:yes/" "/etc/finit.d/available/$n.conf"
    ln -sf "../available/$n.conf" "/etc/finit.d/enabled/$n.conf"
    names="$names $n"
done
initctl reload
sleep 2
for n in $names; do
    check "golden $n is read by finit" sh -c "initctl -p status $n | grep -q 'Command : .* --exec '"
done
check "golden deps-mix keeps its start conditions" sh -c 'initctl -p status deps-mix | grep -q "Condition(s): <.*service/dbus/running"'
check "golden restart-always has the restart policy of finit" sh -c 'initctl -p status restart-always | grep -q "Restarts : .* (.*/-1)"'
check "golden reload-stop has its stop-post script" sh -c 'test -x /etc/finit.d/available/reload-stop.stop-post && sh -n /etc/finit.d/available/reload-stop.stop-post'
for n in $names; do rm -f "/etc/finit.d/enabled/$n.conf"; done
initctl reload
sleep 1


# --- A shutdown stops the services through the signal of finit, ExecStop= included ---------------------------
unit e2e-shutdown 'ExecStart=/bin/sleep 1017
ExecStop=/bin/touch /out/e2e-shutdown-stop'
expect "enable --now of the service that a shutdown stops" 0 "" systemctl enable --now e2e-shutdown
expect "it is active" 0 "active" systemctl is-active e2e-shutdown
sleep 3
check "finit is still running" initctl -p status keventd

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
