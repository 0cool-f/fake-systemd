//! The environment of the service process, composed like systemd's manager does. Layers in
//! increasing priority: the base (a clean `PATH` and the locale for system units, the whole
//! environment of the manager for user units), `INVOCATION_ID`, the account variables,
//! `$*_DIRECTORY` and `$MAINPID`, `PassEnvironment=`, `Environment=`, `EnvironmentFile=` in
//! order, then `UnsetEnvironment=` removes names.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const model = @import("../unit/model.zig");
const name_mod = @import("../unit/name.zig");
const accounts = @import("accounts.zig");
const envfile = @import("envfile.zig");
const expand = @import("expand.zig");

pub const Vars = expand.Vars;
pub const Error = error{EnvironmentFile} || Allocator.Error;

const path_merged_usr = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin";
const path_split_usr = path_merged_usr ++ ":/sbin:/bin";
const max_env_file = 1 << 20;

fn defaultPath(ctx: *const core.Context) []const u8 {
    const st = ctx.fs.lstat("/bin") catch return path_split_usr;
    return if (st.kind == .sym_link) path_merged_usr else path_split_usr;
}

fn isLocaleName(name: []const u8) bool {
    return std.mem.eql(u8, name, "LANG") or std.mem.eql(u8, name, "LANGUAGE") or std.mem.startsWith(u8, name, "LC_");
}

fn loadLocale(ctx: *core.Context, vars: *Vars) Allocator.Error!void {
    for ([_][]const u8{ "/etc/locale.conf", "/etc/default/locale" }) |path| {
        const content = ctx.fs.readFileAlloc(ctx.gpa, path, 64 * 1024) catch continue;
        const entries = envfile.parse(ctx.gpa, content) catch continue;
        for (entries) |e| {
            if (isLocaleName(e.name)) try vars.put(ctx.gpa, e.name, e.value);
        }
        return;
    }
}

fn randomId(ctx: *const core.Context) Allocator.Error![]const u8 {
    var bytes: [16]u8 = undefined;
    ctx.io.random(&bytes);
    return std.fmt.allocPrint(ctx.gpa, "{x}", .{&bytes});
}

/// Builds the environment. `extra` holds the variables the executor itself defines
/// (`$RUNTIME_DIRECTORY`, `$MAINPID`, ...).
pub fn build(
    ctx: *core.Context,
    unit: model.Unit,
    account: ?accounts.User,
    extra: []const model.EnvVar,
) Error!Vars {
    const gpa = ctx.gpa;
    var vars: Vars = .empty;
    switch (ctx.scope) {
        .system => {
            try vars.put(gpa, "PATH", defaultPath(ctx));
            try loadLocale(ctx, &vars);
        },
        .user => {
            var it = ctx.environ.iterator();
            while (it.next()) |e| try vars.put(gpa, e.key_ptr.*, e.value_ptr.*);
        },
    }
    try vars.put(gpa, "INVOCATION_ID", try randomId(ctx));
    if (ctx.scope == .system) {
        if (unit.user) |name| {
            const user_name = if (account) |a| a.name else name;
            try vars.put(gpa, "LOGNAME", user_name);
            try vars.put(gpa, "USER", user_name);
        }
        if (account) |a| {
            if (a.home) |h| try vars.put(gpa, "HOME", h);
            if (a.shell) |s| try vars.put(gpa, "SHELL", s);
        }
    }
    for (extra) |e| try vars.put(gpa, e.name, e.value);
    for (unit.pass_environment) |name| {
        if (ctx.environ.get(name)) |value| try vars.put(gpa, name, value);
    }
    for (unit.environment) |e| try vars.put(gpa, e.name, e.value);
    for (unit.environment_file) |f| try loadEnvironmentFile(ctx, &vars, f);
    for (unit.unset_environment) |entry| unset(&vars, entry);
    return vars;
}

fn unset(vars: *Vars, entry: []const u8) void {
    if (std.mem.findScalar(u8, entry, '=')) |eq| {
        const current = vars.get(entry[0..eq]) orelse return;
        if (std.mem.eql(u8, current, entry[eq + 1 ..])) _ = vars.orderedRemove(entry[0..eq]);
    } else _ = vars.orderedRemove(entry);
}

fn loadEnvironmentFile(ctx: *core.Context, vars: *Vars, file: model.EnvFile) Error!void {
    if (!name_mod.hasGlob(file.path)) return loadOne(ctx, vars, file.path, file.optional);
    const dir = std.fs.path.dirname(file.path) orelse "/";
    const pattern = std.fs.path.basename(file.path);
    const entries = ctx.fs.iterateDir(ctx.gpa, dir) catch return;
    for (entries) |e| {
        if (e.kind == .directory or !name_mod.globMatch(pattern, e.name)) continue;
        try loadOne(ctx, vars, try std.fs.path.join(ctx.gpa, &.{ dir, e.name }), true);
    }
}

fn loadOne(ctx: *core.Context, vars: *Vars, path: []const u8, optional: bool) Error!void {
    const content = ctx.fs.readFileAlloc(ctx.gpa, path, max_env_file) catch |e| {
        if (optional) return;
        ctx.diag.err("cannot read EnvironmentFile {s}: {t}", .{ path, e });
        return error.EnvironmentFile;
    };
    const entries = envfile.parse(ctx.gpa, content) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedQuote => {
            if (optional) return;
            ctx.diag.err("EnvironmentFile {s}: unterminated quote", .{path});
            return error.EnvironmentFile;
        },
    };
    for (entries) |e| try vars.put(ctx.gpa, e.name, e.value);
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

    fn ctx(t: *TestEnv, scope: core.Scope) !core.Context {
        return core.Context.init(t.arena.allocator(), std.testing.io, &t.fs, &t.diag, &t.env, scope, 0);
    }
};

fn get(vars: Vars, name: []const u8) ?[]const u8 {
    return vars.get(name);
}

test "layers: environment files override Environment, unset removes" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try t.ctx(.system);
    try t.fs.makePath("/etc/app");
    try t.fs.writeFileAtomic("/etc/app/one.env", "A=file1\nB=file1\nFROM_FILE=yes\n", 0o644);
    try t.fs.writeFileAtomic("/etc/app/two.env", "B=file2\n", 0o644);
    try t.env.put("PASSED", "from-manager");
    try t.env.put("NOT_PASSED", "x");
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.environment = &.{ .{ .name = "A", .value = "env" }, .{ .name = "C", .value = "env" }, .{ .name = "PASSED", .value = "unit" } };
    unit.environment_file = &.{
        .{ .path = "/etc/app/one.env", .optional = false },
        .{ .path = "/etc/app/missing.env", .optional = true },
        .{ .path = "/etc/app/two.env", .optional = false },
    };
    unit.pass_environment = &.{ "PASSED", "UNSET_IN_MANAGER" };
    unit.unset_environment = &.{ "FROM_FILE", "C=other", "NOT_THERE" };
    const vars = try build(&ctx, unit, null, &.{.{ .name = "MAINPID", .value = "42" }});
    try std.testing.expectEqualStrings("file1", get(vars, "A").?);
    try std.testing.expectEqualStrings("file2", get(vars, "B").?);
    try std.testing.expectEqualStrings("env", get(vars, "C").?);
    try std.testing.expectEqualStrings("unit", get(vars, "PASSED").?);
    try std.testing.expect(get(vars, "FROM_FILE") == null);
    try std.testing.expect(get(vars, "NOT_PASSED") == null);
    try std.testing.expect(get(vars, "UNSET_IN_MANAGER") == null);
    try std.testing.expectEqualStrings("42", get(vars, "MAINPID").?);
    try std.testing.expect(get(vars, "PATH") != null);
    try std.testing.expectEqual(@as(usize, 32), get(vars, "INVOCATION_ID").?.len);
}

test "unset with a value only removes an exact match" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try t.ctx(.system);
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.environment = &.{ .{ .name = "C", .value = "env" }, .{ .name = "D", .value = "env" } };
    unit.unset_environment = &.{ "C=other", "D=env" };
    const vars = try build(&ctx, unit, null, &.{});
    try std.testing.expectEqualStrings("env", get(vars, "C").?);
    try std.testing.expect(get(vars, "D") == null);
}

test "missing required file and glob files" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try t.ctx(.system);
    try t.fs.makePath("/etc/conf.d");
    try t.fs.writeFileAtomic("/etc/conf.d/10-a.env", "X=a\nY=a\n", 0o644);
    try t.fs.writeFileAtomic("/etc/conf.d/20-b.env", "Y=b\n", 0o644);
    try t.fs.writeFileAtomic("/etc/conf.d/skip.txt", "X=no\n", 0o644);
    var unit: model.Unit = .{ .name = undefined, .scope = .system };
    unit.environment_file = &.{.{ .path = "/etc/conf.d/*.env", .optional = false }};
    const vars = try build(&ctx, unit, null, &.{});
    try std.testing.expectEqualStrings("a", get(vars, "X").?);
    try std.testing.expectEqualStrings("b", get(vars, "Y").?);

    unit.environment_file = &.{.{ .path = "/etc/none.env", .optional = false }};
    try std.testing.expectError(error.EnvironmentFile, build(&ctx, unit, null, &.{}));
    try std.testing.expect(std.mem.find(u8, t.err.written(), "none.env") != null);
}

test "system base is clean, with locale and the account variables" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var ctx = try t.ctx(.system);
    try t.env.put("SECRET", "leak");
    try t.fs.makePath("/etc");
    try t.fs.writeFileAtomic("/etc/locale.conf", "LANG=it_IT.UTF-8\nOTHER=1\n", 0o644);
    var unit: model.Unit = .{ .name = undefined, .scope = .system, .user = "app" };
    const account: accounts.User = .{ .name = "app", .uid = 1, .gid = 1, .home = "/var/lib/app", .shell = "/bin/sh" };
    const vars = try build(&ctx, unit, account, &.{});
    try std.testing.expect(get(vars, "SECRET") == null);
    try std.testing.expect(get(vars, "OTHER") == null);
    try std.testing.expectEqualStrings("it_IT.UTF-8", get(vars, "LANG").?);
    try std.testing.expectEqualStrings("app", get(vars, "USER").?);
    try std.testing.expectEqualStrings("app", get(vars, "LOGNAME").?);
    try std.testing.expectEqualStrings("/var/lib/app", get(vars, "HOME").?);
    try std.testing.expectEqualStrings("/bin/sh", get(vars, "SHELL").?);
    unit.user = null;
    const plain = try build(&ctx, unit, null, &.{});
    try std.testing.expect(get(plain, "USER") == null and get(plain, "HOME") == null);
}

test "user scope inherits the manager environment" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    try t.env.put("DISPLAY", ":0");
    var ctx = try t.ctx(.user);
    const unit: model.Unit = .{ .name = undefined, .scope = .user };
    const vars = try build(&ctx, unit, null, &.{});
    try std.testing.expectEqualStrings(":0", get(vars, "DISPLAY").?);
}
