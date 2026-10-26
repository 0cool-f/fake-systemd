// SPDX-License-Identifier: GPL-3.0-or-later
//! Where BSD-style rc services live: the scripts `rc.<name>` in `/etc/rc.d`, which are enabled
//! by their execute permission, and the two hook scripts that start and stop the generated ones.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

pub const prefix = "rc.";
/// Run by `rc.M` when the system enters a multi-user runlevel, after the network scripts.
pub const start_hook = "rc.local";
/// Run by `rc.6` with the argument `stop` before the system stops its daemons.
pub const stop_hook = "rc.local_shutdown";

/// Boot scripts of the system that are not services: they take no service verbs, and a unit
/// named like one would replace a part of the boot sequence.
const reserved = [_][]const u8{ "0", "4", "6", "K", "M", "S", "local", "local_shutdown", "sysvinit", "modules", "modules.local" };

pub fn isReserved(service: []const u8) bool {
    for (reserved) |r| if (std.mem.eql(u8, r, service)) return true;
    return false;
}

/// Service name of a unit; an instance becomes `name.instance` as in OpenRC.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    if (name.isInstance()) return std.fmt.allocPrint(gpa, "{s}.{s}", .{ name.prefix, name.instance.? });
    return gpa.dupe(u8, name.prefix);
}

/// The directory that receives generated scripts.
pub fn generationDir(dirs: *const Dirs) []const u8 {
    return if (dirs.admin.len > 0) dirs.admin[0] else "/etc/rc.d";
}

pub fn lookupDirs(dirs: *const Dirs) []const []const u8 {
    return dirs.admin;
}

/// File name of the script of `service`.
pub fn scriptName(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, service });
}

/// Path of the script of `service` in the generation directory.
pub fn scriptPath(gpa: Allocator, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ generationDir(dirs), try scriptName(gpa, service) });
}

/// Path of the script of `service`, or null when no script directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    const file = try scriptName(ctx.gpa, service);
    for (lookupDirs(dirs)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, file });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

/// Service a script file belongs to: the name without `rc.`.
pub fn serviceOfFile(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return std.mem.cutPrefix(u8, base, prefix) orelse base;
}

pub fn hookPath(gpa: Allocator, dirs: *const Dirs, hook: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(gpa, &.{ generationDir(dirs), hook });
}

const testing = std.testing;

test "scripts are named rc.<service> and reserved names are the boot scripts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty.tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("rc.foo", try scriptName(a, "foo"));
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/rc.d/rc.foo"));
    try testing.expect(isReserved("M") and isReserved("local_shutdown") and !isReserved("sshd"));
}
