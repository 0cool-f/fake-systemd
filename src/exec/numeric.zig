// SPDX-License-Identifier: GPL-3.0-or-later
//! Numeric ids for a unit whose account the static executor cannot resolve from `/etc/passwd`
//! and `/etc/group` (LDAP, sssd, NIS): the system libc is asked through `id` and `getent`, the
//! way the generated init scripts ask it, and the ids go to the executor as an explicit identity.
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const core = @import("../core/root.zig");
const model = @import("../unit/model.zig");
const accounts = @import("accounts.zig");
const identity = @import("identity.zig");
const executor = @import("executor.zig");

pub const Error = error{ NotResolved, OutOfMemory };

/// A name that no tool reads as an option and that needs no quoting.
fn plainName(name: []const u8) bool {
    if (name.len == 0 or accounts.Db.isDashed(name)) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}

fn allDigits(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Output of `tool args...` when it exits with status 0; null otherwise.
fn capture(ctx: *core.Context, tool: []const u8, args: []const []const u8) Error!?[]const u8 {
    const exe = (try executor.findExecutable(ctx.gpa, tool)) orelse return null;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.gpa, exe);
    try argv.appendSlice(ctx.gpa, args);
    const res = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv.items, .environ_map = ctx.environ }) catch return null;
    switch (res.term) {
        .exited => |c| if (c != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, res.stdout, " \t\r\n");
}

fn idNumber(ctx: *core.Context, flag: []const u8, user: []const u8) Error!u32 {
    const text = (try capture(ctx, "id", &.{ flag, "--", user })) orelse return error.NotResolved;
    return std.fmt.parseInt(u32, text, 10) catch error.NotResolved;
}

/// Gid of a group name or number: from the database when it lists the group, else `getent`.
fn groupId(ctx: *core.Context, db: accounts.Db, name: []const u8) Error!u32 {
    if (allDigits(name)) return std.fmt.parseInt(u32, name, 10) catch error.NotResolved;
    if (db.findGroup(name)) |g| return g.gid;
    const line = (try capture(ctx, "getent", &.{ "group", name })) orelse return error.NotResolved;
    var fields = std.mem.splitScalar(u8, line, ':');
    _ = fields.next();
    _ = fields.next();
    return std.fmt.parseInt(u32, fields.next() orelse return error.NotResolved, 10) catch error.NotResolved;
}

/// True when the static executor resolves every account of `unit`.
fn executorResolves(db: accounts.Db, unit: model.Unit) bool {
    if (unit.user) |u| if (db.findUser(u) == null) return false;
    if (unit.group) |g| if (db.findGroup(g) == null) return false;
    for (unit.supplementary_groups) |g| if (db.findGroup(g) == null) return false;
    return true;
}

/// The ids of the account of `unit` for the root executor, or null when the executor resolves the
/// accounts itself, there is no `User=`, or a name is not plain, which the executor then refuses.
/// `NotResolved` when the system libc does not know the account either.
pub fn lookup(ctx: *core.Context, db: accounts.Db, unit: model.Unit) Error!?identity.Switch {
    if (unit.scope == .user or linux.geteuid() != 0) return null;
    const user = unit.user orelse return null;
    if (executorResolves(db, unit)) return null;
    if (!plainName(user)) return null;
    if (unit.group) |g| if (!allDigits(g) and !plainName(g)) return null;
    for (unit.supplementary_groups) |g| if (!allDigits(g) and !plainName(g)) return null;

    const uid = try idNumber(ctx, "-u", user);
    const gid = if (unit.group) |g| try groupId(ctx, db, g) else try idNumber(ctx, "-g", user);
    var groups: std.ArrayList(u32) = .empty;
    const listed = (try capture(ctx, "id", &.{ "-G", "--", user })) orelse return error.NotResolved;
    var it = std.mem.tokenizeAny(u8, listed, " \t\n");
    while (it.next()) |g| try groups.append(ctx.gpa, std.fmt.parseInt(u32, g, 10) catch return error.NotResolved);
    for (unit.supplementary_groups) |g| {
        const id = try groupId(ctx, db, g);
        if (std.mem.findScalar(u32, groups.items, id) == null) try groups.append(ctx.gpa, id);
    }
    return .{ .uid = uid, .gid = gid, .groups = try groups.toOwnedSlice(ctx.gpa) };
}
