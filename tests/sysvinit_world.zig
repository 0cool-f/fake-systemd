// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the sysvinit tests: a tmp root with accounts, a native script and systemd
//! units, plus the sysvinit backend of one flavour bound to the harness context.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");
const s6_world = @import("s6_world.zig");

pub const sysvinit = h.backend.Sysvinit;
pub const Variant = sysvinit.Variant;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

pub const Script = s6_world.Script;
pub const Rule = s6_world.Rule;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";

const native_debian =
    \\#!/bin/sh
    \\### BEGIN INIT INFO
    \\# Provides:          syslog
    \\# Required-Start:    $remote_fs
    \\# Required-Stop:     $remote_fs
    \\# Default-Start:     2 3 4 5
    \\# Default-Stop:      0 1 6
    \\# Short-Description: system logger
    \\### END INIT INFO
    \\DAEMON=/usr/bin/native
    \\case "$1" in
    \\  start) start-stop-daemon --start --quiet --pidfile /run/syslog.pid --exec $DAEMON -- --serve ;;
    \\esac
    \\
;

const native_redhat =
    \\#!/bin/sh
    \\# chkconfig: 2345 12 88
    \\# description: system logger
    \\. /etc/rc.d/init.d/functions
    \\exec=/usr/bin/native
    \\start() {
    \\    daemon --pidfile=/var/run/syslog.pid $exec --serve
    \\}
    \\
;

/// Accounts, a native `syslog` script, `setpriv`, the runlevel directories, and translatable
/// systemd units `dbus.service` and `postgresql.service`.
pub fn populate(t: *h.Harness, variant: Variant) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/etc/init.d/syslog", if (variant == .debian) native_debian else native_redhat, 0o755);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    const base = if (variant == .debian) "/etc" else "/etc/rc.d";
    for ("0123456S") |level| {
        const keep = try std.fmt.allocPrint(t.a(), "{s}/rc{c}.d/.KEEP", .{ base, level });
        try t.write(keep, "", 0o644);
    }
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

/// Binds a sysvinit backend of `variant` to `t`.
pub fn use(t: *h.Harness, s: *sysvinit, variant: Variant) void {
    const dirs = switch (variant) {
        .debian => h.detect.profile.byName("debian").?.dirs(.sysvinit_debian),
        .redhat => h.detect.profile.byName("redhat").?.dirs(.sysvinit_redhat),
    };
    s.* = .init(&t.ctx, dirs, variant);
}
