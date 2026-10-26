#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside a container started by run.sh: inside.sh online|offline
# `online` starts a shepherd daemon first, `offline` runs where none does, as in a chroot or a container build.
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
# hline NAME TEXT  (a line of `herd status` contains TEXT)
hline() { herd status "$1" 2>/dev/null | grep -qF -- "$2"; }
# hpid NAME  (the process id `herd status` prints)
hpid() { herd status "$1" 2>/dev/null | sed -n 's/^ *Main PID: \([0-9]*\)$/\1/p'; }
# cmdline NAME  (the command line of the main process of the service)
cmdline() { tr "\0" " " <"/proc/$(hpid "$1")/cmdline"; }
# cmdline_has NAME TEXT  (the command line of the main process contains TEXT)
cmdline_has() { cmdline "$1" | grep -q "$2"; }
# loaded NAME  (shepherd knows the service)
loaded() { herd status "$1" >/dev/null 2>&1; }

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
ln -sf fake-systemd /usr/bin/journalctl
mkdir -p /usr/lib/systemd/system /usr/local/bin
echo "# $(dpkg-query -W -f='${Package} ${Version} ' shepherd util-linux)"

# unit NAME BODY  (a service unit wanted by multi-user.target)
unit() { printf '[Unit]\nDescription=%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" >"/usr/lib/systemd/system/$1.service"; }
# unitx NAME UNITLINES BODY  (a service unit with lines in its [Unit] section)
unitx() { printf '[Unit]\nDescription=%s\n%s\n[Service]\n%s\n[Install]\nWantedBy=multi-user.target\n' "$1" "$2" "$3" >"/usr/lib/systemd/system/$1.service"; }

if [ "$mode" = offline ]; then
    # --- No daemon runs: a chroot or a container build -------------------------------------------
    check "no shepherd runs" sh -c '! pgrep -x guile >/dev/null && test ! -e /run/shepherd/socket'
    expect "the backend is shepherd, found from its tools" 0 "shepherd" systemctl --version
    unit e2e-off 'ExecStart=/bin/sleep 1000'
    expect "enable succeeds offline" 0 "" systemctl enable e2e-off
    check "the file was generated" grep -q "^# Generated automatically by fake-systemd" /etc/shepherd/available/e2e-off.scm
    check "the file starts with the block comment Guile skips" sh -c 'head -n 1 /etc/shepherd/available/e2e-off.scm | grep -qx "#!" && grep -qx "!#" /etc/shepherd/available/e2e-off.scm'
    check "the link is in init.d" sh -c 'test "$(readlink /etc/shepherd/init.d/e2e-off.scm)" = ../available/e2e-off.scm'
    check "the configuration was written because none existed" grep -q 'init.d' /etc/shepherd.scm
    expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-off
    expect "start offline only says so" 0 "" systemctl start e2e-off
    check "nothing was started" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
    expect "is-active answers inactive" 3 "inactive" systemctl is-active e2e-off
    expect "daemon-reload offline succeeds" 0 "" systemctl daemon-reload
    expect "enable --now offline enables and starts nothing" 0 "" systemctl enable --now e2e-off
    expect "disable succeeds offline" 0 "" systemctl disable e2e-off
    expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-off
    check "the generated file stays" test -e /etc/shepherd/available/e2e-off.scm

    # A configuration of the user's own is not rewritten.
    printf '(use-modules (shepherd service))\n' >/etc/shepherd.scm
    unit e2e-two 'ExecStart=/bin/sleep 1000'
    expect "enable with a configuration that does not load init.d warns" 0 "" systemctl enable e2e-two
    check "the configuration is untouched" sh -c '[ "$(cat /etc/shepherd.scm)" = "(use-modules (shepherd service))" ]'
    check "the loader is written beside it" grep -q 'scandir' /etc/shepherd.scm.loader

    # A root that is not the running one: nothing is called, links are relative.
    r=/tmp/e2e-root
    mkdir -p $r/usr/lib/systemd/system $r/etc/shepherd $r/usr/bin
    cp /etc/os-release $r/etc/os-release
    cp /bin/true $r/usr/bin/true
    printf '[Service]\nExecStart=/usr/bin/true\n[Install]\nWantedBy=multi-user.target\n' >$r/usr/lib/systemd/system/e2e-root.service
    expect "enable in another root succeeds" 0 "" env FAKE_SYSTEMD_INIT=shepherd systemctl --root=$r enable e2e-root
    check "the file is in the other root" grep -q "^# Generated automatically by fake-systemd" $r/etc/shepherd/available/e2e-root.scm
    check "the link resolves inside that root" test -e $r/etc/shepherd/init.d/e2e-root.scm
    check "nothing was written to the running root" test ! -e /etc/shepherd/available/e2e-root.scm
    expect "disable in the other root succeeds" 0 "" env FAKE_SYSTEMD_INIT=shepherd systemctl --root=$r disable e2e-root

    echo "# $passed passed, $failed failed"
    [ "$failed" -eq 0 ]
    exit
fi

# --- A daemon runs ---------------------------------------------------------------------------------
echo "# $(shepherd --version | head -n 1)"
shepherd_up() {
    rm -f /run/shepherd/socket
    (setsid shepherd >>/tmp/shepherd.log 2>&1 &)
    i=0
    while [ $i -lt 100 ]; do
        herd status >/dev/null 2>&1 && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}
check "shepherd starts as a daemon" shepherd_up
expect "the backend is shepherd" 0 "shepherd" systemctl --version

# --- Lifecycle -----------------------------------------------------------------------------------
unit e2e-sleeper 'ExecStart=/bin/sleep 1000'
expect "enable succeeds" 0 "" systemctl enable e2e-sleeper
check "the configuration loads init.d, as it did not exist before" grep -q 'init.d' /etc/shepherd.scm
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "is-active answers inactive: the daemon has not read the file yet" 3 "inactive" systemctl is-active e2e-sleeper
expect "start loads the service into the daemon and starts it" 0 "" systemctl start e2e-sleeper
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
check "shepherd runs the service" hline e2e-sleeper "It is running since"
expect "status shows the main process" 0 "Main PID" systemctl status e2e-sleeper
check "status shows the pid shepherd has" sh -c "systemctl status e2e-sleeper | grep -q 'Main PID: $(hpid e2e-sleeper)'"
check "the main process is the unit command, after the executor replaced itself" cmdline_has e2e-sleeper "sleep 1000"
first_pid=$(hpid e2e-sleeper)
expect "restart succeeds" 0 "" systemctl restart e2e-sleeper
check "restart started a new process" sh -c "test \"\$(herd status e2e-sleeper | sed -n 's/^ *Main PID: //p')\" != $first_pid"
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
expect "start of a running service succeeds" 0 "" systemctl start e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
check "shepherd reports it stopped" hline e2e-sleeper "It is stopped"
check "no process is left" sh -c '! pgrep -f "[s]leep 1000" >/dev/null'
check "stopping an enabled service keeps its link" test -L /etc/shepherd/init.d/e2e-sleeper.scm
expect "restart of a stopped service starts it" 0 "" systemctl restart e2e-sleeper
expect "disable keeps a running service running" 0 "" systemctl disable e2e-sleeper
expect "the service is still active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
check "the link is gone" test ! -e /etc/shepherd/init.d/e2e-sleeper.scm
expect "stop of a disabled service succeeds" 0 "" systemctl stop e2e-sleeper
expect "enable turns the link back" 0 "" systemctl enable e2e-sleeper
expect "stop of a stopped service succeeds" 0 "" systemctl stop e2e-sleeper

# --- Exit states ----------------------------------------------------------------------------------
unit e2e-failer 'ExecStart=/bin/sh -c "echo e2e-failer-line; exit 3"'
unit e2e-clean 'ExecStart=/bin/sh -c "echo e2e-clean-output; echo e2e-clean-error >&2; sleep 0.5"'
expect "a service that exits with an error starts" 0 "" systemctl start e2e-failer
wait_for "it reads failed" 5 active e2e-failer failed
expect "is-failed answers 0" 0 "failed" systemctl is-failed e2e-failer
expect "start of a failed service works again, though shepherd disabled it" 0 "" systemctl start e2e-failer
wait_for "it fails again" 5 active e2e-failer failed
expect "stop resets nothing and succeeds" 0 "" systemctl stop e2e-failer
expect "a service that ends cleanly starts" 0 "" systemctl start e2e-clean
wait_for "a clean exit reads inactive" 5 active e2e-clean inactive
expect "is-failed answers 1 for a clean exit" 1 "inactive" systemctl is-failed e2e-clean
wait_for "stdout reached the uniform log" 5 grep -q e2e-clean-output /var/log/fake-systemd/e2e-clean.service/current
wait_for "so did stderr" 5 grep -q e2e-clean-error /var/log/fake-systemd/e2e-clean.service/current
check "log lines carry an ISO 8601 timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+[+-][0-9:]+ e2e-clean' /var/log/fake-systemd/e2e-clean.service/current
expect "journalctl -u shows the output of the service" 0 "e2e-clean-output" journalctl -u e2e-clean.service --no-pager
unit e2e-killed 'ExecStart=/bin/sleep 1004'
expect "start of a service to kill" 0 "" systemctl start e2e-killed
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-killed
wait_for "a service killed by a signal reads failed" 5 active e2e-killed failed
expect "start of a killed service starts it again" 0 "" systemctl start e2e-killed
expect "it is active again" 0 "active" systemctl is-active e2e-killed
expect "stop succeeds" 0 "" systemctl stop e2e-killed

# --- Restart= is the respawn of Shepherd ---------------------------------------------------------------
unit e2e-always 'ExecStart=/bin/sleep 1005
Restart=always
RestartSec=1'
expect "a Restart=always service starts" 0 "" systemctl start e2e-always
check "the file respawns with a delay" sh -c 'grep -q "#:respawn? #t" /etc/shepherd/available/e2e-always.scm && grep -q "#:respawn-delay 1" /etc/shepherd/available/e2e-always.scm'
old=$(hpid e2e-always)
expect "kill of the main process" 0 "" systemctl kill -s KILL e2e-always
wait_for "shepherd respawned it with a new process" 10 sh -c "p=\$(herd status e2e-always | sed -n 's/^ *Main PID: //p'); [ -n \"\$p\" ] && [ \"\$p\" != $old ]"
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
check "the file signals the executor alone, which runs ExecStop=" grep -q -- '"--stop-on-signal"' /etc/shepherd/available/e2e-hooks.scm
check "the runtime directory exists while it runs" test -d /run/e2e-hooks
expect "stop succeeds" 0 "" systemctl stop e2e-hooks
check "ExecStop= ran while the service process was alive" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran after the stop" test -e /tmp/e2e-post-ran
check "the runtime directory was removed" test ! -e /run/e2e-hooks
rm -f /tmp/e2e-stop-alive /tmp/e2e-post-ran
expect "start again" 0 "" systemctl start e2e-hooks
expect "herd stop runs the same stop" 0 "" herd stop e2e-hooks
check "ExecStop= ran for herd too" test -e /tmp/e2e-stop-alive
check "ExecStopPost= ran for herd too" test -e /tmp/e2e-post-ran

# --- Reload runs ExecReload= through the executor ------------------------------------------------------
unit e2e-reload 'ExecStart=/bin/sleep 1008
ExecReload=/bin/touch /tmp/e2e-reload-ran'
expect "start of a service with ExecReload=" 0 "" systemctl start e2e-reload
expect "reload succeeds" 0 "" systemctl reload e2e-reload
check "ExecReload= ran" test -e /tmp/e2e-reload-ran
expect "the service was not restarted" 0 "active" systemctl is-active e2e-reload
expect "stop succeeds" 0 "" systemctl stop e2e-reload

# --- Oneshots run to the end inside start -----------------------------------------------------------------
printf '[Unit]\nDescription=oneshot\n[Service]\nType=oneshot\nExecStart=/bin/sh -c "echo oneshot-out; sleep 1; touch /tmp/e2e-oneshot-ran"\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-oneshot.service
printf '[Unit]\nDescription=remain\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\nExecStop=/bin/touch /tmp/e2e-remain-stopped\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-remain.service
printf '[Unit]\nDescription=badshot\n[Service]\nType=oneshot\nExecStart=/bin/false\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2e-badshot.service
expect "a oneshot runs and start waits for it" 0 "" systemctl start e2e-oneshot
check "the command ran before start returned" test -e /tmp/e2e-oneshot-ran
expect "a oneshot without RemainAfterExit= is inactive after it ran" 3 "inactive" systemctl is-active e2e-oneshot
rm -f /tmp/e2e-oneshot-ran
expect "start runs it again" 0 "" systemctl start e2e-oneshot
check "the command ran again" test -e /tmp/e2e-oneshot-ran
wait_for "its output reached the log" 5 grep -q oneshot-out /var/log/fake-systemd/e2e-oneshot.service/current
expect "a oneshot with RemainAfterExit= starts" 0 "" systemctl start e2e-remain
expect "it stays active" 0 "active" systemctl is-active e2e-remain
expect "stop of it runs ExecStop=" 0 "" systemctl stop e2e-remain
check "ExecStop= ran" test -e /tmp/e2e-remain-stopped
expect "it is inactive after the stop" 3 "inactive" systemctl is-active e2e-remain
expect "a failing oneshot fails the start" 1 "" systemctl start e2e-badshot

# --- Dependencies are requirements ---------------------------------------------------------------------
unit e2e-dep 'ExecStart=/bin/sleep 1009'
unitx e2e-main 'Requires=e2e-dep.service
After=e2e-dep.service' 'ExecStart=/bin/sleep 1010'
expect "start of a service with Requires=" 0 "" systemctl start e2e-main
check "the file requires its dependency" grep -q "#:requirement '(e2e-dep)" /etc/shepherd/available/e2e-main.scm
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
check "the file has no setpriv: the executor switches" sh -c '! grep -q setpriv /etc/shepherd/available/e2e-user.scm'
wait_for "it runs as the account" 5 grep -qx e2eapp /tmp/e2e-user-name
wait_for "with the groups of the account" 5 grep -qw e2egrp /tmp/e2e-user-groups
expect "stop succeeds" 0 "" systemctl stop e2e-user

# --- An account only the system libc knows (LDAP, sssd) is switched by setpriv -----------------------------
mkdir -p /var/lib/extrausers
echo 'ldaplike:x:2500:2500:ldap like:/:/usr/sbin/nologin' >/var/lib/extrausers/passwd
printf 'ldapgrp:x:2500:\nldapsup:x:2600:ldaplike\n' >/var/lib/extrausers/group
: >/var/lib/extrausers/shadow
sed -i 's/^passwd:.*/passwd: files extrausers/; s/^group:.*/group: files extrausers/' /etc/nsswitch.conf
unit e2e-ldap 'User=ldaplike
ExecStart=/bin/sh -c "id -un >/tmp/e2e-ldap-name; id -gn >/tmp/e2e-ldap-group; id -Gn >/tmp/e2e-ldap-groups; exec sleep 1018"
ExecReload=/bin/sh -c "id -un >/tmp/e2e-ldap-reload"'
expect "a service whose account is not in /etc/passwd starts" 0 "" systemctl start e2e-ldap
check "the file switches with setpriv, which resolves the account through the libc" grep -q 'setpriv' /etc/shepherd/available/e2e-ldap.scm
wait_for "it runs as the account" 5 grep -qx ldaplike /tmp/e2e-ldap-name
wait_for "with its primary group" 5 grep -qx ldapgrp /tmp/e2e-ldap-group
wait_for "and its supplementary groups" 5 grep -qw ldapsup /tmp/e2e-ldap-groups
expect "reload runs behind the same switch" 0 "" systemctl reload e2e-ldap
wait_for "ExecReload= ran as the account" 5 grep -qx ldaplike /tmp/e2e-ldap-reload
expect "stop succeeds" 0 "" systemctl stop e2e-ldap

# --- Native services win --------------------------------------------------------------------------------
printf '#!/bin/sh\nexec sleep 1012\n' >/usr/local/bin/e2e-nat
chmod 755 /usr/local/bin/e2e-nat
cat >/etc/shepherd/init.d/e2enative.scm <<'X'
(use-modules (shepherd service))
(register-services
 (list (service '(e2e-native-name)
         #:start (make-forkexec-constructor '("/usr/local/bin/e2e-nat"))
         #:stop (make-kill-destructor))))
X
printf '[Unit]\nDescription=native twin\n[Service]\nExecStart=/usr/local/bin/e2e-nat\n[Install]\nWantedBy=multi-user.target\n' >/usr/lib/systemd/system/e2enative.service
herd load root /etc/shepherd/init.d/e2enative.scm >/dev/null 2>&1
expect "enable uses the native service" 0 "" systemctl enable e2enative
check "nothing was generated" test ! -e /etc/shepherd/available/e2enative.scm
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2enative
expect "start uses the name the native definition provides" 0 "" systemctl start e2enative
expect "it is active" 0 "active" systemctl is-active e2enative
expect "stop succeeds" 0 "" systemctl stop e2enative

# --- Templates --------------------------------------------------------------------------------------------
printf '[Unit]\nDescription=template %%i\n[Service]\nExecStart=/bin/sleep 1013\n[Install]\nWantedBy=multi-user.target\n' >'/usr/lib/systemd/system/e2e-tpl@.service'
expect "an instance starts" 0 "" systemctl start e2e-tpl@one.service
check "it is a service named name-instance" grep -q "(service '(e2e-tpl-one)" /etc/shepherd/available/e2e-tpl-one.scm
expect "it is active" 0 "active" systemctl is-active e2e-tpl@one.service
expect "stop succeeds" 0 "" systemctl stop e2e-tpl@one.service

# --- daemon-reload and regeneration ----------------------------------------------------------------------
unit e2e-regen 'ExecStart=/bin/sleep 1014'
expect "start of a service to change" 0 "" systemctl start e2e-regen
check "it runs the first command" cmdline_has e2e-regen "sleep 1014"
unit e2e-regen 'ExecStart=/bin/sleep 1015'
expect "daemon-reload regenerates the file and has shepherd read it again" 0 "" systemctl daemon-reload
check "the running process was left alone" cmdline_has e2e-regen "sleep 1014"
expect "restart picks the change up" 0 "" systemctl restart e2e-regen
wait_for "the service runs the new command" 5 cmdline_has e2e-regen "sleep 1015"
expect "stop succeeds" 0 "" systemctl stop e2e-regen

# --- Timers: the built-in runner is a Shepherd service -----------------------------------------------------
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
check "the timer is assigned to the built-in runner" grep -q "^timer.e2e-tick.timer.builtin" /var/lib/fake-systemd/shepherd/index
check "the runner unit is translated like any unit" grep -q '"--exec" "fake-systemd-timers.service"' /etc/shepherd/available/fake-systemd-timers.scm
check "the runner is enabled at boot" test -L /etc/shepherd/init.d/fake-systemd-timers.scm
wait_for "shepherd runs the runner" 10 hline fake-systemd-timers "It is running since"
wait_for "the timer fired at least twice" 30 sh -c '[ "$(grep -c e2e-tick-output /var/log/fake-systemd/e2e-tick.service/current)" -ge 2 ]'
expect "journalctl -u shows the output of the timer job" 0 "e2e-tick-output" journalctl -u e2e-tick.service --no-pager
expect "list-timers lists the timer with its service" 0 "e2e-tick.service" systemctl list-timers
expect "disable of the timer succeeds" 0 "" systemctl disable e2e-tick.timer
expect "the runner is stopped when no timer needs it" 3 "inactive" systemctl is-active fake-systemd-timers

# --- The goldens of the corpus are registered by Shepherd ------------------------------------------------------
mkdir -p /tmp/golden
for g in /golden/*.shepherd; do
    awk -v dir=/tmp/golden '
        /^=== / { if (out) close(out); out = dir "/" $2; next }
        { print > out }
    ' "$g"
done
for f in /tmp/golden/*.scm; do
    n=$(basename "$f" .scm)
    check "golden $n loads into shepherd" sh -c "herd load root $f && herd status $n"
done
check "golden deps-mix requires its dependencies" sh -c 'herd status deps-mix | grep -q "Requires\|Provides: deps-mix"'
check "golden restart-always will be respawned" sh -c 'herd status restart-always | grep -q "Will be respawned"'
check "golden notify-service has the kill signal handled" sh -c 'herd status notify-service >/dev/null'

# --- A service that is enabled starts when shepherd starts ------------------------------------------------------
unit e2e-boot 'ExecStart=/bin/sleep 1016'
expect "enable of the service that starts at boot" 0 "" systemctl enable e2e-boot
expect "stop the daemon" 0 "" herd stop root
wait_for "the daemon is gone" 10 sh -c '! herd status >/dev/null 2>&1'
check "shepherd starts again" shepherd_up
wait_for "the enabled service was started by the loader" 15 active e2e-boot active
check "a service that is not enabled was not" sh -c '! loaded e2e-regen'

# --- A shutdown stops the services, ExecStop= included -----------------------------------------------------------
unit e2e-shutdown 'ExecStart=/bin/sleep 1017
ExecStop=/bin/touch /out/e2e-shutdown-stop'
expect "enable --now of the service that a shutdown stops" 0 "" systemctl enable --now e2e-shutdown
expect "it is active" 0 "active" systemctl is-active e2e-shutdown
expect "stop of the daemon stops its services" 0 "" herd stop root
wait_for "ExecStop= ran at the shutdown" 10 test -e /out/e2e-shutdown-stop
check "no service process is left" sh -c '! pgrep -f "[s]leep 101[0-9]" >/dev/null'

echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
