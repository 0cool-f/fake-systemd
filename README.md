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
| 66, BSD-style rc, BusyBox init, finit, procd, GNU Shepherd, nosh | planned (second block) |

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
  account, and `setpriv` in front of the executor for the others. The account that the executor cannot
  read from `/etc/passwd` gets a log directory it owns, because the logger runs as it.
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
packaging/aur/test.sh                                                        # AUR package: makepkg and namcap
```

## License

GPL-3.0-or-later, see `LICENSE`. `src/timers/calendar.zig` and `src/timers/schedule.zig` are derived
from `calendarspec.c` and `timer.c` of systemd (LGPL-2.1-or-later) and keep that attribution in their
headers.
