// SPDX-License-Identifier: GPL-3.0-or-later
//! Where finit services live: service names, the `available/` directory that receives generated
//! files, the `enabled/` directory whose symlinks load them at boot, and the volatile directory
//! finit also reads.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

/// Directory of the `.conf` files finit reads; `rcsd` in `finit.conf`.
pub const default_rcsd = "/etc/finit.d";
/// `.conf` files of this directory are read before the ones of `rcsd`; they load a service
/// without enabling it.
pub const runtime_dir = "/run/finit/system";
/// Suffix of a service file.
pub const conf_suffix = ".conf";
/// Suffix of the script that finit runs after the service stopped.
pub const post_suffix = ".stop-post";

/// An instance becomes `name-instance`, because `@` in a finit identity selects a template.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, name.prefix);
    if (name.isInstance()) {
        try out.append(gpa, '-');
        for (name.instance.?) |c| try out.append(gpa, if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_');
    }
    return out.toOwnedSlice(gpa);
}

/// Service a generated file belongs to: the `.conf` file and the stop-post script of a service
/// share its name.
pub fn serviceOfFile(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.cutSuffix(u8, base, conf_suffix)) |s| return s;
    if (std.mem.cutSuffix(u8, base, post_suffix)) |s| return s;
    return base;
}

pub fn rcsd(dirs: *const Dirs) []const u8 {
    return if (dirs.admin.len > 0) dirs.admin[0] else default_rcsd;
}

/// The one directory that receives generated files, whatever the tier of the unit.
pub fn availableDir(gpa: Allocator, dirs: *const Dirs) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ rcsd(dirs), "available" });
}

pub fn enabledDir(gpa: Allocator, dirs: *const Dirs) Allocator.Error![]const u8 {
    return if (dirs.enable_dir) |d| gpa.dupe(u8, d) else std.fs.path.join(gpa, &.{ rcsd(dirs), "enabled" });
}

pub fn confName(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ service, conf_suffix });
}

pub fn availablePath(gpa: Allocator, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ try availableDir(gpa, dirs), try confName(gpa, service) });
}

pub fn enabledPath(gpa: Allocator, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ try enabledDir(gpa, dirs), try confName(gpa, service) });
}

/// Link in the volatile directory that makes finit load `service` until it is removed.
pub fn runtimePath(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ runtime_dir, try confName(gpa, service) });
}

/// Path of the stop-post script of `service`, next to its `.conf` file.
pub fn postScriptPath(gpa: Allocator, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ try availableDir(gpa, dirs), try std.fmt.allocPrint(gpa, "{s}{s}", .{ service, post_suffix }) });
}

/// Directories whose `.conf` files define services: loaded at boot (`rcsd`, `enabled`) or on
/// demand (`available`).
pub fn lookupDirs(gpa: Allocator, dirs: *const Dirs) Allocator.Error![]const []const u8 {
    const out = try gpa.alloc([]const u8, 3);
    out[0] = try availableDir(gpa, dirs);
    out[1] = rcsd(dirs);
    out[2] = try enabledDir(gpa, dirs);
    return out;
}

/// Path of the `.conf` file of `service`, or null when none of the lookup directories holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    const file = try confName(ctx.gpa, service);
    for (try lookupDirs(ctx.gpa, dirs)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, file });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

const testing = std.testing;

test "instances become name-instance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty-tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("wg-quick-wg_0", try serviceName(a, try name_mod.parse(a, "wg-quick@wg:0.service")));
}

test "files of a service map back to its name" {
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/finit.d/available/foo.conf"));
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/finit.d/available/foo.stop-post"));
}

test "paths follow the profile directory" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = profile.generic.dirs(.finit);
    try testing.expectEqualStrings("/etc/finit.d/available/foo.conf", try availablePath(a, d, "foo"));
    try testing.expectEqualStrings("/etc/finit.d/enabled/foo.conf", try enabledPath(a, d, "foo"));
    try testing.expectEqualStrings("/run/finit/system/foo.conf", try runtimePath(a, "foo"));
    try testing.expectEqualStrings("/etc/finit.d/available/foo.stop-post", try postScriptPath(a, d, "foo"));
}
