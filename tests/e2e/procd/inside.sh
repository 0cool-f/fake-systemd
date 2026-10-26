#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh online|boot|offline
# `online` runs with procd as PID 1 on OpenWrt, `boot` after the container started again from the
# same file system, and `offline` where no init runs, as in a chroot or a container build.
# The shell is the ash of BusyBox, whose sleep takes whole seconds.
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

# wait_for DESC SECONDS COMMAND...  (polls once a second until the command succeeds)
wait_for() {
    desc=$1 secs=$2
    shift 2
    i=0
    while [ $i -lt "$secs" ]; do
        if "$@" >/dev/null 2>&1; then ok "$desc"; return; fi
        sleep 1
        i=$((i + 1))
    done
    fail "$desc" "timed out after ${secs}s: $*"
}

# active NAME STATE  (systemctl is-active prints STATE)
active() { systemctl is-active "$1" | grep -q "^$2\$"; }
slink() { ls /etc/rc.d/S??"$1" >/dev/null 2>&1; }
klink() { ls /etc/rc.d/K??"$1" >/dev/null 2>&1; }
# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }
# instance NAME  (the first instance procd lists for NAME, as a JSON text)
instance() { ubus call service list "{\"name\": \"$1\"}"; }

cp /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
chmod 755 /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/local/bin
chmod 1777 /tmp
echo "# $(grep OPENWRT_RELEASE /etc/os-release | tr -d '"')"

if [ "$mode" = offline ]; then
    # --- No init runs: a chroot or a container build ---------------------------------------------
    check "PID 1 is not procd" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" != procd'
    expect "the backend is procd, found from its executable" 0 "procd" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    check "the script was generated" grep -q "^# Generated automatically by fake-systemd" /etc/init.d/e2e-off
    check "the script is run by rc.common" sh -c 'head -n 1 /etc/init.d/e2e-off | grep -qx "#!/bin/sh /etc/rc.common"'
    check "the start link was written by the script" slink e2e-off
    check "so was the stop link" klink e2e-off
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    # The script takes a lock in /var/lock, which a booted system has: it cannot enable anything
    # without one, which is why the links are written directly here.
    check "the script cannot run without a booted system" sh -c '! /etc/init.d/e2e-off enabled'
    mkdir -p /var/lock
    check "the script agrees: enabled" /etc/init.d/e2e-off enabled
    expect "start offline only says so" 0 "" systemctl start e2e-off
    check "nothing was started" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
    expect "enable --now offline enables and starts nothing" 0 "" systemctl enable --now e2e-off
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off
    check "the stop link stays, for a service that may still run" klink e2e-off
    check "the script agrees: not enabled" sh -c '! /etc/init.d/e2e-off enabled'

    # A root that is not the running one: the links are written directly.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/etc/init.d $r/etc/rc.d $r/sbin $r/usr/bin
    cp /etc/os-release $r/etc/os-release
    cp /bin/true $r/sbin/procd
    cp /bin/true $r/usr/bin/true
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root succeeds" 0 "" systemctl --root=$r enable e2e-root
    check "the script is in the other root" grep -q "^# Generated automatically by fake-systemd" $r/etc/init.d/e2e-root
    check "the start link is in the other root" test -L $r/etc/rc.d/S50e2e-root
    check "the link resolves inside that root" test -e $r/etc/rc.d/S50e2e-root
    check "so does the stop link" test -L $r/etc/rc.d/K50e2e-root
    check "nothing was written to the running root" test ! -e /etc/init.d/e2e-root
    expect "is-enabled in the other root answers enabled" 0 "enabled" systemctl --root=$r is-enabled e2e-root
    expect "disable in the other root succeeds" 0 "" systemctl --root=$r disable e2e-root
    check "its start link is gone" test ! -e $r/etc/rc.d/S50e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

if [ "$mode" = boot ]; then
    # --- The container started again: procd ran the start links ---------------------------------
    check "procd is PID 1 again" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" = procd'
    wait_for "the enabled service was started by its start link" 20 active e2e-boot active
    wait_for "the remaining oneshot ran its start again" 20 active e2e-remain active
    check "the oneshot ran at boot: its start was recorded twice" sh -c '[ "$(grep -c "^remain-start$" /out/marks)" -eq 2 ]'
    expect "the service that was only started by hand is not started" 3 "inactive" systemctl is-active e2e-manual
    expect "the requirement of an enabled service is up through it" 0 "active" systemctl is-active e2e-dep
    expect "the service of the system is up as before" 0 "active" systemctl is-active dropbear
    if [ "$failed" -gt 0 ]; then
        ubus call service list | sed "s/^/#   /"
        logread | grep -E "e2e|fake-systemd" | tail -n 20 | sed "s/^/#   /"
    fi
    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- An init is running ---------------------------------------------------------------------------
check "PID 1 is procd" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" = procd'
wait_for "ubus has the service object of procd" 20 ubus list service
expect "the backend is procd" 0 "procd" systemctl --version

# --- Lifecycle -----------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sleep 1000'
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
if grep -q "native service" /tmp/stderr 2>/dev/null; then fail "the sleep applet of busybox is not a native service"; else ok "the sleep applet of busybox is not mistaken for the crond of the system"; fi
check "the script carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/init.d/e2e-sleeper
check "the script is run by rc.common" sh -c 'head -n 1 /etc/init.d/e2e-sleeper | grep -qx "#!/bin/sh /etc/rc.common"'
check "the script passes sh -n" sh -n /etc/init.d/e2e-sleeper
check "the script is executable" test -x /etc/init.d/e2e-sleeper
check "the script asks for procd" grep -q "^USE_PROCD=1$" /etc/init.d/e2e-sleeper
check "the start link is in /etc/rc.d" slink e2e-sleeper
check "the stop link is in /etc/rc.d" klink e2e-sleeper
check "the link points at the script" sh -c 'test "$(readlink /etc/rc.d/S50e2e-sleeper)" = ../init.d/e2e-sleeper'
check "the script says it is enabled" /etc/init.d/e2e-sleeper enabled
check "service lists it as enabled and running" sh -c 'service | grep e2e-sleeper | grep -q "enabled.*running"'
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
check "procd lists the executor as the command of the instance" sh -c 'ubus call service list "{\"name\": \"e2e-sleeper\"}" | grep -q "fake-systemd"'
check "procd supervises the service: running" /etc/init.d/e2e-sleeper running
check "the script's status says running" sh -c '/etc/init.d/e2e-sleeper status | grep -qx running'
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "the process is gone when stop returned" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
check "stopping an enabled service keeps its links" slink e2e-sleeper
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
first_pid=$(instance e2e-sleeper | grep '"pid"' | tr -dc 0-9)
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
check "restart started a new process" test "$(instance e2e-sleeper | grep '"pid"' | tr -dc 0-9)" != "$first_pid"
expect "start of a running service succeeds" 0 "" systemctl start e2e-sleeper
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service without Restart= reads failed" 5 active e2e-sleeper failed
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
expect "start of a failed service starts it again" 0 "" systemctl start e2e-sleeper
wait_for "the service is active again" 5 active e2e-sleeper active
expect "stop succeeds again" 0 "" systemctl stop e2e-sleeper
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
check "no start link is left" sh -c '! ls /etc/rc.d/S??e2e-sleeper'
check "the stop link stays, so that a service started by hand stops at shutdown" klink e2e-sleeper
expect "enable of a disabled service turns the link back" 0 "" systemctl enable e2e-sleeper
expect "is-enabled answers enabled again" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "enable of an enabled service changes nothing" 0 "" systemctl enable e2e-sleeper
expect "start of an enabled service" 0 "" systemctl start e2e-sleeper
expect "disable keeps a running service running" 0 "" systemctl disable e2e-sleeper
expect "the service is still active" 0 "active" systemctl is-active e2e-sleeper
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable --runtime persists, since procd has no volatile enablement" 0 "" systemctl enable --runtime e2e-sleeper
expect "disable removes it again" 0 "" systemctl disable e2e-sleeper

# --- Supervision: Restart= is honored by procd --------------------------------------------------------
unit e2e-always 'ExecStart=/bin/sleep 1001
Restart=always
RestartSec=1'
expect "a Restart=always service starts" 0 "" systemctl start e2e-always
check "the script has the respawn parameters of the unit" grep -q "procd_set_param respawn 10 1 5" /etc/init.d/e2e-always
wait_for "it is active" 5 active e2e-always active
old=$(instance e2e-always | grep '"pid"' | tr -dc 0-9)
expect "kill of the main process" 0 "" systemctl kill -s KILL e2e-always
wait_for "procd respawned it with another pid" 10 sh -c "[ -n \"\$(ubus call service list '{\"name\": \"e2e-always\"}' | grep '\"pid\"' | tr -dc 0-9)\" ] && [ \"\$(ubus call service list '{\"name\": \"e2e-always\"}' | grep '\"pid\"' | tr -dc 0-9)\" != $old ]"
expect "it reads active again" 0 "active" systemctl is-active e2e-always
expect "stop succeeds, procd does not respawn a service that was stopped" 0 "" systemctl stop e2e-always
check "it stays down" sh -c 'sleep 2; ! pgrep -f "[s]leep 1001" >/dev/null'

# --- Output, exit and the uniform log -------------------------------------------------------------
unit e2e-failer 'ExecStart=/bin/sh -c "echo e2e-failer-line; exit 3"'
unit e2e-clean 'ExecStart=/bin/sh -c "echo e2e-clean-output; echo e2e-clean-error >&2; exit 0"'
expect "a failing service starts" 0 "" systemctl start e2e-failer
wait_for "a service whose process exited with an error is failed" 5 active e2e-failer failed
check "procd recorded the exit code" sh -c 'ubus call service list "{\"name\": \"e2e-failer\"}" | grep -q "\"exit_code\": 3"'
expect "stop resets the failed state" 0 "" systemctl stop e2e-failer
expect "is-active answers inactive after reset" 3 "inactive" systemctl is-active e2e-failer
expect "a service that ends cleanly starts" 0 "" systemctl start e2e-clean
wait_for "a clean exit reads inactive" 5 active e2e-clean inactive
wait_for "stdout reached the uniform log" 5 grep -q e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current
wait_for "so did stderr, through the same logger" 5 grep -q e2e-clean-error /var/log/fake-systemd/e2e-clean.service/current
check "log lines carry an ISO 8601 timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+[+-][0-9:]+ e2e-clean' /var/log/fake-systemd/e2e-clean.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-clean-output" journalctl -u e2e-clean.service --no-pager
expect "is-failed answers 1 for a service that ended cleanly" 1 "inactive" systemctl is-failed e2e-clean
expect "stop of a finished service succeeds" 0 "" systemctl stop e2e-clean

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
check "the environment file is a file procd watches" grep -q "procd_set_param file /etc/e2e-env" /etc/init.d/e2e-pre
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
wait_for "the service is active" 5 active e2e-pre active
expect "stop succeeds" 0 "" systemctl stop e2e-pre

# --- ExecStop= runs before the process is terminated, ExecStopPost= after it ended --------------------
unit e2e-hooks 'ExecStart=/bin/sleep 1002
ExecStop=/bin/sh -c "kill -0 $MAINPID && sleep 2 && touch /tmp/e2e-stop-alive"
ExecStopPost=/bin/touch /tmp/e2e-post-ran
ExecReload=/bin/touch /tmp/e2e-reloaded'
expect "a unit with stop hooks starts" 0 "" systemctl start e2e-hooks
wait_for "it runs" 5 active e2e-hooks active
check "the executor stays resident to run ExecStop= on SIGTERM" grep -q -- "--stop-on-signal" /etc/init.d/e2e-hooks
expect "reload runs ExecReload=" 0 "" systemctl reload e2e-hooks
check "ExecReload= ran" test -e /tmp/e2e-reloaded
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the process was alive, and stop waited for it" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran before stop returned" test -e /tmp/e2e-post-ran
expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-hooks
rm -f /tmp/e2e-stop-alive /tmp/e2e-post-ran
expect "start again" 0 "" systemctl start e2e-hooks
wait_for "it runs again" 5 active e2e-hooks active
expect "the init script's stop action is the same stop" 0 "" /etc/init.d/e2e-hooks stop
check "ExecStop= ran for the init script too" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran for the init script too" test -e /tmp/e2e-post-ran
unit e2e-noreload 'ExecStart=/bin/sleep 1012'
expect "a unit without ExecReload= refuses reload" 1 "" sh -c 'systemctl start e2e-noreload && systemctl reload e2e-noreload'
expect "stop of it succeeds" 0 "" systemctl stop e2e-noreload

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
daemon=$(cat /run/e2e-fork.pid)
expect "stop of a forking unit succeeds" 0 "" systemctl stop e2e-fork
wait_for "the forked daemon is gone" 5 sh -c "! kill -0 $daemon"

# --- Identity ---------------------------------------------------------------------------------------
echo "e2eextra:x:1501:nobody" >>/etc/group
unit e2e-user 'User=nobody
Group=nogroup
SupplementaryGroups=e2eextra
ExecStart=/bin/sh -c "grep -E \"^(Uid|Gid|Groups)\" /proc/self/status > /tmp/e2e-user-id; exec sleep 1007"'
expect "a unit with User= starts" 0 "" systemctl start e2e-user
wait_for "the service ran" 5 test -s /tmp/e2e-user-id
check "it runs as nobody" grep -q '^Uid:.65534' /tmp/e2e-user-id
check "with its group" grep -q '^Gid:.65534' /tmp/e2e-user-id
check "and the supplementary group of the unit" grep -q '^Groups:.*1501' /tmp/e2e-user-id
check "the log directory is there for the logger, which the executor started as root" test -d /var/log/fake-systemd/e2e-user.service
expect "stop succeeds" 0 "" systemctl stop e2e-user

# --- Dependencies ----------------------------------------------------------------------------------
unit e2e-dep 'ExecStart=/bin/sleep 1004'
unit e2e-boot 'ExecStart=/bin/sleep 1005'
sed -i 's|^\[Unit\]|[Unit]\nRequires=e2e-dep.service\nAfter=e2e-dep.service|' /usr/lib/systemd/system/e2e-boot.service
expect "start of a unit with Requires= starts the requirement" 0 "" systemctl start e2e-boot
expect "the requirement is active" 0 "active" systemctl is-active e2e-dep
check "the requirement is not enabled" sh -c '! ls /etc/rc.d/S??e2e-dep'
check "the script starts the requirement" grep -q "/etc/init.d/e2e-dep start" /etc/init.d/e2e-boot
check "the unit starts after its requirement" sh -c 'a=$(ls /etc/rc.d | sed -n "s/^K\([0-9][0-9]\)e2e-boot$/\1/p"); b=$(ls /etc/rc.d | sed -n "s/^K\([0-9][0-9]\)e2e-dep$/\1/p"); [ "$a" -lt "$b" ]'
expect "stop of the unit leaves the requirement" 0 "" systemctl stop e2e-boot
expect "stop of the requirement succeeds" 0 "" systemctl stop e2e-dep

# --- Native services --------------------------------------------------------------------------------
printf '[Service]\nExecStart=/usr/sbin/dropbear -F\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/dropbear.service
expect "the unit of dropbear is the native service" 0 "" systemctl status dropbear
check "no script was generated for it" sh -c '! grep -q "Generated automatically" /etc/init.d/dropbear'
expect "is-enabled reads the links of the system" 0 "enabled" systemctl is-enabled dropbear
expect "is-active reads the instance of procd" 0 "active" systemctl is-active dropbear
expect "stop runs the native script" 0 "" systemctl stop dropbear
expect "is-active reads it inactive" 3 "inactive" systemctl is-active dropbear
expect "start runs the native script" 0 "" systemctl start dropbear
wait_for "dropbear is active" 5 active dropbear active

# --- Generated scripts run in rc.common ------------------------------------------------------------
for f in /golden/*.procd; do
    n=$(basename "$f" .procd)
    cp "$f" "/etc/init.d/$n"
    chmod 755 "/etc/init.d/$n"
    check "golden $n passes sh -n" sh -n "/etc/init.d/$n"
    check "rc.common sources golden $n and lists its commands" sh -c "/etc/init.d/$n help | grep -q enable"
    check "golden $n enables with its own priorities" sh -c "/etc/init.d/$n enable && /etc/init.d/$n enabled"
    check "golden $n disables" sh -c "/etc/init.d/$n disable && ! /etc/init.d/$n enabled"
    rm -f "/etc/init.d/$n"
done

# --- Templates and the timer runner ----------------------------------------------------------------
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

cat >/usr/lib/systemd/system/e2e-tick.service <<'X'
[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo e2e-tick-output"
X
cat >/usr/lib/systemd/system/e2e-tick.timer <<'X'
[Timer]
OnCalendar=*:*:0/5
[Install]
WantedBy=timers.target
X
expect "enable of a timer with a seconds calendar succeeds" 0 "" systemctl enable e2e-tick.timer
check "the runner is a procd instance of the timer runner" grep -q -- "--exec fake-systemd-timers.service" /etc/init.d/fake-systemd-timers
check "the runner is enabled at boot" slink fake-systemd-timers
wait_for "procd started the runner" 10 active fake-systemd-timers active
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
pid=$(instance fake-systemd-timers | grep '"pid"' | tr -dc 0-9)
expect "kill of the runner" 0 "" kill -9 "$pid"
wait_for "procd restarted the runner, which nothing did with sysvinit" 10 sh -c "[ -n \"\$(ubus call service list '{\"name\": \"fake-systemd-timers\"}' | grep '\"running\": true')\" ]"
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tick.timer
check "the runner script is removed" test ! -e /etc/init.d/fake-systemd-timers
wait_for "the runner is stopped" 10 sh -c '! pgrep -f "[f]ake-systemd --timers" >/dev/null'

# --- daemon-reload ----------------------------------------------------------------------------------
unit e2e-gone 'ExecStart=/bin/sleep 1030'
expect "enable of a unit that goes away" 0 "" systemctl enable e2e-gone
rm -f /usr/lib/systemd/system/e2e-gone.service
expect "daemon-reload removes the script of a unit that is gone" 0 "" systemctl daemon-reload
check "the script is gone" test ! -e /etc/init.d/e2e-gone
check "so is its stop link" sh -c '! ls /etc/rc.d/K??e2e-gone 2>/dev/null'

# --- Services left for the shutdown and the next boot ------------------------------------------------
: >/out/marks
unit e2e-boot 'ExecStart=/bin/sleep 1020
ExecStop=/bin/sh -c "echo boot-stop >> /out/marks"'
sed -i 's|^\[Unit\]|[Unit]\nRequires=e2e-dep.service\nAfter=e2e-dep.service|' /usr/lib/systemd/system/e2e-boot.service
unit e2e-dep 'ExecStart=/bin/sleep 1021
ExecStop=/bin/sh -c "echo dep-stop >> /out/marks"'
printf '[Unit]\nDescription=remain\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/sh -c "echo remain-start >> /out/marks"\nExecStop=/bin/sh -c "echo remain-stop >> /out/marks"\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-remain.service
unit e2e-manual 'ExecStart=/bin/sleep 1022
ExecStop=/bin/sh -c "echo manual-stop >> /out/marks"'
expect "enable --now of the service with a requirement" 0 "" systemctl enable --now e2e-boot
expect "enable --now of the oneshot that remains" 0 "" systemctl enable --now e2e-remain
expect "start of a service that is not enabled" 0 "" systemctl start e2e-manual
expect "the requirement is up, though it is not enabled" 0 "active" systemctl is-active e2e-dep
check "the stop link of the service that is not enabled is there" klink e2e-manual
check "the stop link of the requirement is there" klink e2e-dep
expect "daemon-reload succeeds against the running init" 0 "" systemctl daemon-reload

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
