// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the OpenRC tests: a tmp root with accounts, a native service and systemd
//! units, plus the OpenRC backend bound to the harness context.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");
const s6_world = @import("s6_world.zig");

pub const openrc = h.backend.OpenRc;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

pub const Script = s6_world.Script;
pub const Rule = s6_world.Rule;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";
const native_script =
    \\#!/sbin/openrc-run
    \\command=/usr/bin/native
    \\command_args="--serve"
    \\
;

/// Accounts, a native `syslog` service, `setpriv`, the default runlevel, and translatable systemd
/// units `dbus.service` and `postgresql.service`.
pub fn populate(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/etc/init.d/syslog", native_script, 0o755);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/etc/runlevels/default/.KEEP", "", 0o644);
    try t.write("/usr/libexec/rc/version", "0.63.2\n", 0o644);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds an OpenRC backend to `t` with the Alpine profile.
pub fn use(t: *h.Harness, o: *openrc) void {
    o.* = .init(&t.ctx, h.detect.profile.byName("alpine").?.dirs(.openrc));
}
