#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh online|boot|offline
#   online   66 is PID 1 (`66 boot -c`) and the whole lifecycle is driven through systemctl
#   boot     the same container after a restart: what was enabled has been started by the boot
#   offline  no init runs, as in a chroot or a container build
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
mode=${1:?}
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

# is_pid VALUE  (a number above 1)
is_pid() { case $1 in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 1 ]; }
# alive PID, gone PID, changed PID OTHER  (an empty or non-numeric value fails instead of passing)
alive() { is_pid "$1" && kill -0 "$1" 2>/dev/null; }
gone() { is_pid "$1" && ! kill -0 "$1" 2>/dev/null; }
changed() { is_pid "$1" && is_pid "$2" && [ "$1" != "$2" ]; }

# active NAME STATE  (systemctl is-active prints STATE)
active() { systemctl is-active "$1" | grep -q "^$2\$"; }
# s66enabled NAME  (66 says the service is enabled)
s66enabled() { [ "$(66 status -nf enabled "$1" 2>/dev/null | head -n 1)" = yes ]; }
# s66state NAME STATE  (the runtime record of 66)
s66state() { [ "$(66 runstate -nf state "$1" 2>/dev/null | head -n 1)" = "$2" ]; }
s66pid() { 66 runstate -nf pid "$1" 2>/dev/null | head -n 1; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/lib/systemd/user /usr/local/bin
echo "# $(66 version 2>&1) $(execlineb -h 2>&1 | head -n 1)"

# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }

if [ "$mode" = offline ]; then
    # --- No init runs: a chroot or a container build -------------------------------------------
    check "PID 1 is not 66" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" != 66-scandir'
    expect "the backend is 66, found from its tool" 0 "backend: 66" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    check "the frontend file was generated" grep -q "^# Generated automatically by fake-systemd" /usr/share/66/service/e2e-off
    check "66 enabled the service in its default tree" s66enabled e2e-off
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    expect "start offline only says so" 0 "" systemctl start e2e-off
    refute "nothing was started" pgrep -f "[s]leep 1000"
    expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-off
    expect "daemon-reload offline succeeds" 0 "" systemctl daemon-reload
    expect "enable --now offline enables and starts nothing" 0 "" systemctl enable --now e2e-off
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off
    refute "66 agrees the service is disabled" s66enabled e2e-off
    check "the frontend file stays, as the unit does" test -e /usr/share/66/service/e2e-off

    # A root that is not the running one: 66 keeps its state in compiled files and cannot be run there.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/usr/share/66/service $r/etc $r/usr/bin
    cp /etc/os-release $r/etc/os-release
    cp /bin/true $r/usr/bin/true
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root is refused with the reason" 1 "" env FAKE_SYSTEMD_INIT=66 systemctl --root=$r enable e2e-root
    check "the frontend file was written to the other root" grep -q "^# Generated automatically by fake-systemd" $r/usr/share/66/service/e2e-root
    check "nothing was parsed in the running root" test ! -e /var/lib/66/system/.resolve/service/e2e-root
    expect "is-enabled in the other root answers disabled" 1 "disabled" env FAKE_SYSTEMD_INIT=66 systemctl --root=$r is-enabled e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

if [ "$mode" = boot ]; then
    # --- After a restart of the container: 66 booted and started what was enabled ----------------
    check "PID 1 is the scanner of 66" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" = 66-scandir'
    expect "the backend is 66" 0 "backend: 66" systemctl --version
    expect "a service enabled before is active" 0 "active" systemctl is-active e2e-boot
    expect "a service whose requirement was not enabled is active" 0 "active" systemctl is-active e2e-dep-b
    expect "the requirement was started with it, though it is not enabled" 0 "active" systemctl is-active e2e-dep-a
    expect "the requirement is not enabled" 1 "disabled" systemctl is-enabled e2e-dep-a
    expect "a oneshot with RemainAfterExit= is active after the boot" 0 "active" systemctl is-active e2e-boot-once
    check "its command ran at the boot" test "$(cat /tmp/e2e-boot-once-ran 2>/dev/null)" = ran
    expect "a service that was disabled is not active" 3 "inactive" systemctl is-active e2e-never
    expect "the enabled service is still enabled" 0 "enabled" systemctl is-enabled e2e-boot
    wait_for "the output of a service reached the uniform log after the boot" 5 grep -q e2e-boot-hello /var/log/fake-systemd/e2e-boot.service/current
    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- 66 is PID 1 ------------------------------------------------------------------------------------
check "PID 1 is the scanner of 66" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" = 66-scandir'
expect "the backend is 66" 0 "backend: 66" systemctl --version

# --- Lifecycle -------------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sh -c "echo e2e-hello; exec sleep 1000"'
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
check "the frontend file carries the marker" grep -q "^# Generated automatically by fake-systemd" /usr/share/66/service/e2e-sleeper
check "66 parsed it in the default tree" sh -c '66 status -nf tree e2e-sleeper | grep -qx global'
check "66 enabled it" s66enabled e2e-sleeper
check "66 runs it" s66state e2e-sleeper up
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
check "the main pid is the one 66 supervises" sh -c 'systemctl show -p MainPID e2e-sleeper | grep -qx "MainPID=$(66 runstate -nf pid e2e-sleeper | head -n 1)"'
check "the executor made way for the program: sleep is the supervised process" sh -c 'grep -q sleep /proc/$(66 runstate -nf pid e2e-sleeper | head -n 1)/cmdline'
wait_for "the output of the service reached the uniform log" 5 grep -q e2e-hello /var/log/fake-systemd/e2e-sleeper.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-hello" journalctl -u e2e-sleeper.service --no-pager
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "66 says the service is down" s66state e2e-sleeper down
check "stopping an enabled service keeps it enabled" s66enabled e2e-sleeper
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
first_pid=$(s66pid e2e-sleeper)
check "the service has a pid" is_pid "$first_pid"
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
check "restart started a new process" changed "$(s66pid e2e-sleeper)" "$first_pid"
expect "start of a running service succeeds" 0 "" systemctl start e2e-sleeper
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service without Restart= reads failed" 5 active e2e-sleeper failed
expect "is-failed answers 0 for it" 0 "failed" systemctl is-failed e2e-sleeper
expect "stop of a failed service leaves it inactive" 0 "" systemctl stop e2e-sleeper
expect "it is inactive after the stop" 3 "inactive" systemctl is-active e2e-sleeper
expect "start of a stopped service starts it again" 0 "" systemctl start e2e-sleeper
expect "the service is active again" 0 "active" systemctl is-active e2e-sleeper
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "a disabled service keeps running until it is stopped" 0 "active" systemctl is-active e2e-sleeper
expect "stop succeeds again" 0 "" systemctl stop e2e-sleeper

# --- Restart= -----------------------------------------------------------------------------------------
unit e2e-always 'ExecStart=/bin/sleep 1000
Restart=always'
expect "a service with Restart=always starts" 0 "" systemctl start e2e-always
pid=$(s66pid e2e-always)
check "the service has a pid" is_pid "$pid"
expect "kill -s KILL ends the process" 0 "" systemctl kill -s KILL e2e-always
wait_for "66 starts the service again" 15 sh -c "p=\$(66 runstate -nf pid e2e-always | head -n 1); [ -n \"\$p\" ] && [ \"\$p\" != 0 ] && [ \"\$p\" != $pid ]"
expect "it is active again" 0 "active" systemctl is-active e2e-always
expect "stop leaves it down: a restart is not a reason to start again" 0 "" systemctl stop e2e-always
sleep 3
expect "it stayed inactive" 3 "inactive" systemctl is-active e2e-always

unit e2e-onfail 'ExecStart=/bin/sh -c "echo run >> /tmp/e2e-onfail-runs; sleep 1; exit 3"
Restart=on-failure
RestartSec=1'
expect "a service with Restart=on-failure starts" 0 "" systemctl start e2e-onfail
wait_for "it fails and is started again" 20 sh -c '[ "$(grep -c run /tmp/e2e-onfail-runs)" -ge 2 ]'
expect "stop succeeds" 0 "" systemctl stop e2e-onfail
expect "it is inactive" 3 "inactive" systemctl is-active e2e-onfail

unit e2e-no3 'ExecStart=/bin/sh -c "sleep 1; exit 3"'
expect "a service that exits with 3 starts" 0 "" systemctl start e2e-no3
wait_for "it ends and reads failed" 10 active e2e-no3 failed
expect "is-failed answers 0" 0 "failed" systemctl is-failed e2e-no3
unit e2e-ok3 'ExecStart=/bin/sh -c "sleep 1; exit 3"
SuccessExitStatus=3'
expect "a service whose exit status 3 is a success starts" 0 "" systemctl start e2e-ok3
wait_for "it ends and reads inactive" 10 active e2e-ok3 inactive
unit e2e-ok0 'ExecStart=/bin/sh -c "sleep 1"'
expect "a service that exits with 0 starts" 0 "" systemctl start e2e-ok0
wait_for "it ends and reads inactive" 10 active e2e-ok0 inactive

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

# --- Oneshots --------------------------------------------------------------------------------------------
unit e2e-once 'Type=oneshot
ExecStart=/bin/sh -c "echo e2e-once-output; touch /tmp/e2e-once-ran"'
expect "a oneshot starts" 0 "" systemctl start e2e-once
check "the oneshot ran" test -e /tmp/e2e-once-ran
expect "a finished oneshot is inactive" 3 "inactive" systemctl is-active e2e-once
expect "journalctl -u shows the output of the oneshot" 0 "e2e-once-output" journalctl -u e2e-once.service --no-pager
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
expect "a oneshot that fails makes start fail" 1 "" systemctl start e2e-bad
expect "is-failed answers 0 for it" 0 "failed" systemctl is-failed e2e-bad
expect "stop forgets the failure" 0 "" systemctl stop e2e-bad
expect "it is inactive" 3 "inactive" systemctl is-active e2e-bad

# --- Dependencies -----------------------------------------------------------------------------------------
unit e2e-dep-a 'ExecStart=/bin/sleep 1000'
unit e2e-dep-b 'ExecStart=/bin/sleep 1000
Requires=e2e-dep-a.service'
printf '[Unit]\nRequires=e2e-dep-a.service\nAfter=e2e-dep-a.service\n\n[Service]\nExecStart=/bin/sleep 1000\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-dep-b.service
expect "start of a service starts what it requires" 0 "" systemctl start e2e-dep-b
expect "the requirement is active" 0 "active" systemctl is-active e2e-dep-a
check "the frontend file names the requirement" grep -q '^Depends = ( e2e-dep-a )$' /usr/share/66/service/e2e-dep-b
expect "stop of the requirement stops the service that needs it" 0 "" systemctl stop e2e-dep-a
expect "the dependent service is inactive" 3 "inactive" systemctl is-active e2e-dep-b
expect "enable of the dependent service" 0 "" systemctl enable e2e-dep-b
expect "the requirement is not enabled with it" 1 "disabled" systemctl is-enabled e2e-dep-a
expect "the dependent service is enabled" 0 "enabled" systemctl is-enabled e2e-dep-b
expect "disable of the requirement does not disable what needs it" 0 "" systemctl disable e2e-dep-a
expect "the dependent service stays enabled" 0 "enabled" systemctl is-enabled e2e-dep-b

# --- ExecStop=, timeouts, signals and what the executor applies --------------------------------------
unit e2e-hook 'ExecStart=/bin/sleep 1000
ExecStop=/bin/touch /tmp/e2e-hook-stop
ExecStopPost=/bin/touch /tmp/e2e-hook-post'
expect "a service with ExecStop= starts" 0 "" systemctl start e2e-hook
expect "stop succeeds" 0 "" systemctl stop e2e-hook
check "ExecStop= ran" test -e /tmp/e2e-hook-stop
check "ExecStopPost= ran" test -e /tmp/e2e-hook-post
cat >/usr/local/bin/e2e-stubborn <<'X'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-stubborn
unit e2e-stubborn 'ExecStart=/usr/local/bin/e2e-stubborn
TimeoutStopSec=2'
expect "the stubborn service starts" 0 "" systemctl start e2e-stubborn
began=$(date +%s)
expect "stop kills a service that ignores TERM after TimeoutStopSec=" 0 "" systemctl stop e2e-stubborn
check "it did not wait for the default of 90 seconds" test $(($(date +%s) - began)) -lt 30
expect "the stubborn service is gone" 3 "" systemctl is-active e2e-stubborn
cat >/usr/local/bin/e2e-signals <<'X'
#!/bin/sh
trap 'touch /tmp/e2e-hup' HUP
trap 'touch /tmp/e2e-usr1' USR1
touch /tmp/e2e-signals-ready
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-signals
unit e2e-signals 'ExecStart=/usr/local/bin/e2e-signals'
rm -f /tmp/e2e-signals-ready
expect "a signal-handling service starts" 0 "" systemctl start e2e-signals
wait_for "it installed its signal handlers" 30 test -e /tmp/e2e-signals-ready
expect "kill -s HUP goes through 66 signal" 0 "" systemctl kill -s HUP e2e-signals
wait_for "the service got SIGHUP" 5 test -e /tmp/e2e-hup
expect "kill -s SIGUSR1 goes through 66 signal" 0 "" systemctl kill -s SIGUSR1 e2e-signals
wait_for "the service got SIGUSR1" 5 test -e /tmp/e2e-usr1
expect "stop succeeds" 0 "" systemctl stop e2e-signals
unit e2e-reload 'ExecStart=/bin/sleep 1000
ExecReload=/bin/sh -c "echo $MAINPID > /tmp/e2e-reload-pid"'
expect "a service with ExecReload= starts" 0 "" systemctl start e2e-reload
expect "reload runs ExecReload=" 0 "" systemctl reload e2e-reload
check "ExecReload= got the main pid" test "$(cat /tmp/e2e-reload-pid)" = "$(s66pid e2e-reload)"
expect "stop succeeds" 0 "" systemctl stop e2e-reload
printf '#!/bin/sh\nid -un >/tmp/e2e-user-id\nexec sleep 1000\n' >/usr/local/bin/e2e-whoami
chmod 755 /usr/local/bin/e2e-whoami
unit e2e-nobody 'ExecStart=/usr/local/bin/e2e-whoami
User=nobody
Environment=E2E_VAR=value'
expect "a service with User= starts" 0 "" systemctl start e2e-nobody
wait_for "it runs as that user" 5 sh -c 'test "$(cat /tmp/e2e-user-id)" = nobody'
expect "stop succeeds" 0 "" systemctl stop e2e-nobody

# --- A service the system already has --------------------------------------------------------------------
# The program is the one of no other service: a unit is taken for the native service that runs the same one.
cat >/usr/local/bin/e2e-native <<'X'
#!/bin/sh
trap 'touch /tmp/e2e-nat-hup' HUP
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-native
cat >/usr/share/66/service/e2e-nat <<'X'
[Main]
Type = classic
Description = "native service"
Options = ( !log )

[Start]
Execute = ( /usr/local/bin/e2e-native )
X
unit e2e-nat 'ExecStart=/usr/local/bin/e2e-native'
expect "enable --now uses the native service" 0 "" systemctl enable --now e2e-nat
check "nothing was generated over the native service" sh -c '! grep -q "Generated automatically" /usr/share/66/service/e2e-nat'
expect "the native service is active" 0 "active" systemctl is-active e2e-nat
expect "reload of a native service sends SIGHUP" 0 "" systemctl reload e2e-nat
wait_for "the native service got SIGHUP" 5 test -e /tmp/e2e-nat-hup
expect "disable and stop the native service" 0 "" sh -c 'systemctl disable e2e-nat && systemctl stop e2e-nat'
rm /usr/share/66/service/e2e-nat

# --- Generated frontend files parse in 66 --------------------------------------------------------------
for dep in dbus postgresql syslog; do
    printf '[Main]\nType = classic\nOptions = ( !log )\n\n[Start]\nExecute = ( /usr/local/bin/e2e-dummy-%s )\n' "$dep" >"/etc/66/service/$dep"
done
for f in /golden/*.66; do
    n=$(basename "$f" .66)
    [ "$n" = user-unit ] && continue
    cp "$f" "/etc/66/service/e2e-golden-$n"
    check "golden $n is a frontend file 66 parses" 66 parse "e2e-golden-$n"
    check "66 reads it as a service with the command of the executor" sh -c "66 resolve -f run_user e2e-golden-$n | grep -q 'fake-systemd --exec'"
done
check "golden user-ldap gives the executor the numeric ids of the account" grep -q -- '^exec /usr/bin/fake-systemd --exec user-ldap.service --log --uid "$(id -u -- svc-directory)"' /golden/user-ldap.66

# --- An account only the system libc resolves: the start script gives the executor numeric ids ---------
printf '#!/bin/sh\nid >/tmp/e2e-ldap-id\nexec sleep 1000\n' >/usr/local/bin/dirsync
chmod 755 /usr/local/bin/dirsync
unit e2e-ldap 'ExecStart=/usr/local/bin/dirsync
User=svc-directory
Group=svc-directory
SupplementaryGroups=e2eextra'
expect "a unit for an account nobody lists is translated" 0 "" systemctl enable e2e-ldap
cat >/tmp/e2e-want-ids <<'X'
exec /usr/bin/fake-systemd --exec e2e-ldap.service --log --uid "$(id -u -- svc-directory)" --gid "$(getent group svc-directory | cut -d: -f3)" --groups "$(id -G -- svc-directory | tr ' ' ,),$(getent group e2eextra | cut -d: -f3)"
X
check "the frontend file gives the executor the numeric ids" grep -qxFf /tmp/e2e-want-ids /usr/share/66/service/e2e-ldap
echo "svc-directory:x:1500:1500::/home/svc:/bin/sh" >>/etc/passwd
echo "svc-directory:x:1500:" >>/etc/group
echo "e2eextra:x:1501:svc-directory" >>/etc/group
# systemctl would translate the unit again, now that the account is listed, and the executor would switch it; 66 runs the generated file as it is.
expect "the generated file starts the service as the account" 0 "" 66 start e2e-ldap
wait_for "it runs" 10 test -s /tmp/e2e-ldap-id
check "the account has its primary group" grep -q 'uid=1500(svc-directory) gid=1500(svc-directory)' /tmp/e2e-ldap-id
check "the account has its supplementary group" grep -q '1501(e2eextra)' /tmp/e2e-ldap-id
wait_for "its log directory exists, root's" 5 sh -c 'test "$(stat -c %U /var/log/fake-systemd/e2e-ldap.service)" = root'
expect "stop succeeds" 0 "" 66 stop e2e-ldap
expect "disable succeeds" 0 "" systemctl disable e2e-ldap

# --- Instances and names 66 would take for identifiers ---------------------------------------------------------
printf '[Unit]\nDescription=Instance %%i\n[Service]\nExecStart=/bin/sh -c "echo instance-%%i; exec sleep 1000"\n[Install]\nWantedBy=multi-user.target\n' >'/usr/lib/systemd/system/e2e-tpl@.service'
expect "an instance starts" 0 "" systemctl start e2e-tpl@Home
check "its service is named after the template and the instance" test -e /usr/share/66/service/e2e-tpl-Home
check "the instance name was kept from 66's identifiers" sh -c '! grep -v "^#" /usr/share/66/service/e2e-tpl-Home | grep -q "@H"'
expect "the instance is active" 0 "active" systemctl is-active e2e-tpl@Home
wait_for "its output reached the log of the instance" 5 grep -q instance-Home /var/log/fake-systemd/e2e-tpl@Home.service/current
expect "stop succeeds" 0 "" systemctl stop e2e-tpl@Home

# --- A frontend file that changed is parsed again ---------------------------------------------------------------------
unit e2e-regen 'ExecStart=/bin/sh -c "echo regen-one >> /tmp/e2e-regen; exec sleep 1000"'
expect "a service is enabled and started" 0 "" systemctl enable --now e2e-regen
wait_for "the first version ran" 5 grep -q regen-one /tmp/e2e-regen
expect "stop succeeds" 0 "" systemctl stop e2e-regen
sleep 1
unit e2e-regen 'ExecStart=/bin/sh -c "echo regen-two >> /tmp/e2e-regen; exec sleep 1000"'
expect "daemon-reload picks the new unit up" 0 "" systemctl daemon-reload
expect "the service is still enabled after it was parsed again" 0 "enabled" systemctl is-enabled e2e-regen
check "66 still has it enabled" s66enabled e2e-regen
expect "start runs the new version" 0 "" systemctl start e2e-regen
wait_for "the second version ran" 5 grep -q regen-two /tmp/e2e-regen
expect "stop succeeds" 0 "" systemctl stop e2e-regen
rm /usr/lib/systemd/system/e2e-regen.service
expect "daemon-reload drops what lost its unit" 0 "" systemctl daemon-reload
check "66 no longer knows the service" test ! -e /var/lib/66/system/.resolve/service/e2e-regen
check "its frontend file is gone" test ! -e /usr/share/66/service/e2e-regen

# --- Timers: the built-in runner as a 66 service ------------------------------------------------------------------
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
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/66/index
check "the runner service runs the timer runner" grep -q -- "--exec fake-systemd-timers.service --log" /etc/66/service/fake-systemd-timers
wait_for "66 runs the runner" 10 s66state fake-systemd-timers up
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tick.timer
check "the runner unit is removed" test ! -e /etc/systemd/system/fake-systemd-timers.service

# --- What the boot starts ----------------------------------------------------------------------------------------------
unit e2e-boot 'ExecStart=/bin/sh -c "echo e2e-boot-hello; exec sleep 1000"'
expect "a service is enabled without being started" 0 "" systemctl enable e2e-boot
expect "it is inactive" 3 "inactive" systemctl is-active e2e-boot
unit e2e-boot-once 'Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo ran > /tmp/e2e-boot-once-ran"'
expect "a oneshot is enabled without being started" 0 "" systemctl enable e2e-boot-once
unit e2e-never 'ExecStart=/bin/sleep 1000'
printf '[Unit]\nDescription=Stopped at shutdown\n[Service]\nExecStart=/bin/sleep 1000\nExecStop=/bin/touch /out/e2e-shutdown-stop\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-shutdown.service
expect "a service with ExecStop= is enabled and started for the shutdown" 0 "" systemctl enable --now e2e-shutdown
expect "the requirements enabled earlier stay enabled" 0 "enabled" systemctl is-enabled e2e-dep-b

# --- User services: the user has a supervision tree of their own ---------------------------------------------------------
echo "tester:x:1000:1000::/home/tester:/bin/sh" >>/etc/passwd
echo "tester:x:1000:" >>/etc/group
mkdir -p /home/tester /run/user/1000
chown 1000:1000 /home/tester /run/user/1000
cat >/usr/lib/systemd/user/e2e-user.service <<'X'
[Service]
ExecStart=/bin/sh -c "echo e2e-user-hello; exec sleep 1000"

[Install]
WantedBy=default.target
X
# as_tester COMMAND...  (runs the command as the user, with the environment of a session)
as_tester() { su -s /bin/sh tester -c "export HOME=/home/tester XDG_RUNTIME_DIR=/run/user/1000 PATH=/usr/local/bin:/usr/bin:/bin; exec $*"; }
setsid su -s /bin/sh tester -c 'export HOME=/home/tester XDG_RUNTIME_DIR=/run/user/1000 PATH=/usr/local/bin:/usr/bin:/bin; exec 66 scandir start' >/tmp/user-scandir.log 2>&1 &
wait_for "the scandir of the user is up" 10 test -p /run/66/scandir/1000/.66-scandir/control
expect "user enable --now succeeds" 0 "" as_tester systemctl --user enable --now e2e-user
check "the user service is generated in the personal directory" test -e /home/tester/.66/service/e2e-user
expect "user is-active answers active" 0 "active" as_tester systemctl --user is-active e2e-user
upid=$(as_tester 66 runstate -nf pid e2e-user | head -n 1)
check "the user service has a pid" is_pid "$upid"
check "the user service runs as the user" sh -c "ps -o user= -p $upid | grep -qx tester"
wait_for "the user logger writes below the state directory" 5 test -s /home/tester/.local/state/fake-systemd/log/e2e-user.service/current
expect "user stop succeeds" 0 "" as_tester systemctl --user stop e2e-user
expect "user is-active answers inactive" 3 "inactive" as_tester systemctl --user is-active e2e-user
expect "user disable succeeds" 0 "" as_tester systemctl --user disable e2e-user
expect "user is-enabled answers disabled" 1 "disabled" as_tester systemctl --user is-enabled e2e-user

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
