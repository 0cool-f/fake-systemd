// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the BusyBox init tests: a tmp root with accounts, an inittab of one of the
//! two kinds of system the backend serves, and systemd units, plus the backend bound to the
//! harness context.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");

pub const Busybox = h.backend.Busybox;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";

/// What a system with BusyBox init and a serial console has in its inittab.
pub const base_inittab =
    \\::sysinit:/etc/init.d/rcS
    \\ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
    \\::ctrlaltdel:/sbin/reboot
    \\::shutdown:/bin/umount -a -r
    \\
;

pub const Setup = enum {
    /// The inittab starts `runsvdir /var/service`.
    runsv,
    /// The inittab starts `runsvdir /etc/service`.
    runsv_etc,
    /// The inittab starts no service manager.
    inittab,
};

/// Accounts, `setpriv`, an inittab, and translatable units `dbus.service` and `postgresql.service`.
pub fn populate(t: *h.Harness, setup: Setup) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/usr/bin/dep", "#!/bin/sh\n", 0o755);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
    const text = switch (setup) {
        .runsv => base_inittab ++ "::respawn:/bin/runsvdir /var/service\n",
        .runsv_etc => base_inittab ++ "::respawn:/bin/runsvdir /etc/service\n",
        .inittab => base_inittab,
    };
    try t.write("/etc/inittab", text, 0o644);
    try t.write("/var/service/.KEEP", "", 0o644);
    try t.write("/etc/service/.KEEP", "", 0o644);
    try t.write("/etc/init.d/rcS", "#!/bin/sh\n", 0o755);
}

/// Binds a BusyBox backend to `t` with the generic profile. The backend reads the inittab when
/// it is built, so the inittab is written first.
pub fn use(t: *h.Harness, b: *Busybox) void {
    b.* = .init(&t.ctx, h.detect.profile.generic.dirs(.busybox));
    t.backend_override = b.backend();
}
