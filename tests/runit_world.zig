// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the runit tests: a tmp root with accounts, a native service and systemd
//! units, plus the runit backend bound to the harness context.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");

pub const runit = h.backend.Runit;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

pub const Scripted = dinit_world.Scripted;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";
const native_run = "#!/bin/sh\nexec 2>&1\nexec /usr/bin/native --serve\n";

/// Accounts, a native `syslog` service, and translatable systemd units `dbus.service` and
/// `postgresql.service`.
pub fn populate(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/etc/sv/syslog/run", native_run, 0o755);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/etc/runit/runsvdir/default/.KEEP", "", 0o644);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds a runit backend to `t` with the Void profile.
pub fn use(t: *h.Harness, r: *runit) void {
    r.* = .init(&t.ctx, h.detect.profile.byName("void").?.dirs(.runit));
}
