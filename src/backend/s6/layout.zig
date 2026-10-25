// SPDX-License-Identifier: GPL-3.0-or-later
//! Where s6 and s6-rc services live: service names, the generation directory, lookup of a
//! service by name and the shape of an s6-rc service (a longrun with its logger pipeline, a
//! oneshot, or a bundle).
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

/// Plain s6 (a scan directory of service directories) or s6-rc (sources compiled into a
/// database).
pub const Flavor = enum { plain, rc };

pub const producer_suffix = "-srv";
pub const logger_suffix = "-log";

/// Name of a unit's service. `s6-supervise` and s6-rc accept `@`, `:` and `.` in a name, so an
/// instance keeps its `foo@bar` form.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    if (name.isInstance()) return std.fmt.allocPrint(gpa, "{s}@{s}", .{ name.prefix, name.instance.? });
    return gpa.dupe(u8, name.prefix);
}

/// Directory of the s6-rc longrun that runs a service with a logger pipeline.
pub fn producerName(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ service, producer_suffix });
}

pub fn loggerName(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ service, logger_suffix });
}

/// The one directory that receives generated services, whatever the tier of the unit.
pub fn generationDir(dirs: *const Dirs, flavor: Flavor) []const u8 {
    if (dirs.admin.len > 0) return dirs.admin[0];
    return switch (flavor) {
        .plain => "/etc/s6/sv",
        .rc => "/etc/s6-rc/source",
    };
}

/// Service directories, the one that receives generated services first.
pub fn lookupDirs(ctx: *const core.Context, dirs: *const Dirs, flavor: Flavor) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(ctx.gpa, generationDir(dirs, flavor));
    if (flavor == .rc) {
        for (dirs.admin) |d| if (!contains(out.items, d)) try out.append(ctx.gpa, d);
        for (dirs.vendor) |d| if (!contains(out.items, d)) try out.append(ctx.gpa, d);
    }
    return out.toOwnedSlice(ctx.gpa);
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

pub const Type = enum { longrun, oneshot, bundle };

/// Type declared in the `type` file of an s6-rc service directory.
pub fn typeOf(ctx: *const core.Context, dir: []const u8) ?Type {
    const path = std.fs.path.join(ctx.gpa, &.{ dir, "type" }) catch return null;
    const text = ctx.fs.readFileAlloc(ctx.gpa, path, 64) catch return null;
    return std.meta.stringToEnum(Type, std.mem.trim(u8, text, " \t\r\n"));
}

/// An s6-rc service found in a source directory.
pub const Located = struct {
    /// Path of the directory that defines the service; of the producer for a pipeline.
    dir: []const u8,
    /// Name of the s6-rc longrun or oneshot, or of the bundle, that `dir` defines.
    name: []const u8,
    /// True when `dir` is the producer of a logger pipeline, which `service` names as a whole.
    pipeline: bool,
    kind: Type,
};

/// The s6-rc service `service` stands for: the producer `service-srv` of a pipeline, else a
/// directory named `service`.
pub fn locateRc(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?Located {
    const gpa = ctx.gpa;
    const producer = try producerName(gpa, service);
    for (try lookupDirs(ctx, dirs, .rc)) |dir| {
        const srv = try std.fs.path.join(gpa, &.{ dir, producer });
        if (typeOf(ctx, srv)) |kind| return .{ .dir = srv, .name = producer, .pipeline = true, .kind = kind };
        const plain = try std.fs.path.join(gpa, &.{ dir, service });
        if (typeOf(ctx, plain)) |kind| return .{ .dir = plain, .name = service, .pipeline = false, .kind = kind };
    }
    return null;
}

/// Path of the plain s6 service directory of `service`, or null when no lookup directory holds it.
pub fn locatePlain(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    for (try lookupDirs(ctx, dirs, .plain)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, service });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

/// Service a generated file of plain s6 belongs to: the directory below the service directory
/// that holds `run`, `finish`, `log/run` and the data files.
pub fn serviceOfPlainFile(path: []const u8) []const u8 {
    var dir = std.fs.path.dirname(path) orelse return std.fs.path.basename(path);
    if (std.mem.eql(u8, std.fs.path.basename(dir), "log")) dir = std.fs.path.dirname(dir) orelse dir;
    return std.fs.path.basename(dir);
}

/// Service a generated file of s6-rc belongs to: the directory name without the pipeline suffix.
pub fn serviceOfRcFile(path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(path) orelse return std.fs.path.basename(path);
    const leaf = std.fs.path.basename(dir);
    for ([_][]const u8{ producer_suffix, logger_suffix }) |suffix| {
        if (std.mem.endsWith(u8, leaf, suffix) and leaf.len > suffix.len) return leaf[0 .. leaf.len - suffix.len];
    }
    return leaf;
}

const testing = std.testing;

test "instances keep the @ and the characters of the unit name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty@tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("foo-srv", try producerName(a, "foo"));
    try testing.expectEqualStrings("foo-log", try loggerName(a, "foo"));
}

test "the service of a generated file is found through the log directory and the pipeline suffix" {
    try testing.expectEqualStrings("foo", serviceOfPlainFile("/etc/s6/sv/foo/run"));
    try testing.expectEqualStrings("foo", serviceOfPlainFile("/etc/s6/sv/foo/log/run"));
    try testing.expectEqualStrings("foo", serviceOfPlainFile("/etc/s6/sv/foo/timeout-kill"));
    try testing.expectEqualStrings("foo", serviceOfRcFile("/etc/s6/adminsv/foo-srv/run"));
    try testing.expectEqualStrings("foo@a", serviceOfRcFile("/etc/s6/adminsv/foo@a-log/run"));
    try testing.expectEqualStrings("oneo", serviceOfRcFile("/etc/s6/adminsv/oneo/up"));
    try testing.expectEqualStrings("-srv", serviceOfRcFile("/etc/s6/adminsv/-srv/run"));
}
