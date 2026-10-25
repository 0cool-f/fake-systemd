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
| s6 / s6-rc | planned |
| OpenRC | planned |
| sysvinit | planned |
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
packaging/aur/test.sh                                                        # AUR package: makepkg and namcap
```

## License

GPL-3.0-or-later, see `LICENSE`. `src/timers/calendar.zig` and `src/timers/schedule.zig` are derived
from `calendarspec.c` and `timer.c` of systemd (LGPL-2.1-or-later) and keep that attribution in their
headers.
