// SPDX-License-Identifier: GPL-3.0-or-later
//! `RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=` and
//! `ConfigurationDirectory=`: creation with the configured mode, ownership for the service
//! account, the `$RUNTIME_DIRECTORY`-style variables, and removal of runtime directories.
//! Every path goes through `Fs`, so it is created below the filesystem root in use.
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const core = @import("../core/root.zig");
const model = @import("../unit/model.zig");
const identity = @import("identity.zig");

pub const Kind = enum {
    runtime,
    state,
    cache,
    logs,
    configuration,

    fn envName(k: Kind) []const u8 {
        return switch (k) {
            .runtime => "RUNTIME_DIRECTORY",
            .state => "STATE_DIRECTORY",
            .cache => "CACHE_DIRECTORY",
            .logs => "LOGS_DIRECTORY",
            .configuration => "CONFIGURATION_DIRECTORY",
        };
    }

    /// systemd exit status when the directory cannot be set up.
    fn exitCode(k: Kind) u8 {
        return switch (k) {
            .runtime => 233,
            .state => 238,
            .cache => 239,
            .logs => 240,
            .configuration => 241,
        };
    }

    fn names(k: Kind, u: model.Unit) []const []const u8 {
        return switch (k) {
            .runtime => u.runtime_directory,
            .state => u.state_directory,
            .cache => u.cache_directory,
            .logs => u.logs_directory,
            .configuration => u.configuration_directory,
        };
    }

    fn mode(k: Kind, u: model.Unit) u16 {
        const m = switch (k) {
            .runtime => u.runtime_directory_mode,
            .state => u.state_directory_mode,
            .cache => u.cache_directory_mode,
            .logs => u.logs_directory_mode,
            .configuration => u.configuration_directory_mode,
        };
        return m orelse 0o755;
    }

    fn base(k: Kind, ctx: *const core.Context) []const u8 {
        return switch (ctx.scope) {
            .system => switch (k) {
                .runtime => "/run",
                .state => "/var/lib",
                .cache => "/var/cache",
                .logs => "/var/log",
                .configuration => "/etc",
            },
            .user => switch (k) {
                .runtime => ctx.xdg_runtime_dir,
                .state => ctx.xdg_state_home,
                .cache => ctx.xdg_cache_home,
                .logs => ctx.xdg_state_home,
                .configuration => ctx.xdg_config_home,
            },
        };
    }

    /// Directory below the base: user-scope logs live in `<state>/log`.
    fn path(k: Kind, ctx: *const core.Context, name: []const u8) Allocator.Error![]const u8 {
        if (k == .logs and ctx.scope == .user) return std.fs.path.join(ctx.gpa, &.{ k.base(ctx), "log", name });
        return std.fs.path.join(ctx.gpa, &.{ k.base(ctx), name });
    }
};

const all_kinds = [_]Kind{ .runtime, .state, .cache, .logs, .configuration };

/// A relative path without `..` components and without the `:` of symlink syntax.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or std.mem.findScalar(u8, name, ':') != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn relZ(gpa: Allocator, abs: []const u8) Allocator.Error![:0]const u8 {
    return gpa.dupeSentinel(u8, std.mem.trimStart(u8, abs, "/"), 0);
}

fn rootRel(gpa: Allocator, ctx: *const core.Context, abs: []const u8) ![:0]const u8 {
    const real = try ctx.fs.realpath(gpa, abs);
    return relZ(gpa, real);
}

const Owner = struct { uid: u32, gid: u32 };

fn ownerOf(ctx: *const core.Context, rel: [:0]const u8) ?Owner {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(ctx.fs.root.handle, rel.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .GID = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .uid = stx.uid, .gid = stx.gid };
}

fn chownOne(ctx: *const core.Context, rel: [:0]const u8, sw: identity.Switch) linux.E {
    const uid: u32 = sw.uid orelse std.math.maxInt(u32);
    const gid: u32 = sw.gid orelse std.math.maxInt(u32);
    return linux.errno(linux.fchownat(ctx.fs.root.handle, rel.ptr, uid, gid, linux.AT.SYMLINK_NOFOLLOW));
}

fn chownTree(ctx: *const core.Context, dir_real: []const u8, sw: identity.Switch) !void {
    const entries = try ctx.fs.iterateDir(ctx.gpa, dir_real);
    for (entries) |e| {
        const child = try std.fs.path.join(ctx.gpa, &.{ dir_real, e.name });
        const rel = try relZ(ctx.gpa, child);
        const errno = chownOne(ctx, rel, sw);
        if (errno != .SUCCESS) return error.ChownFailed;
        if (e.kind == .directory) try chownTree(ctx, child, sw);
    }
}

/// Creates the directories of every kind and appends the `*_DIRECTORY` variables to `vars`.
/// Returns the exit status to stop with after printing the reason, or null on success.
pub fn prepare(
    ctx: *core.Context,
    unit: model.Unit,
    sw: ?identity.Switch,
    vars: *std.ArrayList(model.EnvVar),
) Allocator.Error!?u8 {
    for (all_kinds) |kind| {
        const names = kind.names(unit);
        if (names.len == 0) continue;
        var joined: std.ArrayList(u8) = .empty;
        for (names) |name| {
            if (!validName(name)) {
                ctx.diag.err("{s}: invalid directory '{s}'", .{ kind.envName(), name });
                return kind.exitCode();
            }
            const abs = try kind.path(ctx, name);
            if (setup(ctx, kind, unit, sw, abs)) |e| {
                ctx.diag.err("{s}: cannot set up {s}: {t}", .{ kind.envName(), abs, e });
                return kind.exitCode();
            }
            if (joined.items.len > 0) try joined.append(ctx.gpa, ':');
            try joined.appendSlice(ctx.gpa, abs);
        }
        try vars.append(ctx.gpa, .{ .name = kind.envName(), .value = try joined.toOwnedSlice(ctx.gpa) });
    }
    return null;
}

fn setup(ctx: *core.Context, kind: Kind, unit: model.Unit, sw: ?identity.Switch, abs: []const u8) ?anyerror {
    ctx.fs.makePath(abs) catch |e| return e;
    const real = ctx.fs.realpath(ctx.gpa, abs) catch |e| return e;
    const rel = relZ(ctx.gpa, real) catch |e| return e;
    const chmod_rc = linux.fchmodat(ctx.fs.root.handle, rel.ptr, kind.mode(unit));
    if (linux.errno(chmod_rc) != .SUCCESS) return error.ChmodFailed;
    const target = sw orelse return null;
    if (kind == .configuration or (target.uid == null and target.gid == null)) return null;
    const current = ownerOf(ctx, rel) orelse return error.StatFailed;
    const wanted_uid = target.uid orelse current.uid;
    const wanted_gid = target.gid orelse current.gid;
    if (current.uid == wanted_uid and current.gid == wanted_gid) return null;
    if (chownOne(ctx, rel, target) != .SUCCESS) return error.ChownFailed;
    chownTree(ctx, real, target) catch |e| return e;
    return null;
}

/// Removes the runtime directories unless `RuntimeDirectoryPreserve=` keeps them. `restart`
/// counts as `yes` because the executor cannot tell a restart from a stop.
pub fn removeRuntime(ctx: *core.Context, unit: model.Unit) Allocator.Error!void {
    if (unit.runtime_directory_preserve) |p| if (p != .no) return;
    for (unit.runtime_directory) |name| {
        if (!validName(name)) continue;
        const abs = try Kind.runtime.path(ctx, name);
        ctx.fs.deleteTree(abs) catch |e| switch (e) {
            error.FileNotFound => {},
            else => ctx.diag.warn("cannot remove {s}: {t}", .{ abs, e }),
        };
    }
}

fn testCtx(t: *TestEnv, scope: core.Scope) !core.Context {
    return core.Context.init(t.arena.allocator(), std.testing.io, &t.fs, &t.diag, &t.env, scope, 0);
}

const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    fs: core.Fs,
    env: std.process.Environ.Map,
    err: std.Io.Writer.Allocating,
    diag: core.Diag,

    fn init(t: *TestEnv) void {
        t.arena = .init(std.testing.allocator);
        t.tmp = std.testing.tmpDir(.{ .iterate = true });
        t.fs = .initDir(std.testing.io, t.tmp.dir);
        t.env = .init(std.testing.allocator);
        t.err = .init(std.testing.allocator);
        t.diag = .init(&t.err.writer, .notice);
    }

    fn deinit(t: *TestEnv) void {
        t.err.deinit();
        t.env.deinit();
        t.tmp.cleanup();
        t.arena.deinit();
    }
};

fn modeOf(t: *TestEnv, path: []const u8) !u16 {
    return (try t.fs.stat(path)).mode;
}

test "directories are created with modes and exported" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.runtime_directory = &.{ "app", "app/sub" };
    unit.runtime_directory_mode = 0o700;
    unit.state_directory = &.{"app"};
    var vars: std.ArrayList(model.EnvVar) = .empty;
    try std.testing.expect((try prepare(&ctx, unit, null, &vars)) == null);
    try std.testing.expectEqual(@as(u16, 0o700), try modeOf(&t, "/run/app"));
    try std.testing.expectEqual(@as(u16, 0o700), try modeOf(&t, "/run/app/sub"));
    try std.testing.expectEqual(@as(u16, 0o755), try modeOf(&t, "/var/lib/app"));
    try std.testing.expectEqual(@as(usize, 2), vars.items.len);
    try std.testing.expectEqualStrings("RUNTIME_DIRECTORY", vars.items[0].name);
    try std.testing.expectEqualStrings("/run/app:/run/app/sub", vars.items[0].value);
    try std.testing.expectEqualStrings("/var/lib/app", vars.items[1].value);
}

test "user scope uses the XDG directories" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    try t.env.put("XDG_RUNTIME_DIR", "/xr");
    try t.env.put("XDG_STATE_HOME", "/xs");
    var ctx = try testCtx(&t, .user);
    var unit: model.Unit = .{ .name = undefined, .scope = .user };
    unit.runtime_directory = &.{"u"};
    unit.logs_directory = &.{"u"};
    var vars: std.ArrayList(model.EnvVar) = .empty;
    try std.testing.expect((try prepare(&ctx, unit, null, &vars)) == null);
    try std.testing.expect(t.fs.exists("/xr/u"));
    try std.testing.expect(t.fs.exists("/xs/log/u"));
}

test "unsafe names are refused" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    for ([_][]const u8{ "../etc", "/abs", "a/../../b", "a:b", "" }) |bad| {
        var unit: model.Unit = .{ .name = undefined, .scope = .system };
        unit.state_directory = &.{bad};
        var vars: std.ArrayList(model.EnvVar) = .empty;
        try std.testing.expectEqual(@as(?u8, 238), try prepare(&ctx, unit, null, &vars));
    }
}

test "runtime directories are removed on stop unless preserved" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.runtime_directory = &.{"gone"};
    unit.state_directory = &.{"kept"};
    var vars: std.ArrayList(model.EnvVar) = .empty;
    _ = try prepare(&ctx, unit, null, &vars);
    try t.fs.writeFileAtomic("/run/gone/file", "x", 0o644);
    unit.runtime_directory_preserve = .yes;
    try removeRuntime(&ctx, unit);
    try std.testing.expect(t.fs.exists("/run/gone/file"));
    unit.runtime_directory_preserve = .restart;
    try removeRuntime(&ctx, unit);
    try std.testing.expect(t.fs.exists("/run/gone/file"));
    unit.runtime_directory_preserve = null;
    try removeRuntime(&ctx, unit);
    try std.testing.expect(!t.fs.exists("/run/gone"));
    try std.testing.expect(t.fs.exists("/var/lib/kept"));
    try removeRuntime(&ctx, unit);
}

test "ownership follows the service account and is applied recursively" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.state_directory = &.{"owned"};
    unit.configuration_directory = &.{"cfg"};
    try t.fs.makePath("/var/lib/owned/inner");
    try t.fs.writeFileAtomic("/var/lib/owned/inner/f", "x", 0o644);
    try t.fs.symLink("/nonexistent", "/var/lib/owned/link");
    var vars: std.ArrayList(model.EnvVar) = .empty;
    const sw: identity.Switch = .{ .uid = 4242, .gid = 4343 };
    try std.testing.expect((try prepare(&ctx, unit, sw, &vars)) == null);
    const real = try t.fs.realpath(t.arena.allocator(), "/var/lib/owned/inner/f");
    const owner = ownerOf(&ctx, try relZ(t.arena.allocator(), real)).?;
    try std.testing.expectEqual(@as(u32, 4242), owner.uid);
    try std.testing.expectEqual(@as(u32, 4343), owner.gid);
    const cfg = ownerOf(&ctx, try relZ(t.arena.allocator(), "/etc/cfg")).?;
    try std.testing.expectEqual(@as(u32, 0), cfg.uid);
}
