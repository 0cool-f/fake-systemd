// SPDX-License-Identifier: GPL-3.0-or-later
//! Identity of the service process: which account `User=`, `Group=` and `SupplementaryGroups=`
//! name, and whether the executor itself switches to it.
//!
//! As root the executor switches to the named account, which must resolve from `/etc/passwd`
//! and `/etc/group`; a name that does not resolve is refused (status 217 for the user, 216 for
//! groups) because running the service as root instead would be a privilege escalation. The
//! refusal does not apply when the identity was already set by the service manager, which is
//! assumed when the executor does not run as root or was started with `--identity-set`. Without
//! root, a requested identity that differs from the current one cannot be taken: a warning is
//! printed and the current identity is kept.
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

/// A name that does not resolve, or a numeric identity that lacks the uid or the gid, while the
/// executor is root.
pub const Refusal = struct {
    /// systemd exit status: 217 for the user, 216 for groups.
    code: u8,
    name: []const u8,
    incomplete: bool = false,
};

pub const Identity = struct {
    /// The account of `User=` when it resolves, for `HOME`, `SHELL` and the home directory.
    account: ?accounts.User = null,
    switch_to: ?Switch = null,
    refused: ?Refusal = null,
};

pub const Warning = union(enum) {
    unprivileged: []const u8,
};

pub const Current = struct {
    euid: u32,
    egid: u32,
    /// The service manager has set the identity already, so nothing is switched or refused.
    identity_set: bool = false,
    /// A numeric identity given by the service manager, switched to instead of the accounts named
    /// by the unit, which need not resolve.
    explicit: ?Switch = null,
};

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
    if (current.identity_set) return result;
    if (current.explicit) |sw| {
        if (current.euid == 0) {
            // A uid without a gid would leave gid 0 and root's groups on the service.
            if (sw.uid == null or sw.gid == null) {
                result.refused = .{ .code = 217, .name = unit.user orelse unit.group orelse "", .incomplete = true };
                return result;
            }
            var full = sw;
            if (full.groups == null) full.groups = try gpa.dupe(u32, &.{sw.gid.?});
            result.switch_to = full;
        } else if ((sw.uid != null and sw.uid.? != current.euid) or (sw.gid != null and sw.gid.? != current.egid)) {
            try warnings.append(gpa, .{ .unprivileged = unit.user orelse unit.group orelse "" });
        }
        return result;
    }
    if (unit.user == null and unit.group == null and unit.supplementary_groups.len == 0) return result;

    var sw: Switch = .{};
    var unresolved: ?Refusal = null;
    if (unit.user) |name| {
        if (result.account) |u| {
            sw.uid = u.uid;
            sw.gid = u.gid;
        } else unresolved = unresolved orelse .{ .code = 217, .name = name };
    }
    if (unit.group) |name| {
        if (db.findGroup(name)) |g| sw.gid = g.gid else unresolved = unresolved orelse .{ .code = 216, .name = name };
    }
    var groups: std.ArrayList(u32) = .empty;
    if (result.account) |u| try groups.appendSlice(gpa, try db.groupsOf(gpa, u.name));
    for (unit.supplementary_groups) |name| {
        if (db.findGroup(name)) |g| {
            if (std.mem.findScalar(u32, groups.items, g.gid) == null) try groups.append(gpa, g.gid);
        } else unresolved = unresolved orelse .{ .code = 216, .name = name };
    }
    if (result.account != null or unit.supplementary_groups.len > 0) sw.groups = try groups.toOwnedSlice(gpa);

    if (current.euid != 0) {
        if (unresolved != null) return result;
        const differs = (sw.uid != null and sw.uid.? != current.euid) or (sw.gid != null and sw.gid.? != current.egid);
        if (differs) try warnings.append(gpa, .{ .unprivileged = unit.user orelse unit.group orelse "" });
        return result;
    }
    if (unresolved) |refusal| {
        result.refused = refusal;
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

test "an unresolved name is refused as root and ignored when the identity is already set" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const db = try testDb(arena.allocator());
    const user = try resolve(arena.allocator(), db, testUnit("ldapuser", "log", &.{}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expect(user.switch_to == null);
    try std.testing.expectEqual(@as(u8, 217), user.refused.?.code);
    try std.testing.expectEqualStrings("ldapuser", user.refused.?.name);
    const group = try resolve(arena.allocator(), db, testUnit("app", "nogroup", &.{}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expectEqual(@as(u8, 216), group.refused.?.code);
    const supp = try resolve(arena.allocator(), db, testUnit("app", null, &.{"nosuch"}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expectEqual(@as(u8, 216), supp.refused.?.code);
    try std.testing.expectEqualStrings("nosuch", supp.refused.?.name);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);

    const switched = try resolve(arena.allocator(), db, testUnit("ldapuser", null, &.{}), .{ .euid = 1000, .egid = 1000 }, &warnings);
    try std.testing.expect(switched.switch_to == null and switched.refused == null);
    const flagged = try resolve(arena.allocator(), db, testUnit("ldapuser", "log", &.{"nosuch"}), .{ .euid = 0, .egid = 0, .identity_set = true }, &warnings);
    try std.testing.expect(flagged.switch_to == null and flagged.refused == null);
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

test "an explicit numeric identity replaces the accounts and is only switched to as root" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const db = try testDb(arena.allocator());
    const numeric: Switch = .{ .uid = 1500, .gid = 1501, .groups = &.{1502} };
    const root = try resolve(arena.allocator(), db, testUnit("ldapuser", "nogroup", &.{"nosuch"}), .{ .euid = 0, .egid = 0, .explicit = numeric }, &warnings);
    try std.testing.expect(root.refused == null);
    try std.testing.expectEqual(@as(?u32, 1500), root.switch_to.?.uid);
    try std.testing.expectEqualSlices(u32, &.{1502}, root.switch_to.?.groups.?);
    const user = try resolve(arena.allocator(), db, testUnit("ldapuser", null, &.{}), .{ .euid = 1000, .egid = 1000, .explicit = numeric }, &warnings);
    try std.testing.expect(user.switch_to == null and user.refused == null);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
    const same = try resolve(arena.allocator(), db, testUnit("ldapuser", null, &.{}), .{ .euid = 1500, .egid = 1501, .explicit = numeric }, &warnings);
    try std.testing.expect(same.switch_to == null);
    try std.testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "a numeric identity needs both the uid and the gid, and the groups default to the gid" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const db = try testDb(arena.allocator());
    const only_uid: Switch = .{ .uid = 1500 };
    const refused = try resolve(arena.allocator(), db, testUnit("ldapuser", null, &.{}), .{ .euid = 0, .egid = 0, .explicit = only_uid }, &warnings);
    try std.testing.expect(refused.switch_to == null);
    try std.testing.expectEqual(@as(u8, 217), refused.refused.?.code);
    try std.testing.expect(refused.refused.?.incomplete);
    const only_gid: Switch = .{ .gid = 1501, .groups = &.{1502} };
    const gid_refused = try resolve(arena.allocator(), db, testUnit("ldapuser", null, &.{}), .{ .euid = 0, .egid = 0, .explicit = only_gid }, &warnings);
    try std.testing.expect(gid_refused.refused != null and gid_refused.switch_to == null);

    const no_groups: Switch = .{ .uid = 1500, .gid = 1501 };
    const full = try resolve(arena.allocator(), db, testUnit("ldapuser", null, &.{}), .{ .euid = 0, .egid = 0, .explicit = no_groups }, &warnings);
    try std.testing.expect(full.refused == null);
    try std.testing.expectEqualSlices(u32, &.{1501}, full.switch_to.?.groups.?);
}

test "names that start with a dash never resolve, even when the database lists them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    const db: accounts.Db = .{
        .users = &.{.{ .name = "-r", .uid = 0, .gid = 0 }},
        .groups = &.{.{ .name = "-g", .gid = 0 }},
    };
    const user = try resolve(arena.allocator(), db, testUnit("-r", null, &.{}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expect(user.switch_to == null);
    try std.testing.expectEqual(@as(u8, 217), user.refused.?.code);
    const group = try resolve(arena.allocator(), db, testUnit(null, "-g", &.{}), .{ .euid = 0, .egid = 0 }, &warnings);
    try std.testing.expectEqual(@as(u8, 216), group.refused.?.code);
}
