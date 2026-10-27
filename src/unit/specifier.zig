// SPDX-License-Identifier: GPL-3.0-or-later
//! Unit-file specifiers (`%n`, `%i`, `%t`, ...) resolved against the unit name and the
//! scope-dependent environment.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Name = @import("name.zig").Name;
const Scope = @import("../core/types.zig").Scope;

pub const Error = error{ UnknownSpecifier, TrailingPercent, Unresolved } || Allocator.Error;

pub const Failure = struct {
    /// The specifier character that could not be expanded.
    specifier: u8 = 0,
};

/// Fields left null make the specifiers that need them fail with `error.Unresolved`.
pub const UserInfo = struct {
    name: []const u8,
    uid: ?u32 = null,
    group: ?[]const u8 = null,
    gid: ?u32 = null,
    home: ?[]const u8 = null,
};

const Fs = @import("../core/Fs.zig");
const account_db = @import("../exec/accounts.zig");

/// Accounts read from the contents of `/etc/passwd` and `/etc/group` of the root in use; the
/// process environment is never consulted.
pub const Accounts = struct {
    passwd: []const u8 = "",
    group: []const u8 = "",

    /// A missing file reads as empty; a file that cannot be read or is larger than the limit of the
    /// executor's account database is an error.
    pub fn read(gpa: Allocator, fs: Fs) !Accounts {
        return .{
            .passwd = try account_db.readFile(gpa, fs, "/etc/passwd"),
            .group = try account_db.readFile(gpa, fs, "/etc/group"),
        };
    }

    fn groupName(a: Accounts, gid: u32) ?[]const u8 {
        var lines = std.mem.splitScalar(u8, a.group, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next() orelse continue;
            _ = f.next() orelse continue;
            const id = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            if (id == gid) return name;
        }
        return null;
    }

    fn entry(a: Accounts, line: []const u8) ?UserInfo {
        var f = std.mem.splitScalar(u8, line, ':');
        const name = f.next() orelse return null;
        _ = f.next() orelse return null;
        const uid = std.fmt.parseInt(u32, f.next() orelse return null, 10) catch return null;
        const gid = std.fmt.parseInt(u32, f.next() orelse return null, 10) catch return null;
        _ = f.next() orelse return null;
        const home = f.next() orelse return null;
        if (name.len == 0) return null;
        return .{ .name = name, .uid = uid, .group = a.groupName(gid), .gid = gid, .home = if (home.len > 0) home else null };
    }

    pub fn byUid(a: Accounts, uid: u32) ?UserInfo {
        var lines = std.mem.splitScalar(u8, a.passwd, '\n');
        while (lines.next()) |line| {
            const e = a.entry(line) orelse continue;
            if (e.uid == uid) return e;
        }
        return null;
    }

    pub fn byName(a: Accounts, name: []const u8) ?UserInfo {
        var lines = std.mem.splitScalar(u8, a.passwd, '\n');
        while (lines.next()) |line| {
            const e = a.entry(line) orelse continue;
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// The user running the manager: its passwd entry, else root, else a nameless numeric account.
    pub fn manager(a: Accounts, gpa: Allocator, uid: u32) Allocator.Error!UserInfo {
        if (a.byUid(uid)) |u| return u;
        if (uid == 0) return .{ .name = "root", .uid = 0, .group = "root", .gid = 0, .home = "/root" };
        return .{ .name = try std.fmt.allocPrint(gpa, "{d}", .{uid}), .uid = uid };
    }

    /// Callback for `model.UserLookup`; `context` is a `*const Accounts`.
    pub fn lookup(context: ?*anyopaque, name: []const u8) ?UserInfo {
        const a: *const Accounts = @ptrCast(@alignCast(context.?));
        return a.byName(name);
    }
};

pub const XdgDirs = struct {
    runtime: []const u8,
    state: []const u8,
    cache: []const u8,
    config: []const u8,
};

/// Values that do not depend on the unit.
pub const Env = struct {
    scope: Scope,
    /// User running the manager; `%u`, `%U`, `%g`, `%G` and `%h` refer to it unless `User=` is set.
    user: UserInfo,
    runtime_dir: []const u8,
    state_dir: []const u8,
    cache_dir: []const u8,
    logs_dir: []const u8,
    config_dir: []const u8,
    tmp_dir: []const u8 = "/tmp",
    var_tmp_dir: []const u8 = "/var/tmp",
    hostname: ?[]const u8 = null,
    machine_id: ?[]const u8 = null,
    boot_id: ?[]const u8 = null,

    pub fn system(user: UserInfo) Env {
        return .{
            .scope = .system,
            .user = user,
            .runtime_dir = "/run",
            .state_dir = "/var/lib",
            .cache_dir = "/var/cache",
            .logs_dir = "/var/log",
            .config_dir = "/etc",
        };
    }

    pub fn userScope(gpa: Allocator, user: UserInfo, xdg: XdgDirs) Allocator.Error!Env {
        return .{
            .scope = .user,
            .user = user,
            .runtime_dir = xdg.runtime,
            .state_dir = xdg.state,
            .cache_dir = xdg.cache,
            .logs_dir = try std.fs.path.join(gpa, &.{ xdg.state, "log" }),
            .config_dir = xdg.config,
        };
    }
};

pub const Context = struct {
    env: Env,
    name: Name,
    /// Account named by `User=`, when it is set.
    service_user: ?UserInfo = null,

    pub fn effectiveUser(c: Context) UserInfo {
        return c.service_user orelse c.env.user;
    }
};

/// Expands every specifier in `input`. Returns `input` itself when it has no `%`; otherwise the
/// result is allocated with `gpa`. `failure` receives the offending specifier on error.
pub fn expand(gpa: Allocator, ctx: Context, input: []const u8, failure: ?*Failure) Error![]const u8 {
    if (std.mem.findScalar(u8, input, '%') == null) return input;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c != '%') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) {
            if (failure) |f| f.specifier = 0;
            return error.TrailingPercent;
        }
        const spec = input[i + 1];
        if (failure) |f| f.specifier = spec;
        try appendSpecifier(gpa, &out, ctx, spec);
        i += 2;
    }
    return out.toOwnedSlice(gpa);
}

fn appendSpecifier(gpa: Allocator, out: *std.ArrayList(u8), ctx: Context, spec: u8) Error!void {
    const n = ctx.name;
    const env = ctx.env;
    const user = ctx.effectiveUser();
    switch (spec) {
        '%' => try out.append(gpa, '%'),
        'n' => try out.appendSlice(gpa, n.full),
        'N' => try out.appendSlice(gpa, n.base()),
        'p' => try out.appendSlice(gpa, n.prefix),
        'P' => try appendUnescaped(gpa, out, n.prefix),
        'i' => try out.appendSlice(gpa, n.instance orelse ""),
        'I' => try appendUnescaped(gpa, out, n.instance orelse ""),
        'j' => try out.appendSlice(gpa, lastComponent(n.prefix)),
        'J' => try appendUnescaped(gpa, out, lastComponent(n.prefix)),
        'f' => {
            var path: std.ArrayList(u8) = .empty;
            defer path.deinit(gpa);
            try appendUnescaped(gpa, &path, if (n.isInstance()) n.instance.? else n.prefix);
            if (path.items.len == 0 or path.items[0] != '/') try out.append(gpa, '/');
            try out.appendSlice(gpa, path.items);
        },
        'u' => try out.appendSlice(gpa, user.name),
        'U' => try out.print(gpa, "{d}", .{user.uid orelse return error.Unresolved}),
        'g' => try out.appendSlice(gpa, user.group orelse return error.Unresolved),
        'G' => try out.print(gpa, "{d}", .{user.gid orelse return error.Unresolved}),
        'h' => try out.appendSlice(gpa, user.home orelse return error.Unresolved),
        't' => try out.appendSlice(gpa, env.runtime_dir),
        'S' => try out.appendSlice(gpa, env.state_dir),
        'C' => try out.appendSlice(gpa, env.cache_dir),
        'L' => try out.appendSlice(gpa, env.logs_dir),
        'E' => try out.appendSlice(gpa, env.config_dir),
        'T' => try out.appendSlice(gpa, env.tmp_dir),
        'V' => try out.appendSlice(gpa, env.var_tmp_dir),
        'H' => try out.appendSlice(gpa, env.hostname orelse return error.Unresolved),
        'l' => {
            const host = env.hostname orelse return error.Unresolved;
            try out.appendSlice(gpa, host[0 .. std.mem.findScalar(u8, host, '.') orelse host.len]);
        },
        'm' => try out.appendSlice(gpa, env.machine_id orelse return error.Unresolved),
        'b' => try out.appendSlice(gpa, env.boot_id orelse return error.Unresolved),
        else => return error.UnknownSpecifier,
    }
}

fn lastComponent(prefix: []const u8) []const u8 {
    const dash = std.mem.findScalarLast(u8, prefix, '-') orelse return prefix;
    return prefix[dash + 1 ..];
}

/// Reverses unit-name escaping: `-` becomes `/` and `\xNN` becomes the byte NN.
pub fn appendUnescaped(gpa: Allocator, out: *std.ArrayList(u8), escaped: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < escaped.len) {
        const c = escaped[i];
        if (c == '\\' and i + 4 <= escaped.len and escaped[i + 1] == 'x') {
            if (std.fmt.parseInt(u8, escaped[i + 2 .. i + 4], 16)) |byte| {
                try out.append(gpa, byte);
                i += 4;
                continue;
            } else |_| {}
        }
        try out.append(gpa, if (c == '-') '/' else c);
        i += 1;
    }
}

pub fn unescape(gpa: Allocator, escaped: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendUnescaped(gpa, &out, escaped);
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;
const name_mod = @import("name.zig");

const root_user: UserInfo = .{ .name = "root", .uid = 0, .group = "root", .gid = 0, .home = "/root" };

fn testEnv() Env {
    var env = Env.system(root_user);
    env.hostname = "box.example.org";
    env.machine_id = "0123456789abcdef0123456789abcdef";
    env.boot_id = "fedcba9876543210fedcba9876543210";
    return env;
}

fn ctxFor(arena: Allocator, unit: []const u8) !Context {
    return .{ .env = testEnv(), .name = try name_mod.parse(arena, unit) };
}

fn expectExpand(arena: Allocator, ctx: Context, input: []const u8, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, try expand(arena, ctx, input, null));
}

test "name specifiers for a plain unit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try ctxFor(a, "foo-bar.service");
    try expectExpand(a, ctx, "%n", "foo-bar.service");
    try expectExpand(a, ctx, "%N", "foo-bar");
    try expectExpand(a, ctx, "%p", "foo-bar");
    try expectExpand(a, ctx, "%P", "foo/bar");
    try expectExpand(a, ctx, "%i|%I", "|");
    try expectExpand(a, ctx, "%j", "bar");
    try expectExpand(a, ctx, "%J", "bar");
    try expectExpand(a, ctx, "%f", "/foo/bar");
}

test "name specifiers for an instance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try ctxFor(a, "my-app@etc-fstab.service");
    try expectExpand(a, ctx, "%n", "my-app@etc-fstab.service");
    try expectExpand(a, ctx, "%N", "my-app@etc-fstab");
    try expectExpand(a, ctx, "%p", "my-app");
    try expectExpand(a, ctx, "%i", "etc-fstab");
    try expectExpand(a, ctx, "%I", "etc/fstab");
    try expectExpand(a, ctx, "%f", "/etc/fstab");
    try expectExpand(a, ctx, "%j", "app");
}

test "escaped instance bytes are decoded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try ctxFor(a, "x@a\\x2db\\x20c.service");
    try expectExpand(a, ctx, "%i", "a\\x2db\\x20c");
    try expectExpand(a, ctx, "%I", "a-b c");
    try expectEqualUnescape(a, "bad\\xZZ-x", "bad\\xZZ/x");
    try expectEqualUnescape(a, "tail\\x4", "tail\\x4");
}

fn expectEqualUnescape(a: Allocator, input: []const u8, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, try unescape(a, input));
}

test "percent escape and plain text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try ctxFor(a, "foo.service");
    try expectExpand(a, ctx, "100%%", "100%");
    try expectExpand(a, ctx, "%%n", "%n");
    try expectExpand(a, ctx, "no specifiers", "no specifiers");
    try expectExpand(a, ctx, "/run/%n/%n.pid", "/run/foo.service/foo.service.pid");
    const same = "plain";
    try testing.expectEqual(same.ptr, (try expand(a, ctx, same, null)).ptr);
}

test "system scope directories and host values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try ctxFor(a, "foo.service");
    try expectExpand(a, ctx, "%t", "/run");
    try expectExpand(a, ctx, "%S", "/var/lib");
    try expectExpand(a, ctx, "%C", "/var/cache");
    try expectExpand(a, ctx, "%L", "/var/log");
    try expectExpand(a, ctx, "%E", "/etc");
    try expectExpand(a, ctx, "%T", "/tmp");
    try expectExpand(a, ctx, "%V", "/var/tmp");
    try expectExpand(a, ctx, "%H", "box.example.org");
    try expectExpand(a, ctx, "%l", "box");
    try expectExpand(a, ctx, "%m", "0123456789abcdef0123456789abcdef");
    try expectExpand(a, ctx, "%b", "fedcba9876543210fedcba9876543210");
}

test "user scope directories follow XDG values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user: UserInfo = .{ .name = "fabio", .uid = 1000, .group = "fabio", .gid = 1000, .home = "/home/fabio" };
    const env = try Env.userScope(a, user, .{
        .runtime = "/run/user/1000",
        .state = "/home/fabio/.local/state",
        .cache = "/home/fabio/.cache",
        .config = "/home/fabio/.config",
    });
    const ctx: Context = .{ .env = env, .name = try name_mod.parse(a, "foo.service") };
    try expectExpand(a, ctx, "%t", "/run/user/1000");
    try expectExpand(a, ctx, "%S", "/home/fabio/.local/state");
    try expectExpand(a, ctx, "%C", "/home/fabio/.cache");
    try expectExpand(a, ctx, "%L", "/home/fabio/.local/state/log");
    try expectExpand(a, ctx, "%E", "/home/fabio/.config");
    try expectExpand(a, ctx, "%u %U %g %G %h", "fabio 1000 fabio 1000 /home/fabio");
}

test "User= overrides the user specifiers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try ctxFor(a, "foo.service");
    try expectExpand(a, ctx, "%u:%U:%g:%G:%h", "root:0:root:0:/root");
    ctx.service_user = .{ .name = "www", .uid = 33, .group = "www-data", .gid = 33, .home = "/var/www" };
    try expectExpand(a, ctx, "%u:%U:%g:%G:%h", "www:33:www-data:33:/var/www");
    ctx.service_user = .{ .name = "nobody" };
    try expectExpand(a, ctx, "%u", "nobody");
    var failure: Failure = .{};
    try testing.expectError(error.Unresolved, expand(a, ctx, "x %h", &failure));
    try testing.expectEqual(@as(u8, 'h'), failure.specifier);
    try testing.expectError(error.Unresolved, expand(a, ctx, "%U", null));
}

test "missing host values are unresolved" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = try ctxFor(a, "foo.service");
    ctx.env.hostname = null;
    ctx.env.machine_id = null;
    ctx.env.boot_id = null;
    for ([_][]const u8{ "%H", "%l", "%m", "%b" }) |s| {
        try testing.expectError(error.Unresolved, expand(a, ctx, s, null));
    }
}

test "unknown specifier and trailing percent name the culprit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try ctxFor(a, "foo.service");
    var failure: Failure = .{};
    try testing.expectError(error.UnknownSpecifier, expand(a, ctx, "ok %n then %z", &failure));
    try testing.expectEqual(@as(u8, 'z'), failure.specifier);
    try testing.expectError(error.TrailingPercent, expand(a, ctx, "abc%", &failure));
    try testing.expectError(error.TrailingPercent, expand(a, ctx, "%", null));
}

test "accounts come from passwd and group, not from the environment" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a: Accounts = .{
        .passwd = "root:x:0:0:r:/root:/bin/sh\nsvc:x:994:993::/var/lib/svc:/sbin/nologin\n",
        .group = "root:x:0:\nsvcgrp:x:993:\n",
    };
    const svc = a.byName("svc").?;
    try testing.expectEqual(@as(?u32, 994), svc.uid);
    try testing.expectEqualStrings("svcgrp", svc.group.?);
    try testing.expectEqualStrings("/var/lib/svc", svc.home.?);
    try testing.expectEqualStrings("svc", (try a.manager(arena.allocator(), 994)).name);
    try testing.expectEqualStrings("root", (try (Accounts{}).manager(arena.allocator(), 0)).name);
    const unknown = try (Accounts{}).manager(arena.allocator(), 4242);
    try testing.expectEqualStrings("4242", unknown.name);
    try testing.expect(unknown.home == null);
    try testing.expect(a.byName("nobody") == null);
}

test "accounts are read above 1 MiB and an unreadable file is an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fs: Fs = .initDir(testing.io, tmp.dir);
    const none = try Accounts.read(arena.allocator(), fs);
    try testing.expectEqualStrings("", none.passwd);
    try fs.makePath("/etc");
    var big: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    while (big.items.len < (2 << 20)) : (n += 1) {
        try big.print(arena.allocator(), "filler{d}:x:{d}:{d}::/h:/s\n", .{ n, 100000 + n, 100000 + n });
    }
    try big.appendSlice(arena.allocator(), "late:x:4242:4242::/home/late:/s\n");
    try fs.writeFileAtomic("/etc/passwd", big.items, 0o644);
    const acc = try Accounts.read(arena.allocator(), fs);
    try testing.expectEqual(@as(u32, 4242), acc.byName("late").?.uid);

    try fs.deleteFile("/etc/passwd");
    try fs.makePath("/etc/passwd");
    try testing.expectError(error.IsDir, Accounts.read(arena.allocator(), fs));
}
