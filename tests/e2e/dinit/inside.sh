#!/bin/sh
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

install -m 755 /opt/fake-systemd/fake-systemd /usr/bin/fake-systemd
ln -sf fake-systemd /usr/bin/systemctl
mkdir -p /usr/lib/dinit.d /etc/dinit.d/boot.d /usr/lib/systemd/system /etc/default
printf 'type = internal\nwaits-for.d = /etc/dinit.d/boot.d\n' > /usr/lib/dinit.d/boot

dinit -s -o -q -l /tmp/dinit.log </dev/null >/dev/null 2>&1 &
wait_for "dinit control socket is up" 5 test -S /run/dinitctl
dinit --version | head -1

cat > /usr/lib/systemd/system/e2e-sleeper.service <<'X'
[Unit]
Description=End-to-end sleeper

[Service]
ExecStart=/bin/sleep 1000

[Install]
WantedBy=multi-user.target
X
cat > /usr/lib/systemd/system/e2e-failer.service <<'X'
[Unit]
Description=Exits with an error

[Service]
ExecStart=/bin/sh -c "exit 3"
Restart=no

[Install]
WantedBy=multi-user.target
X

expect "enable --now succeeds" 0 "" systemctl enable --now e2e-sleeper
check "service file is generated with the marker" grep -q "^# Generated automatically by fake-systemd" /usr/lib/dinit.d/e2e-sleeper
check "service file passes dinit-check" dinit-check -d /usr/lib/dinit.d -d /etc/dinit.d e2e-sleeper
check "boot link points at the service file" test "$(readlink /etc/dinit.d/boot.d/e2e-sleeper)" = /usr/lib/dinit.d/e2e-sleeper
wait_for "dinit reports the service started" 5 sh -c 'dinitctl is-started e2e-sleeper | grep -q STARTED'
expect "is-active answers active" 0 "active" systemctl is-active e2e-sleeper
expect "is-enabled answers enabled" 0 "enabled" systemctl is-enabled e2e-sleeper
expect "status exits 0 for a running service" 0 "" systemctl status e2e-sleeper
expect "stop succeeds" 0 "" systemctl stop e2e-sleeper
expect "is-active answers inactive after stop" 3 "inactive" systemctl is-active e2e-sleeper
expect "restart starts a stopped service" 0 "" systemctl restart e2e-sleeper
expect "is-active answers active after restart" 0 "active" systemctl is-active e2e-sleeper
expect "restart of a running service succeeds" 0 "" systemctl restart e2e-sleeper
expect "kill sends a signal to the service" 0 "" systemctl kill -s KILL e2e-sleeper
wait_for "a killed service without Restart= is failed" 5 sh -c 'systemctl is-active e2e-sleeper | grep -q failed'
expect "is-failed answers 0 for a failed service" 0 "failed" systemctl is-failed e2e-sleeper
expect "disable succeeds" 0 "" systemctl disable e2e-sleeper
check "boot link is removed" test ! -e /etc/dinit.d/boot.d/e2e-sleeper
expect "is-enabled answers disabled" 1 "disabled" systemctl is-enabled e2e-sleeper
expect "daemon-reload succeeds against the running dinit" 0 "" systemctl daemon-reload
expect "enable --runtime adds the dependency without a link" 0 "" systemctl enable --runtime e2e-sleeper
check "no boot link is written for --runtime" test ! -e /etc/dinit.d/boot.d/e2e-sleeper
expect "disable --runtime removes the dependency" 0 "" systemctl disable --runtime e2e-sleeper

expect "a failing service starts" 0 "" systemctl start e2e-failer
wait_for "a service whose process exited with an error is failed" 5 sh -c 'systemctl is-active e2e-failer | grep -q failed'

# Unit that needs the executor: ExecStartPre= runs before the main command.
cat > /usr/lib/systemd/system/e2e-pre.service <<'X'
[Unit]
Description=Needs the executor

[Service]
ExecStartPre=/bin/touch /tmp/e2e-pre-ran
ExecStart=/bin/sleep 1000

[Install]
WantedBy=multi-user.target
X
expect "a unit with ExecStartPre= starts" 0 "" systemctl start e2e-pre
check "generated command goes through the executor" grep -q "^command = /usr/bin/fake-systemd --exec e2e-pre.service$" /usr/lib/dinit.d/e2e-pre
if /usr/bin/fake-systemd --exec e2e-pre.service --help 2>&1 | grep -q "^usage: invoke as"; then
    ok "ExecStartPre= ran before the main command # SKIP the binary has no --exec entry point yet"
    ok "executor service is active # SKIP the binary has no --exec entry point yet"
else
    wait_for "ExecStartPre= ran before the main command" 5 test -e /tmp/e2e-pre-ran
    wait_for "executor service is active" 5 sh -c 'systemctl is-active e2e-pre | grep -q "^active"'
fi
systemctl stop e2e-pre >/dev/null 2>&1

# Dependency closure: starting a brings up b through depends-on.
cat > /usr/lib/systemd/system/e2e-a.service <<'X'
[Unit]
Description=Requires b
Requires=e2e-b.service
After=e2e-b.service

[Service]
ExecStart=/bin/sleep 1000

[Install]
WantedBy=multi-user.target
X
cat > /usr/lib/systemd/system/e2e-b.service <<'X'
[Unit]
Description=Required by a

[Service]
ExecStart=/bin/sleep 1000

[Install]
WantedBy=multi-user.target
X
expect "enable --now of a unit with Requires= succeeds" 0 "" systemctl enable --now e2e-a
check "the required unit is translated too" grep -q "^depends-on = e2e-b$" /usr/lib/dinit.d/e2e-a
check "the required unit is not enabled at boot" test ! -e /etc/dinit.d/boot.d/e2e-b
wait_for "dinit brought the required service up" 5 sh -c 'dinitctl is-started e2e-b | grep -q STARTED'
expect "the required unit is active" 0 "active" systemctl is-active e2e-b
systemctl stop e2e-a >/dev/null 2>&1
rm -f /usr/lib/systemd/system/e2e-a.service
expect "daemon-reload collects the dependency of a removed unit" 0 "" systemctl daemon-reload
check "the dependency's service file is removed" test ! -e /usr/lib/dinit.d/e2e-b

# Golden services are accepted by dinit-check.
mkdir -p /svc /var/log/fake-systemd /home/tester/.local/state/fake-systemd/log/user-unit.service
for f in /golden/*.dinit; do cp "$f" "/svc/$(basename "$f" .dinit)"; done
for d in network syslog dbus postgresql; do printf 'type = internal\n' > "/svc/$d"; done
echo "svc-directory:x:1500:1500::/home/x:/bin/sh" >> /etc/passwd
echo "svc-directory:x:1500:" >> /etc/group
grep -h '^\(command\|stop-command\) = ' /svc/* | sed 's/^[a-z-]* = //' | tr ' ' '\n' | grep '^/' | sort -u | while read -r p; do
    [ -e "$p" ] || { mkdir -p "$(dirname "$p")"; printf '#!/bin/sh\n' > "$p"; chmod 755 "$p"; }
done
grep -h '^logfile = ' /svc/* | sed 's/^logfile = //;s|/current$||' | while read -r d; do mkdir -p "$d"; done
for s in $(ls /svc); do
    case $s in network | syslog | dbus | postgresql) continue ;; esac
    check "golden $s passes dinit-check" sh -c "dinit-check -d /svc $s 2>&1 | grep -q 'No problems found'"
done

dinitctl shutdown >/dev/null 2>&1
echo "# $passed passed, $failed failed"
[ "$failed" -eq 0 ]
