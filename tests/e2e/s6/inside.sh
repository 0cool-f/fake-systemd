#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside the container started by run.sh; E2E_MODE is artix, alpine-rc or alpine-s6.
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

# refute DESC COMMAND...  (succeeds when the command fails)
refute() {
    desc=$1
    shift
    if "$@" >/tmp/check.out 2>&1; then fail "$desc" "command succeeded: $*"; else ok "$desc"; fi
}

# active NAME STATE  (systemctl is-active prints STATE)
active() { systemctl is-active "$1" | grep -q "^$2\$"; }
count() { [ -e "$1" ] && wc -l <"$1" | tr -d ' '; }

mode=${E2E_MODE:?}
install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/lib/systemd/user /etc/default

# --- The setup of each mode: where services live, how they are enabled and found running -------
case $mode in
artix)
    gen=/etc/s6/adminsv
    live=/run/s6-rc
    repo=/etc/s6/repo/sources/current
    bootdb=/etc/s6/rc/compiled
    ;;
alpine-rc)
    gen=/etc/s6-rc/source
    live=/run/s6-rc
    bootdb=/etc/s6-rc/compiled
    export FAKE_SYSTEMD_INIT=s6-rc
    ;;
alpine-s6)
    gen=/etc/s6/sv
    scan=/service
    export FAKE_SYSTEMD_INIT=s6
    ;;
esac

case $mode in
artix | alpine-rc)
    is_rc=1
    # Directory with run of a service, and the directory s6-supervise keeps its state in.
    pdir() { echo "$gen/$1-srv"; }
    ldir() { echo "$gen/$1-log"; }
    sdir() { echo "$live/servicedirs/$1-srv"; }
    lsdir() { echo "$live/servicedirs/$1-log"; }
    ;;
alpine-s6)
    is_rc=0
    pdir() { echo "$gen/$1"; }
    ldir() { echo "$gen/$1/log"; }
    sdir() { echo "$scan/$1"; }
    lsdir() { echo "$scan/$1/log"; }
    ;;
esac

# What the init was told about a service: listed for boot, as each setup records it.
enabled_artifact() {
    case $mode in
    artix) test -L "$repo/active/$1-srv" ;;
    alpine-rc) test -e "$gen/default/contents.d/$1" ;;
    alpine-s6) test -L "$scan/$1" && test ! -e "$gen/$1/down" ;;
    esac
}
svrun() { s6-svstat "$(sdir "$1")" 2>/dev/null | grep -q '^up '; }
svpid() { s6-svstat -o pid "$(sdir "$1")"; }

case $mode in
artix)
    # The image was built in a chroot, so its repository names stores by their build path.
    s6 repository init -U
    s6 repository sync
    mkdir -p /run/service
    s6-svscan /run/service >/tmp/svscan.log 2>&1 &
    wait_for "s6-svscan listens on its scan directory" 5 test -p /run/service/.s6-svscan/control
    s6-rc-init -c "$bootdb" /run/service
    ;;
alpine-rc)
    mkdir -p "$gen/default/contents.d" /run/service
    echo bundle >"$gen/default/type"
    s6-rc-compile "$bootdb" "$gen"
    s6-svscan /run/service >/tmp/svscan.log 2>&1 &
    wait_for "s6-svscan listens on its scan directory" 5 test -p /run/service/.s6-svscan/control
    s6-rc-init -c "$bootdb" /run/service
    ;;
alpine-s6)
    mkdir -p "$gen" "$scan" /run/s6
    s6-svscan "$scan" >/tmp/svscan.log 2>&1 &
    wait_for "s6-svscan listens on its scan directory" 5 test -p "$scan/.s6-svscan/control"
    ;;
esac
wait_for "s6-svscan is up" 5 pgrep -x s6-svscan
for p in s6-svscan s6-rc s6-svc s6-svstat; do command -v "$p" >/dev/null && echo "# $p: $(command -v "$p")"; done
if [ -x /usr/bin/pacman ]; then pacman -Q s6 s6-rc s6-frontend s6-linux-init execline skalibs; else apk info -v | grep -E '^(s6|s6-rc|execline|skalibs)-[0-9]'; fi
expect "the backend is detected" 0 "backend: $([ $is_rc = 1 ] && echo s6-rc || echo s6)" systemctl --version

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
check "run carries the marker" grep -q "^# Generated automatically by fake-systemd" "$(pdir e2e-sleeper)/run"
check "the logger runs the uniform logger" grep -q "^exec /usr/bin/fake-systemd --log e2e-sleeper.service$" "$(ldir e2e-sleeper)/run"
for f in run finish; do check "$f passes sh -n" sh -n "$(pdir e2e-sleeper)/$f"; done
check "the logger script passes sh -n" sh -n "$(ldir e2e-sleeper)/run"
if [ $is_rc = 1 ]; then
    check "type, producer-for and the meta file are in place" sh -c "grep -qx longrun '$(pdir e2e-sleeper)/type' && grep -qx e2e-sleeper-log '$(pdir e2e-sleeper)/producer-for' && test -e '$(pdir e2e-sleeper)/fake-systemd.meta'"
    check "the logger declares the pipeline" sh -c "grep -qx e2e-sleeper-srv '$(ldir e2e-sleeper)/consumer-for' && grep -qx e2e-sleeper '$(ldir e2e-sleeper)/pipeline-name'"
    check "s6-rc knows the pipeline" sh -c "s6-rc-db -l $live type e2e-sleeper | grep -qx bundle"
else
    check "the link points at the service directory" test "$(readlink "$scan/e2e-sleeper")" = "$gen/e2e-sleeper"
fi
wait_for "the service is supervised and up" 10 svrun e2e-sleeper
wait_for "the logger runs next to the service" 10 sh -c "s6-svstat '$(lsdir e2e-sleeper)' | grep -q '^up '"
check "the service is enabled at boot" enabled_artifact e2e-sleeper
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "Main PID" systemctl status e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "stopping an enabled service keeps it enabled" enabled_artifact e2e-sleeper
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
expect "a restarted Restart=no service is running again" 0 "active" systemctl is-active e2e-sleeper
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service without Restart= is failed" 5 active e2e-sleeper failed
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
check "finish recorded the end" grep -q "^failed 256 9$" "$(sdir e2e-sleeper)/supervise/exit-status"
expect "start of a failed service starts it again" 0 "" systemctl start e2e-sleeper
wait_for "it is active again" 5 active e2e-sleeper active
expect "disable keeps a running service running" 0 "" systemctl disable e2e-sleeper
expect "the service is still active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
refute "it is no longer enabled at boot" enabled_artifact e2e-sleeper
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
expect "daemon-reload succeeds against the running init" 0 "" systemctl daemon-reload
expect "the service is still known after daemon-reload" 3 "inactive" systemctl is-active e2e-sleeper

# --- Enabled at boot or not, independent of running --------------------------------------------
expect "start of a service that is not enabled" 0 "" systemctl start e2e-sleeper
wait_for "it runs" 5 svrun e2e-sleeper
expect "start does not enable" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable lists the service for boot" 0 "" systemctl enable e2e-sleeper
check "is-enabled answers enabled" systemctl is-enabled e2e-sleeper
expect "disable of a service that is not running" 0 "" systemctl disable e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
unit e2e-boot 'ExecStart=/bin/sleep 1000'
expect "enable of a service that was never started" 0 "" systemctl enable e2e-boot
if [ $is_rc = 1 ]; then
    check "the boot bundle holds the service" sh -c "s6-rc-db -l $live contents default | grep -Eq '^e2e-boot(-srv)?\$'"
else
    wait_for "s6-svscan starts an enabled service at its next scan" 10 active e2e-boot active
fi
expect "disable of the service" 0 "" systemctl disable e2e-boot
systemctl stop e2e-boot >/dev/null 2>&1

expect "a failing service starts" 0 "" systemctl start e2e-failer
wait_for "a service whose process exited with an error is failed" 5 active e2e-failer failed
expect "stop resets the failed state" 0 "" systemctl stop e2e-failer
expect "is-active answers inactive after reset" 3 "inactive" systemctl is-active e2e-failer

# --- Executor: ExecStartPre= and EnvironmentFile= ----------------------------------------------
echo "E2E_VAR=hello" >/etc/default/e2e-pre
unit e2e-pre 'EnvironmentFile=/etc/default/e2e-pre
ExecStartPre=/bin/touch /tmp/e2e-pre-ran
ExecStart=/bin/sh -c "env >/tmp/e2e-pre-env; exec sleep 1000"'
expect "a unit with ExecStartPre= starts" 0 "" systemctl start e2e-pre
check "run goes through the executor" grep -q "^exec /usr/bin/fake-systemd --exec e2e-pre.service$" "$(pdir e2e-pre)/run"
wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
wait_for "EnvironmentFile= reached the service" 5 grep -q '^E2E_VAR=hello$' /tmp/e2e-pre-env
wait_for "executor service is active" 5 active e2e-pre active
check "the executor became the service process" sh -c "grep -q sleep /proc/$(svpid e2e-pre)/cmdline"
expect "stop succeeds" 0 "" systemctl stop e2e-pre

# --- ExecStop= runs before the process is terminated, ExecStopPost= after it ended ---------------
unit e2e-hooks 'ExecStart=/bin/sleep 1000
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-stop-alive"
ExecStopPost=/bin/touch /tmp/e2e-post-ran'
expect "a unit with stop hooks starts" 0 "" systemctl start e2e-hooks
wait_for "it runs" 5 svrun e2e-hooks
check "run starts the executor in stop mode" grep -q "^exec /usr/bin/fake-systemd --exec e2e-hooks.service --stop-on-signal$" "$(pdir e2e-hooks)/run"
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the service process was alive" test -e /tmp/e2e-stop-alive
wait_for "ExecStopPost= ran" 5 test -e /tmp/e2e-post-ran
expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-hooks
unit e2e-post 'ExecStart=/bin/sh -c "exit 1"
ExecStopPost=/bin/touch /tmp/e2e-post-crash'
expect "start of a service that exits at once" 0 "" systemctl start e2e-post
wait_for "ExecStopPost= ran after the process exited by itself" 5 test -e /tmp/e2e-post-crash
systemctl stop e2e-post >/dev/null 2>&1

# --- ExecStop= runs whenever the service is brought down, not only by systemctl -----------------------
rm -f /tmp/e2e-direct-stop /tmp/e2e-dep-stop
unit e2e-direct 'ExecStart=/bin/sleep 1000
ExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-direct-stop"'
expect "a service with ExecStop= starts" 0 "" systemctl start e2e-direct
wait_for "it runs" 5 svrun e2e-direct
check "s6-svc -d, which is what a shutdown does, ran ExecStop= with the process alive" sh -c "s6-svc -wd -T 20000 -d '$(sdir e2e-direct)' && test -e /tmp/e2e-direct-stop"
if [ $is_rc = 1 ]; then
    unit e2e-dbase 'ExecStart=/bin/sleep 1000'
    printf '[Unit]\nRequires=e2e-dbase.service\nAfter=e2e-dbase.service\n\n[Service]\nExecStart=/bin/sleep 1000\nExecStop=/bin/sh -c "kill -0 $MAINPID && touch /tmp/e2e-dep-stop"\n' >/usr/lib/systemd/system/e2e-dtop.service
    expect "the dependent service starts with its dependency" 0 "" systemctl start e2e-dtop
    wait_for "it runs" 5 svrun e2e-dtop
    check "s6-rc brings the dependency down, which stops the dependent" sh -c "s6-rc -l $live -d change e2e-dbase"
    wait_for "ExecStop= ran when s6-rc stopped the service as a dependent" 10 test -e /tmp/e2e-dep-stop
    expect "the dependent service is inactive" 3 "inactive" systemctl is-active e2e-dtop
fi

# --- Type=forking through the executor ---------------------------------------------------------------
unit e2e-fork 'Type=forking
PIDFile=/run/e2e-fork.pid
ExecStart=/usr/local/bin/e2e-forker'
expect "a forking unit starts" 0 "" systemctl start e2e-fork
wait_for "the executor follows the daemon" 5 active e2e-fork active
check "the followed pid is a live daemon" sh -c 'kill -0 "$(cat /run/e2e-fork.pid)"'
daemon=$(cat /run/e2e-fork.pid 2>/dev/null)
expect "stop of a forking unit succeeds" 0 "" systemctl stop e2e-fork
wait_for "the forked daemon is gone" 5 sh -c "! kill -0 $daemon"

# --- Dependency closure ------------------------------------------------------------------------------
unit e2e-b 'ExecStart=/bin/sleep 1000'
printf '[Unit]\nDescription=Requires b\nRequires=e2e-b.service\nAfter=e2e-b.service\n\n[Service]\nExecStart=/bin/sleep 1000\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-a.service
expect "enable --now of a unit with Requires= succeeds" 0 "" systemctl enable --now e2e-a
if [ $is_rc = 1 ]; then
    check "the required unit is a dependency of the longrun" grep -qx e2e-b "$(pdir e2e-a)/dependencies"
else
    check "the required unit is started from run" grep -q "^s6-svc -u $scan/e2e-b" "$(pdir e2e-a)/run"
    check "the required unit is linked with down, not enabled" sh -c "test -L $scan/e2e-b && test -e $gen/e2e-b/down"
fi
wait_for "the required service came up" 10 svrun e2e-b
expect "the required unit is active" 0 "active" systemctl is-active e2e-b
case $mode in
artix) expect "a set enables the dependencies of an enabled service" 0 "enabled" systemctl is-enabled e2e-b ;;
*) expect "the required unit is not enabled" 1 "disabled" systemctl is-enabled e2e-b ;;
esac
systemctl stop e2e-a >/dev/null 2>&1
systemctl stop e2e-b >/dev/null 2>&1
systemctl disable e2e-a >/dev/null 2>&1
rm -f /usr/lib/systemd/system/e2e-a.service
expect "daemon-reload collects the dependency of a removed unit" 0 "" systemctl daemon-reload
if [ $mode = artix ]; then
    refute "the working set no longer names the collected dependency" sh -c "s6 set list | grep -Eqx 'e2e-b-(srv|log)'"
    refute "no link to it is left in the set" sh -c "ls $repo/active | grep -Eqx 'e2e-b-(srv|log)'"
    check "the set still commits" s6 set commit
fi
check "the dependency's service files are removed" test ! -e "$(pdir e2e-b)/run"
if [ $is_rc = 1 ]; then
    check "the live database no longer holds it" sh -c "! s6-rc-db -l $live list all | grep -qx e2e-b-srv"
else
    check "the dependency's link is removed" test ! -e "$scan/e2e-b"
fi

# --- Templates ----------------------------------------------------------------------------------------
printf '[Service]\nExecStart=/bin/sh -c "echo %%i >/tmp/e2e-tpl-%%i; exec sleep 1000"\n\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-tpl@.service
expect "a template instance starts" 0 "" systemctl start e2e-tpl@one
check "the instance is a service named with @" test -e "$(pdir e2e-tpl@one)/run"
wait_for "the supervisor accepts the @ in the name" 5 svrun e2e-tpl@one
wait_for "the instance saw its name" 5 grep -q '^one$' /tmp/e2e-tpl-one
expect "stop of the instance succeeds" 0 "" systemctl stop e2e-tpl@one

# --- Restart= -----------------------------------------------------------------------------------------
rm -f /tmp/e2e-rf.count /tmp/e2e-rclean.count /tmp/e2e-rno.count
unit e2e-rf 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rf.count; exit 1"
Restart=on-failure
RestartSec=2'
unit e2e-rclean 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rclean.count; exit 0"
Restart=on-failure'
unit e2e-rno 'ExecStart=/bin/sh -c "echo x >>/tmp/e2e-rno.count; exit 1"
Restart=no'
expect "the Restart=on-failure service starts" 0 "" systemctl start e2e-rf
expect "the clean-exit service starts" 0 "" systemctl start e2e-rclean
expect "the Restart=no service starts" 0 "" systemctl start e2e-rno
wait_for "Restart=on-failure restarts a failing service" 15 sh -c '[ "$(wc -l </tmp/e2e-rf.count)" -ge 2 ]'
sleep 3
check "Restart=on-failure does not restart a clean exit" test "$(count /tmp/e2e-rclean.count)" = 1
check "Restart=no does not restart" test "$(count /tmp/e2e-rno.count)" = 1
expect "a service that exited cleanly is inactive" 3 "inactive" systemctl is-active e2e-rclean
systemctl stop e2e-rf >/dev/null 2>&1

# --- Oneshot ------------------------------------------------------------------------------------------
unit e2e-once 'Type=oneshot
ExecStart=/bin/touch /tmp/e2e-once-ran'
expect "a oneshot starts" 0 "" systemctl start e2e-once
wait_for "the oneshot ran" 5 test -e /tmp/e2e-once-ran
expect "a finished oneshot is inactive" 3 "inactive" systemctl is-active e2e-once
rm -f /tmp/e2e-once-ran
expect "a oneshot runs again at the next start" 0 "" systemctl start e2e-once
wait_for "it ran again" 5 test -e /tmp/e2e-once-ran
if [ $is_rc = 1 ]; then
    check "the oneshot is an s6-rc oneshot with up in execline" sh -c "grep -qx oneshot '$gen/e2e-once/type' && head -1 '$gen/e2e-once/up' | grep -qx '#!/bin/execlineb -P'"
fi
unit e2e-remain 'Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/touch /tmp/e2e-remain-start
ExecStop=/bin/touch /tmp/e2e-remain-stop'
expect "a oneshot with RemainAfterExit= starts" 0 "" systemctl start e2e-remain
wait_for "its command ran" 5 test -e /tmp/e2e-remain-start
wait_for "it stays active after the command exited" 5 active e2e-remain active
expect "stop runs ExecStop=" 0 "" systemctl stop e2e-remain
check "ExecStop= of the oneshot ran" test -e /tmp/e2e-remain-stop
expect "it is inactive after stop" 3 "inactive" systemctl is-active e2e-remain

# --- Signals and logs ---------------------------------------------------------------------------------
unit e2e-signals 'ExecStart=/usr/local/bin/e2e-signals'
expect "a signal-handling service starts" 0 "" systemctl start e2e-signals
wait_for "it runs" 5 svrun e2e-signals
expect "kill -s HUP goes through s6-svc" 0 "" systemctl kill -s HUP e2e-signals
wait_for "the service got SIGHUP" 5 test -e /tmp/e2e-hup
expect "kill -s WINCH goes through s6-svc -s" 0 "" systemctl kill -s WINCH e2e-signals
wait_for "the service got SIGWINCH" 5 test -e /tmp/e2e-winch
wait_for "the service output reached the uniform log" 5 grep -q e2e-hello-from-the-service /var/log/fake-systemd/e2e-signals.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-hello-from-the-service" journalctl -u e2e-signals.service --no-pager
expect "stop succeeds" 0 "" systemctl stop e2e-signals

# --- A service the system already has ------------------------------------------------------------------
mkdir -p "$gen/e2e-nat"
if [ $is_rc = 1 ]; then echo longrun >"$gen/e2e-nat/type"; fi
printf '#!/bin/execlineb -P\nfdmove -c 2 1\ns6-softlimit -o 1024 exec /bin/sleep 1000\n' >"$gen/e2e-nat/run"
chmod 755 "$gen/e2e-nat/run"
unit e2e-nat 'ExecStart=/bin/sleep 1000'
expect "enable --now uses the native service" 0 "" systemctl enable --now e2e-nat
check "nothing was generated over the native service" sh -c "! grep -q 'Generated automatically' '$gen/e2e-nat/run' && test ! -e '$gen/e2e-nat/finish' && test ! -e '$gen/e2e-nat-srv'"
if [ $is_rc = 1 ]; then ndir="$live/servicedirs/e2e-nat"; else ndir="$scan/e2e-nat"; fi
wait_for "the native service runs" 10 sh -c "s6-svstat '$ndir' | grep -q '^up '"
expect "reload of a native service sends SIGHUP" 0 "" systemctl reload e2e-nat
expect "disable and stop the native service" 0 "" sh -c 'systemctl disable e2e-nat && systemctl stop e2e-nat'

# --- Generated services are valid -----------------------------------------------------------------------
mkdir -p /tmp/golden-split
for f in /golden/*; do
    n=$(basename "$f")
    n=${n%.*}
    mkdir -p "/tmp/golden-split/$n"
    awk -v dir="/tmp/golden-split/$n" '/^=== /{ p = $2; out = dir "/" p; d = out; sub("/[^/]*$", "", d); system("mkdir -p \"" d "\""); printf "" > out; next } { print >> out }' "$f"
done
if [ $is_rc = 1 ]; then
    mkdir -p /tmp/golden-src
    for d in /tmp/golden-split/*; do cp -r "$d"/. /tmp/golden-src/; done
    # Dependencies that the corpus names without defining them get an empty longrun.
    for f in /tmp/golden-src/*/dependencies; do
        while read -r dep; do
            [ -d "/tmp/golden-src/$dep" ] || [ -d "/tmp/golden-src/$dep-srv" ] || {
                mkdir -p "/tmp/golden-src/$dep"
                echo longrun >"/tmp/golden-src/$dep/type"
                printf '#!/bin/sh\nexec sleep 1\n' >"/tmp/golden-src/$dep/run"
            }
        done <"$f"
    done
    check "s6-rc-compile accepts every golden service of the corpus" s6-rc-compile /tmp/golden-db /tmp/golden-src
    check "the compiled corpus lists the pipelines" sh -c "s6-rc-db -c /tmp/golden-db list bundles | grep -qx simple-daemon"
    check "the compiled corpus holds the oneshots" sh -c "s6-rc-db -c /tmp/golden-db type oneshot-remain | grep -qx oneshot"
else
    for s in /tmp/golden-split/*/run /tmp/golden-split/*/finish /tmp/golden-split/*/log/run; do
        [ -e "$s" ] && check "golden $(basename "$(dirname "$s")")/$(basename "$s") passes sh -n" sh -n "$s"
    done
fi

# --- An account only the system libc resolves: the script switches with setpriv and the groups follow ---
unit e2e-ldap 'User=svc-directory
ExecStart=/usr/bin/dirsync'
printf '#!/bin/sh\nid >/tmp/e2e-ldap-id\nexec sleep 1000\n' >/usr/bin/dirsync
chmod 755 /usr/bin/dirsync
unit e2e-ldapjob 'Type=oneshot
User=svc-directory
ExecStart=/usr/bin/dirjob'
printf '#!/bin/sh\nid >/tmp/e2e-ldapjob-id\n' >/usr/bin/dirjob
chmod 755 /usr/bin/dirjob
expect "enable of units for an account the executor cannot resolve" 0 "" systemctl enable e2e-ldap e2e-ldapjob
check "the longrun uses setpriv" grep -Eq '^exec /(usr/)?bin/setpriv --reuid=svc-directory --regid="\$\(id -g svc-directory\)" --init-groups ' "$(pdir e2e-ldap)/run"
if [ $is_rc = 1 ]; then
    check "the oneshot runs setpriv through a shell" grep -Eq '^sh -c "exec /(usr/)?bin/setpriv --reuid=svc-directory ' "$gen/e2e-ldapjob/up"
fi
echo "svc-directory:x:1500:1500::/home/svc:/bin/sh" >>/etc/passwd
echo "svc-directory:x:1500:" >>/etc/group
echo "e2eextra:x:1501:svc-directory" >>/etc/group
expect "start as the account" 0 "" systemctl start e2e-ldap e2e-ldapjob
wait_for "the generated run script starts as the account" 12 test -s /tmp/e2e-ldap-id
check "the account has its primary group" grep -q 'uid=1500(svc-directory) gid=1500(svc-directory)' /tmp/e2e-ldap-id
check "the account has its supplementary group" grep -q '1501(e2eextra)' /tmp/e2e-ldap-id
wait_for "the oneshot ran as the account" 12 test -s /tmp/e2e-ldapjob-id
check "the oneshot has the supplementary group too" grep -q '1501(e2eextra)' /tmp/e2e-ldapjob-id
systemctl stop e2e-ldap >/dev/null 2>&1
systemctl disable e2e-ldap e2e-ldapjob >/dev/null 2>&1

# --- Limits, nice and umask are applied by the script itself -----------------------------------------------
cat >/usr/local/bin/e2e-limits <<'X'
#!/bin/sh
{ ulimit -n; ulimit -Hn; umask; nice; echo "V=$E2E_V"; pwd; } >/tmp/e2e-limits
exec sleep 1000
X
chmod 755 /usr/local/bin/e2e-limits
unit e2e-limits 'LimitNOFILE=777
UMask=0027
Nice=5
Environment=E2E_V=native
WorkingDirectory=/tmp
ExecStart=/usr/local/bin/e2e-limits'
expect "a unit with limits, umask, nice and environment starts" 0 "" systemctl start e2e-limits
check "the service was not sent through the executor" grep -Eq "^exec /(usr/)?bin/nice -n 5 s6-softlimit -H -o 777 /usr/local/bin/e2e-limits$" "$(pdir e2e-limits)/run"
wait_for "the service reported its settings" 5 test -s /tmp/e2e-limits
check "the open files limit is 777" sh -c "sed -n 1p /tmp/e2e-limits | grep -qx 777 && sed -n 2p /tmp/e2e-limits | grep -qx 777"
check "the umask is 0027" sh -c "sed -n 3p /tmp/e2e-limits | grep -qx 0027"
check "nice is 5" sh -c "sed -n 4p /tmp/e2e-limits | grep -qx 5"
check "the environment and the directory arrived" sh -c "sed -n 5p /tmp/e2e-limits | grep -qx V=native && sed -n 6p /tmp/e2e-limits | grep -qx /tmp"
expect "stop succeeds" 0 "" systemctl stop e2e-limits

# --- Timeouts and network providers -------------------------------------------------------------------------
cat >/usr/local/bin/e2e-stubborn <<'X'
#!/bin/sh
trap '' TERM
while :; do sleep 1; done
X
chmod 755 /usr/local/bin/e2e-stubborn
unit e2e-stubborn 'ExecStart=/usr/local/bin/e2e-stubborn
TimeoutStopSec=2'
expect "the stubborn service starts" 0 "" systemctl start e2e-stubborn
check "the stop timeout is the timeout-kill of the service" grep -qx 2000 "$(pdir e2e-stubborn)/timeout-kill"
wait_for "the stubborn service runs" 10 svrun e2e-stubborn
began=$(date +%s)
expect "stop kills a service that ignores TERM after TimeoutStopSec=" 0 "" systemctl stop e2e-stubborn
check "it did not wait for the default of 90 seconds" test $(($(date +%s) - began)) -lt 30
expect "the stubborn service is gone" 3 "" systemctl is-active e2e-stubborn
expect "a service that had to be killed is inactive, not failed" 3 "inactive" systemctl is-active e2e-stubborn
case $mode in
artix)
    mkdir -p "$gen/dhcpcd-srv" "$gen/dhcpcd-log"
    echo longrun >"$gen/dhcpcd-srv/type"
    printf '#!/bin/sh\nexec sleep 1000\n' >"$gen/dhcpcd-srv/run"
    echo dhcpcd-log >"$gen/dhcpcd-srv/producer-for"
    echo longrun >"$gen/dhcpcd-log/type"
    printf '#!/bin/sh\nexec cat >/dev/null\n' >"$gen/dhcpcd-log/run"
    echo dhcpcd-srv >"$gen/dhcpcd-log/consumer-for"
    echo dhcpcd >"$gen/dhcpcd-log/pipeline-name"
    chmod 755 "$gen/dhcpcd-srv/run" "$gen/dhcpcd-log/run"
    s6 repository sync && s6 set enable -p dhcpcd && s6 set commit && s6 live install
    ;;
alpine-rc)
    mkdir -p "$gen/dhcpcd"
    echo longrun >"$gen/dhcpcd/type"
    printf '#!/bin/sh\nexec sleep 1000\n' >"$gen/dhcpcd/run"
    chmod 755 "$gen/dhcpcd/run"
    touch "$gen/default/contents.d/dhcpcd"
    ;;
alpine-s6)
    mkdir -p "$gen/dhcpcd"
    printf '#!/bin/sh\nexec sleep 1000\n' >"$gen/dhcpcd/run"
    chmod 755 "$gen/dhcpcd/run"
    ln -s "$gen/dhcpcd" "$scan/dhcpcd"
    ;;
esac
printf '#!/bin/sh\nexec sleep 1000\n' >/usr/local/bin/e2e-net-svc
chmod 755 /usr/local/bin/e2e-net-svc
printf '[Unit]\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nExecStart=/usr/local/bin/e2e-net-svc\n' >/usr/lib/systemd/system/e2e-net.service
expect "a unit that waits for the network starts" 0 "" systemctl start e2e-net
if [ $is_rc = 1 ]; then
    check "the enabled network provider became a dependency" grep -qx dhcpcd "$(pdir e2e-net)/dependencies"
    case $mode in artix) pd="$live/servicedirs/dhcpcd-srv" ;; *) pd="$live/servicedirs/dhcpcd" ;; esac
else
    check "the enabled network provider became a soft dependency" grep -q "^s6-svc -u $scan/dhcpcd" "$(pdir e2e-net)/run"
    pd="$scan/dhcpcd"
fi
wait_for "starting the unit started the provider" 10 sh -c "s6-svstat '$pd' | grep -q '^up '"
systemctl stop e2e-net >/dev/null 2>&1

# --- Timers: built-in runner as a service --------------------------------------------------------------------
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
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" "/var/lib/fake-systemd/$([ $is_rc = 1 ] && echo s6-rc || echo s6)/index"
check "the runner service runs the timer runner" grep -q "^exec /usr/bin/fake-systemd --timers$" "$(pdir fake-systemd-timers)/run"
check "the runner is enabled at boot" enabled_artifact fake-systemd-timers
wait_for "the runner is up" 15 svrun fake-systemd-timers
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
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
wait_for "the signal made the running runner load the new timer" 30 sh -c 'grep -q e2e-tock-output /var/log/fake-systemd/e2e-tock.service/current'
expect "daemon-reload keeps the runner going" 0 "" systemctl daemon-reload
expect "disable of one timer keeps the runner" 0 "" systemctl disable e2e-tick.timer
check "the runner unit stays while a built-in timer is left" test -e /etc/systemd/system/fake-systemd-timers.service
expect "disable of the last built-in timer succeeds" 0 "" systemctl disable e2e-tock.timer
check "the runner unit is removed" test ! -e /etc/systemd/system/fake-systemd-timers.service
check "the runner service files are removed" test ! -e "$(pdir fake-systemd-timers)/run"
wait_for "the runner is stopped" 10 sh -c "! s6-svstat '$(sdir fake-systemd-timers)' 2>/dev/null | grep -q '^up '"

# --- User services are not offered ---------------------------------------------------------------------------
printf '[Service]\nExecStart=/bin/sleep 1000\n\n[Install]\nWantedBy=default.target\n' >/usr/lib/systemd/user/e2e-user.service
expect "user services are refused with a message" 1 "" systemctl --user enable e2e-user
check "the message says why" sh -c "systemctl --user enable e2e-user 2>&1 | grep -q 'has no user services'"

# --- Offline: a root that is not the running system ---------------------------------------------------------
if [ $is_rc = 1 ]; then init=s6-rc; else init=s6; fi
mkdir -p /tmp/fakeroot/usr/lib/systemd/system /tmp/fakeroot/etc /tmp/fakeroot/bin
cp /etc/os-release /tmp/fakeroot/etc/
cp /bin/sleep /tmp/fakeroot/bin/
cp /usr/lib/systemd/system/e2e-sleeper.service /tmp/fakeroot/usr/lib/systemd/system/
expect "enable in a --root tree succeeds" 0 "" env FAKE_SYSTEMD_INIT=$init systemctl --root=/tmp/fakeroot enable e2e-sleeper
if [ $is_rc = 1 ]; then
    check "the sources were written inside the root" test -e "/tmp/fakeroot$(pdir e2e-sleeper)/run"
    if [ $mode = artix ]; then verb=enable; else verb=disable; fi
    check "the database is left for the target with a notice" sh -c "FAKE_SYSTEMD_INIT=$init systemctl --root=/tmp/fakeroot $verb e2e-sleeper 2>&1 | grep -q 'not rebuilt inside a --root tree'"
else
    check "the link was written inside the root" test -L "/tmp/fakeroot$scan/e2e-sleeper"
fi

# Take the init down, then enable in the real root as an image build does.
if [ $is_rc = 1 ]; then s6-svscanctl -t /run/service; else s6-svscanctl -t "$scan"; fi
wait_for "s6-svscan is gone" 15 sh -c '! pgrep -x s6-svscan'
rm -rf /run/s6-rc /run/s6-rc:* /run/service
printf '#!/bin/sh\nexec sleep 1000\n' >/usr/local/bin/e2e-offline-svc
chmod 755 /usr/local/bin/e2e-offline-svc
unit e2e-offline 'ExecStart=/usr/local/bin/e2e-offline-svc'
expect "enable in the real root without a running init" 0 "" systemctl --root=/ enable e2e-offline
expect "is-enabled answers enabled" 0 "enabled" systemctl --root=/ is-enabled e2e-offline
case $mode in
artix) check "the boot database holds the service" sh -c "s6-rc-db -c $bootdb contents default | grep -Eqx 'e2e-offline(-srv)?'" ;;
alpine-rc) check "the boot database holds the service" sh -c "s6-rc-db -c $bootdb contents default | grep -Eqx 'e2e-offline(-srv)?'" ;;
alpine-s6) check "the service is linked into the scan directory" test -L "$scan/e2e-offline" ;;
esac
expect "disable in the real root" 0 "" systemctl --root=/ disable e2e-offline
expect "is-enabled answers disabled" 1 "disabled" systemctl --root=/ is-enabled e2e-offline

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
