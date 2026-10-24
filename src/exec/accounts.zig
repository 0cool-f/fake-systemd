//! Users and groups from `/etc/passwd` and `/etc/group`, read through `Fs`. There is no NSS:
//! accounts that live elsewhere are not found.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../core/Fs.zig");

pub const User = struct {
    name: []const u8,
    uid: u32,
    gid: u32,
    home: ?[]const u8 = null,
    shell: ?[]const u8 = null,
};

pub const Group = struct {
    name: []const u8,
    gid: u32,
    members: []const []const u8 = &.{},
};

pub const Db = struct {
    users: []const User = &.{},
    groups: []const Group = &.{},

    /// Reads both files; a missing or unreadable file reads as empty. Allocates with `gpa`,
    /// an arena.
    pub fn load(gpa: Allocator, fs: Fs) Db {
        return .{
            .users = parsePasswd(gpa, readOrEmpty(gpa, fs, "/etc/passwd")) catch &.{},
            .groups = parseGroup(gpa, readOrEmpty(gpa, fs, "/etc/group")) catch &.{},
        };
    }

    /// A user name or a numeric uid. A numeric uid without a passwd entry resolves to itself
    /// with the same gid.
    pub fn findUser(db: Db, spec: []const u8) ?User {
        if (std.fmt.parseInt(u32, spec, 10)) |uid| {
            for (db.users) |u| if (u.uid == uid) return u;
            return .{ .name = spec, .uid = uid, .gid = uid };
        } else |_| {}
        for (db.users) |u| if (std.mem.eql(u8, u.name, spec)) return u;
        return null;
    }

    /// A group name or a numeric gid; a numeric gid needs no group entry.
    pub fn findGroup(db: Db, spec: []const u8) ?Group {
        if (std.fmt.parseInt(u32, spec, 10)) |gid| {
            for (db.groups) |g| if (g.gid == gid) return g;
            return .{ .name = spec, .gid = gid };
        } else |_| {}
        for (db.groups) |g| if (std.mem.eql(u8, g.name, spec)) return g;
        return null;
    }

    /// Gids of the groups that list `user_name` as a member.
    pub fn groupsOf(db: Db, gpa: Allocator, user_name: []const u8) Allocator.Error![]const u32 {
        var out: std.ArrayList(u32) = .empty;
        for (db.groups) |g| {
            for (g.members) |m| {
                if (std.mem.eql(u8, m, user_name)) {
                    try out.append(gpa, g.gid);
                    break;
                }
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

fn readOrEmpty(gpa: Allocator, fs: Fs, path: []const u8) []const u8 {
    return fs.readFileAlloc(gpa, path, 4 << 20) catch "";
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

pub fn parsePasswd(gpa: Allocator, content: []const u8) Allocator.Error![]const User {
    var out: std.ArrayList(User) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        _ = f.next() orelse continue;
        const home = f.next() orelse continue;
        const shell = f.next() orelse "";
        if (name.len == 0 or name[0] == '#' or name[0] == '+' or name[0] == '-') continue;
        try out.append(gpa, .{ .name = name, .uid = uid, .gid = gid, .home = nonEmpty(home), .shell = nonEmpty(shell) });
    }
    return out.toOwnedSlice(gpa);
}

pub fn parseGroup(gpa: Allocator, content: []const u8) Allocator.Error![]const Group {
    var out: std.ArrayList(Group) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse continue;
        _ = f.next() orelse continue;
        const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const member_list = f.next() orelse "";
        if (name.len == 0 or name[0] == '#' or name[0] == '+' or name[0] == '-') continue;
        var members: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, member_list, ',');
        while (it.next()) |m| try members.append(gpa, std.mem.trim(u8, m, " \t"));
        try out.append(gpa, .{ .name = name, .gid = gid, .members = try members.toOwnedSlice(gpa) });
    }
    return out.toOwnedSlice(gpa);
}

fn testDb(arena: Allocator) !Db {
    return .{
        .users = try parsePasswd(arena,
            \\root:x:0:0:root:/root:/bin/bash
            \\# comment
            \\+@nis::::::
            \\app:x:1001:1001::/var/lib/app:
            \\broken:x:abc:1:::
            \\
        ),
        .groups = try parseGroup(arena,
            \\root:x:0:
            \\wheel:x:10:root,app
            \\app:x:1001:app
            \\data:x:2000:other, app
            \\
        ),
    };
}

test "passwd and group parsing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const db = try testDb(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), db.users.len);
    try std.testing.expectEqualStrings("/var/lib/app", db.users[1].home.?);
    try std.testing.expect(db.users[1].shell == null);
    try std.testing.expectEqual(@as(usize, 4), db.groups.len);
}

test "lookup by name and number" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const db = try testDb(arena.allocator());
    try std.testing.expectEqual(@as(u32, 1001), db.findUser("app").?.uid);
    try std.testing.expectEqualStrings("app", db.findUser("1001").?.name);
    try std.testing.expect(db.findUser("ghost") == null);
    const numeric = db.findUser("4242").?;
    try std.testing.expectEqual(@as(u32, 4242), numeric.gid);
    try std.testing.expectEqual(@as(u32, 10), db.findGroup("wheel").?.gid);
    try std.testing.expectEqual(@as(u32, 77), db.findGroup("77").?.gid);
    try std.testing.expect(db.findGroup("ghosts") == null);
}

test "supplementary groups of a user" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const db = try testDb(arena.allocator());
    const gids = try db.groupsOf(arena.allocator(), "app");
    try std.testing.expectEqualSlices(u32, &.{ 10, 1001, 2000 }, gids);
}

test "load reads through Fs and tolerates absence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs: Fs = .initDir(std.testing.io, tmp.dir);
    try std.testing.expectEqual(@as(usize, 0), Db.load(arena.allocator(), fs).users.len);
    try fs.makePath("/etc");
    try fs.writeFileAtomic("/etc/passwd", "u:x:5:6::/h:/s\n", 0o644);
    const db = Db.load(arena.allocator(), fs);
    try std.testing.expectEqual(@as(u32, 5), db.findUser("u").?.uid);
}
