#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh online|boot|offline
# `online` runs with sysvinit as PID 1 on Slackware, whose boot scripts start the rc.local that
# fake-systemd writes; `boot` runs after the container started again from the same file system,
# and `offline` where no init runs, as in a chroot or a container build.
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

# active NAME STATE  (systemctl is-active prints STATE)
active() { systemctl is-active "$1" | grep -q "^$2\$"; }
# executable FILE
executable() { [ -x "$1" ]; }
# rcstate NAME CODE  (the status verb exits with CODE: 0 running, 1 dead, 3 not running)
rcstate() { /etc/rc.d/rc."$1" status >/dev/null 2>&1; [ $? -eq "$2" ]; }
# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/local/bin
echo "# $(ls /var/log/packages | grep -E '^(sysvinit-[0-9]|sysvinit-scripts|util-linux|sysklogd)' | tr '\n' ' ')"

if [ "$mode" = offline ]; then
    # --- No init runs: a chroot or a container build ---------------------------------------------
    check "PID 1 is not an init" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" != init'
    expect "the backend is BSD-style rc, found from the release file" 0 "bsd-rc" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    check "the script was generated" grep -q "^# Generated automatically by fake-systemd" /etc/rc.d/rc.e2e-off
    check "enable made it executable" executable /etc/rc.d/rc.e2e-off
    check "rc.local starts it" grep -q "rc.e2e-off start" /etc/rc.d/rc.local
    check "rc.local_shutdown stops it" grep -q "rc.e2e-off stop" /etc/rc.d/rc.local_shutdown
    check "the hook scripts pass sh -n" sh -c 'sh -n /etc/rc.d/rc.local && sh -n /etc/rc.d/rc.local_shutdown'
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    expect "start offline only says so" 0 "" systemctl start e2e-off
    check "nothing was started" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
    expect "enable --now offline enables and starts nothing" 0 "" systemctl enable --now e2e-off
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off
    check "the script is not executable" sh -c '! test -x /etc/rc.d/rc.e2e-off'
    check "rc.local is the file of the system again" sh -c '! grep -q fake-systemd /etc/rc.d/rc.local'

    # A root that is not the running one: the same files, below that root.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/etc/rc.d $r/usr/bin
    cp /etc/os-release $r/etc/os-release
    cp /etc/slackware-version $r/etc/slackware-version
    cp /etc/rc.d/rc.local $r/etc/rc.d/rc.local
    cp /bin/true $r/usr/bin/true
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root succeeds" 0 "" systemctl --root=$r enable e2e-root
    check "the script is in the other root, executable" test -x $r/etc/rc.d/rc.e2e-root
    check "its rc.local starts it" grep -q "rc.e2e-root start" $r/etc/rc.d/rc.local
    check "nothing was written to the running root" test ! -e /etc/rc.d/rc.e2e-root
    expect "is-enabled in the other root answers enabled" 0 "enabled" systemctl --root=$r is-enabled e2e-root
    expect "disable in the other root succeeds" 0 "" systemctl --root=$r disable e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

if [ "$mode" = boot ]; then
    # --- The container started again: the boot scripts ran rc.local ----------------------------
    expect "sysvinit runs the default runlevel again" 0 "N 3" runlevel
    wait_for "the enabled service was started by rc.local at boot" 10 active e2e-boot active
    wait_for "the remaining oneshot ran its start again" 10 active e2e-remain active
    check "the oneshot ran at boot: its start was recorded twice" sh -c '[ "$(grep -c "^remain-start$" /out/marks)" -eq 2 ]'
    expect "the service that was only started by hand is not started" 3 "inactive" systemctl is-active e2e-manual
    expect "the dependency of an enabled service is up through it" 0 "active" systemctl is-active e2e-dep
    expect "the native service of the system is started by rc.M, not by a block" 0 "active" systemctl is-active syslogd
    check "rc.local lists the enabled service and not its requirement, which the script starts" sh -c "grep -q 'rc.e2e-boot start' /etc/rc.d/rc.local && ! grep -q 'rc.e2e-dep start' /etc/rc.d/rc.local"
    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- An init is running ---------------------------------------------------------------------------
check "PID 1 is sysvinit's init" sh -c 'test "$(basename "$(readlink /proc/1/exe)")" = init'
expect "the runlevel is the default of Slackware" 0 "N 3" runlevel
expect "the backend is BSD-style rc" 0 "bsd-rc" systemctl --version
check "rc.M, which runs rc.local, is the one of the release" grep -q "/etc/rc.d/rc.local" /etc/rc.d/rc.M
check "rc.6 runs rc.local_shutdown with the verb stop" grep -q "rc.local_shutdown stop" /etc/rc.d/rc.6

# --- Lifecycle -----------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sleep 1000'
expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
check "the script carries the marker" grep -q "^# Generated automatically by fake-systemd" /etc/rc.d/rc.e2e-sleeper
check "the script is a sh script" sh -c 'head -n 1 /etc/rc.d/rc.e2e-sleeper | grep -qx "#!/bin/sh"'
check "the script passes sh -n" sh -n /etc/rc.d/rc.e2e-sleeper
check "enabling is the execute permission" executable /etc/rc.d/rc.e2e-sleeper
check "rc.local keeps the text of the release" grep -q "Local system initialization script" /etc/rc.d/rc.local
check "rc.local starts the script between its markers" sh -c "sed -n '/^# BEGIN fake-systemd/,/^# END fake-systemd/p' /etc/rc.d/rc.local | grep -q 'rc.e2e-sleeper start'"
check "rc.local_shutdown stops it" sh -c "sed -n '/^# BEGIN fake-systemd/,/^# END fake-systemd/p' /etc/rc.d/rc.local_shutdown | grep -q 'rc.e2e-sleeper stop'"
check "the status verb runs: 0" rcstate e2e-sleeper 0
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
check "the main process is the one the executor recorded" sh -c 'grep -q sleep /proc/$(cut -d" " -f1 /run/fake-systemd/e2e-sleeper.service.pid)/cmdline'
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "the status verb says not running: 3" rcstate e2e-sleeper 3
check "stopping an enabled service keeps it enabled" executable /etc/rc.d/rc.e2e-sleeper
check "no pid file is left" sh -c 'test ! -e /run/fake-systemd/e2e-sleeper.service.daemon.pid && test ! -e /run/fake-systemd/e2e-sleeper.service.pid'
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
first_pid=$(cut -d" " -f1 /run/fake-systemd/e2e-sleeper.service.pid)
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
check "restart started a new process" test "$(cut -d" " -f1 /run/fake-systemd/e2e-sleeper.service.pid)" != "$first_pid"
expect "start of a running service succeeds" 0 "" systemctl start e2e-sleeper
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service reads failed: nothing supervises it" 5 active e2e-sleeper failed
check "the status verb says dead: 1" rcstate e2e-sleeper 1
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
expect "start of a failed service starts it again" 0 "" systemctl start e2e-sleeper
expect "stop succeeds again" 0 "" systemctl stop e2e-sleeper
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
check "the script is not executable" sh -c '! test -x /etc/rc.d/rc.e2e-sleeper'
check "rc.local does not start it" sh -c '! grep -q rc.e2e-sleeper /etc/rc.d/rc.local'
expect "a disabled service starts, through sh" 0 "" systemctl start e2e-sleeper
expect "it is active" 0 "active" systemctl is-active e2e-sleeper
expect "start does not enable" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable --runtime persists, as there is no volatile enablement" 0 "" systemctl enable --runtime e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "disable removes it again" 0 "" systemctl disable e2e-sleeper

# --- Output, exit and the uniform log -------------------------------------------------------------
unit e2e-failer 'ExecStart=/bin/sh -c "echo e2e-failer-line; exit 3"'
unit e2e-clean 'ExecStart=/bin/sh -c "echo e2e-clean-output; echo e2e-clean-error >&2; exit 0"'
expect "a failing service starts" 0 "" systemctl start e2e-failer
wait_for "a service whose process exited with an error is failed" 5 active e2e-failer failed
check "the executor recorded the failure" grep -q '^failed 3$' /run/fake-systemd/e2e-failer.service.exit
expect "stop resets the failed state" 0 "" systemctl stop e2e-failer
expect "a service that ends cleanly starts" 0 "" systemctl start e2e-clean
wait_for "a clean exit reads inactive" 5 active e2e-clean inactive
wait_for "stdout reached the uniform log" 5 grep -q e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current
wait_for "so did stderr, through the same logger" 5 grep -q e2e-clean-error /var/log/fake-systemd/e2e-clean.service/current
check "log lines carry an ISO 8601 timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+[+-][0-9:]+ e2e-clean' /var/log/fake-systemd/e2e-clean.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-clean-output" journalctl -u e2e-clean.service --no-pager
expect "stop of a finished service succeeds" 0 "" systemctl stop e2e-clean

# --- Restart= is not honored: nothing supervises ----------------------------------------------------
unit e2e-always 'ExecStart=/bin/sleep 1001
Restart=always
RestartSec=1'
expect "a Restart=always service starts" 0 "" systemctl start e2e-always
check "the script says Restart= is not honored" grep -q "^# Restart=always is not honored" /etc/rc.d/rc.e2e-always
expect "kill of the main process" 0 "" systemctl kill -s KILL e2e-always
wait_for "it reads failed" 5 active e2e-always failed
sleep 3
check "nothing restarted it, whatever Restart= says" sh -c '! pgrep -f "[s]leep 1001" >/dev/null'
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
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
expect "stop succeeds" 0 "" systemctl stop e2e-pre

# --- ExecStop= runs before the process is terminated, ExecStopPost= after it ended --------------------
unit e2e-hooks 'ExecStart=/bin/sleep 1002
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-stop-alive"
ExecStopPost=/bin/touch /tmp/e2e-post-ran
ExecReload=/bin/touch /tmp/e2e-reloaded'
expect "a unit with stop hooks starts" 0 "" systemctl start e2e-hooks
wait_for "it runs" 5 active e2e-hooks active
expect "reload runs ExecReload=" 0 "" systemctl reload e2e-hooks
check "ExecReload= ran" test -e /tmp/e2e-reloaded
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the service process was alive" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran" test -e /tmp/e2e-post-ran
rm -f /tmp/e2e-stop-alive /tmp/e2e-post-ran
expect "start again" 0 "" systemctl start e2e-hooks
wait_for "it runs again" 5 active e2e-hooks active
expect "the stop verb of the script is the same stop, run through sh as the service is not enabled" 0 "" sh /etc/rc.d/rc.e2e-hooks stop
check "ExecStop= ran for the script too" test -e /tmp/e2e-stop-alive
unit e2e-noreload 'ExecStart=/bin/sleep 1012'
expect "a unit without ExecReload= refuses reload" 1 "" systemctl reload e2e-noreload

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

# --- Dependencies: the script starts what it requires, and the hooks order them -----------------------
unit e2e-dep 'ExecStart=/bin/sleep 1004'
unit e2e-boot 'ExecStart=/bin/sleep 1005'
sed -i 's|^\[Unit\]|[Unit]\nRequires=e2e-dep.service\nAfter=e2e-dep.service|' /usr/lib/systemd/system/e2e-boot.service
expect "start of a unit with Requires= starts the requirement" 0 "" systemctl start e2e-boot
expect "the requirement is active" 0 "active" systemctl is-active e2e-dep
check "the requirement is not enabled" sh -c '! test -x /etc/rc.d/rc.e2e-dep'
check "the script names the requirement" grep -q "^# Requires: e2e-dep$" /etc/rc.d/rc.e2e-boot
expect "stop of the unit leaves the requirement" 0 "" systemctl stop e2e-boot
expect "stop of the requirement succeeds" 0 "" systemctl stop e2e-dep
systemctl start e2e-boot >/dev/null 2>&1
systemctl stop e2e-boot e2e-dep >/dev/null 2>&1

# --- Native services --------------------------------------------------------------------------------
wait_for "the system logger runs: rc.M started rc.syslog at boot" 10 pgrep -x syslogd
printf '[Service]\nExecStart=/usr/sbin/syslogd\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/syslogd.service
expect "the unit of the logger is the native service" 0 "" systemctl status syslogd
check "no script was generated for it" test ! -e /etc/rc.d/rc.syslogd
expect "is-active reads the process of the native script" 0 "active" systemctl is-active syslogd
expect "stop runs the native script" 0 "" systemctl stop syslogd
wait_for "the logger is gone" 5 sh -c '! pgrep -x syslogd'
expect "is-active reads it inactive" 3 "inactive" systemctl is-active syslogd
expect "disable clears the permission of the native script" 0 "" systemctl disable syslogd
check "rc.syslog is not executable" sh -c '! test -x /etc/rc.d/rc.syslog'
expect "enable sets it again" 0 "" systemctl enable syslogd
check "rc.syslog is executable" test -x /etc/rc.d/rc.syslog
check "rc.local has no block for a script that rc.M starts" sh -c '! grep -q rc.syslog /etc/rc.d/rc.local'
expect "start runs the native script" 0 "" systemctl start syslogd
wait_for "the logger runs" 5 pgrep -x syslogd

# --- Generated scripts run as the real boot scripts do ------------------------------------------------
for f in /golden/*.bsdrc; do
    n=$(basename "$f" .bsdrc)
    cp "$f" "/etc/rc.d/rc.$n"
    check "golden $n passes sh -n" sh -n "/etc/rc.d/rc.$n"
    rm -f "/etc/rc.d/rc.$n"
done
echo "svc-directory:x:1500:1500::/home/svc:/bin/sh" >>/etc/passwd
echo "svc-directory:x:1500:" >>/etc/group
echo "e2eextra:x:1501:svc-directory" >>/etc/group
printf '#!/bin/sh\nid >/tmp/e2e-ldap-id\necho e2e-ldap-line\nexec sleep 1008\n' >/usr/bin/dirsync
chmod 755 /usr/bin/dirsync
cp /corpus/user-ldap.service /usr/lib/systemd/system/user-ldap.service
check "the golden script for such an account gives the executor the numeric ids" grep -q -- '--uid "$(id -u -- svc-directory)"' /golden/user-ldap.bsdrc
cp /golden/user-ldap.bsdrc /etc/rc.d/rc.user-ldap
chmod 755 /etc/rc.d/rc.user-ldap
expect "the script starts as the account" 0 "" /etc/rc.d/rc.user-ldap start
wait_for "the daemon ran" 5 test -s /tmp/e2e-ldap-id
check "the account has its primary group" grep -q 'uid=1500(svc-directory) gid=1500(svc-directory)' /tmp/e2e-ldap-id
check "the account has its supplementary group" grep -q '1501(e2eextra)' /tmp/e2e-ldap-id
check "the executor stays root and owns its state files" sh -c 'test "$(stat -c %U /run/fake-systemd/user-ldap.service.daemon.pid)" = root'
check "the log directory belongs to root, whose executor starts the logger" sh -c 'test "$(stat -c %U /var/log/fake-systemd/user-ldap.service)" = root'
wait_for "the logger running as the account wrote the line" 5 grep -q e2e-ldap-line /var/log/fake-systemd/user-ldap.service/current
check "the status verb says running" rcstate user-ldap 0
expect "the script stops what runs as the account" 0 "" /etc/rc.d/rc.user-ldap stop
check "nothing of it is left" sh -c '! pgrep -f "[s]leep 1008" >/dev/null'
rm -f /etc/rc.d/rc.user-ldap /usr/lib/systemd/system/user-ldap.service

# --- Templates and the timer runner ----------------------------------------------------------------
cat >/usr/lib/systemd/system/e2e-tpl@.service <<'X'
[Service]
ExecStart=/bin/sh -c "echo %i > /tmp/e2e-tpl-%i; exec sleep 1006"

[Install]
WantedBy=multi-user.target
X
expect "a template instance starts" 0 "" systemctl start e2e-tpl@one
check "the instance is a script named with a dot" test -e /etc/rc.d/rc.e2e-tpl.one
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
check "the runner is a script that starts the timer runner as a daemon" grep -q -- "--exec fake-systemd-timers.service --daemon" /etc/rc.d/rc.fake-systemd-timers
check "the runner is enabled at boot" executable /etc/rc.d/rc.fake-systemd-timers
wait_for "the script started the runner" 10 active fake-systemd-timers active
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tick.timer
check "the runner script is removed" test ! -e /etc/rc.d/rc.fake-systemd-timers
wait_for "the runner is stopped" 10 sh -c '! pgrep -f "[f]ake-systemd --timers" >/dev/null'

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
check "rc.local lists the enabled service and not its requirement, which the script starts" sh -c "grep -q 'rc.e2e-boot start' /etc/rc.d/rc.local && ! grep -q 'rc.e2e-dep start' /etc/rc.d/rc.local"
check "rc.local_shutdown stops the service before its requirement" sh -c "[ \$(grep -n 'rc.e2e-boot stop' /etc/rc.d/rc.local_shutdown | cut -d: -f1) -lt \$(grep -n 'rc.e2e-dep stop' /etc/rc.d/rc.local_shutdown | cut -d: -f1) ]"
check "rc.local_shutdown also stops a service that is not enabled" grep -q "rc.e2e-manual stop" /etc/rc.d/rc.local_shutdown
expect "daemon-reload succeeds against the running init" 0 "" systemctl daemon-reload

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
