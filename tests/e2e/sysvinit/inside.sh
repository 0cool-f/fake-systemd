#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh devuan|debian|redhat|redhat9 online|offline
# `online` runs with an init (sysvinit as PID 1; on Red Hat its control socket stands in for one),
# `offline` runs where none is, as in a chroot or a container build.
export PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
case $1 in
    redhat9) family=redhat ;;
    *) family=$1 ;;
esac
mode=$2
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

case $family in
    redhat) rc_base=/etc/rc.d level=3 ;;
    *) rc_base=/etc level=2 ;;
esac
rcd() { echo "$rc_base/rc$1.d"; }
# slink NAME  (a start link in the default runlevel)
slink() { ls "$(rcd $level)"/S??"$1" >/dev/null 2>&1; }
# klink NAME LEVEL  (a stop link)
klink() { ls "$(rcd "$2")"/K??"$1" >/dev/null 2>&1; }
# number NAME  (the number of the start link in the default runlevel)
number() { ls "$(rcd $level)" | sed -n "s/^S\([0-9][0-9]\)$1\$/\1/p" | sed 's/^0//'; }
# active NAME STATE  (systemctl is-active prints STATE)
active() { systemctl is-active "$1" | grep -q "^$2\$"; }
# lsbstate NAME CODE  (the status action exits with CODE: 0 running, 1 dead with a pid file, 3 not running)
lsbstate() { /etc/init.d/"$1" status >/dev/null 2>&1; [ $? -eq "$2" ]; }
count() { [ -e "$1" ] && wc -l <"$1" | tr -d ' '; }
# update_ok NAME  (update-rc.d accepts the header: exit 0 and no complaint of insserv)
update_ok() {
    out=$(env _SKIP_SYSTEMD_NATIVE=1 update-rc.d "$1" defaults 2>&1)
    rc=$?
    [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -Eq 'FATAL|broken|missing|loop'
}
# insserv_ok [NAME]  (insserv accepts the headers: no error, no warning about a broken header)
insserv_ok() {
    out=$(insserv "$@" 2>&1)
    rc=$?
    [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -Eq 'FATAL|broken|missing|loop'
}

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/local/bin
if [ "$family" = redhat ]; then
    echo "# $(rpm -q chkconfig initscripts | tr '\n' ' ')"
else
    echo "# $(dpkg-query -W -f='${Package} ${Version} ' sysvinit-core insserv dpkg)"
fi

# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }

if [ "$mode" = offline ]; then
    # --- No init runs: a chroot or a container build ---------------------------------------------
    check "PID 1 is not an init" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" != init'
    # The images of Devuan and Debian may keep the socket of sysvinit where none runs.
    [ -p /run/initctl ] || mkfifo /run/initctl
    expect "the backend is sysvinit, found from its tools" 0 "sysvinit" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    check "the script was generated" grep -q "^# Generated automatically by fake-systemd" /etc/init.d/e2e-off
    check "the tool of the family wrote the start link of the default runlevel" slink e2e-off
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    expect "start offline only says so" 0 "" systemctl start e2e-off
    check "nothing was started, though the socket of sysvinit is there" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
    expect "is-active answers inactive: the socket without an init as PID 1 is no running init" 3 "inactive" systemctl is-active e2e-off
    if [ "$family" != redhat ]; then
        # policy-rc.d is what invoke-rc.d asks in a chroot or an image; systemctl does not.
        printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
        chmod 755 /usr/sbin/policy-rc.d
        expect "policy-rc.d denies invoke-rc.d" 101 "" invoke-rc.d --query e2e-off start
        expect "it has no say in the enable of fake-systemd" 0 "" systemctl enable e2e-off
        expect "nor in the disable" 0 "" systemctl disable e2e-off
    fi
    expect "daemon-reload offline succeeds" 0 "" systemctl daemon-reload
    expect "enable --now offline enables and starts nothing" 0 "" systemctl enable --now e2e-off
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off
    check "no start link is left in the default runlevel" sh -c "! ls $(rcd $level)/S??e2e-off"

    # Without the tool the links are written directly, and the tool takes them over later.
    tool=/usr/sbin/update-rc.d
    [ "$family" != redhat ] || tool=/usr/sbin/chkconfig
    mv "$tool" "$tool.off"
    unit e2e-direct 'ExecStart=/bin/sleep 1000'
    expect "enable without the tool succeeds" 0 "" systemctl enable e2e-direct
    check "the start link has the number of the late priority" test -L "$(rcd $level)/S80e2e-direct"
    check "the stop link of runlevel 6 has the number of the early priority" test -L "$(rcd 6)/K20e2e-direct"
    check "the links point at the script" sh -c "test \"\$(readlink $(rcd $level)/S80e2e-direct)\" = ../init.d/e2e-direct"
    mv "$tool.off" "$tool"
    if [ "$family" = redhat ]; then
        check "chkconfig reads the links as the start in the default runlevel" chkconfig --level 3 e2e-direct
        check "chkconfig can take the priorities over from the header" env SYSTEMCTL_SKIP_REDIRECT=1 chkconfig e2e-direct resetpriorities
    else
        check "insserv accepts the direct links and orders them" insserv_ok e2e-direct
        check "the start link is still in the default runlevel" slink e2e-direct
    fi
    expect "disable of the direct links succeeds" 0 "" systemctl disable e2e-direct
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-direct
    check "the start links turned into stop links" klink e2e-direct "$level"

    # A root that is not the running one: no tool is called, the links are written directly.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/etc/rc.d $r/usr/bin
    if [ "$family" = redhat ]; then
        # The layout of Red Hat: /etc/init.d is a link to rc.d/init.d.
        mkdir -p $r/etc/rc.d/init.d
        ln -s rc.d/init.d $r/etc/init.d
    else
        mkdir -p $r/etc/init.d
    fi
    for l in 0 1 2 3 4 5 6 S; do mkdir -p "$r/etc/rc$l.d" "$r/etc/rc.d/rc$l.d"; done
    cp /etc/os-release $r/etc/os-release
    cp /bin/true $r/usr/bin/true
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root succeeds" 0 "" env FAKE_SYSTEMD_INIT=sysvinit systemctl --root=$r enable e2e-root
    check "the script is in the other root" grep -q "^# Generated automatically by fake-systemd" $r/etc/init.d/e2e-root
    check "the start link is in the other root" test -L "$r$rc_base/rc$level.d/S80e2e-root"
    check "the link resolves inside that root" test -e "$r$rc_base/rc$level.d/S80e2e-root"
    check "nothing was written to the running root" test ! -e /etc/init.d/e2e-root
    expect "is-enabled in the other root answers enabled" 0 "enabled" env FAKE_SYSTEMD_INIT=sysvinit systemctl --root=$r is-enabled e2e-root
    expect "disable in the other root succeeds" 0 "" env FAKE_SYSTEMD_INIT=sysvinit systemctl --root=$r disable e2e-root
    expect "is-enabled in the other root answers disabled" 1 "disabled" env FAKE_SYSTEMD_INIT=sysvinit systemctl --root=$r is-enabled e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- An init is running ---------------------------------------------------------------------------
check "PID 1 is an init" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" = init'
if [ "$family" = redhat ]; then
    mkfifo /run/initctl
else
    expect "sysvinit runs the default runlevel" 0 "N 2" runlevel
fi
expect "the backend is sysvinit" 0 "sysvinit" systemctl --version
if [ "$family" != redhat ]; then
    # policy-rc.d is what invoke-rc.d asks before it starts a service in a chroot or an image. A
    # systemctl a user runs does not, as the real one does not.
    printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
fi

# --- Lifecycle -----------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sleep 1000'
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
check "the script carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/init.d/e2e-sleeper
check "the script is a sh script" sh -c 'head -n 1 /etc/init.d/e2e-sleeper | grep -qx "#!/bin/sh"'
check "the script passes sh -n" sh -n /etc/init.d/e2e-sleeper
check "the script is executable" test -x /etc/init.d/e2e-sleeper
check "the start link is in the default runlevel" slink e2e-sleeper
check "the stop links are in the runlevels of shutdown" sh -c "ls $(rcd 0)/K??e2e-sleeper $(rcd 1)/K??e2e-sleeper $(rcd 6)/K??e2e-sleeper"
check "the link points at the script" sh -c "test \"\$(readlink $(rcd $level)/S??e2e-sleeper)\" = ../init.d/e2e-sleeper"
if [ "$family" = redhat ]; then
    check "chkconfig lists the service on in the default runlevel" chkconfig --level $level e2e-sleeper
    check "the script has the chkconfig header" grep -q "^# chkconfig: 2345 80 20$" /etc/init.d/e2e-sleeper
else
    check "insserv accepts the header and orders the boot" insserv_ok e2e-sleeper
fi
check "service runs the status action: running" service e2e-sleeper status
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
if [ "$family" != redhat ]; then
    expect "policy-rc.d denies the start to invoke-rc.d, though systemctl started the service" 101 "" invoke-rc.d --query e2e-sleeper start
fi
check "the daemon is detached: its executor leads no session of the caller" sh -c 'pid=$(cat /run/fake-systemd/e2e-sleeper.service.daemon.pid); [ "$(ps -o comm= -p $pid)" = fake-systemd ]'
check "the main process is the one the executor recorded" sh -c 'grep -q sleep /proc/$(cut -d" " -f1 /run/fake-systemd/e2e-sleeper.service.pid)/cmdline'
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "the status action says not running: 3" lsbstate e2e-sleeper 3
check "stopping an enabled service keeps its start link" slink e2e-sleeper
check "no pid file is left" sh -c 'test ! -e /run/fake-systemd/e2e-sleeper.service.daemon.pid && test ! -e /run/fake-systemd/e2e-sleeper.service.pid'
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
first_pid=$(cut -d" " -f1 /run/fake-systemd/e2e-sleeper.service.pid)
check "the service has a pid" is_pid "$first_pid"
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
check "restart started a new process" changed "$(cut -d" " -f1 /run/fake-systemd/e2e-sleeper.service.pid)" "$first_pid"
expect "start of a running service succeeds" 0 "" systemctl start e2e-sleeper
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service reads failed: nothing supervises it" 5 active e2e-sleeper failed
check "the status action says dead with a pid file: 1" lsbstate e2e-sleeper 1
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
expect "start of a failed service starts it again" 0 "" systemctl start e2e-sleeper
expect "the service is active again" 0 "active" systemctl is-active e2e-sleeper
expect "stop succeeds again" 0 "" systemctl stop e2e-sleeper
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
check "no start link is left in the default runlevel" sh -c "! ls $(rcd $level)/S??e2e-sleeper"
check "the stop links stay, as the tools leave them" klink e2e-sleeper "$level"
expect "daemon-reload succeeds against the running init" 0 "" systemctl daemon-reload
expect "enable of a disabled service turns the links back" 0 "" systemctl enable e2e-sleeper
expect "is-enabled answers enabled again" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "is-active answers inactive after enable" 3 "inactive" systemctl is-active e2e-sleeper
expect "enable of an enabled service changes nothing" 0 "" systemctl enable e2e-sleeper

# --- Enabled at boot or not, independent of running ---------------------------------------------
expect "start of an enabled service" 0 "" systemctl start e2e-sleeper
expect "disable keeps a running service running" 0 "" systemctl disable e2e-sleeper
expect "the service is still active" 0 "active" systemctl is-active e2e-sleeper
expect "start does not enable" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable --runtime persists, since there is no volatile runlevel" 0 "" systemctl enable --runtime e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "disable removes it again" 0 "" systemctl disable e2e-sleeper

# --- Output, exit and the uniform log -------------------------------------------------------------
unit e2e-failer 'ExecStart=/bin/sh -c "echo e2e-failer-line; exit 3"'
unit e2e-clean 'ExecStart=/bin/sh -c "echo e2e-clean-output; echo e2e-clean-error >&2; exit 0"'
expect "a failing service starts" 0 "" systemctl start e2e-failer
wait_for "a service whose process exited with an error is failed" 5 active e2e-failer failed
check "the executor recorded the failure" grep -q '^failed 3$' /run/fake-systemd/e2e-failer.service.exit
check "the status action says dead: 1" lsbstate e2e-failer 1
expect "stop resets the failed state" 0 "" systemctl stop e2e-failer
expect "is-active answers inactive after reset" 3 "inactive" systemctl is-active e2e-failer
expect "a service that ends cleanly starts" 0 "" systemctl start e2e-clean
wait_for "a clean exit reads inactive" 5 active e2e-clean inactive
check "the executor recorded the clean end" grep -q '^ok 0$' /run/fake-systemd/e2e-clean.service.exit
check "the status action says not running: 3" lsbstate e2e-clean 3
wait_for "stdout reached the uniform log" 5 grep -q e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current
wait_for "so did stderr, through the same logger" 5 grep -q e2e-clean-error /var/log/fake-systemd/e2e-clean.service/current
check "log lines carry an ISO 8601 timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+[+-][0-9:]+ e2e-clean' /var/log/fake-systemd/e2e-clean.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-clean-output" journalctl -u e2e-clean.service --no-pager
expect "is-failed answers 1 for a service that ended cleanly" 1 "inactive" systemctl is-failed e2e-clean
expect "start of a service that ended cleanly runs it again" 0 "" systemctl start e2e-clean
wait_for "the second run was logged" 5 sh -c '[ "$(grep -c e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current)" -ge 2 ]'
expect "stop of a finished service succeeds" 0 "" systemctl stop e2e-clean

# --- Restart= is not honored: sysvinit does not supervise -------------------------------------------
unit e2e-always 'ExecStart=/bin/sleep 1001
Restart=always
RestartSec=1'
expect "a Restart=always service starts" 0 "" systemctl start e2e-always
check "the script says Restart= is not honored" grep -q "^# Restart=always is not honored" /etc/init.d/e2e-always
wait_for "it is active" 5 active e2e-always active
old=$(cut -d" " -f1 /run/fake-systemd/e2e-always.service.pid)
check "the service has a pid" is_pid "$old"
expect "kill of the main process" 0 "" systemctl kill -s KILL e2e-always
wait_for "it reads failed" 5 active e2e-always failed
sleep 4
check "nothing restarted it, whatever Restart= says" sh -c '! pgrep -f "[s]leep 1001" >/dev/null'
check "status says it is dead and not restarted" sh -c '/etc/init.d/e2e-always status | grep -q "not restarted"'
expect "stop resets it" 0 "" systemctl stop e2e-always

# --- Executor: ExecStartPre= and EnvironmentFile= -------------------------------------------------
echo 'E2E_VAR=hello' >/etc/e2e-env
cat >/usr/local/bin/e2e-pre <<'X'
#!/bin/sh
env >/tmp/e2e-pre-env
exec sleep 1000
X
chmod 755 /usr/local/bin/e2e-pre
unit e2e-pre 'EnvironmentFile=/etc/e2e-env
ExecStartPre=/bin/touch /tmp/e2e-pre-ran
ExecStart=/usr/local/bin/e2e-pre'
expect "a unit with ExecStartPre= starts" 0 "" systemctl start e2e-pre
check "the script goes through the executor" grep -q -- "--exec e2e-pre.service" /etc/init.d/e2e-pre
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
wait_for "the executor service is active" 5 active e2e-pre active
expect "stop succeeds" 0 "" systemctl stop e2e-pre

# --- ExecStop= runs before the process is terminated, ExecStopPost= after it ended --------------------
unit e2e-hooks 'ExecStart=/bin/sleep 1002
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-stop-alive"
ExecStopPost=/bin/touch /tmp/e2e-post-ran'
expect "a unit with stop hooks starts" 0 "" systemctl start e2e-hooks
wait_for "it runs" 5 active e2e-hooks active
check "the executor stays resident to run ExecStop= on SIGTERM" grep -q -- "--stop-on-signal" /etc/init.d/e2e-hooks
check "the stop action runs ExecStopPost= through the executor" grep -q -- "--phase stop-post" /etc/init.d/e2e-hooks
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the service process was alive" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran" test -e /tmp/e2e-post-ran
expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-hooks
rm -f /tmp/e2e-stop-alive /tmp/e2e-post-ran
expect "start again" 0 "" systemctl start e2e-hooks
wait_for "it runs again" 5 active e2e-hooks active
expect "the init script stop action is the same stop" 0 "" /etc/init.d/e2e-hooks stop
check "ExecStop= ran for the init script too" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran for the init script too" test -e /tmp/e2e-post-ran
rm -f /tmp/e2e-stop-alive /tmp/e2e-post-ran
if [ "$family" != redhat ]; then
    # A runlevel change runs the stop link of the new runlevel for what the old one started.
    expect "enable of the hooked service" 0 "" systemctl enable --now e2e-hooks
    wait_for "it runs" 5 active e2e-hooks active
    rm -f "$(rcd 4)"/S??e2e-hooks
    ln -s ../init.d/e2e-hooks "$(rcd 4)/K01e2e-hooks"
    expect "telinit 4 changes the runlevel" 0 "" telinit 4
    wait_for "the stop link of the new runlevel stopped the service through ExecStop=" 15 test -e /tmp/e2e-stop-alive
    wait_for "ExecStopPost= ran on the runlevel change" 5 test -e /tmp/e2e-post-ran
    wait_for "the service is inactive" 5 active e2e-hooks inactive
    expect "telinit 2 returns to the default runlevel" 0 "" telinit 2
    wait_for "its start link started the service again" 15 active e2e-hooks active
    expect "disable and stop" 0 "" sh -c 'systemctl disable e2e-hooks && systemctl stop e2e-hooks'
    rm -f "$(rcd 4)/K01e2e-hooks"
fi

# --- Type=forking ----------------------------------------------------------------------------------
cat >/usr/local/bin/e2e-forker <<'X'
#!/bin/sh
sleep 1003 </dev/null >/dev/null 2>&1 &
echo $! >/run/e2e-fork.pid
X
chmod 755 /usr/local/bin/e2e-forker
unit e2e-fork 'Type=forking
PIDFile=/run/e2e-fork.pid
ExecStart=/usr/local/bin/e2e-forker'
expect "a forking unit with a pid file starts" 0 "" systemctl start e2e-fork
wait_for "the executor follows the daemon: active" 5 active e2e-fork active
wait_for "the daemon wrote its pid file" 5 test -s /run/e2e-fork.pid
daemon=$(cat /run/e2e-fork.pid 2>/dev/null)
check "the pid file holds a pid" is_pid "$daemon"
check "the pid is a live daemon" alive "$daemon"
expect "stop of a forking unit succeeds" 0 "" systemctl stop e2e-fork
wait_for "the forked daemon is gone" 5 gone "$daemon"

# start and restart return once the daemon has written its pid file and the executor has read it
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
unit e2e-fork2 'Type=forking
ExecStart=/usr/local/bin/e2e-forker'
expect "a forking unit without a pid file starts" 0 "" systemctl start e2e-fork2
check "the script says the daemon is not followed" grep -q "^# Type=forking without PIDFile=" /etc/init.d/e2e-fork2
expect "it reads active: the command ran to the end" 0 "active" systemctl is-active e2e-fork2
daemon=$(cat /run/e2e-fork.pid 2>/dev/null)
check "the command left a daemon that is not followed" alive "$daemon"
expect "stop succeeds, though it cannot signal what it does not follow" 0 "" systemctl stop e2e-fork2
expect "it reads inactive" 3 "inactive" systemctl is-active e2e-fork2
kill "$daemon" 2>/dev/null
wait_for "the daemon that was not followed is gone" 5 gone "$daemon"

# --- Dependency closure ----------------------------------------------------------------------------
unit e2e-b 'ExecStart=/bin/sleep 1004'
unit e2e-a 'ExecStart=/bin/sleep 1005'
sed -i 's|^\[Unit\]|[Unit]\nRequires=e2e-b.service\nAfter=e2e-b.service|' /usr/lib/systemd/system/e2e-a.service
expect "enable --now of a unit with Requires= succeeds" 0 "" systemctl enable --now e2e-a
if [ "$family" = redhat ]; then
    check "the required unit is required by the header, as chkconfig takes it" grep -q "^# Required-Start:    \$remote_fs e2e-b$" /etc/init.d/e2e-a
else
    check "the required unit is Should-Start, which insserv drops when it is not enabled" grep -q "^# Should-Start:      e2e-b$" /etc/init.d/e2e-a
fi
check "the required unit is named in Pulls-In" grep -q "^# Pulls-In: e2e-b$" /etc/init.d/e2e-a
check "the required unit is enabled too, to be started at boot with the unit" slink e2e-b
check "the requiring unit is enabled" slink e2e-a
if [ "$family" = redhat ]; then
    check "chkconfig starts the required unit before the unit that requires it" sh -c "[ $(number e2e-b) -lt $(number e2e-a) ]"
else
    check "insserv starts the required unit before the unit that requires it" sh -c "[ $(number e2e-b) -lt $(number e2e-a) ]"
    check "insserv accepts every header" insserv_ok
fi
expect "disable of the requiring unit succeeds" 0 "" systemctl disable e2e-a
expect "disable of the requirement succeeds then" 0 "" systemctl disable e2e-b
if [ "$family" != redhat ]; then
    check "insserv still accepts every header after the requirement went" insserv_ok
fi
systemctl stop e2e-a e2e-b >/dev/null 2>&1

# A requirement added to an enabled unit is enabled by daemon-reload, which also sorts the boot again.
unit e2e-late 'ExecStart=/bin/sleep 1011'
unit e2e-early 'ExecStart=/bin/sleep 1012'
expect "enable of a unit without requirements" 0 "" systemctl enable e2e-late
sed -i 's|^\[Unit\]|[Unit]\nRequires=e2e-early.service|' /usr/lib/systemd/system/e2e-late.service
check "the unit that is going to be required is not enabled" sh -c "! ls $(rcd $level)/S??e2e-early"
expect "daemon-reload generates the script again" 0 "" systemctl daemon-reload
check "the script names the new requirement" grep -q "^# Pulls-In: e2e-early$" /etc/init.d/e2e-late
check "daemon-reload enabled the new requirement" slink e2e-early
check "the requirement starts first" sh -c "[ $(number e2e-early) -lt $(number e2e-late) ]"
if [ "$family" != redhat ]; then
    check "insserv accepts every header" insserv_ok
fi
expect "disable of both" 0 "" sh -c 'systemctl disable e2e-late && systemctl disable e2e-early'

# --- Templates -------------------------------------------------------------------------------------
cat >/usr/lib/systemd/system/e2e-tpl@.service <<'X'
[Service]
ExecStart=/bin/sh -c "echo %i > /tmp/e2e-tpl-%i; exec sleep 1006"

[Install]
WantedBy=multi-user.target
X
expect "a template instance starts" 0 "" systemctl start e2e-tpl@one
check "the instance is a script named with a dot" test -e /etc/init.d/e2e-tpl.one
wait_for "the instance saw its name" 5 grep -q '^one$' /tmp/e2e-tpl-one
expect "stop of the instance succeeds" 0 "" systemctl stop e2e-tpl@one

# --- Oneshot ---------------------------------------------------------------------------------------
unit e2e-once 'Type=oneshot
ExecStart=/bin/sh -c "echo e2e-once-output; echo run >> /tmp/e2e-once-count"'
expect "a oneshot starts" 0 "" systemctl start e2e-once
check "the oneshot ran" test "$(count /tmp/e2e-once-count)" = 1
expect "a finished oneshot is inactive" 3 "inactive" systemctl is-active e2e-once
check "the status action says not running: 3" lsbstate e2e-once 3
expect "a second start runs it again" 0 "" systemctl start e2e-once
check "the oneshot ran twice" test "$(count /tmp/e2e-once-count)" = 2
wait_for "its output reached the uniform log" 5 grep -q e2e-once-output /var/log/fake-systemd/e2e-once.service/current
check "no stale pid file of the executor is left" test ! -e /run/fake-systemd/e2e-once.service.pid
expect "stop of a finished oneshot succeeds" 0 "" systemctl stop e2e-once
unit e2e-onefail 'Type=oneshot
ExecStart=/bin/sh -c "exit 4"'
expect "a failing oneshot fails the start" 1 "" systemctl start e2e-onefail
expect "it reads failed" 3 "failed" systemctl is-active e2e-onefail
expect "stop resets it" 0 "" systemctl stop e2e-onefail
unit e2e-remain 'Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/touch /tmp/e2e-remain-start
ExecStop=/bin/touch /tmp/e2e-remain-stop'
expect "a oneshot with RemainAfterExit= starts" 0 "" systemctl start e2e-remain
check "its command ran" test -e /tmp/e2e-remain-start
expect "it stays active after the command exited" 0 "active" systemctl is-active e2e-remain
check "the status action says running: 0" lsbstate e2e-remain 0
expect "a second start changes nothing" 0 "" systemctl start e2e-remain
expect "stop runs ExecStop=" 0 "" systemctl stop e2e-remain
check "ExecStop= of the oneshot ran" test -e /tmp/e2e-remain-stop
expect "it is inactive after stop" 3 "inactive" systemctl is-active e2e-remain

# --- Signals and reload ------------------------------------------------------------------------------
cat >/usr/local/bin/e2e-signals <<'X'
#!/bin/sh
trap 'touch /tmp/e2e-hup' HUP
trap 'touch /tmp/e2e-winch' WINCH
echo e2e-hello-from-the-service
while :; do sleep 0.2; done
X
chmod 755 /usr/local/bin/e2e-signals
unit e2e-signals 'ExecStart=/usr/local/bin/e2e-signals
ExecReload=/bin/kill -HUP $MAINPID'
expect "a signal-handling service starts" 0 "" systemctl start e2e-signals
wait_for "it runs" 5 active e2e-signals active
expect "reload runs ExecReload= with the main pid" 0 "" systemctl reload e2e-signals
wait_for "the service got SIGHUP from ExecReload=" 5 test -e /tmp/e2e-hup
expect "kill -s WINCH signals the service" 0 "" systemctl kill -s WINCH e2e-signals
wait_for "the service got SIGWINCH" 5 test -e /tmp/e2e-winch
wait_for "the service output reached the uniform log" 5 grep -q e2e-hello-from-the-service /var/log/fake-systemd/e2e-signals.service/current
check "service reload runs the same action" sh -c 'rm -f /tmp/e2e-hup; service e2e-signals reload; sleep 1; test -e /tmp/e2e-hup'
expect "stop succeeds" 0 "" systemctl stop e2e-signals
expect "reload of a stopped service fails" 1 "" systemctl reload e2e-signals

# --- A script the system already has ---------------------------------------------------------------
if [ "$family" = redhat ]; then
    cat >/etc/init.d/e2e-nat <<'X'
#!/bin/sh
# chkconfig: 2345 85 15
# description: a native service
. /etc/rc.d/init.d/functions
pidfile=/var/run/e2e-nat.pid
case "$1" in
    start) /bin/sleep 1007 </dev/null >/dev/null 2>&1 & echo $! >$pidfile; touch /var/lock/subsys/e2e-nat ;;
    stop) killproc -p $pidfile /bin/sleep; rm -f /var/lock/subsys/e2e-nat ;;
    reload) touch /tmp/e2e-nat-reload ;;
    status) status -p $pidfile e2e-nat ;;
esac
X
else
    cat >/etc/init.d/e2e-nat <<'X'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          e2e-nat
# Required-Start:    $remote_fs
# Required-Stop:     $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: a native service
### END INIT INFO
. /lib/lsb/init-functions
DAEMON=/bin/sleep
PIDFILE=/run/e2e-nat.pid
case "$1" in
    start) start-stop-daemon --start --quiet --background --make-pidfile --pidfile $PIDFILE --exec $DAEMON -- 1007 ;;
    stop) start-stop-daemon --stop --quiet --oknodo --pidfile $PIDFILE; rm -f $PIDFILE ;;
    reload) touch /tmp/e2e-nat-reload ;;
    status) status_of_proc -p $PIDFILE $DAEMON e2e-nat ;;
esac
X
fi
chmod 755 /etc/init.d/e2e-nat
unit e2e-nat 'ExecStart=/bin/sleep 1007'
expect "enable --now uses the native script" 0 "" systemctl enable --now e2e-nat
check "nothing was generated over the native script" sh -c '! grep -q "Generated automatically" /etc/init.d/e2e-nat'
check "the native script is enabled" slink e2e-nat
wait_for "the native service runs" 5 sh -c 'pgrep -f "[s]leep 1007" >/dev/null'
expect "is-active reads the status action of the native script" 0 "active" systemctl is-active e2e-nat
expect "reload of a native service goes through its script" 0 "" systemctl reload e2e-nat
check "the native reload ran" test -e /tmp/e2e-nat-reload
expect "status of a native service reports a pid" 0 "Main PID" systemctl status e2e-nat
expect "stop and disable the native service" 0 "" sh -c 'systemctl stop e2e-nat && systemctl disable e2e-nat'
check "the native service is gone" sh -c '! pgrep -f "[s]leep 1007" >/dev/null'
rm -f /etc/init.d/e2e-nat

# --- Generated scripts are accepted by the tools ----------------------------------------------------
for dep in dbus postgresql syslog; do
    if [ "$family" = redhat ]; then
        printf '#!/bin/sh\n# chkconfig: 2345 80 20\n# description: %s\n### BEGIN INIT INFO\n# Provides: %s\n# Default-Start: 2 3 4 5\n# Default-Stop: 0 1 6\n# Short-Description: %s\n### END INIT INFO\nexit 0\n' "$dep" "$dep" "$dep" >"/etc/init.d/$dep"
    else
        printf '#!/bin/sh\n### BEGIN INIT INFO\n# Provides: %s\n# Required-Start: $remote_fs\n# Required-Stop: $remote_fs\n# Default-Start: 2 3 4 5\n# Default-Stop: 0 1 6\n# Short-Description: %s\n### END INIT INFO\nexit 0\n' "$dep" "$dep" >"/etc/init.d/$dep"
    fi
    chmod 755 "/etc/init.d/$dep"
    if [ "$family" = redhat ]; then env SYSTEMCTL_SKIP_REDIRECT=1 chkconfig --add "$dep"; else env _SKIP_SYSTEMD_NATIVE=1 update-rc.d "$dep" defaults >/dev/null 2>&1; fi
done
for f in /golden/*.sysvinit; do
    n=$(basename "$f" .sysvinit)
    cp "$f" "/etc/init.d/$n"
    chmod 755 "/etc/init.d/$n"
    check "golden $n passes sh -n" sh -n "/etc/init.d/$n"
    if [ "$family" = redhat ]; then
        check "chkconfig accepts golden $n" env SYSTEMCTL_SKIP_REDIRECT=1 chkconfig --add "$n"
        check "chkconfig puts golden $n on in the default runlevel" chkconfig --level $level "$n"
    else
        check "update-rc.d and insserv accept golden $n" update_ok "$n"
        check "the start link of golden $n exists" slink "$n"
    fi
done
if [ "$family" = redhat ]; then
    check "chkconfig starts deps-mix after dbus, which it requires" sh -c "[ $(number deps-mix) -gt $(number dbus) ]"
else
    check "insserv accepts the whole set of golden scripts" insserv_ok
    check "insserv starts deps-mix after dbus, which it requires" sh -c "[ $(number deps-mix) -gt $(number dbus) ]"
fi
for f in /golden/*.sysvinit; do
    n=$(basename "$f" .sysvinit)
    if [ "$family" = redhat ]; then chkconfig --del "$n" >/dev/null 2>&1; else env _SKIP_SYSTEMD_NATIVE=1 update-rc.d -f "$n" remove >/dev/null 2>&1; fi
    rm -f "/etc/init.d/$n"
done
for dep in dbus postgresql syslog; do
    if [ "$family" = redhat ]; then chkconfig --del "$dep" >/dev/null 2>&1; else env _SKIP_SYSTEMD_NATIVE=1 update-rc.d -f "$dep" remove >/dev/null 2>&1; fi
    rm -f "/etc/init.d/$dep"
done

# --- An account only the system libc resolves --------------------------------------------------------
echo "svc-directory:x:1500:1500::/home/svc:/bin/sh" >>/etc/passwd
echo "svc-directory:x:1500:" >>/etc/group
echo "e2eextra:x:1501:svc-directory" >>/etc/group
printf '#!/bin/sh\nid >/tmp/e2e-ldap-id\necho e2e-ldap-line\nexec sleep 1008\n' >/usr/bin/dirsync
chmod 755 /usr/bin/dirsync
cp /corpus/user-ldap.service /usr/lib/systemd/system/user-ldap.service
check "the golden script for such an account gives the executor the numeric ids" grep -q -- '--uid "$(id -u -- svc-directory)"' /golden/user-ldap.sysvinit
cp /golden/user-ldap.sysvinit /etc/init.d/user-ldap
chmod 755 /etc/init.d/user-ldap
expect "the script starts as the account" 0 "" /etc/init.d/user-ldap start
wait_for "the daemon ran" 5 test -s /tmp/e2e-ldap-id
check "the account has its primary group" grep -q 'uid=1500(svc-directory) gid=1500(svc-directory)' /tmp/e2e-ldap-id
check "the account has its supplementary group" grep -q '1501(e2eextra)' /tmp/e2e-ldap-id
check "the log directory belongs to root, whose executor starts the logger" sh -c 'test "$(stat -c %U /var/log/fake-systemd/user-ldap.service)" = root'
wait_for "the logger running as the account wrote the line" 5 grep -q e2e-ldap-line /var/log/fake-systemd/user-ldap.service/current
check "the executor stays root, and so do the files it writes" sh -c 'pid=$(cat /run/fake-systemd/user-ldap.service.daemon.pid); [ -n "$pid" ] && test "$(stat -c %U /proc/$pid)" = root && test "$(stat -c %U /run/fake-systemd/user-ldap.service.daemon.pid)" = root'
check "the status action says running" lsbstate user-ldap 0
expect "the script stops what runs as the account" 0 "" /etc/init.d/user-ldap stop
check "nothing of it is left" sh -c '! pgrep -f "[s]leep 1008" >/dev/null'
check "the status action says not running" lsbstate user-ldap 3
rm -f /etc/init.d/user-ldap /usr/lib/systemd/system/user-ldap.service

# --- Timeouts and network targets --------------------------------------------------------------------
cat >/usr/local/bin/e2e-stubborn <<'X'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-stubborn
unit e2e-stubborn 'ExecStart=/usr/local/bin/e2e-stubborn
TimeoutStopSec=2'
expect "the stubborn service starts" 0 "" systemctl start e2e-stubborn
check "the stop timeout, plus the grace of the executor, is the wait of the script" grep -q "^stop_wait=12$" /etc/init.d/e2e-stubborn
wait_for "the stubborn service runs" 5 active e2e-stubborn active
began=$(date +%s)
expect "stop kills a service that ignores TERM after TimeoutStopSec=" 0 "" systemctl stop e2e-stubborn
check "it did not wait for the default of 90 seconds" test $(($(date +%s) - began)) -lt 30
expect "the stubborn service is gone" 3 "" systemctl is-active e2e-stubborn
check "the process of the stubborn service is gone, not left behind by the executor" sh -c '! pgrep -f "[s]h /usr/local/bin/e2e-stubborn" >/dev/null'
cat >/usr/local/bin/e2e-intonly <<'X'
#!/bin/sh
trap '' TERM
trap 'touch /tmp/e2e-int; exit 0' INT
while :; do sleep 0.2; done
X
chmod 755 /usr/local/bin/e2e-intonly
unit e2e-intonly 'ExecStart=/usr/local/bin/e2e-intonly
KillSignal=SIGINT
TimeoutStopSec=30'
expect "a service that exits on SIGINT only starts" 0 "" systemctl start e2e-intonly
wait_for "it runs" 5 active e2e-intonly active
began=$(date +%s)
expect "stop sends KillSignal= to the service" 0 "" systemctl stop e2e-intonly
check "the service got SIGINT" test -e /tmp/e2e-int
check "it did not wait for TimeoutStopSec=" test $(($(date +%s) - began)) -lt 15
printf '[Unit]\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nExecStart=/bin/sleep 1009\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-net.service
expect "a unit that waits for the network starts" 0 "" systemctl enable --now e2e-net
check "the network targets became the network facility" grep -q '^# Should-Start:      \$network$' /etc/init.d/e2e-net
if [ "$family" != redhat ]; then
    check "insserv resolves the network facility" insserv_ok e2e-net
fi
wait_for "the service runs" 5 active e2e-net active
systemctl disable e2e-net >/dev/null 2>&1
systemctl stop e2e-net >/dev/null 2>&1
printf '[Unit]\nRequires=network-online.target\n\n[Service]\nExecStart=/bin/sleep 1013\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-net2.service
expect "a unit that requires the network is enabled" 0 "" systemctl enable e2e-net2
check "the network is a required facility" grep -q '^# Required-Start:    \$remote_fs \$network$' /etc/init.d/e2e-net2
if [ "$family" != redhat ]; then
    check "insserv accepts the required network facility" insserv_ok e2e-net2
else
    check "chkconfig accepts the required network facility" chkconfig --level $level e2e-net2
fi
expect "disable succeeds" 0 "" systemctl disable e2e-net2

# --- Timers: built-in runner as a daemon without supervision -----------------------------------------
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
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/sysvinit/index
check "the runner is a script that starts the timer runner as a daemon" grep -q -- "--exec fake-systemd-timers.service --" /etc/init.d/fake-systemd-timers
check "the runner is enabled at boot" slink fake-systemd-timers
wait_for "the init script started the runner" 10 active fake-systemd-timers active
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "status shows the trigger" 0 "Trigger:" systemctl status e2e-tick.timer
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
runner=$(cut -d" " -f1 /run/fake-systemd/fake-systemd-timers.service.pid)
check "the runner has a pid" is_pid "$runner"
kill -KILL "$runner"
wait_for "the runner died: nothing restarts it, and status says so" 5 active fake-systemd-timers failed
expect "systemctl status of the runner shows the failure" 3 "Active: failed" systemctl status fake-systemd-timers
check "the status action of the script says why" sh -c '/etc/init.d/fake-systemd-timers status | grep -q "not restarted"'
sleep 3
check "the runner was not restarted" sh -c '! pgrep -f "[f]ake-systemd --timers" >/dev/null'
expect "start of the dead runner starts it again" 0 "" systemctl start fake-systemd-timers
wait_for "the runner is active again" 5 active fake-systemd-timers active
expect "disable of one timer keeps the runner" 0 "" systemctl disable e2e-tick.timer
check "the runner unit stays while a built-in timer is left" test -e /etc/systemd/system/fake-systemd-timers.service
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tock.timer
check "the runner unit is removed" test ! -e /etc/systemd/system/fake-systemd-timers.service
check "the runner script is removed" test ! -e /etc/init.d/fake-systemd-timers
wait_for "the runner is stopped" 10 sh -c '! pgrep -f "[f]ake-systemd --timers" >/dev/null'

# --- A service left enabled and running for the shutdown ---------------------------------------------
unit e2e-shutdown 'ExecStart=/bin/sleep 1010
ExecStop=/bin/touch /out/e2e-shutdown-stop'
expect "enable --now of the service the shutdown has to stop" 0 "" systemctl enable --now e2e-shutdown
wait_for "it runs" 5 active e2e-shutdown active

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
