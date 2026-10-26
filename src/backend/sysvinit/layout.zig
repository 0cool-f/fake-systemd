// SPDX-License-Identifier: GPL-3.0-or-later
//! Where sysvinit services live: init script names and directory, the `rc?.d` directories
//! whose links enable a script, and the default runlevel.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");
const native = @import("native.zig");

pub const Dirs = profile.BackendDirs;

/// Script name of a unit; an instance becomes `name.instance` as in OpenRC.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    if (name.isInstance()) return std.fmt.allocPrint(gpa, "{s}.{s}", .{ name.prefix, name.instance.? });
    return gpa.dupe(u8, name.prefix);
}

/// The directory that receives generated scripts.
pub fn generationDir(dirs: *const Dirs) []const u8 {
    return if (dirs.admin.len > 0) dirs.admin[0] else "/etc/init.d";
}

pub fn lookupDirs(dirs: *const Dirs) []const []const u8 {
    return dirs.admin;
}

/// Path of the script of `service`, or null when no script directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    for (lookupDirs(dirs)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, service });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

/// `/etc/inittab`, which names the default runlevel on systems that run sysvinit.
const inittab = "/etc/inittab";

/// The runlevel whose links say whether a service is enabled: the `initdefault` of `inittab`,
/// else the one the profile names.
pub fn defaultRunlevel(ctx: *const core.Context, dirs: *const Dirs) u8 {
    if (ctx.fs.readFileAlloc(ctx.gpa, inittab, 1 << 16)) |text| {
        if (native.parseInitDefault(text)) |level| return level;
    } else |_| {}
    const named = dirs.boot_target orelse "2";
    return if (named.len == 1) named[0] else '2';
}

/// Directory of the runlevel `level`: `/etc/rc2.d` on Debian, `/etc/rc.d/rc3.d` on Red Hat.
pub fn runlevelDir(gpa: Allocator, dirs: *const Dirs, level: u8) Allocator.Error![]const u8 {
    const base = dirs.enable_dir orelse "/etc";
    const name = try std.fmt.allocPrint(gpa, "rc{c}.d", .{level});
    return std.fs.path.join(gpa, &.{ base, name });
}

/// Relative target of a link in a runlevel directory.
pub fn linkTarget(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "../init.d/{s}", .{service});
}

/// A link of a script found in a runlevel directory.
pub const Found = struct {
    level: u8,
    start: bool,
    number: u8,
    /// Path of the link.
    path: []const u8,
};

pub const levels = "0123456S";

/// The links of `service` in all runlevel directories, in runlevel order.
pub fn linksOf(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error![]const Found {
    var out: std.ArrayList(Found) = .empty;
    for (levels) |level| {
        const dir = try runlevelDir(ctx.gpa, dirs, level);
        const entries = ctx.fs.iterateDir(ctx.gpa, dir) catch continue;
        for (entries) |e| {
            const link = native.parseLink(e.name) orelse continue;
            if (!std.mem.eql(u8, link.name, service)) continue;
            try out.append(ctx.gpa, .{
                .level = level,
                .start = link.start,
                .number = link.number,
                .path = try std.fs.path.join(ctx.gpa, &.{ dir, e.name }),
            });
        }
    }
    return out.toOwnedSlice(ctx.gpa);
}

const testing = std.testing;

test "instances become name.instance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty.tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
}

test "runlevel directories follow the profile" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deb = profile.byName("debian").?.dirs(.sysvinit_debian);
    const rh = profile.byName("redhat").?.dirs(.sysvinit_redhat);
    try testing.expectEqualStrings("/etc/rc2.d", try runlevelDir(a, deb, '2'));
    try testing.expectEqualStrings("/etc/rc.d/rc3.d", try runlevelDir(a, rh, '3'));
    try testing.expectEqualStrings("../init.d/foo", try linkTarget(a, "foo"));
}
