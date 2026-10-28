# fake-systemd

A `systemctl` and `journalctl` compatibility layer for Linux systems that do not run systemd.

## The problem

On **Artix**, **Void**, **Devuan**, **Alpine**, **Gentoo**, **Chimera** and similar distributions, third-party packages and
scripts, from **AUR** for example, still call systemd tools while installing/upgrading packages, and you
get into your terminal something like this:

```text
/tmp/alpm_jKVKZ5/.INSTALL: line 58: systemctl: command not found
```

**fake-systemd** is a single static, multi-call binary written in **Zig**. Invoked as `systemctl` or
`journalctl`, it follows the systemd command-line contract (verbs, options, output, exit codes) and
drives the init that is actually running. systemd units are translated into the init's native service
format on first use, so `systemctl enable --now foo` ends up as a real service of your init.

It does not implement D-Bus, socket activation, cgroups, sandboxing, or the other systemd tools
(`systemd-tmpfiles`, `systemd-sysusers`, ...).

## Supported init systems

| Init | Status | User services |
|---|---|---|
| [dinit](#dinit) | supported | yes (`dinit --user`) |
| [runit](#runit) (Void, Artix) | supported | with turnstile |
| [s6-rc](#s6-and-s6-rc) (Artix with the `s6` frontend; elsewhere compiled from source directories) | supported | no |
| [s6](#s6-and-s6-rc) (scan directory without s6-rc) | supported | no |
| [OpenRC](#openrc) (Alpine, Gentoo, Artix) | supported | 0.60 or later with `openrc-user` |
| [sysvinit](#sysvinit) (Devuan, Debian, Red Hat family) | supported | no |
| [BSD-style rc](#bsd-style-rc-slackware) (Slackware) | supported | no |
| [procd](#procd-openwrt) (OpenWrt) | supported | no |
| [66](#66-obarun) (Obarun; 0.9 and later) | supported | yes |
| [BusyBox init](#busybox-init) (with `runsvdir` in the inittab, or with init scripts) | supported | no |
| [finit](#finit) (4.x) | supported | no |
| [GNU Shepherd](#gnu-shepherd) (outside Guix System; on Guix System `enable` and `disable` only warn) | supported | yes |
| [nosh](#nosh-experimental) (delegates to its unit converter) | experimental | no |

## Installation

### Arch Linux (AUR)

```sh
git clone https://aur.archlinux.org/fake-systemd-bin.git
cd fake-systemd-bin && makepkg -si
```

The package provides `systemctl` and conflicts with `systemd`.

### Release tarball

The AUR package above is the recommended path; it installs into `/usr/bin`.
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
doas cp -P "fake-systemd-$version-$target"/{fake-systemd,systemctl,journalctl} /usr/bin/
```

The tarball also contains `LICENSE` and this `README.md`. `systemctl` and `journalctl` are symlinks
to `fake-systemd`.

Install into `/usr/bin`, not `/usr/local/bin`, for two reasons:

- The generated services run the executor as `/usr/bin/fake-systemd`, a path that is fixed in the
  generated files, so a copy only in `/usr/local/bin` leaves them without their executor.
- The caller of `systemctl` may not have `/usr/local/bin` in its `PATH`. Package managers do not agree
  on the `PATH` of their scripts. apk runs package scripts with `PATH=/usr/sbin:/usr/bin:/sbin:/bin`
  unless `--preserve-env` is given (`src/context.c` of apk-tools). The sources of libalpm (pacman
  scriptlets, 7.1.0), dpkg (maintainer scripts) and xbps (INSTALL and REMOVE scripts) do not set
  `PATH`, so those scripts get the one of the process that runs the package manager, which may leave
  out `/usr/local/bin`. Init scripts may run with a reduced `PATH` as well; that was not checked.

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

`start` and `restart` of a `Type=forking` unit with `PIDFile=` return once the daemon named in the pid
file is recorded as the main process, as they do in systemd, and fail when `TimeoutStartSec=` runs out
first. The init scripts and procd wait in their own scripts; for the supervisors that run the
executor (runit, s6, shepherd, ...) fake-systemd waits itself.

### Translation

A unit is translated to the init's native format only when a verb needs it (`Translate=lazy`);
`daemon-reload` translates every candidate with `Translate=eager`. A native service that already
provides the same functionality (same name or alias, and the same executable) is used instead of
generating one. A native service that has the name of the unit but runs another program is a conflict:
`enable` fails and asks for an entry in `[Aliases]`. Units that cannot be translated are reported as
`unsupported` in `list-unit-files`.

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

### Logging and journalctl

Services that fake-systemd generates log to one place whatever the init is, and `journalctl` reads it.
There is no binary journal.

- System services log to `/var/log/fake-systemd/<unit>/current`, user services to
  `$XDG_STATE_HOME/fake-systemd/log/<unit>/` (`~/.local/state` when unset).
- A line is plain text, `2026-10-24T12:05:01.123+02:00 <message>`: ISO 8601 with milliseconds and the
  local offset (`TZ`, else `/etc/localtime`, else UTC).
- `fake-systemd --log <unit>` does the writing and the rotation. When `current` plus the next line would
  exceed 1 MiB, `current` becomes `@<unix seconds>.log` in the same directory, and at most 10 files are
  kept, `current` included. A `flock` on `.lock` keeps concurrent loggers from rotating twice.
- The directory of a unit is created with mode 0750 and `current` and `.lock` with 0640, both subject to
  the umask; there is no `chown`.
- `fake-systemd --log` is the logger of the runit and s6 services (`log/run`, the logger service of
  s6-rc), and OpenRC passes it to `supervise-daemon` as `output_logger` and `error_logger`. Where nothing
  supervises a logger (sysvinit, BSD-style rc, BusyBox with an inittab, procd, 66, finit, Shepherd), the
  executor started with `fake-systemd --exec <unit> --log` starts it.
- Two backends write the raw output of the service to `current` instead, with no timestamp and no
  rotation: the `logfile` of dinit, and `output_log` and `error_log` of OpenRC before 0.51. `journalctl`
  gives such a line the timestamp of the one before it. The services of nosh log where nosh sends them,
  so `journalctl -u` shows nothing for them.

`journalctl` merges the logs of the selected units by timestamp, in the `short` format (`Oct 24 12:05:01
host unit: message`) or `cat`. It supports:

- `-u`/`--unit` and `--user-unit` (repeatable, globs allowed) and the matches `_SYSTEMD_UNIT=` and
  `_SYSTEMD_USER_UNIT=`; without a selection, the logs of every system unit. Other matches are ignored
  with a warning.
- `-n` (a number or `all`), `-e` (the last 1000 lines), `-f` (shows 10 lines unless `-n` says otherwise,
  then follows new lines and rotation), `-o short|cat`, `-q`, `--no-hostname`, `--no-pager` (nothing
  is paged anyway), and `-k`, which runs `dmesg`.
- `--since` and `--until` with `now`, `today`, `yesterday`, `tomorrow`, `@<unix seconds>`, relative
  times (`-1h`, `+5min`, `5 min ago`, `1h left`), and `YYYY-MM-DD[ HH:MM[:SS[.fff]]]` or `HH:MM[:SS]`
  (the current day), in the local zone unless followed by `UTC`.
- `-b`, which means the entries since the boot time that `/proc/stat` reports. `-b <id>` for any other
  boot says that only the current boot is kept and shows nothing.
- For a unit named with `-u` that has no uniform log, the native log files of the init's profile: a file
  per service is shown whole, a shared file only for its lines that mention the service. Those lines are
  printed as they are and dated by the modification time of the file. When nothing is found, a notice
  lists the locations that were checked.

It does not read `/run/log` or any journal file, has no pager, knows no boot ids, and rejects other
options (`--user`, `-p`, `-o json`, ...) as unknown or invalid.

### dinit

A unit becomes one service description file, named after the unit (`foo.service` becomes `foo`), in the
directory of its tier: `/etc/dinit.d` for administrator units, `/usr/lib/dinit.d` for vendor units
(`/usr/local/lib/dinit.d` when the unit comes from `/usr/local`), and `/run/dinit.d` for runtime units
when it exists. User services go to `$XDG_CONFIG_HOME/dinit.d`, or to `/etc/dinit.d/user`,
`/usr/lib/dinit.d/user` and `/usr/local/lib/dinit.d/user` for the units of those tiers.
`enable` does not run `dinitctl enable`, which also starts the service. It writes the link that
command writes, `<name>` in the directory that the `waits-for.d` setting of the `boot` service names
(`/etc/dinit.d/boot.d` when the boot service cannot be read, `~/.config/dinit.d/boot.d` for a user): a
relative link `../<name>` when the file sits next to that directory, otherwise the path of the file.
This is the same online and offline. `enable --runtime` with dinit running uses
`dinitctl --quiet add-dep waits-for boot <name>` (`disable --runtime` uses `rm-dep`); without a running
dinit it warns and enables persistently. `disable` does not stop the service, and `is-enabled` is
whether the link exists. Verified with a real dinit (not PID 1) in a Chimera container, where
`dinit-check` accepts the generated files; the states of `dinitctl status` that the unit tests map were
observed with dinit 0.22. The image installs the package of Chimera without a pinned version.

- `Type=simple` is `type = process`, `Type=oneshot` is `scripted`, and `Type=forking` is `bgprocess` with
  `pid-file` when it has `PIDFile=`, `scripted` when it does not (the daemon is started and not
  supervised, which the file says in a comment), and `process` under the executor. `Type=notify`
  readiness is not emitted. `Requires=` and `BindsTo=` become `depends-on`, `Wants=` `waits-for`, and
  `After=` and `Before=` `after` and `before`. Units that a unit requires or wants are translated with it.
  `network.target` becomes the first service that exists of `network.target` and `network`, and
  `network-online.target` the first of `network-online.target`, `network-online`, `network` and
  `network.target`. The enabled network providers (`dhcpcd`, `NetworkManager`, `connmand`, `iwd`,
  `wpa_supplicant`, `netctl`) are added as `waits-for`. Other targets are dropped.
- The command is `ExecStart=` when dinit can run it as it stands, else the executor
  (`fake-systemd --exec <unit>`). `Environment=` becomes `/usr/bin/env NAME=VALUE ...`. Settings that
  need the executor include `ExecStartPre=`, `ExecStartPost=`, `EnvironmentFile=`, `Group=`,
  `SupplementaryGroups=`, `UMask=`, the `*Directory=` settings, most `Limit*=` and variable expansion;
  `LimitNOFILE=`, `LimitCORE=`, `LimitDATA=` and `LimitAS=` become `rlimit-*`.
- Logging: every file has `logfile = <log directory>/current` with `logfile-permissions = 640`, so dinit
  writes the raw output of the service there, even under the executor: no timestamps and no rotation, and
  `journalctl` gives each line the timestamp of the one before it. The log directory of a service and of
  the services it pulls in is created by `start`, `restart` and by `enable` when it writes a new link,
  since dinit does not create it.
- Identity: for a native command with `User=` in system scope, `run-as` and
  `load-options = export-passwd-vars`, so dinit looks the account up with its libc. When the executor
  runs the unit it does the switch itself: from `/etc/passwd` and `/etc/group` for an account it can read,
  otherwise (LDAP, sssd) with numeric ids that a `/bin/sh -c` wrapper looks up with `id` when dinit starts
  the service, the executor staying root. User services have no `run-as`.
- `Restart=` becomes `restart = false`, `true` (`always`, and `on-success` approximated, which the file
  says in a comment) or `on-failure` (the other variants), with `smooth-recovery = true` and
  `restart-delay` from `RestartSec=`. A `scripted` service always has `restart = false`. `ExecStop=` of a
  oneshot is `stop-command` when it is one plain command, and every other `ExecStop=` or `ExecStopPost=`
  runs through `stop-command` with the executor (`--phase stop`). `TimeoutStartSec=` and `TimeoutStopSec=`
  become `start-timeout` and `stop-timeout`; `KillSignal=`, `Nice=` and `NoNewPrivileges=` become
  `term-signal`, `nice` and `options: no-new-privs`.
- Templates: dinit reads `name@arg` as an instance of the file `name@`, so `getty@tty1.service` becomes
  the service `getty-tty1` with a file of its own, and characters outside letters, digits, `.`, `-`
  and `_` in the instance become `_`.
- `stop` uses `dinitctl stop --force`. `restart` starts a service that is stopped, which `dinitctl restart`
  refuses. dinit has no reload action: `reload` runs the executor with `--phase reload` for a generated
  service and fails for a native one. `daemon-reload` runs `dinitctl reload` on the loaded services that
  fake-systemd generated. Power verbs run `shutdown -r`, `-p` and `-h`.
- User services run in `dinit --user` (`dinitctl --user`). They are covered by the unit and golden
  tests, not by the end-to-end test, which has no user instance of dinit.
- Not emitted: `Conflicts=`, `PartOf=`, socket activation, `env-file` and `ready-notification`.
  `KillMode=none` and `mixed` are handled like `control-group`.

### runit

A unit becomes a service directory with `run`, `log/run`, and when the unit needs them `finish`,
`control/t` and `fake-systemd.meta`: in `/etc/sv` on Void and in `/etc/runit/sv` on Artix, or in
`~/.config/sv` for a user (the other distributions use the layout of Void). `enable` links the directory
into `/etc/runit/runsvdir/default`, which `/var/service` (Void) and `/run/runit/service` (Artix) point to
through `runsvdir/current`, and which also exists in a chroot. `runsvdir` starts everything it finds, so
the service is enabled when the link exists and the directory has no `down` file: `enable` creates the
link and removes `down`. `start` of a service that is not enabled links it with a `down` file, so it does
not start at boot, and the link stays after `stop`; the services that `run` starts (`Requires=`,
`BindsTo=`, `Wants=`) are linked with `down` as well, since `runsvdir` supervises them but does not start
them. `disable` of a running service writes `down` and keeps the link, because removing the link makes
`runsvdir` stop the service; otherwise it removes the link and waits up to 8 s for the `runsv` to go.
`is-enabled` is a link without `down`. `enable` never calls `sv`, and `--runtime` is not supported: it warns
and enables persistently. Verified with a real `runsvdir` (not PID 1) in a Void musl container; the Artix
layout is covered by the profile tests only, and the version of runit is that of the Void repository.

- Dependencies are lines at the top of `run`. `Requires=` and `BindsTo=` become `sv start <dep> || exit 1`,
  and `Wants=` and the enabled network providers `sv start <dep>` whose result is ignored
  (`SVDIR=<dir> sv start` for a user). `After=` and `Before=` are not expressed, and the network targets
  map to nothing but those providers. `start` and `stop` give `TimeoutStartSec=` and `TimeoutStopSec=`
  (90 s for a stop without it) to `sv -w`.
- Logging: `log/run` is `exec /usr/bin/fake-systemd --log <unit>`, and `run` starts with `exec 2>&1`, so
  the uniform log has timestamps and rotation. The native logs that `journalctl` falls back to are
  `/var/log/<name>/current`.
- Identity: an account that the executor can read from `/etc/passwd` and `/etc/group` runs under the
  executor, which switches itself. For an account only the system libc knows (LDAP, sssd), a native
  command is run with `setpriv --init-groups`, or with `chpst -u` and a warning when `setpriv` is not
  installed, since `chpst` applies no supplementary groups; under the executor the scripts look up numeric
  ids with `id` and pass them as `--uid`, `--gid` and `--groups`. The executor also runs every oneshot,
  every `Type=forking`, and every unit with `Limit*=`, `*Directory=`, `ExecStartPre=` or `ExecStartPost=`.
  A oneshot with `RemainAfterExit=yes` runs its command and then `exec sleep 2147483647`.
- `Restart=`: `runsv` restarts a service after every exit, so `Restart=always` needs no `finish`. The
  others, a oneshot, `ExecStopPost=` and a `RestartSec=` of 2 s or more (up to 24 h) get a `finish` that
  records how the process ended in `supervise/exit-status` (`status` reads `failed` from it), runs
  `ExecStopPost=` through the executor, sleeps for `RestartSec=`, and keeps the service down
  (`sv once .`) after the exits that `Restart=` does not restart on. It sends `sv once .` only while the service is wanted up, since a
  control byte still queued after a stop would start it again. `restart` is a stop and a start, because
  `sv restart` would ignore what `finish` decided.
- `ExecStop=` is `control/t`: it runs the executor with `--phase stop-main` and the pid of the main process
  as `MAINPID`. Without `ExecStop=`, a `KillSignal=` other than `SIGTERM` is a `control/t` that sends it
  to the pid in `supervise/pid`. `reload` runs `ExecReload=` through the executor, or `sv reload` for a
  service that was not generated. Power verbs run `runit-init 6` (reboot) and `runit-init 0` (poweroff
  and halt).
- Templates keep their name: `foo@bar.service` is the directory `foo@bar`, which `runsvdir` and `sv`
  accept.
- User services need turnstile with its runit backend, detected from `/usr/libexec/turnstile/runit` and
  `backend = runit` in `/etc/turnstile/turnstiled.conf`. Services are generated in `~/.config/sv` and
  linked into `~/.config/service`, or into the `services_dir` of `/etc/turnstile/backend/runit.conf`, and
  `sv` is given the path of the link. The end-to-end test runs a `runsvdir` per user by hand with a stub
  of the turnstile files, not turnstile itself.
- Limits: no ordering without a dependency (`After=`, `Before=`), no `--runtime`, and user services only
  with turnstile.

### s6 and s6-rc

A unit becomes the source directories of an s6-rc longrun `foo-srv` whose output feeds the logger
`foo-log` of a pipeline named `foo` (a oneshot unit becomes an s6-rc oneshot with `up` and `down` in
execline), or, on plain s6, a service directory linked into the scan directory. On Artix the `s6`
frontend does the work: `enable` runs `s6 repository sync`, `s6 set enable -p`, `s6 set commit` and
`s6 live install`. Elsewhere `enable` lists the service in the boot bundle `default` and builds a new
database with `s6-rc-compile`, which `s6-rc-update` moves the running system to; `daemon-reload`
builds it again.

- On plain s6, `start` rescans the scan directory and waits, up to `TimeoutStartSec=`, until
  `s6-supervise` of the service and of its linked dependencies is ready, and fails when it never
  appears. `stop` waits for `finish` to end (`s6-svc -wD`, `s6-svwait -D` on s6-rc).
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
service does not depend on what `start-stop-daemon` can do (the one of dpkg can do little). `start`
returns once the executor recorded the main process or the end of the service, and fails when it dies
first or `TimeoutStartSec=` runs out.

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
  and its executor pid is in `<unit>.daemon.pid`; `<unit>.pid` holds the main process. `start` returns
  once the executor recorded it, or the end of the service, and fails when the executor dies first or
  `TimeoutStartSec=` runs out.
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
- The presence of a `/run/initctl` socket does not mean an init is running unless PID 1 is an `init`:
  container images keep one where nothing runs, and systemd offers a socket of that name.
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
  and `halt` applets, which make init run the `shutdown` entries. With `runsvdir`, init would signal
  every process at once, and a `runsv` that sees its service die first never runs `ExecStop=`, so the
  backend keeps a `# BEGIN fake-systemd` block in the inittab with `::shutdown:sv -w 90 force-stop
  <scan directory>/*` while a service is linked: `sv` stops the services, `ExecStop=` included, before
  init signals anything.
- Verified with BusyBox 1.37.0 built from the release tarball, as PID 1 in a container, after a restart,
  at shutdown and offline, in both modes.
- There are no user services, and a native `respawn` entry of the inittab is not seen as a native service.

### finit

A unit becomes `/etc/finit.d/available/<name>.conf` (`foo@bar.service` becomes `foo-bar`) with one
`service` stanza (a `task` for a oneshot), and `enable` links it into `/etc/finit.d/enabled`, which
finit loads at boot. Dependencies are start conditions: `Requires=` and `BindsTo=` become
`<service/dep/running>` (`<task/dep/success>` for a oneshot), enabling a service also enables the
services its conditions name, and `network-online.target` becomes `<net/route/default>`. Finit loads a
service only from a file it read at a reload, so `systemctl start` on a service that is not enabled links
it into `/run/finit/system` and reloads, and `systemctl stop` removes the link again. Verified with finit 4.12 (Debian
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
- `Type=forking` is handled by the converter itself: nosh does not follow the daemon or read `PIDFile=`,
  so `start` does not wait for it and `stop` does not end the forked daemon.
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

# Maps a systemd unit to a native service of a different name, as in
# apache2.service=httpd. An alias is authoritative: when the native service exists it is
# used without comparing executables, and nothing is generated. When it does not exist,
# the normal name and executable rules apply. An empty value removes the alias.
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
