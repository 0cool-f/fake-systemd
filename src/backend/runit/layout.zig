// SPDX-License-Identifier: GPL-3.0-or-later
//! Where runit services live: service directory names, the single generation directory per
//! scope, lookup, and the directory whose symlinks `runsvdir` supervises.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

/// Directory name of a unit. `runsvdir` and `sv` accept `@`, `:` and `\` in a name, so an
/// instance keeps its `foo@bar` form, which also lets `getty@tty1` read as in systemd.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    if (name.isInstance()) return std.fmt.allocPrint(gpa, "{s}@{s}", .{ name.prefix, name.instance.? });
    return gpa.dupe(u8, name.prefix);
}

/// Replaces a leading `~/` (`~/.config/` maps to `$XDG_CONFIG_HOME/`).
pub fn expandHome(ctx: *const core.Context, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.cutPrefix(u8, path, "~/.config/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.xdg_config_home, rest });
    if (std.mem.cutPrefix(u8, path, "~/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.home, rest });
    return path;
}

/// The one directory that receives generated services, whatever the tier of the unit.
pub fn generationDir(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const u8 {
    return switch (scope) {
        .system => if (dirs.admin.len > 0) dirs.admin[0] else "/etc/sv",
        .user => expandHome(ctx, if (dirs.user.len > 0) dirs.user[0] else "~/.config/sv"),
    };
}

/// Service directories of `scope`, the places `sv` names resolve to.
pub fn lookupDirs(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (scope) {
        .system => try out.appendSlice(ctx.gpa, dirs.admin),
        .user => try out.append(ctx.gpa, try generationDir(ctx, dirs, .user)),
    }
    return out.toOwnedSlice(ctx.gpa);
}

/// Path of the directory of `service`, or null when no lookup directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    for (try lookupDirs(ctx, dirs, ctx.scope)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, service });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

/// Directory whose symlinks are the enabled services. `user_override` replaces the profile's
/// user directory when the user service manager is configured to use another one.
pub fn enableDir(ctx: *const core.Context, dirs: *const Dirs, user_override: ?[]const u8) Allocator.Error![]const u8 {
    return switch (ctx.scope) {
        .system => dirs.enable_dir orelse "/etc/runit/runsvdir/default",
        .user => user_override orelse try expandHome(ctx, dirs.user_enable_dir orelse "~/.config/service"),
    };
}

/// Service a generated file belongs to: the directory below the service directory that holds
/// `run`, `finish`, `log/run` and `control/*`.
pub fn serviceOfFile(path: []const u8) []const u8 {
    var dir = std.fs.path.dirname(path) orelse return std.fs.path.basename(path);
    const leaf = std.fs.path.basename(dir);
    if (std.mem.eql(u8, leaf, "log") or std.mem.eql(u8, leaf, "control")) dir = std.fs.path.dirname(dir) orelse dir;
    return std.fs.path.basename(dir);
}

const testing = std.testing;

test "instances keep the @ and the characters of the unit name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty@tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("wg-quick@wg0", try serviceName(a, try name_mod.parse(a, "wg-quick@wg0.service")));
    try testing.expectEqualStrings("x@a:b\\x2d", try serviceName(a, try name_mod.parse(a, "x@a:b\\x2d.service")));
}

test "the service of a generated file is found through log and control" {
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/sv/foo/run"));
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/sv/foo/finish"));
    try testing.expectEqualStrings("foo@a", serviceOfFile("/etc/sv/foo@a/log/run"));
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/sv/foo/control/t"));
}
