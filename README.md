# fake-systemd

A `systemctl` and `journalctl` compatibility layer for Linux systems that do not run systemd.

## The problem

On Artix, Void, Devuan, Alpine, Gentoo, Chimera and similar distributions, third-party packages and
scripts still call systemd tools:

```text
/tmp/alpm_jKVKZ5/.INSTALL: line 58: systemctl: command not found
```

fake-systemd is a single static, multi-call binary written in Zig. Invoked as `systemctl` or
`journalctl`, it follows the systemd command-line contract (verbs, options, output, exit codes) and
drives the init that is actually running. systemd units are translated into the init's native service
format on first use, so `systemctl enable --now foo` ends up as a real service of your init.

It does not implement D-Bus, socket activation, cgroups, sandboxing, or the other systemd tools
(`systemd-tmpfiles`, `systemd-sysusers`, ...).

## Supported init systems

| Init | Status |
|---|---|
| dinit | supported |
| runit (Void, Artix) | supported |
| s6-rc (Artix with the `s6` frontend; elsewhere compiled from source directories) | supported |
| s6 (scan directory without s6-rc) | supported |
| OpenRC (Alpine, Gentoo, Artix) | supported |
| sysvinit (Devuan, Debian, Red Hat family) | supported |
| BSD-style rc (Slackware) | supported |
| procd (OpenWrt) | supported |
| 66 (Obarun; 0.9 and later) | supported |
| BusyBox init (with `runsvdir` in the inittab, or with init scripts) | supported |
| finit (4.x) | supported |
| GNU Shepherd (outside Guix System; on Guix System `enable` and `disable` only warn) | supported |
| nosh (delegates to its unit converter; no user services) | experimental |

## Installation

### Arch Linux (AUR)

```sh
git clone https://aur.archlinux.org/fake-systemd-bin.git
cd fake-systemd-bin && makepkg -si
```

The package provides `systemctl` and conflicts with `systemd`.

### Release tarball

Each release at `https://github.com/0cool-f/fake-systemd/releases` ships static tarballs
`fake-systemd-<version>-<target>.tar.gz` for `x86_64-linux-musl`, `aarch64-linux-musl`,
`arm-linux-musleabihf`, `riscv64-linux-musl` and `x86-linux-musl`, plus `SHA256SUMS` signed with
[cosign](https://github.com/sigstore/cosign) (keyless, Sigstore). Verify, then install:

```sh
version=0.1.0
target=x86_64-linux-musl
base=https://github.com/0cool-f/fake-systemd/releases/download/v$version
curl -fLO "$base/fake-systemd-$version-$target.tar.gz"
curl -fLO "$base/SHA256SUMS"
curl -fLO "$base/SHA256SUMS.sigstore.json"

cosign verify-blob \
    --bundle SHA256SUMS.sigstore.json \
    --certificate-identity "https://github.com/0cool-f/fake-systemd/.github/workflows/release.yml@refs/tags/v$version" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS

tar -xzf "fake-systemd-$version-$target.tar.gz"
doas cp -P "fake-systemd-$version-$target"/{fake-systemd,systemctl,journalctl} /usr/local/bin/
```

The tarball also contains `LICENSE` and this `README.md`. `systemctl` and `journalctl` are symlinks
to `fake-systemd`.

## Usage

```sh
systemctl daemon-reload
systemctl enable --now foo.service
systemctl is-active foo
systemctl status foo
systemctl restart foo
systemctl disable --now foo
systemctl list-unit-files
systemctl list-timers
journalctl -u foo -n 50
journalctl -u foo -f
```

Offline work on another root (chroots, image builds):

```sh
systemctl --root=/mnt/target enable foo
```

`--version` prints the fake-systemd version and the detected backend.

### Translation

A unit is translated to the init's native format only when a verb needs it (`Translate=lazy`);
`daemon-reload` translates every candidate with `Translate=eager`. A native service that already
provides the same functionality always wins over a translated one. Units that cannot be translated
are reported as `unsupported` in `list-unit-files`.

### Markers, local edits and backups

Every generated file starts with a header block (`Generated automatically by fake-systemd...`) that
records the unit, its source and content hashes. An index under `/var/lib/fake-systemd/<backend>/`
(`$XDG_STATE_HOME/fake-systemd/` for `--user`) tracks generated files and can be rebuilt from the
markers.

Local edits to generated files are kept. When both you and a package changed a file, your file stays
and the new version is saved as `.fsnew` under `/var/lib/fake-systemd/backup/<backend>/`; when the
source unit is removed but the file was modified, it is moved there as `.fssave`. Removing the header
block makes the file yours: fake-systemd no longer touches it.

### Dry run

`--dry-run` (or `FAKE_SYSTEMD_DRY_RUN=1`, for scripts you cannot edit) runs the whole pipeline without
writing anything or contacting the init. It prints a unified diff for each file that would change and
the init commands that would run:

```sh
systemctl --dry-run enable foo
```

### Timers

`.timer` units are managed with the usual verbs. For each enabled timer fake-systemd picks a
scheduler: a native cron (cronie or Debian cron through `/etc/cron.d`, dcron and BusyBox `crond`
through the root crontab, fcron) when the schedule translates exactly, otherwise a built-in runner
(`fake-systemd-timers`, a service supervised by the init). Both run the same job, so logs,
`journalctl -u` and `list-timers` behave identically. `--user` timers always use the built-in runner.

### s6 and s6-rc

A unit becomes the source directories of an s6-rc longrun `foo-srv` whose output feeds the logger
`foo-log` of a pipeline named `foo` (a oneshot unit becomes an s6-rc oneshot with `up` and `down` in
execline), or, on plain s6, a service directory linked into the scan directory. On Artix the `s6`
frontend does the work: `enable` runs `s6 repository sync`, `s6 set enable -p`, `s6 set commit` and
`s6 live install`. Elsewhere `enable` lists the service in the boot bundle `default` and builds a new
database with `s6-rc-compile`, which `s6-rc-update` moves the running system to; `daemon-reload`
builds it again.

- s6-rc has one kind of dependency, so `Wants=` and the network providers become dependencies like
  `Requires=`. With the Artix sets an enabled service pulls its dependencies into the set, so they are
  enabled too.
- Offline in the real root (`--root=/`) the database is built without touching a live one; inside
  another root only the sources are written and the database is left for the target.
- A service with `ExecStop=` runs under the executor, which stays resident and runs the stop commands
  when it gets SIGTERM, so they run on every stop: `systemctl stop`, s6-rc stopping the service as a
  dependent, a shutdown. (On plain s6 a oneshot that holds after its command gets them from
  `systemctl stop` only.)
- A oneshot without `RemainAfterExit=` runs again at each `start`: s6-rc brings it down first, which also
  stops the services that depend on it.
- There are no user services.

### OpenRC

A unit becomes an `openrc-run` script in `/etc/init.d` (`foo@bar.service` becomes `foo.bar`), and
`enable` adds a link to it in the `default` runlevel with `rc-update`. Verified on Alpine (OpenRC
0.63.2), Gentoo (0.63.3), Artix (0.64.1) and Devuan (0.45.2). Units with `Restart=` run under
`supervise-daemon`, with the output going to the uniform log through `output_logger` and
`error_logger`. The others run their executor under `start-stop-daemon` with a pid file of its own;
the executor logs the output of the service itself and records how the main process ended, so the
service does not depend on what `start-stop-daemon` can do (the one of dpkg can do little).

- `Requires=` and `BindsTo=` become `need`, `Wants=` becomes `want`, `After=` and `Before=` become
  `after` and `before`, and the network targets become `use net` and `use network-online`.
  OpenRC starts the services a script needs itself, so they are not enabled.
- `supervise-daemon` respawns on every exit, so `Restart=on-failure` and its variants restart after a
  clean exit too.
- OpenRC records a service whose process is gone as started and crashed. For a service without
  `Restart=`, `status` reads the file its executor wrote: a clean end (or `SuccessExitStatus=`) is
  `inactive`, anything else, and a death without a file, is `failed`. A service that `supervise-daemon`
  gave up on is `failed` as well.
- A oneshot stays started in OpenRC; `status` reads it as inactive unless `RemainAfterExit=yes`, and
  each `start` runs it again.
- A service with `ExecStop=` runs under the executor, which stays resident and runs the stop commands
  when it gets SIGTERM, so they run on every stop: `systemctl stop`, a runlevel change, a shutdown.
- `User=` and `Group=` use `command_user` under `supervise-daemon`, which applies the groups of the
  account. An account the executor cannot read from `/etc/passwd` (LDAP, sssd) reaches the executor as
  numeric ids (`--uid`, `--gid`, `--groups`) that the script looks up with `id` and `getent`; the
  executor stays root and switches itself.
- OpenRC reads dependencies from a cache that it does not rebuild when a script appears, so `start` and
  `restart` run `rc-update -u` first when the script directory is newer than the cache.
- User services need OpenRC 0.60 or later with a user session (`openrc-user`).

### sysvinit

A unit becomes an LSB init script in `/etc/init.d` (`foo@bar.service` becomes `foo.bar`) with the LSB
header that `insserv` reads, and on Red Hat the `chkconfig:` header as well. `enable` links it with
`update-rc.d <script> defaults` on Debian and Devuan and with `chkconfig <script> on` on Red Hat, and
`is-enabled` looks for a start link in the default runlevel: the `initdefault` of `/etc/inittab`, else 2
on Debian and 3 on Red Hat. The scripts have the actions `start`, `stop`, `restart`, `try-restart`,
`reload`, `force-reload` and `status`, and answer `status` with the exit statuses of the LSB (0 running,
1 dead with a pid file, 3 not running). Verified with sysvinit as PID 1 on Devuan 5 (sysvinit 3.06,
insserv 1.24.0, dpkg 1.21.23) and Debian 13 (sysvinit 3.14, insserv 1.26.0, dpkg 1.22.22). The Red Hat
family is verified on Rocky Linux 10 (chkconfig 1.30, initscripts 10.26) and 9 (chkconfig 1.24,
initscripts 10.11.8), which boot systemd: no sysvinit runs there, so the tests stand in a process
named `init` and the control socket for it. The `/etc/rc.d/rc` of a sysvinit system (CentOS 6,
initscripts 9.03.61) was read for the lock files, not run.

- Every service runs under the executor, which logs, records how the main process ended in
  `/run/fake-systemd/<unit>.exit`, and turns SIGTERM into the stop, so `ExecStop=` runs whenever the
  script stops the service: `systemctl stop`, a runlevel change, a shutdown. A daemon is started in the
  background by `start-stop-daemon` on Debian and by `fake-systemd --exec <unit> --daemon` on Red Hat,
  and its executor pid is in `<unit>.daemon.pid`; `<unit>.pid` holds the main process.
- sysvinit supervises nothing: `Restart=` is not honored, and a service that dies stays dead. `status`
  reads `failed` for it (the script says it is dead and not restarted), which is also how a timer
  runner that died shows, since the runner is such a service. A oneshot runs to the end in `start` and
  is `inactive` afterwards, or `active` with `RemainAfterExit=yes`; a `Type=forking` service without
  `PIDFile=` is that kind of oneshot, which stop cannot signal.
- `Requires=` and `BindsTo=` are named in a `# Pulls-In:` line, and `enable` enables those scripts with
  the service (`daemon-reload` does for a requirement added later). `After=` and `Wants=` only order.
  On Debian every unit a unit follows, wants or requires is `Should-Start`: `insserv` stops with a fatal
  error at a `Required-Start` that names a script that is not enabled, and then at every later run for
  any script. Red Hat's `chkconfig` sorts by `Required-Start` and `Should-Start` alike and ignores a missing
  script, so the hard dependencies are `Required-Start` there. `Before=` is `X-Start-Before`, which
  `insserv` honors and `chkconfig` does not. The network targets are the `$network` facility, and the
  filesystems `$remote_fs`.
- `update-rc.d` calls `systemctl` for `enable` and `disable` when one is installed, and `chkconfig` does
  for a script that has a unit of the same name; both would call this program, so they run with
  `_SKIP_SYSTEMD_NATIVE=1` and `SYSTEMCTL_SKIP_REDIRECT=1`.
- Offline, in a chroot or a container build, the tools are used as they are online, since they write
  the links without an init. For another `--root` they cannot be called, and the links are written
  directly: late start links and early stop links (80 and 20, or the priorities of `chkconfig:`), which
  `insserv` or `chkconfig` sort at their next run.
- On Red Hat a start creates `/var/lock/subsys/<script>` and a stop removes it, because `/etc/rc.d/rc`
  runs a stop link only for a script that has one.
- `policy-rc.d` is consulted by `invoke-rc.d` and by the maintainer scripts of packages, not by
  `systemctl`, which does not consult it with systemd either. `systemctl start` starts the service where
  `invoke-rc.d` is denied; offline, nothing starts in any case.
- A socket `/run/initctl` is no running init unless PID 1 is an `init`: container images keep one where
  nothing runs, and systemd offers a socket of that name.
- Power verbs run `shutdown -r now`, `shutdown -h -P now` and `shutdown -h -H now`, which go through the
  stop links of runlevel 6 and 0.
- There are no user services.

### BSD-style rc (Slackware)

A unit becomes the script `/etc/rc.d/rc.<name>` (`foo@bar.service` becomes `rc.foo.bar`), which takes
the verbs `start`, `stop`, `restart`, `reload` and `status` and answers `status` with the exit statuses
of the LSB. Slackware has no mechanism for a new service: `rc.M` starts a fixed list of scripts and then
`rc.local`, and `rc.6` runs `rc.local_shutdown stop` before it stops a fixed list. So `enable` sets the
execute permission of the script, which is what enables a script of the system, and writes a managed
block (`# BEGIN fake-systemd` ... `# END fake-systemd`) in `rc.local` that starts the enabled generated
scripts, ordered by their dependencies. A block in `rc.local_shutdown` stops every generated script in
the opposite order, enabled or not, so that a service started by hand or as a requirement runs its
`ExecStop=` at the shutdown too. A script that is not executable is disabled, and `start` runs it
through `sh`. A native script that `rc.M` already starts, such as `rc.syslog`, is enabled by the
permission alone; for another one `enable` warns that nothing starts it. Verified with sysvinit 3.01 as
PID 1 on Slackware 15.0 (`aclemons/slackware:15.0`, a rolling image pinned by digest, with the packages
of the release installed by `slackpkg`): a boot starts the enabled services from `rc.local`, and
`systemctl poweroff` runs their stop commands through `rc.local_shutdown`.

- Every service runs under the executor, as with sysvinit: it logs, records how the main process ended
  in `/run/fake-systemd/<unit>.exit`, and turns SIGTERM into the stop. A daemon is detached with
  `fake-systemd --exec <unit> --daemon`. Nothing supervises it: `Restart=` is not honored, and a service
  that dies reads `failed`. A oneshot runs to the end in `start`, and is `inactive` afterwards, or
  `active` with `RemainAfterExit=yes`, whose `ExecStop=` runs at the shutdown.
- `Requires=`, `BindsTo=` and `Wants=` are scripts that `start` runs first, a failure of the first two
  failing the start. `After=` and `Before=` only order the blocks. The network targets map to nothing:
  `rc.local` runs after `rc.inet1` and `rc.inet2`.
- The state of a native script is the process of its pid file, else a process named like the program
  it starts, since these scripts have no `status` verb.
- An account the executor cannot read from `/etc/passwd` (LDAP, sssd) reaches it as numeric ids
  (`--uid`, `--gid`, `--groups`) that the script looks up with `id` and `getent`; the executor stays
  root and switches itself.
- Power verbs run `shutdown -r now`, `shutdown -h -P now` and `shutdown -h -H now`, which go through
  `rc.6`.
- There are no user services.

### procd (OpenWrt)

A unit becomes an init script `/etc/init.d/<name>` that starts with `#!/bin/sh /etc/rc.common` and
sets `USE_PROCD=1`, and `enable` runs `/etc/init.d/<name> enable`, which writes `S<START><name>` and
`K<STOP><name>` in `/etc/rc.d`. Without an init the links are written directly: the script cannot run,
since its procd library takes a lock in `/var/lock`. Verified on the OpenWrt 25.12.5 root file system
(`openwrt/rootfs`, procd as PID 1 started by `/sbin/init` in a rootless container): a boot starts the
enabled services from their start links, and `systemctl poweroff` runs their stop commands through the
stop links.

- A daemon is an instance that `start_service` registers with procd, which supervises it and respawns
  it as `Restart=` and `RestartSec=` say (`procd_set_param respawn 10 <RestartSec> 5`). procd respawns
  on every exit, so `Restart=on-failure` and its variants restart after a clean exit too. The command is
  the executor, `fake-systemd --exec <unit> --log`, because procd can send the output of a service to
  its log daemon but not to a file; the executor also switches `User=` and `Group=` and applies the
  limits, so procd's own `user` parameter, which would drop the privileges the executor needs for the log
  directory, is not used. `status` is what `ubus call service list` says: `active`, `failed` after an
  instance exited with an error, `inactive` otherwise.
- `procd_kill` returns before the instance is gone, so the script waits for it in `service_stopped`
  (up to `TimeoutStopSec=` and the grace of the executor): `ExecStop=` and `ExecStopPost=` have run when
  `stop` returns, and procd does not go on with the shutdown before they did. procd runs the stop
  links only, so every generated script has one, `disable` leaves it, and a service that was started by
  hand or as a requirement stops with the others. The stop links of scripts that are gone leave at
  `daemon-reload`.
- `Requires=`, `BindsTo=` and `Wants=` are scripts that `start_service` starts first, a failure of the
  first two failing the start. `START` follows the scripts a unit requires, wants or follows (one more
  than the greatest) and precedes those it is before; `STOP` is `100 - START`. The network targets are
  satisfied by the default `START=50`, after `network` (20).
- A oneshot has no instance, so its script defines `start`, `stop`, `status` and `running` itself and
  keeps the state in the files of the executor, as the sysvinit scripts do. `EnvironmentFile=` paths are
  `procd_set_param file`, so that `reload` restarts the instance when a file changed. `ExecReload=` is
  `reload_service`; without it `reload` says so, and does not restart.
- OpenWrt uses musl, which reads accounts from `/etc/passwd` and `/etc/group` only, and has no `setpriv`:
  the executor switches every account it can find there, and the script says so when it cannot.
- BusyBox applets are links to one binary: the normalization of executables keeps their names, or
  `/bin/sleep` would be taken for the `crond` of the system.
- Power verbs run `reboot`, `poweroff` and `halt`, which signal procd.
- There are no user services.

### 66 (Obarun)

A unit becomes a frontend file in 66's own format: `/usr/share/66/service` for a vendor unit,
`/etc/66/service` for an administrator unit, `~/.66/service` for a user unit (root writes the user
directories of the system, `/usr/share/66/service/user` and `/etc/66/service/user`, an account that is not
root cannot, and gets the personal directory for every tier). `enable` runs `66 enable -P`, which parses
the frontend file into the default tree and enables the service alone, without the dependencies 66 would
enable and the dependents it would disable; `66 start` starts a dependency that is not enabled anyway.
Verified on 66 0.9.1.2 with oblibs 0.4.0.1 (built from source on Alpine 3.24, where nothing packages 66)
as PID 1 (`66 boot -c`), after a restart of the container, at shutdown, and offline. Releases before
0.9.0.0 name the `Timeout` keys differently and are not supported.

- Every service runs through the executor: `[Start] Execute` is a shell script that execs
  `fake-systemd --exec <unit> --log`, and 66's own logger is off. A logger of 66 reads a pipe that only
  its own `66-execute` can obtain, so a program that writes the uniform log cannot take its place, and
  `66 log` and the log lines of `66 status` are empty; `journalctl` reads the uniform log as everywhere.
- The restart policy is the exit status of `finish`: 125 tells `66-supervise` not to start the service
  again. `finish` reads how the process ended from `66 runstate`, which also gives `systemctl status` its
  state: a process that ended by itself without a clean exit is `failed`, one that `stop` or the shutdown
  ended is `inactive`. `Restart=always` hits the crash budget of 66 (5 deaths in 30 s) as systemd hits its
  start limit.
- `Wants=` is expressed like `Requires=`: 66 has one kind of dependency, which starts the dependency
  first and stops the service before it. A dependency is a service that 66 finds as a frontend file, so
  requirements are generated before the unit that needs them.
- 66 0.9.1.2 does not deliver `66 signal` and `66 reload` to a service that is up (`skipping already up
  service`), so `kill` and `reload` signal the pid that `66 runstate` reports, and a crash-looping service
  that `66 stop` does not catch between two runs is held down through its control fifo (`66-svctl`).
- 66 runs what it parsed, so a frontend file that was generated again is parsed again before the service
  starts and at `daemon-reload`; parsing resets the enabled state, which is set again afterwards, and a
  service whose frontend file is gone is removed from 66.
- 66 replaces `@U`, `@H`, `@I` and the like anywhere in a frontend file and has no escape: such a name
  in a command or an instance (`foo@Home`) is kept out of the file, and in a description it reads `(at)U`.
- Inside a `--root` tree 66 cannot run (its state is compiled under `/var/lib/66`), so `enable` and
  `disable` are refused there, and `is-enabled` answers from the resolve files.
- `Type=notify` is ready when the process starts, and `66 start` waits for no more.

### BusyBox init

BusyBox init runs the entries of `/etc/inittab` and has no control interface: nothing starts or stops one
entry, and a `respawn` entry would be started again when it is stopped. The backend therefore serves what
the system runs next to init:

- With `runsvdir` in the inittab (BusyBox built with the runit applets, which the stock builds of Alpine,
  Debian and Void leave out) the services are runit service directories, served by the runit backend with
  the directory that `runsvdir` scans taken from the inittab (`/var/service` by default) and the `sv`
  applet of BusyBox behind an adapter: its messages differ, and it looks in `/var/service` unless
  `SVDIR` says otherwise, which a generated `run` that starts a requirement is told when the directory
  is another. `finish` brings a service down with `sv down .` where runit's would use `sv once .`: the
  `runsv` of BusyBox, when it sees `finish` exit before it reads that byte, starts the service that
  just ended. Supervision, logger per service and restart policy are those of runit.
- Without it the services are the init scripts of the sysvinit backend (Red Hat flavour, whose scripts run
  the executor in the background with `--daemon`), and `enable` lists the script in a block of the inittab:
  `::wait:` entries at boot, in dependency order, and `::shutdown:` entries in the reverse order. BusyBox
  runs neither on a reload of the inittab, so changing the block starts and stops nothing; the backend
  sends init a SIGHUP so that its shutdown entries are current. A requirement is listed with the service,
  and before it. Nothing supervises the services: `Restart=` is not honored and a service that dies
  reads `failed`.
- The mode is read from the inittab when the backend is built. Power verbs run the `reboot`, `poweroff`
  and `halt` applets, which make init run the `shutdown` entries (or send SIGTERM to the services of
  `runsvdir`, which the executor turns into `ExecStop=`).
- Verified with BusyBox 1.37.0 built from the release tarball, as PID 1 in a container, after a restart,
  at shutdown and offline, in both modes.
- There are no user services, and a native `respawn` entry of the inittab is not seen as a native service.

### finit

A unit becomes `/etc/finit.d/available/<name>.conf` (`foo@bar.service` becomes `foo-bar`) with one
`service` stanza (a `task` for a oneshot), and `enable` links it into `/etc/finit.d/enabled`, which
finit loads at boot. Dependencies are start conditions: `Requires=` and `BindsTo=` become
`<service/dep/running>` (`<task/dep/success>` for a oneshot), enabling a service also enables the
services its conditions name, and `network-online.target` becomes `<net/route/default>`. Finit loads a
service only from a file it read at a reload, so `start` of a service that is not enabled links it into
`/run/finit/system` and reloads, and `stop` takes the link away again. Verified with finit 4.12 (Debian
13) as PID 1 in a rootless container.

- The command of every stanza is the executor, which logs to the uniform location and applies the unit
  settings, so finit supervises it: `Restart=` becomes `norestart` or `restart:always` (finit restarts
  after any exit, so `on-failure` is approximated), `RestartSec=` `restart_sec:`, `TimeoutStopSec=`
  `kill:` (1 to 60 s) and `KillSignal=` `halt:`. `ExecStop=` runs when finit signals the service, and
  `ExecStopPost=` and the removal of runtime directories run in a `<name>.stop-post` script.
- Finit has no soft dependencies and no ordering without dependency: `Wants=` and `After=` are not
  expressed. `initctl reload` starts what is newly enabled and restarts what changed, so `daemon-reload`
  does both. `Type=forking` without `PIDFile=` is a task, started but not supervised. User services are
  not supported. Finit's `@user` option sets no groups, so an account the executor cannot read from
  `/etc/passwd` reaches the executor as numeric ids (`--uid`, `--gid`, `--groups`) that a script looks
  up with `id` and `getent`; the executor stays root and switches itself.
- Finit kills the process group of a service when its process ends, so the last lines the logger still
  holds can be lost when a service exits at once.

### GNU Shepherd

A unit becomes `/etc/shepherd/available/<name>.scm` (`~/.config/shepherd/available` for a user), Scheme
that registers one service, and `enable` links it into `init.d`, which the configuration of `shepherd`
loads at startup and starts. When `/etc/shepherd.scm` (`~/.config/shepherd/init.scm`) does not exist it
is written with that loader; one that does not mention `init.d` is left alone and the loader is written
beside it. The marker is inside a `#! ... !#` block comment, which Guile skips. `Requires=` becomes
`#:requirement`, `Restart=` `#:respawn?` and `#:respawn-delay`, a oneshot a `#:one-shot?` service whose
start runs the executor to the end, and `RemainAfterExit=` a service that stays started. `start` of a
service the daemon does not know loads its file with `herd load root`, and a service Shepherd disabled
after its process died is enabled again first. Verified with shepherd 1.0.3 (Debian 13) as a daemon
of a rootless container, restarted to see the enabled services start, and with `herd stop root` to see
the stop hooks run.

- On Guix System the services come from the operating-system declaration: `enable` and `disable` warn
  that it has to change and do nothing else, `start`, `stop` and `status` work. That case was not run:
  the executor is expected at `/usr/bin/fake-systemd`, which Guix System does not have.
- The command is always the executor. `ExecStop=` runs when the destructor signals the executor alone,
  `ExecStopPost=` when the service is stopped, not when its process ends by itself. Shepherd has no
  soft dependencies and no signal action: `Wants=` is not expressed and `kill` signals the main process.
  `#:user` sets neither group nor supplementary groups, so an account the executor cannot read from
  `/etc/passwd` reaches the executor as numeric ids (`--uid`, `--gid`, `--groups`) that a shell looks
  up when the service starts; the executor stays root and switches itself.

### nosh (experimental)

fake-systemd translates nothing itself. A unit becomes a record in `/etc/service-bundles/fake-systemd`
that names the unit and the directory it is in, and `system-control convert-systemd-units` of nosh makes
the service bundle in `/etc/service-bundles/services` when the service is enabled or started and when
`daemon-reload` finds the unit changed. `enable`, `disable`, `start`, `stop` and `status` are those of
`system-control`; `enable` reads the links back, because `system-control enable` exits 0 when it could not
make one. The marker is a comment in the `run` script of the bundle, and a bundle whose record is gone is
removed at the next `daemon-reload` of a running service manager. Verified with nosh 1.41 (the binary
packages of its author, checked by sha256) in a rootless container, with the service manager started
by `local-datagram-socket-listen` and not under `system-manager`; the control groups that the converted
`run` scripts move into do not exist for a rootless container, so the test mounts a tmpfs there.

- The converter reads the unit file and the drop-ins beside it, not the merge of every search
  directory, and refuses what nosh cannot run: `Type=notify`, `Type=idle`, and a stop mechanism it has no
  name for. It ignores `ExecStop=`, `ExecReload=` and the sandboxing settings, and maps `Restart=` to
  a `restart` script. `reload` runs `ExecReload=` through the executor.
- Services log where nosh sends them, not to the uniform location, so `journalctl -u` shows nothing for
  them. `restart` is a stop and a start. User services are not supported, and in a `--root` tree the
  converter cannot run: the record is written and `enable` says to reload on the target.

## Configuration

INI files, read in this order, later ones overriding earlier ones: `/etc/fake-systemd/fake-systemd.conf`,
`/etc/fake-systemd/fake-systemd.conf.d/*.conf`, and (user scope) `$XDG_CONFIG_HOME/fake-systemd/fake-systemd.conf`.

```ini
# Init: backend, "auto" detects the running init. Profile: distribution profile.
# Translate: lazy or eager.
[Main]
Init=auto
Profile=auto
Translate=lazy

# Scheduler: auto, native or builtin.
[Timers]
Scheduler=auto

# Maps a systemd unit to a native service.
[Aliases]
foo.service=bar

# Space-separated glob patterns that force or exclude translation.
[Classify]
Allow=
Deny=
```

The environment overrides the files: `FAKE_SYSTEMD_INIT`, `FAKE_SYSTEMD_PROFILE`,
`FAKE_SYSTEMD_DRY_RUN`, `FAKE_SYSTEMD_LOG_LEVEL`.

## Security notes

Unit files are trusted as the packages that install them are: a unit is installed by root, and
fake-systemd runs its commands, and hands its directories to its account, with the privileges of
the caller. The executor limits what a service account can steer.

- `User=`, `Group=` and `SupplementaryGroups=` names that start with `-` are refused. A name that
  is not in `/etc/passwd` and `/etc/group` is refused as root (status 217 or 216) instead of
  running the service as root; accounts that only the system libc knows (LDAP, sssd) reach the
  executor as numeric ids, which always come as a uid and a gid together.
- `RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=` and
  `ConfigurationDirectory=` may not name `fake-systemd` or anything below it under any base:
  the index, its locks, the runtime state and the logs belong to root.
- Like systemd, the directory settings take over an existing directory: `StateDirectory=dpkg`
  changes the owner of `/var/lib/dpkg` and everything in it to the service account. Symlinks are
  changed themselves, never followed; files with several links are skipped, since another link may
  lie outside the directory. Only install units whose directory names you would accept in systemd.
  Setting up a directory is refused when a component below the base is on another mount than the
  base; the ownership change skips a directory on another device, and the removal of a runtime
  directory refuses it.
- `stop`, `reload` and kill act on the process that the executor recorded when it started the
  service, as `<pid> <start time>` in its root-owned state file, and only while that start time
  still holds. `PIDFile=` is read once, at start, and only for a process that descends from the
  executor; a pid file that names any other process, and `MAINPID` from the caller, are ignored
  unless the process runs as the service account.
- Backends read pid files through the opened file, without following links.
- `daemon-reload` stops nothing: a service whose unit file disappeared is disabled at boot and
  keeps running, except on inits (runit, s6) that stop a service when its definition is removed.

## Building

The toolchain is Zig, pinned in `.zig-version` and built into a container image by the `Containerfile`
(the Zig tarball is verified with the official minisign key):

```sh
podman build --build-arg ZIG_VERSION="$(cat .zig-version)" -t fake-systemd-build .
podman run --rm -v "$PWD":/src:Z -w /src fake-systemd-build zig build -Doptimize=ReleaseSmall
podman run --rm -v "$PWD":/src:Z -w /src fake-systemd-build zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

The result is in `zig-out/bin`. `packaging/build-tarball.sh TARGET OUTDIR` builds a release tarball.

## Testing

```sh
podman run --rm -v "$PWD":/src:Z -w /src fake-systemd-build zig fmt --check build.zig src tests
podman run --rm -v "$PWD":/src:Z -w /src fake-systemd-build zig build test   # unit, golden and integration tests
tests/e2e/dinit/run.sh                                                       # real dinit in a container
tests/e2e/runit/run.sh                                                       # real runsvdir in a Void container
tests/e2e/s6/run.sh                                                          # real s6-svscan and s6-rc in Artix and Alpine containers
tests/e2e/openrc/run.sh                                                      # real OpenRC in Alpine and Devuan containers
tests/e2e/sysvinit/run.sh                                                    # real sysvinit as PID 1 in Devuan and Debian, chkconfig in Rocky containers
tests/e2e/66/run.sh                                                          # real 66 as PID 1 (66 boot -c) in an Alpine container
tests/e2e/busybox/run.sh                                                     # real BusyBox init, runsvdir and sv as PID 1 in an Alpine container
tests/e2e/bsdrc/run.sh                                                       # real sysvinit with the boot scripts of Slackware as PID 1 in a container
tests/e2e/procd/run.sh                                                       # real procd as PID 1 in an OpenWrt root file system container
tests/e2e/finit/run.sh                                                       # real finit as PID 1 in a Debian container
tests/e2e/shepherd/run.sh                                                    # real shepherd daemon in a Debian container
tests/e2e/nosh/run.sh                                                        # real nosh converter and service manager in a Debian container
packaging/aur/test.sh                                                        # AUR package: makepkg and namcap
```

## License

GPL-3.0-or-later, see `LICENSE`. `src/timers/calendar.zig` and `src/timers/schedule.zig` are derived
from `calendarspec.c` and `timer.c` of systemd (LGPL-2.1-or-later) and keep that attribution in their
headers.
