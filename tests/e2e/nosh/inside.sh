#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh online|offline
# `online` starts the service manager of nosh first, `offline` runs where none does, as in a chroot or a container build.
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
# nstate NAME WORD  (the State line of `system-control status` names WORD)
nstate() { system-control status "$1" 2>/dev/null | sed -n 's/^[[:space:]]*State[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' | grep -qx "$2"; }
# npid NAME  (the main process of the service)
npid() { system-control status "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Main PID:[[:space:]]*\([0-9]*\)$/\1/p'; }
# cmdline NAME  (the command line of the main process of the service)
cmdline() { tr "\0" " " <"/proc/$(npid "$1")/cmdline"; }
# cmdline_has NAME TEXT  (the command line of the main process contains TEXT)
cmdline_has() { cmdline "$1" | grep -q "$2"; }
# fakecg NAME...  (the control group directories the run script of a bundle moves into)
fakecg() { for n in "$@"; do mkdir -p "/sys/fs/$n.service" 2>/dev/null && : >"/sys/fs/$n.service/cgroup.procs"; done; return 0; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/local/bin
echo "# $(dpkg-query -W -f='${Package} ${Version} ' nosh-service-management nosh-bundles util-linux)"

# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; fakecg "$1"; }
# unitx NAME UNITLINES BODY  (a service unit with lines in its [Unit] section)
unitx() { printf '[Unit]\nDescription=%s\n%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" "$3" >"/usr/lib/systemd/system/$1.service"; fakecg "$1"; }

if [ "$mode" = offline ]; then
    # --- No service manager runs: a chroot or a container build ---------------------------------------
    check "no service manager runs" sh -c 'test ! -e /run/service-manager/control'
    expect "the backend is nosh, found from its tools" 0 "nosh" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    check "the unit was recorded" grep -q "^# Generated automatically by fake-systemd" /etc/service-bundles/fake-systemd/e2e-off
    check "nosh converted it into a bundle" test -x /etc/service-bundles/services/e2e-off/service/run
    check "the run script carries the marker, after its #! line" sh -c 'head -n 1 /etc/service-bundles/services/e2e-off/service/run | grep -qx "#!/bin/nosh" && grep -q "^# Unit: e2e-off.service" /etc/service-bundles/services/e2e-off/service/run'
    check "the bundle is wanted by multi-user and the target links it" test -L /etc/service-bundles/targets/multi-user/wants/e2e-off
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    expect "start offline only says so" 0 "" systemctl start e2e-off
    check "nothing was started" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
    expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-off
    expect "daemon-reload offline succeeds" 0 "" systemctl daemon-reload
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off
    check "the bundle stays" test -x /etc/service-bundles/services/e2e-off/service/run
    rm /usr/lib/systemd/system/e2e-off.service
    expect "daemon-reload removes the record of a unit that is gone" 0 "" systemctl daemon-reload
    check "its record is gone, and the bundle stays until a service manager reloads" sh -c 'test ! -e /etc/service-bundles/fake-systemd/e2e-off && test -e /etc/service-bundles/services/e2e-off'

    # A unit the converter of nosh refuses fails with its reason.
    printf '[Unit]\nDescription=notify\n[Service]\nType=notify\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-notify.service
    expect "enable of a Type=notify unit fails, nosh cannot run it" 1 "" systemctl enable e2e-notify
    check "nothing is left of it in the services" test ! -e /etc/service-bundles/services/e2e-notify

    # A root that is not the running one: the tools of nosh do not reach it.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/etc/service-bundles/services $r/usr/bin
    cp /etc/os-release $r/etc/os-release
    cp /bin/true $r/usr/bin/true
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root says where nosh converts" 1 "" env FAKE_SYSTEMD_INIT=nosh systemctl --root=$r enable e2e-root
    check "the record is in the other root" test -e $r/etc/service-bundles/fake-systemd/e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- The service manager runs ----------------------------------------------------------------------
# The converted run scripts move the service into a control group beside that of the manager; a
# rootless container has none to give, so a tmpfs stands in for the control groups.
mount -t tmpfs none /sys/fs && mkdir /sys/fs/cgroup
for t in /etc/service-bundles/targets/*; do mkdir -p "/sys/fs/$(basename "$t").target" && : >"/sys/fs/$(basename "$t").target/cgroup.procs"; done
mkdir -p /run/service-manager
(setsid local-datagram-socket-listen /run/service-manager/control service-manager >/tmp/service-manager.log 2>&1 &)
wait_for "the service manager listens" 10 test -S /run/service-manager/control
expect "the backend is nosh" 0 "nosh" systemctl --version

# --- Lifecycle -----------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sleep 1000'
expect "enable succeeds" 0 "" systemctl enable e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-sleeper
expect "start converts if needed and starts" 0 "" systemctl start e2e-sleeper
wait_for "is-active answers active" 10 active e2e-sleeper active
check "nosh runs the service" nstate e2e-sleeper running
expect "status shows the main process" 0 "Main PID" systemctl status e2e-sleeper
check "status shows the pid nosh has" sh -c "systemctl status e2e-sleeper | grep -q 'Main PID: $(npid e2e-sleeper)'"
check "the main process is the unit command" cmdline_has e2e-sleeper "sleep 1000"
first_pid=$(npid e2e-sleeper)
expect "restart succeeds" 0 "" systemctl restart e2e-sleeper
wait_for "restart started a new process" 10 sh -c "p=\$(system-control status e2e-sleeper | sed -n 's/^[[:space:]]*Main PID: //p'); [ -n \"\$p\" ] && [ \"\$p\" != $first_pid ]"
expect "start of a running service succeeds" 0 "" systemctl start e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
wait_for "is-active answers inactive after stop" 10 active e2e-sleeper inactive
check "no process is left" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
expect "disable keeps a running service running" 0 "" sh -c 'systemctl start e2e-sleeper && systemctl disable e2e-sleeper && systemctl is-active e2e-sleeper'
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper

# --- Exit states ----------------------------------------------------------------------------------
unit e2e-failer 'ExecStart=/bin/sh -c "exit 3"'
unit e2e-clean 'ExecStart=/bin/sh -c "sleep 0.5"'
unit e2e-killed 'ExecStart=/bin/sleep 1004'
expect "a service that exits with an error starts" 0 "" systemctl start e2e-failer
wait_for "it reads failed" 10 active e2e-failer failed
expect "is-failed answers 0" 0 "failed" systemctl is-failed e2e-failer
expect "a service that ends cleanly starts" 0 "" systemctl start e2e-clean
wait_for "a clean exit reads inactive" 10 active e2e-clean inactive
expect "is-failed answers 1 for a clean exit" 1 "inactive" systemctl is-failed e2e-clean
expect "start of a service to kill" 0 "" systemctl start e2e-killed
wait_for "it runs" 10 active e2e-killed active
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-killed
wait_for "a service killed by a signal reads failed" 10 active e2e-killed failed
expect "start of a killed service starts it again" 0 "" systemctl start e2e-killed
wait_for "it is active again" 10 active e2e-killed active
expect "stop succeeds" 0 "" systemctl stop e2e-killed

# --- Restart= is the restart script of nosh --------------------------------------------------------
unit e2e-always 'ExecStart=/bin/sleep 1005
Restart=always
RestartSec=1'
expect "a Restart=always service starts" 0 "" systemctl start e2e-always
wait_for "it runs" 10 active e2e-always active
old=$(npid e2e-always)
expect "kill of the main process" 0 "" systemctl kill -s KILL e2e-always
wait_for "nosh restarted it with a new process" 15 sh -c "p=\$(system-control status e2e-always | sed -n 's/^[[:space:]]*Main PID: //p'); [ -n \"\$p\" ] && [ \"\$p\" != $old ]"
expect "stop succeeds" 0 "" systemctl stop e2e-always

# --- Settings the converter maps ---------------------------------------------------------------------
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
WorkingDirectory=/tmp
ExecStart=/usr/local/bin/e2e-pre ${E2E_VAR}-${E2E_OTHER}'
expect "a unit with environment settings starts" 0 "" systemctl start e2e-pre
wait_for "Environment= reached the service" 10 grep -q '^E2E_OTHER=two$' /tmp/e2e-pre-env
wait_for "EnvironmentFile= reached the service" 10 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
expect "stop succeeds" 0 "" systemctl stop e2e-pre

useradd -M -s /usr/sbin/nologin e2eapp
unit e2e-user 'User=e2eapp
ExecStart=/bin/sh -c "id -un >/tmp/e2e-user-name; exec sleep 1011"'
expect "a service with User= starts" 0 "" systemctl start e2e-user
wait_for "it runs as the account" 10 grep -qx e2eapp /tmp/e2e-user-name
expect "stop succeeds" 0 "" systemctl stop e2e-user

# --- Oneshots ---------------------------------------------------------------------------------------------
printf '[Unit]\nDescription=oneshot\n[Service]\nType=oneshot\nExecStart=/bin/sh -c "sleep 1; touch /tmp/e2e-oneshot-ran"\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-oneshot.service
printf '[Unit]\nDescription=remain\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-remain.service
printf '[Unit]\nDescription=badshot\n[Service]\nType=oneshot\nExecStart=/bin/false\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-badshot.service
fakecg e2e-oneshot e2e-remain e2e-badshot
expect "a oneshot runs and start waits for it" 0 "" systemctl start e2e-oneshot
check "the command ran" test -e /tmp/e2e-oneshot-ran
expect "a oneshot without RemainAfterExit= is inactive after it ran" 3 "inactive" systemctl is-active e2e-oneshot
expect "a oneshot with RemainAfterExit= starts" 0 "" systemctl start e2e-remain
expect "it stays active" 0 "active" systemctl is-active e2e-remain
expect "a failing oneshot fails the start" 1 "" systemctl start e2e-badshot
expect "and reads failed" 3 "failed" systemctl is-active e2e-badshot

# --- Dependencies are the links of the bundle ------------------------------------------------------------
unit e2e-dep 'ExecStart=/bin/sleep 1009'
unitx e2e-main 'Requires=e2e-dep.service
After=e2e-dep.service' 'ExecStart=/bin/sleep 1010'
expect "start of a service with Requires=" 0 "" systemctl start e2e-main
check "the bundle wants its dependency, which the converter makes of Requires=" test -e /etc/service-bundles/services/e2e-main/wants/e2e-dep
wait_for "the dependency was started with it" 10 active e2e-dep active
wait_for "the service is active" 10 active e2e-main active
expect "stop of the service" 0 "" systemctl stop e2e-main
expect "stop of the dependency" 0 "" systemctl stop e2e-dep

# --- Templates --------------------------------------------------------------------------------------------
printf '[Unit]\nDescription=template %%i\n[Service]\nExecStart=/bin/sleep 1013\n[Install]\nWantedBy=multi-user.target\n' >'/usr/lib/systemd/system/e2e-tpl@.service'
mkdir -p '/sys/fs/e2e-tpl@.service' '/sys/fs/e2e-tpl@.service/e2e-tpl@one.service' && : >'/sys/fs/e2e-tpl@.service/e2e-tpl@one.service/cgroup.procs'
expect "an instance starts" 0 "" systemctl start e2e-tpl@one.service
check "it is a bundle named name@instance" test -x /etc/service-bundles/services/e2e-tpl@one/service/run
wait_for "it is active" 10 active e2e-tpl@one.service active
expect "stop succeeds" 0 "" systemctl stop e2e-tpl@one.service

# --- Native services win ------------------------------------------------------------------------------------
mkdir -p /etc/service-bundles/services/e2enative/service
printf '#!/bin/nosh\nmove-to-control-group ../e2enative.service\n/usr/local/bin/e2e-nat\n' >/etc/service-bundles/services/e2enative/service/run
printf '#!/bin/nosh\ntrue\n' >/etc/service-bundles/services/e2enative/service/start
printf '#!/bin/nosh\ntrue\n' >/etc/service-bundles/services/e2enative/service/stop
chmod 755 /etc/service-bundles/services/e2enative/service/*
printf '#!/bin/sh\nexec sleep 1012\n' >/usr/local/bin/e2e-nat
chmod 755 /usr/local/bin/e2e-nat
fakecg e2enative
printf '[Unit]\nDescription=native twin\n[Service]\nExecStart=/usr/local/bin/e2e-nat\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2enative.service
expect "start uses the native bundle" 0 "" systemctl start e2enative
check "nothing was recorded for it" test ! -e /etc/service-bundles/fake-systemd/e2enative
wait_for "it is active" 10 active e2enative active
expect "stop succeeds" 0 "" systemctl stop e2enative

# --- daemon-reload and regeneration ----------------------------------------------------------------------
unit e2e-regen 'ExecStart=/bin/sleep 1014'
expect "start of a service to change" 0 "" systemctl start e2e-regen
wait_for "it runs the first command" 10 cmdline_has e2e-regen "sleep 1014"
unit e2e-regen 'ExecStart=/bin/sleep 1015'
expect "daemon-reload converts the changed unit" 0 "" systemctl daemon-reload
check "the bundle has the new command" grep -q 'sleep 1015' /etc/service-bundles/services/e2e-regen/service/run
check "the running process was left alone" cmdline_has e2e-regen "sleep 1014"
expect "restart picks the change up" 0 "" systemctl restart e2e-regen
wait_for "the service runs the new command" 10 cmdline_has e2e-regen "sleep 1015"
expect "stop succeeds" 0 "" systemctl stop e2e-regen

# --- Reload runs ExecReload= through the executor -------------------------------------------------------------
unit e2e-reload 'ExecStart=/bin/sleep 1008
ExecReload=/bin/touch /tmp/e2e-reload-ran'
expect "start of a service with ExecReload=" 0 "" systemctl start e2e-reload
expect "reload succeeds" 0 "" systemctl reload e2e-reload
check "ExecReload= ran" test -e /tmp/e2e-reload-ran
expect "the service was not restarted" 0 "active" systemctl is-active e2e-reload
expect "stop succeeds" 0 "" systemctl stop e2e-reload

# --- A unit that is gone takes its bundle with it at the next reload ---------------------------------------------
unit e2e-gone 'ExecStart=/bin/sleep 1019'
expect "enable of a unit that will go" 0 "" systemctl enable e2e-gone
check "its bundle exists" test -x /etc/service-bundles/services/e2e-gone/service/run
rm /usr/lib/systemd/system/e2e-gone.service
expect "daemon-reload with the service manager running" 0 "" systemctl daemon-reload
check "the record and the bundle are gone" sh -c 'test ! -e /etc/service-bundles/services/e2e-gone && test ! -e /etc/service-bundles/fake-systemd/e2e-gone'
check "so is its link in the target" sh -c '! test -L /etc/service-bundles/targets/multi-user/wants/e2e-gone || ! test -e /etc/service-bundles/targets/multi-user/wants/e2e-gone'

# --- Timers: the built-in runner is a nosh service -----------------------------------------------------------
cat >/usr/lib/systemd/system/e2e-tick.service <<'X'
[Unit]
Description=Timer job

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo e2e-tick >>/tmp/e2e-tick.log"
X
cat >/usr/lib/systemd/system/e2e-tick.timer <<'X'
[Unit]
Description=Every five seconds

[Timer]
OnCalendar=*:*:0/5

[Install]
WantedBy=timers.target
X
fakecg e2e-tick fake-systemd-timers
expect "enable of a timer with a seconds calendar succeeds" 0 "" systemctl enable e2e-tick.timer
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/nosh/index
check "the runner unit is converted like any unit" test -x /etc/service-bundles/services/fake-systemd-timers/service/run
wait_for "nosh runs the runner" 15 active fake-systemd-timers active
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick /tmp/e2e-tick.log)" -ge 2 ]'
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "disable of the timer succeeds" 0 "" systemctl disable e2e-tick.timer

# --- The converter reads the units of the corpus --------------------------------------------------------------
mkdir -p /tmp/corpus-root /tmp/corpus-units
cp /corpus/*.service /tmp/corpus-units/
for u in /tmp/corpus-units/*.service; do
    n=$(basename "$u")
    case $n in
        # nosh converts services of the types simple, forking and oneshot only, and no ExecStop=
        notify-service.service | tpl-login@.service | apt-daily-upgrade.service) continue ;;
    esac
    check "the converter accepts $n" sh -c "cd /tmp/corpus-units && system-control convert-systemd-units --bundle-root /tmp/corpus-root ./$n"
done
for n in notify-service.service apt-daily-upgrade.service; do
    check "the converter refuses $n, which nosh cannot run" sh -c "cd /tmp/corpus-units && ! system-control convert-systemd-units --bundle-root /tmp/corpus-root ./$n 2>/dev/null"
done
for g in /golden/*.nosh; do
    check "golden $(basename "$g") names its unit" sh -c "grep -q '^unit .*\.service\$' $g"
done

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
