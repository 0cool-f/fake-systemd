//! Identity of the service process: which account `User=`, `Group=` and `SupplementaryGroups=`
//! name, and whether the executor itself switches to it.
//!
//! The switch is made only when every named account resolves from `/etc/passwd` and
//! `/etc/group` and the executor runs as root. When a name does not resolve, the backend is
//! expected to have started the executor with the final identity (spec §6.7), so nothing is
//! switched and a warning is printed if the executor still runs as root. Without root, a
//! requested identity that differs from the current one cannot be taken: a warning is printed
//! and the current identity is kept.
const std = @import("std");
const Allocator = std.mem.Allocator;
const accounts = @import("accounts.zig");
const sys = @import("sys.zig");
const model = @import("../unit/model.zig");

pub const Switch = struct {
    uid: ?u32 = null,
    gid: ?u32 = null,
    /// Null leaves the supplementary groups alone.
    groups: ?[]const u32 = null,
};

pub const Identity = struct {
    /// The account of `User=` when it resolves, for `HOME`, `SHELL` and the home directory.
    account: ?accounts.User = null,
    switch_to: ?Switch = null,
};

pub const Warning = union(enum) {
    unresolved: []const u8,
    unprivileged: []const u8,
};

pub const Current = struct { euid: u32, egid: u32 };

/// `warnings` collects messages for the caller to print.
pub fn resolve(
    gpa: Allocator,
    db: accounts.Db,
    unit: model.Unit,
    current: Current,
    warnings: *std.ArrayList(Warning),
) Allocator.Error!Identity {
    var result: Identity = .{};
    if (unit.user) |name| result.account = db.findUser(name);
    if (unit.user == null and unit.group == null and unit.supplementary_groups.len == 0) return result;

    var sw: Switch = .{};
    var unresolved: ?[]const u8 = null;
    if (unit.user) |name| {
        if (result.account) |u| {
            sw.uid = u.uid;
            sw.gid = u.gid;
        } else unresolved = unresolved orelse name;
    }
    if (unit.group) |name| {
        if (db.findGroup(name)) |g| sw.gid = g.gid else unresolved = unresolved orelse name;
    }
    var groups: std.ArrayList(u32) = .empty;
    if (result.account) |u| try groups.appendSlice(gpa, try db.groupsOf(gpa, u.name));
    for (unit.supplementary_groups) |name| {
        if (db.findGroup(name)) |g| {
            if (std.mem.findScalar(u32, groups.items, g.gid) == null) try groups.append(gpa, g.gid);
        } else unresolved = unresolved orelse name;
    }
    if (result.account != null or unit.supplementary_groups.len > 0) sw.groups = try groups.toOwnedSlice(gpa);

    if (unresolved) |name| {
        if (current.euid == 0) try warnings.append(gpa, .{ .unresolved = name });
        return result;
    }
    if (current.euid != 0) {
        const differs = (sw.uid != null and sw.uid.? != current.euid) or (sw.gid != null and sw.gid.? != current.egid);
        if (differs) try warnings.append(gpa, .{ .unprivileged = unit.user orelse unit.group orelse "" });
        return result;
    }
    result.switch_to = sw;
    return result;
}

pub const Failure = struct {
    /// systemd exit status: 216 for groups, 217 for the user.
    code: u8,
    errno: sys.E,
};

/// Order matters: supplementary groups and the gid must be set while still root.
pub fn apply(sw: Switch) ?Failure {
    if (sw.groups) |g| {
        const e = sys.setGroups(g);
        if (e != .SUCCESS) return .{ .code = 216, .errno = e };
    }
    if (sw.gid) |gid| {
        const e = sys.setGid(gid);
        if (e != .SUCCESS) return .{ .code = 216, .errno = e };
    }
    if (sw.uid) |uid| {
        const e = sys.setUid(uid);
        if (e != .SUCCESS) return .{ .code = 217, .errno = e };
    }
    return null;
}

fn testDb(arena: Allocator) !accounts.Db {
    return .{
        .users = try accounts.parsePasswd(arena, "app:x:1001:1001::/var/lib/app:/bin/sh\n"),
        .groups = try accounts.parseGroup(arena, "app:x:1001:app\nwheel:x:10:app\nlog:x:20:\n"),
    };
}

fn testUnit(user: ?[]const u8, group: ?[]const u8, supp: []const []const u8) model.Unit {
    return .{
        .name = undefined,
        .scope = .system,
        .user = user,
        .group = group,
        .supplementary_groups = supp,
    };
}

test "all names resolve and the executor is root" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const id = try resolve(arena.allocator(), try testDb(arena.allocator()), testUnit("app", "log", &.{"wheel"}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqualStrings("/var/lib/app", id.account.?.home.?);
    const sw = id.switch_to.?;
    try std.testing.expectEqual(@as(u32, 1001), sw.uid.?);
    try std.testing.expectEqual(@as(u32, 20), sw.gid.?);
    try std.testing.expectEqualSlices(u32, &.{ 1001, 10 }, sw.groups.?);
}

test "primary group of the user is the default and supplementary groups are cleared" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const id = try resolve(arena.allocator(), .{ .users = try accounts.parsePasswd(arena.allocator(), "solo:x:7:8::/h:\n") }, testUnit("solo", null, &.{}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expectEqual(@as(u32, 8), id.switch_to.?.gid.?);
    try std.testing.expectEqual(@as(usize, 0), id.switch_to.?.groups.?.len);
}

test "an unresolved name skips the whole switch and warns as root" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const db = try testDb(arena.allocator());
    const id = try resolve(arena.allocator(), db, testUnit("ldapuser", "log", &.{}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expect(id.switch_to == null);
    try std.testing.expectEqualStrings("ldapuser", warnings.items[0].unresolved);
    warnings.clearRetainingCapacity();
    const quiet = try resolve(arena.allocator(), db, testUnit("ldapuser", null, &.{}), .{ .euid = 1000, .egid = 1000 }, &warnings);
    try std.testing.expect(quiet.switch_to == null);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "without root a different identity cannot be taken" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const db = try testDb(arena.allocator());
    const id = try resolve(arena.allocator(), db, testUnit("app", null, &.{}), .{ .euid = 1000, .egid = 1000 }, &warnings);
    try std.testing.expect(id.switch_to == null);
    try std.testing.expectEqualStrings("app", warnings.items[0].unprivileged);
    warnings.clearRetainingCapacity();
    const same = try resolve(arena.allocator(), db, testUnit("app", null, &.{}), .{ .euid = 1001, .egid = 1001 }, &warnings);
    try std.testing.expect(same.switch_to == null);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "no identity settings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const id = try resolve(arena.allocator(), .{}, testUnit(null, null, &.{}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expect(id.switch_to == null and id.account == null);
}
