// SPDX-License-Identifier: GPL-3.0-or-later
//! Where procd services live: the scripts in `/etc/init.d`, and the links `S<START><name>` and
//! `K<STOP><name>` in `/etc/rc.d` that `/etc/init.d/<name> enable` writes and the boot and the
//! shutdown follow.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

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

/// Directory of the boot and shutdown links.
pub fn linkDir(dirs: *const Dirs) []const u8 {
    return dirs.enable_dir orelse "/etc/rc.d";
}

/// Relative target of a link in the link directory.
pub fn linkTarget(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "../init.d/{s}", .{service});
}

pub fn linkFile(gpa: Allocator, dirs: *const Dirs, starts: bool, number: u8, service: []const u8) Allocator.Error![]const u8 {
    const name = try std.fmt.allocPrint(gpa, "{c}{d:0>2}{s}", .{ @as(u8, if (starts) 'S' else 'K'), number, service });
    return std.fs.path.join(gpa, &.{ linkDir(dirs), name });
}

/// A name in the link directory: `S` or `K`, two digits and the name of the script.
pub const Link = struct {
    start: bool,
    number: u8,
    name: []const u8,
};

pub fn parseLink(file: []const u8) ?Link {
    if (file.len < 4 or (file[0] != 'S' and file[0] != 'K')) return null;
    const number = std.fmt.parseInt(u8, file[1..3], 10) catch return null;
    return .{ .start = file[0] == 'S', .number = number, .name = file[3..] };
}

/// A link of a script found in the link directory.
pub const Found = struct {
    start: bool,
    number: u8,
    /// Path of the link.
    path: []const u8,
};

/// The links of `service`.
pub fn linksOf(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error![]const Found {
    var out: std.ArrayList(Found) = .empty;
    const dir = linkDir(dirs);
    const entries = ctx.fs.iterateDir(ctx.gpa, dir) catch return out.items;
    for (entries) |e| {
        const link = parseLink(e.name) orelse continue;
        if (!std.mem.eql(u8, link.name, service)) continue;
        try out.append(ctx.gpa, .{ .start = link.start, .number = link.number, .path = try std.fs.path.join(ctx.gpa, &.{ dir, e.name }) });
    }
    return out.toOwnedSlice(ctx.gpa);
}

const testing = std.testing;

test "links are S or K, two digits and the script name" {
    const s = parseLink("S50foo").?;
    try testing.expect(s.start and s.number == 50 and std.mem.eql(u8, s.name, "foo"));
    try testing.expect(!parseLink("K05a.b").?.start);
    try testing.expect(parseLink("S5foo") == null and parseLink("X50foo") == null and parseLink("S50") == null);
}

test "instances become name.instance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty.tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("/etc/rc.d/S50foo", try linkFile(a, profile.generic.dirs(.procd), true, 50, "foo"));
}
