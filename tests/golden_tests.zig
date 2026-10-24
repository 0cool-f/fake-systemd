// SPDX-License-Identifier: GPL-3.0-or-later
//! Golden tests of the dinit generator: every unit of `tests/corpus` is translated and compared
//! with `tests/golden/dinit`. Run with `FAKE_SYSTEMD_UPDATE_GOLDEN=1` from the project root to
//! rewrite the expected files after an intended change, then rebuild.
const std = @import("std");
const h = @import("harness.zig");
const world = @import("dinit_world.zig");

const testing = std.testing;
const marker = h.index.marker;

const Entry = struct {
    /// Unit file in `tests/corpus`.
    file: []const u8,
    /// Unit translated; differs from `file` for template instances.
    request: []const u8,
    /// Systemd directory the file is installed in.
    src_dir: []const u8,
    scope: h.core.Scope = .system,
    /// Path of the generated service.
    dest: []const u8,
    golden: []const u8,
    unit_text: []const u8,
    expected: []const u8,
};

fn entry(
    comptime file: []const u8,
    comptime request: []const u8,
    comptime src_dir: []const u8,
    comptime scope: h.core.Scope,
    comptime dest: []const u8,
    comptime golden: []const u8,
) Entry {
    return .{
        .file = file,
        .request = request,
        .src_dir = src_dir,
        .scope = scope,
        .dest = dest,
        .golden = golden,
        .unit_text = @embedFile("corpus/" ++ file),
        .expected = @embedFile("golden/dinit/" ++ golden),
    };
}

const vendor = "/usr/lib/systemd/system";
const vendor_dest = "/usr/lib/dinit.d/";

const entries = [_]Entry{
    entry("simple-daemon.service", "simple-daemon.service", vendor, .system, vendor_dest ++ "simple-daemon", "simple-daemon.dinit"),
    entry("forking-pidfile.service", "forking-pidfile.service", vendor, .system, vendor_dest ++ "forking-pidfile", "forking-pidfile.dinit"),
    entry("forking-nopid.service", "forking-nopid.service", vendor, .system, vendor_dest ++ "forking-nopid", "forking-nopid.dinit"),
    entry("oneshot-remain.service", "oneshot-remain.service", vendor, .system, vendor_dest ++ "oneshot-remain", "oneshot-remain.dinit"),
    entry("notify-service.service", "notify-service.service", vendor, .system, vendor_dest ++ "notify-service", "notify-service.dinit"),
    entry("env-exec-pre.service", "env-exec-pre.service", vendor, .system, vendor_dest ++ "env-exec-pre", "env-exec-pre.dinit"),
    entry("runtime-dir.service", "runtime-dir.service", vendor, .system, vendor_dest ++ "runtime-dir", "runtime-dir.dinit"),
    entry("user-ldap.service", "user-ldap.service", vendor, .system, vendor_dest ++ "user-ldap", "user-ldap.dinit"),
    entry("user-group.service", "user-group.service", vendor, .system, vendor_dest ++ "user-group", "user-group.dinit"),
    entry("restart-always.service", "restart-always.service", vendor, .system, vendor_dest ++ "restart-always", "restart-always.dinit"),
    entry("tpl-login@.service", "tpl-login@tty1.service", vendor, .system, vendor_dest ++ "tpl-login-tty1", "tpl-login-tty1.dinit"),
    entry("deps-mix.service", "deps-mix.service", vendor, .system, vendor_dest ++ "deps-mix", "deps-mix.dinit"),
    entry("backup-job.service", "backup-job.service", vendor, .system, vendor_dest ++ "backup-job", "backup-job.dinit"),
    entry("dbus-activated.service", "dbus-activated.service", vendor, .system, vendor_dest ++ "dbus-activated", "dbus-activated.dinit"),
    entry("sandboxed.service", "sandboxed.service", vendor, .system, vendor_dest ++ "sandboxed", "sandboxed.dinit"),
    entry("exec-quoting.service", "exec-quoting.service", vendor, .system, vendor_dest ++ "exec-quoting", "exec-quoting.dinit"),
    entry("exec-vars.service", "exec-vars.service", vendor, .system, vendor_dest ++ "exec-vars", "exec-vars.dinit"),
    entry("multi-oneshot.service", "multi-oneshot.service", vendor, .system, vendor_dest ++ "multi-oneshot", "multi-oneshot.dinit"),
    entry("reload-stop.service", "reload-stop.service", vendor, .system, vendor_dest ++ "reload-stop", "reload-stop.dinit"),
    entry("admin-override.service", "admin-override.service", "/etc/systemd/system", .system, "/etc/dinit.d/admin-override", "admin-override.dinit"),
    entry("user-unit.service", "user-unit.service", "/usr/lib/systemd/user", .user, "/usr/lib/dinit.d/user/user-unit", "user-unit.dinit"),
};

/// Settings dinit-service(5) knows; an unknown one makes dinit reject the whole service.
const known_keys = [_][]const u8{
    "type",                "command",         "stop-command",  "run-as",        "load-options", "working-dir",
    "restart",             "smooth-recovery", "restart-delay", "start-timeout", "stop-timeout", "term-signal",
    "options",             "nice",            "rlimit-nofile", "rlimit-core",   "rlimit-data",  "rlimit-addrspace",
    "pid-file",            "depends-on",      "waits-for",     "after",         "before",       "logfile",
    "logfile-permissions",
};

fn expectKnownKeys(body: []const u8) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const end = std.mem.findAny(u8, line, " =:") orelse line.len;
        const key = line[0..end];
        const known = for (known_keys) |k| {
            if (std.mem.eql(u8, k, key)) break true;
        } else false;
        if (!known) {
            std.debug.print("unknown dinit setting '{s}' in:\n{s}\n", .{ key, body });
            return error.UnknownDinitSetting;
        }
    }
}

fn updateRequested() bool {
    var env = testing.environ.createMap(testing.allocator) catch return false;
    defer env.deinit();
    return env.get("FAKE_SYSTEMD_UPDATE_GOLDEN") != null;
}

fn runEntry(e: Entry) !void {
    var t: h.Harness = undefined;
    try t.init();
    defer t.deinit();
    const a = t.a();
    try world.populate(&t);
    if (e.scope == .user) {
        try t.environ.put("HOME", "/home/tester");
        t.ctx = try .init(a, testing.io, &t.fs, &t.diag, &t.environ, .user, 1000);
    }
    try t.write(try std.fmt.allocPrint(a, "{s}/{s}", .{ e.src_dir, e.file }), e.unit_text, 0o644);
    var d: world.dinit = undefined;
    world.use(&t, &d);
    const be = d.backend();

    const name = try h.unit.name.parse(a, e.request);
    const resolved = try h.unit.resolve.resolve(a, t.fs, .{ .scope = e.scope, .xdg_config_home = t.ctx.xdg_config_home }, name);
    const user: h.unit.specifier.UserInfo = .{ .name = if (e.scope == .user) "tester" else "root", .uid = t.ctx.uid, .home = t.ctx.home };
    const env: h.unit.specifier.Env = switch (e.scope) {
        .system => .system(user),
        .user => try .userScope(a, user, .{ .runtime = "/run/user/1000", .state = "/home/tester/.local/state", .cache = "/home/tester/.cache", .config = "/home/tester/.config" }),
    };
    const unit = try h.unit.model.load(a, t.fs, resolved, .{ .env = env });
    const generated = try be.generate(a, .{ .unit = &unit, .tier = resolved.tier().?, .source = resolved.fragment.?.path, .src_hash = 0x0123456789abcdef });

    try testing.expectEqual(@as(usize, 1), generated.files.len);
    const file = generated.files[0];
    try testing.expectEqualStrings(e.dest, file.path);
    try testing.expectEqualStrings(std.fs.path.basename(e.dest), generated.service_name);

    const parsed = marker.parse(file.content) orelse return error.MissingMarker;
    try testing.expectEqualStrings(name.full, parsed.marker.unit);
    try testing.expect(parsed.bodyIntact());
    try expectKnownKeys(parsed.rest);

    if (updateRequested()) {
        const path = try std.fmt.allocPrint(a, "tests/golden/dinit/{s}", .{e.golden});
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = file.content });
        return;
    }
    testing.expectEqualStrings(e.expected, file.content) catch |err| {
        std.debug.print("golden mismatch for {s}\n", .{e.golden});
        return err;
    };
}

test "corpus translates to the golden dinit services" {
    for (entries) |e| try runEntry(e);
}
