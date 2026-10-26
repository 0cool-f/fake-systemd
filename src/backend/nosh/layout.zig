// SPDX-License-Identifier: GPL-3.0-or-later
//! Where nosh service bundles live: the bundle of a service, the target bundles whose `wants/`
//! directories enable it, and the directory of the files that record which unit a bundle comes from.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

pub const default_services = "/etc/service-bundles/services";

/// An instance becomes `name@instance`, the form nosh uses for the instances of a template.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, name.prefix);
    if (name.isInstance()) {
        try out.append(gpa, '@');
        for (name.instance.?) |c| try out.append(gpa, if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_');
    }
    return out.toOwnedSlice(gpa);
}

/// The directory that receives the converted bundles.
pub fn bundleRoot(dirs: *const Dirs) []const u8 {
    return if (dirs.admin.len > 0) dirs.admin[0] else default_services;
}

/// `/etc/service-bundles`, which holds `services/`, `targets/` and the record directory.
pub fn bundleBase(dirs: *const Dirs) []const u8 {
    return std.fs.path.dirname(bundleRoot(dirs)) orelse "/etc/service-bundles";
}

pub fn targetsDir(gpa: Allocator, dirs: *const Dirs) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ bundleBase(dirs), "targets" });
}

/// Directory of the files that name the unit each generated bundle is converted from.
pub fn recordDir(gpa: Allocator, dirs: *const Dirs) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ bundleBase(dirs), "fake-systemd" });
}

pub fn recordPath(gpa: Allocator, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ try recordDir(gpa, dirs), service });
}

pub fn bundlePath(gpa: Allocator, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ bundleRoot(dirs), service });
}

/// Path of the bundle of `service`, or null when no lookup directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    for (dirs.admin) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, service });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

const testing = std.testing;

test "instances become name@instance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty@tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
}

test "paths derive from the bundle root of the profile" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = profile.generic.dirs(.nosh);
    try testing.expectEqualStrings("/etc/service-bundles/services/foo", try bundlePath(a, d, "foo"));
    try testing.expectEqualStrings("/etc/service-bundles/targets", try targetsDir(a, d));
    try testing.expectEqualStrings("/etc/service-bundles/fake-systemd/foo", try recordPath(a, d, "foo"));
}
