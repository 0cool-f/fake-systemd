// SPDX-License-Identifier: GPL-3.0-or-later
//! Shared fixture for the BSD-style rc and procd tests: a tmp root with accounts, native
//! scripts and systemd units, the backends bound to the harness context, the corpus loader of
//! the golden tests, and the golden file helpers.
const std = @import("std");
const h = @import("harness.zig");
const dinit_world = @import("dinit_world.zig");
const s6_world = @import("s6_world.zig");

pub const bsdrc = h.backend.BsdRc;
pub const procd = h.backend.Procd;

pub const passwd = dinit_world.passwd;
pub const group = dinit_world.group;

pub const Script = s6_world.Script;
pub const Rule = s6_world.Rule;

const dep_unit = "[Unit]\nDescription=dependency\n\n[Service]\nExecStart=/usr/bin/dep\n";

/// `rc.local` as Slackware installs it.
pub const slackware_rc_local =
    \\#!/bin/sh
    \\#
    \\# /etc/rc.d/rc.local:  Local system initialization script.
    \\#
    \\# Put any local startup commands in here.  Also, if you have
    \\# anything that needs to be run at shutdown time you can
    \\# make an /etc/rc.d/rc.local_shutdown script and put those
    \\# commands in there.
    \\
;

/// The parts of `rc.M` and `rc.6` that name the scripts they start and stop.
const slackware_rc_m =
    \\#!/bin/bash
    \\if [ -x /etc/rc.d/rc.syslog ]; then
    \\  /etc/rc.d/rc.syslog start
    \\fi
    \\# /etc/rc.d/rc.ghost is only talked about here.
    \\if [ -x /etc/rc.d/rc.sysvinit ]; then
    \\  /etc/rc.d/rc.sysvinit
    \\fi
    \\if [ -x /etc/rc.d/rc.local ]; then
    \\  /etc/rc.d/rc.local
    \\fi
    \\
;

/// `rc.syslog` of Slackware.
const native_syslog =
    \\#!/bin/sh
    \\# Start/stop/restart the system logging daemon.
    \\syslogd_start() {
    \\  if [ -x /usr/sbin/syslogd ]; then
    \\    echo "Starting syslogd daemon:  /usr/sbin/syslogd ${SYSLOGD_OPTS}"
    \\    /usr/sbin/syslogd $SYSLOGD_OPTS
    \\  fi
    \\}
    \\syslogd_stop() {
    \\  killall syslogd 2> /dev/null
    \\}
    \\case "$1" in
    \\'start')
    \\  syslogd_start
    \\  ;;
    \\'stop')
    \\  syslogd_stop
    \\  ;;
    \\*)
    \\  echo "usage $0 start|stop|restart"
    \\esac
    \\
;

/// Accounts, `setpriv`, the boot scripts of Slackware, a native `syslog` that `rc.M` starts and
/// that is enabled, and translatable systemd units `dbus.service` and `postgresql.service`.
pub fn populateBsdRc(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/usr/bin/setpriv", "#!/bin/sh\n", 0o755);
    try t.write("/etc/rc.d/rc.M", slackware_rc_m, 0o755);
    try t.write("/etc/rc.d/rc.local", slackware_rc_local, 0o755);
    try t.write("/etc/rc.d/rc.syslog", native_syslog, 0o755);
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

pub fn useBsdRc(t: *h.Harness, b: *bsdrc) void {
    b.* = .init(&t.ctx, h.detect.profile.byName("slackware").?.dirs(.bsd_rc));
}

/// `init` script of the base system of OpenWrt that procd runs, native.
const native_cron =
    \\#!/bin/sh /etc/rc.common
    \\
    \\START=50
    \\USE_PROCD=1
    \\
    \\start_service() {
    \\  procd_open_instance
    \\  procd_set_param command /usr/sbin/crond -f -c /etc/crontabs -l 5
    \\  procd_set_param respawn
    \\  procd_close_instance
    \\}
    \\
;

const native_boot =
    \\#!/bin/sh /etc/rc.common
    \\START=10
    \\STOP=90
    \\boot() {
    \\  echo booting
    \\}
    \\
;

/// Accounts, a native `cron` procd script that is enabled, a native `boot` script, busybox
/// applets, and translatable systemd units `dbus.service` and `postgresql.service`.
pub fn populateProcd(t: *h.Harness) !void {
    try t.write("/etc/passwd", passwd, 0o644);
    try t.write("/etc/group", group, 0o644);
    try t.write("/etc/init.d/cron", native_cron, 0o755);
    try t.write("/etc/init.d/boot", native_boot, 0o755);
    try t.write("/etc/init.d/network", "#!/bin/sh /etc/rc.common\nSTART=20\nSTOP=90\n", 0o755);
    try t.write("/etc/rc.d/.KEEP", "", 0o644);
    try t.fs.symLink("../init.d/cron", "/etc/rc.d/S50cron");
    try t.write("/bin/busybox", "x", 0o755);
    try t.fs.makePath("/usr/sbin");
    try t.fs.symLink("busybox", "/bin/sleep");
    try t.fs.symLink("../../bin/busybox", "/usr/sbin/crond");
    try t.write("/usr/lib/systemd/system/dbus.service", dep_unit, 0o644);
    try t.write("/usr/lib/systemd/system/postgresql.service", dep_unit, 0o644);
}

pub fn useProcd(t: *h.Harness, p: *procd) void {
    p.* = .init(&t.ctx, h.detect.profile.byName("openwrt").?.dirs(.procd));
}

// ---- golden files -------------------------------------------------------------------------

const testing = std.testing;
pub const marker = h.index.marker;

pub const Entry = struct {
    /// Unit file in `tests/corpus`.
    file: []const u8,
    /// Unit translated; differs from `file` for template instances.
    request: []const u8,
    /// Systemd directory the file is installed in.
    src_dir: []const u8,
    /// Name of the golden file without its extension.
    golden: []const u8,
    unit_text: []const u8,
    expected: []const u8,
};

pub fn updateRequested() bool {
    var env = testing.environ.createMap(testing.allocator) catch return false;
    defer env.deinit();
    return env.get("FAKE_SYSTEMD_UPDATE_GOLDEN") != null;
}

pub const Loaded = struct {
    name: h.unit.name.Name,
    resolved: h.unit.resolve.Resolved,
    unit: h.unit.model.Unit,
};

/// Installs the unit file of `e` in `t` and loads it like the pipeline does.
pub fn load(t: *h.Harness, e: Entry) !Loaded {
    const a = t.a();
    try t.write(try std.fmt.allocPrint(a, "{s}/{s}", .{ e.src_dir, e.file }), e.unit_text, 0o644);
    const name = try h.unit.name.parse(a, e.request);
    const resolved = try h.unit.resolve.resolve(a, t.fs, .{ .scope = .system, .xdg_config_home = t.ctx.xdg_config_home }, name);
    const user: h.unit.specifier.UserInfo = .{ .name = "root", .uid = t.ctx.uid, .home = t.ctx.home };
    const env: h.unit.specifier.Env = .system(user);
    return .{ .name = name, .resolved = resolved, .unit = try h.unit.model.load(a, t.fs, resolved, .{ .env = env }) };
}

/// `sh -n` accepts the script.
pub fn expectShellSyntax(t: *h.Harness, content: []const u8) !void {
    try t.write("/syntax-check.sh", content, 0o755);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try t.tmp.dir.realPath(testing.io, &buf);
    const path = try std.fmt.allocPrint(t.a(), "{s}/syntax-check.sh", .{buf[0..n]});
    const res = try std.process.run(t.a(), testing.io, .{ .argv = &.{ "/bin/sh", "-n", path } });
    if (res.term != .exited or res.term.exited != 0) {
        std.debug.print("sh -n rejects:\n{s}\n{s}\n", .{ content, res.stderr });
        return error.ShellSyntaxError;
    }
}

/// Compares `content` with the golden file, or rewrites it when `FAKE_SYSTEMD_UPDATE_GOLDEN` is set.
pub fn expectGolden(a: std.mem.Allocator, dir: []const u8, e: Entry, content: []const u8) !void {
    if (updateRequested()) {
        const path = try std.fmt.allocPrint(a, "tests/golden/{s}/{s}", .{ dir, e.golden });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = content });
        return;
    }
    testing.expectEqualStrings(e.expected, content) catch |err| {
        std.debug.print("golden mismatch for {s}/{s}\n", .{ dir, e.golden });
        return err;
    };
}

pub fn entry(
    comptime dir: []const u8,
    comptime ext: []const u8,
    comptime file: []const u8,
    comptime request: []const u8,
    comptime src_dir: []const u8,
    comptime golden: []const u8,
) Entry {
    return .{
        .file = file,
        .request = request,
        .src_dir = src_dir,
        .golden = golden ++ "." ++ ext,
        .unit_text = @embedFile("corpus/" ++ file),
        .expected = @embedFile("golden/" ++ dir ++ "/" ++ golden ++ "." ++ ext),
    };
}

const vendor = "/usr/lib/systemd/system";

/// The corpus units both backends are checked against.
pub fn entries(comptime dir: []const u8, comptime ext: []const u8) [20]Entry {
    return .{
        entry(dir, ext, "simple-daemon.service", "simple-daemon.service", vendor, "simple-daemon"),
        entry(dir, ext, "forking-pidfile.service", "forking-pidfile.service", vendor, "forking-pidfile"),
        entry(dir, ext, "forking-nopid.service", "forking-nopid.service", vendor, "forking-nopid"),
        entry(dir, ext, "oneshot-remain.service", "oneshot-remain.service", vendor, "oneshot-remain"),
        entry(dir, ext, "notify-service.service", "notify-service.service", vendor, "notify-service"),
        entry(dir, ext, "env-exec-pre.service", "env-exec-pre.service", vendor, "env-exec-pre"),
        entry(dir, ext, "runtime-dir.service", "runtime-dir.service", vendor, "runtime-dir"),
        entry(dir, ext, "user-ldap.service", "user-ldap.service", vendor, "user-ldap"),
        entry(dir, ext, "user-group.service", "user-group.service", vendor, "user-group"),
        entry(dir, ext, "restart-always.service", "restart-always.service", vendor, "restart-always"),
        entry(dir, ext, "tpl-login@.service", "tpl-login@tty1.service", vendor, "tpl-login-tty1"),
        entry(dir, ext, "deps-mix.service", "deps-mix.service", vendor, "deps-mix"),
        entry(dir, ext, "backup-job.service", "backup-job.service", vendor, "backup-job"),
        entry(dir, ext, "dbus-activated.service", "dbus-activated.service", vendor, "dbus-activated"),
        entry(dir, ext, "sandboxed.service", "sandboxed.service", vendor, "sandboxed"),
        entry(dir, ext, "exec-quoting.service", "exec-quoting.service", vendor, "exec-quoting"),
        entry(dir, ext, "exec-vars.service", "exec-vars.service", vendor, "exec-vars"),
        entry(dir, ext, "multi-oneshot.service", "multi-oneshot.service", vendor, "multi-oneshot"),
        entry(dir, ext, "reload-stop.service", "reload-stop.service", vendor, "reload-stop"),
        entry(dir, ext, "admin-override.service", "admin-override.service", "/etc/systemd/system", "admin-override"),
    };
}
