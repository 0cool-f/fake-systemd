// SPDX-License-Identifier: GPL-3.0-or-later
//! `RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=` and
//! `ConfigurationDirectory=`: creation with the configured mode, ownership for the service
//! account, the `$RUNTIME_DIRECTORY`-style variables, and removal of runtime directories.
//! The base directory is resolved through `Fs`, so it lies below the filesystem root in use; the
//! names below it are walked with descriptors and never through a symlink (`fdtree`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const core = @import("../core/root.zig");
const model = @import("../unit/model.zig");
const identity = @import("identity.zig");
const fdtree = @import("fdtree.zig");

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

    /// Directory that holds the named directories: user-scope logs live in `<state>/log`.
    fn root(k: Kind, ctx: *const core.Context) Allocator.Error![]const u8 {
        if (k == .logs and ctx.scope == .user) return std.fs.path.join(ctx.gpa, &.{ k.base(ctx), "log" });
        return k.base(ctx);
    }

    fn path(k: Kind, ctx: *const core.Context, name: []const u8) Allocator.Error![]const u8 {
        return std.fs.path.join(ctx.gpa, &.{ try k.root(ctx), name });
    }
};

const all_kinds = [_]Kind{ .runtime, .state, .cache, .logs, .configuration };

/// The first component under every base that belongs to fake-systemd's own state, its index and
/// locks, runtime files and logs; no unit may take it over.
pub const reserved_name = "fake-systemd";

/// True when `name` is the reserved directory or below it.
pub fn isReserved(name: []const u8) bool {
    const first = name[0..(std.mem.findScalar(u8, name, '/') orelse name.len)];
    return std.mem.eql(u8, first, reserved_name);
}

/// A relative path of real names: no `.`, `..` or empty component (so `.`, `./` and `a//b` are
/// refused) and no `:`, the separator of symlink syntax.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or std.mem.findScalar(u8, name, ':') != null) return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn relZ(gpa: Allocator, abs: []const u8) Allocator.Error![:0]const u8 {
    return gpa.dupeSentinel(u8, std.mem.trimStart(u8, abs, "/"), 0);
}

const Owner = struct { uid: u32, gid: u32 };

fn ownerOf(ctx: *const core.Context, rel: [:0]const u8) ?Owner {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(ctx.fs.root.handle, rel.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .GID = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .uid = stx.uid, .gid = stx.gid };
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
            if (isReserved(name)) {
                ctx.diag.err("{s}: '{s}' is reserved for fake-systemd", .{ kind.envName(), name });
                return kind.exitCode();
            }
            const abs = try kind.path(ctx, name);
            if (setup(ctx, kind, unit, sw, name)) |e| {
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

/// Opens the base directory of `kind` (created when missing). Its path is resolved inside the
/// root, symlinks included: the base is administrator-owned.
fn openBase(ctx: *core.Context, kind: Kind, create: bool) !i32 {
    const base = try kind.root(ctx);
    if (create) try ctx.fs.makePath(base);
    const real = try ctx.fs.realpath(ctx.gpa, base);
    return fdtree.openResolved(ctx.fs.root.handle, real);
}

/// Creates `name` below the base of `kind`, walking it with `O_NOFOLLOW` so that a symlink
/// planted below the base is refused, then applies the mode and the ownership of the service
/// account to the directory and everything in it.
fn setup(ctx: *core.Context, kind: Kind, unit: model.Unit, sw: ?identity.Switch, name: []const u8) ?anyerror {
    const base_fd = openBase(ctx, kind, true) catch |e| return e;
    var cur = base_fd;
    defer fdtree.close(cur);
    const base_stat = fdtree.statFd(base_fd) catch return error.StatFailed;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |comp| {
        const z = ctx.gpa.dupeSentinel(u8, comp, 0) catch |e| return e;
        const next = fdtree.openOrCreateDirAt(cur, z, 0o755) catch |e| return e;
        const next_stat = fdtree.statFd(next) catch {
            fdtree.close(next);
            return error.StatFailed;
        };
        if (!next_stat.sameMount(base_stat)) {
            fdtree.close(next);
            return error.MountPoint;
        }
        fdtree.close(cur);
        cur = next;
        depth += 1;
    }
    // `validName` guarantees a component; the final directory is always strictly below the base.
    std.debug.assert(depth > 0);
    if (depth == 0) return error.NotBelowBase;

    fdtree.chmod(cur, kind.mode(unit)) catch return error.ChmodFailed;
    const target = sw orelse return null;
    if (kind == .configuration or (target.uid == null and target.gid == null)) return null;
    const current = fdtree.statFd(cur) catch return error.StatFailed;
    const wanted_uid = target.uid orelse current.uid;
    const wanted_gid = target.gid orelse current.gid;
    if (current.uid == wanted_uid and current.gid == wanted_gid) return null;
    fdtree.chown(cur, wanted_uid, wanted_gid) catch return error.ChownFailed;
    fdtree.chownTree(ctx.gpa, cur, target.uid, target.gid) catch |e| return e;
    return null;
}

/// Makes `abs` a directory with `mode` that belongs to root, when the executor is root:
/// state that root writes and the service account only reads must not belong to it.
pub fn ensureRootDir(ctx: *core.Context, abs: []const u8, mode: u16) !void {
    try ctx.fs.makePathMode(abs, mode);
    if (linux.geteuid() != 0) return;
    const real = try ctx.fs.realpath(ctx.gpa, abs);
    const fd = try fdtree.openResolved(ctx.fs.root.handle, real);
    defer fdtree.close(fd);
    const st = try fdtree.statFd(fd);
    if (st.uid != 0 or st.gid != 0) try fdtree.chown(fd, 0, 0);
    if (st.mode & 0o7777 != mode) try fdtree.chmod(fd, mode);
}

/// Removes the runtime directories unless `RuntimeDirectoryPreserve=` keeps them. `restart`
/// counts as `yes` because the executor cannot tell a restart from a stop. Symlinks below the
/// base are never followed.
pub fn removeRuntime(ctx: *core.Context, unit: model.Unit) Allocator.Error!void {
    if (unit.runtime_directory_preserve) |p| if (p != .no) return;
    for (unit.runtime_directory) |name| {
        if (!validName(name) or isReserved(name)) continue;
        const abs = try Kind.runtime.path(ctx, name);
        removeBelowBase(ctx, name) catch |e| switch (e) {
            error.FileNotFound => {},
            else => ctx.diag.warn("cannot remove {s}: {t}", .{ abs, e }),
        };
    }
}

fn removeBelowBase(ctx: *core.Context, name: []const u8) !void {
    var cur = try openBase(ctx, .runtime, false);
    defer fdtree.close(cur);
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |comp| {
        const z = try ctx.gpa.dupeSentinel(u8, comp, 0);
        if (it.peek() == null) return fdtree.removeAt(ctx.gpa, cur, z);
        const next = try fdtree.openDirAt(cur, z);
        fdtree.close(cur);
        cur = next;
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

fn setMode(t: *TestEnv, path: []const u8, mode: u16) !void {
    const sub = std.mem.trimStart(u8, path, "/");
    const z = try t.arena.allocator().dupeSentinel(u8, sub, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchmodat(t.tmp.dir.handle, z.ptr, mode)));
}

test "dot and empty components are refused for every kind and change nothing" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    const bases = [_][]const u8{ "/run", "/var/lib", "/var/cache", "/var/log", "/etc" };
    for (bases) |base| {
        try t.fs.makePath(base);
        try setMode(&t, base, 0o711);
    }
    for ([_][]const u8{ ".", "./", "a/./b", "a//b", "a/", "./a", "a/." }) |bad| {
        try std.testing.expect(!validName(bad));
        var unit: model.Unit = .{ .name = undefined, .scope = .system };
        const one: []const []const u8 = &.{bad};
        unit.runtime_directory = one;
        unit.state_directory = one;
        unit.cache_directory = one;
        unit.logs_directory = one;
        unit.configuration_directory = one;
        for ([_]u8{ 233, 238, 239, 240, 241 }, 0..) |code, i| {
            var only: model.Unit = .{ .name = undefined, .scope = .system };
            switch (i) {
                0 => only.runtime_directory = one,
                1 => only.state_directory = one,
                2 => only.cache_directory = one,
                3 => only.logs_directory = one,
                else => only.configuration_directory = one,
            }
            var vars: std.ArrayList(model.EnvVar) = .empty;
            try std.testing.expectEqual(@as(?u8, code), try prepare(&ctx, only, null, &vars));
        }
        try removeRuntime(&ctx, unit);
    }
    for (bases) |base| try std.testing.expectEqual(@as(u16, 0o711), try modeOf(&t, base));
}

test "removing RuntimeDirectory=. leaves the runtime base alone" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/run/precious");
    try t.fs.writeFileAtomic("/run/precious/data", "x", 0o644);
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.runtime_directory = &.{"."};
    try removeRuntime(&ctx, unit);
    try std.testing.expect(t.fs.exists("/run/precious/data"));
}

test "a symlink below the base is refused and its target keeps its mode" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/etc/target");
    try setMode(&t, "/etc/target", 0o700);
    try t.fs.makePath("/var/lib/app");
    try t.fs.symLink("/etc/target", "/var/lib/app/sub");
    try t.fs.symLink("/etc/target", "/var/lib/direct");
    for ([_][]const u8{ "app/sub", "direct", "app/sub/deeper" }) |name| {
        var unit: model.Unit = .{ .name = undefined, .scope = .system };
        unit.state_directory = &.{name};
        var vars: std.ArrayList(model.EnvVar) = .empty;
        try std.testing.expectEqual(@as(?u8, 238), try prepare(&ctx, unit, null, &vars));
    }
    try std.testing.expectEqual(@as(u16, 0o700), try modeOf(&t, "/etc/target"));
    try std.testing.expect(!t.fs.exists("/etc/target/deeper"));
}

test "removal never follows a symlink below the base" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/srv/keep/sub");
    try t.fs.writeFileAtomic("/srv/keep/sub/data", "x", 0o644);
    try t.fs.makePath("/run");
    try t.fs.symLink("/srv/keep", "/run/app");
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.runtime_directory = &.{"app/sub"};
    try removeRuntime(&ctx, unit);
    try std.testing.expect(t.fs.exists("/srv/keep/sub/data"));

    // A link inside the directory, and one that is the directory itself, are removed as links.
    try t.fs.makePath("/run/own");
    try t.fs.symLink("/srv/keep", "/run/own/inner");
    try t.fs.symLink("/srv/keep", "/run/direct");
    unit.runtime_directory = &.{ "own", "direct" };
    try removeRuntime(&ctx, unit);
    try std.testing.expect(!t.fs.exists("/run/own"));
    try std.testing.expectError(error.FileNotFound, t.fs.lstat("/run/direct"));
    try std.testing.expect(t.fs.exists("/srv/keep/sub/data"));
}

test "ownership is not applied through symlinks or multiply linked files" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/etc/cfg");
    try t.fs.writeFileAtomic("/etc/secret", "x", 0o600);
    try t.fs.makePath("/var/lib/owned");
    try t.fs.symLink("/etc/cfg", "/var/lib/owned/link");
    const linked = linux.linkat(t.tmp.dir.handle, "etc/secret", t.tmp.dir.handle, "var/lib/owned/hard", 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linked));
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.state_directory = &.{"owned"};
    var vars: std.ArrayList(model.EnvVar) = .empty;
    const sw: identity.Switch = .{ .uid = 4242, .gid = 4343 };
    try std.testing.expect((try prepare(&ctx, unit, sw, &vars)) == null);
    const a = t.arena.allocator();
    try std.testing.expectEqual(@as(u32, 0), ownerOf(&ctx, try relZ(a, "/etc/cfg")).?.uid);
    try std.testing.expectEqual(@as(u32, 0), ownerOf(&ctx, try relZ(a, "/etc/secret")).?.uid);
    try std.testing.expectEqual(@as(u32, 4242), ownerOf(&ctx, try relZ(a, "/var/lib/owned/link")).?.uid);
    try std.testing.expectEqual(@as(u32, 4242), ownerOf(&ctx, try relZ(a, "/var/lib/owned")).?.uid);
}

test "the directory of fake-systemd is reserved under every base for every kind" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    for ([_][]const u8{ "fake-systemd", "fake-systemd/sysvinit", "fake-systemd/a/b" }) |reserved| {
        try std.testing.expect(isReserved(reserved));
        for ([_]u8{ 233, 238, 239, 240, 241 }, 0..) |code, i| {
            var unit: model.Unit = .{ .name = undefined, .scope = .system };
            const one: []const []const u8 = &.{reserved};
            switch (i) {
                0 => unit.runtime_directory = one,
                1 => unit.state_directory = one,
                2 => unit.cache_directory = one,
                3 => unit.logs_directory = one,
                else => unit.configuration_directory = one,
            }
            var vars: std.ArrayList(model.EnvVar) = .empty;
            try std.testing.expectEqual(@as(?u8, code), try prepare(&ctx, unit, null, &vars));
        }
    }
    try std.testing.expect(!t.fs.exists("/run/fake-systemd"));
    try std.testing.expect(!t.fs.exists("/var/lib/fake-systemd"));
    try std.testing.expect(!isReserved("fake-systemd2"));
    try std.testing.expect(!isReserved("a/fake-systemd"));
    var other: model.Unit = .{ .name = undefined, .scope = .system };
    other.state_directory = &.{"fake-systemd2"};
    var vars: std.ArrayList(model.EnvVar) = .empty;
    try std.testing.expect((try prepare(&ctx, other, null, &vars)) == null);
}

test "removal skips the reserved directory" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/run/fake-systemd");
    try t.fs.writeFileAtomic("/run/fake-systemd/x.pid", "1\n", 0o644);
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.runtime_directory = &.{ "fake-systemd", "fake-systemd/x.pid" };
    try removeRuntime(&ctx, unit);
    try std.testing.expect(t.fs.exists("/run/fake-systemd/x.pid"));
}

test "a relative symlink below the base is refused and its target keeps its mode" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/etc/target");
    try setMode(&t, "/etc/target", 0o700);
    try t.fs.makePath("/var/lib");
    try t.fs.symLink("../../etc/target", "/var/lib/rel");
    try t.fs.makePath("/run");
    try t.fs.symLink("../etc/target", "/run/rel");
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.state_directory = &.{"rel"};
    var vars: std.ArrayList(model.EnvVar) = .empty;
    try std.testing.expectEqual(@as(?u8, 238), try prepare(&ctx, unit, null, &vars));
    try std.testing.expectEqual(@as(u16, 0o700), try modeOf(&t, "/etc/target"));
    try t.fs.writeFileAtomic("/etc/target/data", "x", 0o644);
    unit.runtime_directory = &.{"rel/sub"};
    try removeRuntime(&ctx, unit);
    unit.runtime_directory = &.{"rel"};
    try removeRuntime(&ctx, unit);
    try std.testing.expect(t.fs.exists("/etc/target/data"));
    try std.testing.expectError(error.FileNotFound, t.fs.lstat("/run/rel"));
}

test "a directory on another mount below the base is refused and left alone" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/var/lib/app");
    try setMode(&t, "/var/lib/app", 0o700);
    defer fdtree.hooks = .{};
    for ([_]bool{ true, false }) |device| {
        fdtree.FakeMount.set((try t.fs.stat("/var/lib/app")).inode, device);
        var unit: model.Unit = .{ .name = undefined, .scope = .system };
        unit.state_directory = &.{"app/sub"};
        var vars: std.ArrayList(model.EnvVar) = .empty;
        try std.testing.expectEqual(@as(?u8, 238), try prepare(&ctx, unit, null, &vars));
        try std.testing.expectEqual(@as(u16, 0o700), try modeOf(&t, "/var/lib/app"));
    }
}

test "removal does not enter a directory on another mount" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try testCtx(&t, .system);
    try t.fs.makePath("/run/app/mnt");
    try t.fs.writeFileAtomic("/run/app/mnt/data", "x", 0o644);
    fdtree.FakeMount.set((try t.fs.stat("/run/app/mnt")).inode, true);
    defer fdtree.hooks = .{};
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.runtime_directory = &.{"app"};
    try removeRuntime(&ctx, unit);
    try std.testing.expect(t.fs.exists("/run/app/mnt/data"));
}
