const std = @import("std");
const Io = std.Io;
const core = @import("core/root.zig");
const cli = @import("cli/root.zig");
const config = @import("config/root.zig");
const detect = @import("detect/root.zig");
const backend = @import("backend/root.zig");
const ops = @import("ops/root.zig");
const exec = @import("exec/root.zig");

const usage =
    \\usage: invoke as 'systemctl' or 'journalctl' (symlinks to fake-systemd)
    \\
;

const Tool = enum { systemctl, journalctl };

/// Everything `ops` needs, built from the command line and the environment.
const Runtime = struct {
    fs: core.Fs,
    diag: core.Diag,
    ctx: core.Context,
    backends: backend.registry.Storage = .{},
    profile: *const detect.profile.Profile = &detect.profile.generic,
    runner: backend.runner.Real,
    kind: detect.InitKind,
};

fn fail(stderr: *Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print(core.Diag.prefix ++ fmt ++ "\n", args) catch return 1;
    stderr.flush() catch return 1;
    return 1;
}

fn profileFor(rt: *Runtime, os: detect.osrelease.OsRelease, environ: *const std.process.Environ.Map) *const detect.profile.Profile {
    const forced = environ.get("FAKE_SYSTEMD_PROFILE") orelse rt.ctx.config.profile;
    if (forced.len > 0 and !std.mem.eql(u8, forced, "auto")) {
        if (detect.profile.byName(forced)) |p| return p;
        rt.diag.warn("unknown profile '{s}', using detection", .{forced});
    }
    return detect.profile.select(os);
}

fn build(
    rt: *Runtime,
    init: std.process.Init,
    root: ?[]const u8,
    scope: core.Scope,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    const arena = init.arena.allocator();
    rt.fs = try .initRoot(init.io, root orelse "/");
    errdefer rt.fs.deinit();
    rt.diag = .init(stderr, .notice);
    rt.ctx = try .init(arena, init.io, &rt.fs, &rt.diag, init.environ_map, scope, std.os.linux.getuid());
    rt.ctx.config = try config.load.load(arena, rt.fs, &rt.diag, .{
        .scope = scope,
        .xdg_config_home = rt.ctx.xdg_config_home,
        .environ = init.environ_map,
    });
    rt.diag.threshold = rt.ctx.config.log_level orelse .notice;

    const detection = try detect.init.detect(&rt.ctx, .{ .config_init = rt.ctx.config.init, .offline_root = root != null });
    rt.ctx.offline = root != null or !detection.running;
    const os = try detect.osrelease.load(arena, &rt.fs);
    rt.profile = profileFor(rt, os, init.environ_map);
    rt.kind = rt.profile.refine(detection.kind);
    rt.runner = .{ .io = init.io, .out = stdout, .err = stderr };
}

fn deps(rt: *Runtime, stdout: *Io.Writer, stderr: *Io.Writer) ops.Deps {
    return .{
        .backend = backend.registry.select(rt.kind, &rt.backends, .{ .ctx = &rt.ctx, .profile = rt.profile }),
        .runner = rt.runner.runner(),
        .out = stdout,
        .err = stderr,
        .detected = rt.kind.name(),
    };
}

fn runSystemctl(init: std.process.Init, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) u8 {
    const arena = init.arena.allocator();
    const parsed = cli.systemctl.parse(arena, args) catch |e| return fail(stderr, "cannot parse arguments: {t}", .{e});
    const req = switch (parsed) {
        .ok => |r| r,
        .err => |failure| {
            stderr.print(core.Diag.prefix ++ "{f}\n", .{FailureFmt{ .failure = failure }}) catch return 1;
            stderr.flush() catch return 1;
            return 1;
        },
    };
    var rt: Runtime = undefined;
    build(&rt, init, req.options.root, req.options.scope, stdout, stderr) catch |e| {
        return fail(stderr, "cannot initialise: {t}", .{e});
    };
    defer rt.fs.deinit();
    return ops.systemctl(&rt.ctx, deps(&rt, stdout, stderr), req);
}

fn runJournalctl(init: std.process.Init, args: []const [:0]const u8, stdout: *Io.Writer, stderr: *Io.Writer) u8 {
    const arena = init.arena.allocator();
    const parsed = cli.journalctl.parse(arena, args) catch |e| return fail(stderr, "cannot parse arguments: {t}", .{e});
    const req = switch (parsed) {
        .ok => |r| r,
        .err => |failure| {
            stderr.print(core.Diag.prefix ++ "{f}\n", .{FailureFmt{ .failure = failure }}) catch return 1;
            stderr.flush() catch return 1;
            return 1;
        },
    };
    var rt: Runtime = undefined;
    build(&rt, init, null, .system, stdout, stderr) catch |e| {
        return fail(stderr, "cannot initialise: {t}", .{e});
    };
    defer rt.fs.deinit();
    return ops.journalctl(&rt.ctx, deps(&rt, stdout, stderr), req);
}

/// `--exec` and `--log`: the executor and the logger of generated services.
fn runService(init: std.process.Init, args: []const [:0]const u8, stderr: *Io.Writer) u8 {
    const arena = init.arena.allocator();
    const parsed = exec.args.parse(arena, args) catch |e| return fail(stderr, "cannot parse arguments: {t}", .{e});
    const req = switch (parsed) {
        .ok => |r| r,
        .err => |message| {
            stderr.print(core.Diag.prefix ++ "{s}\n{s}", .{ message, exec.args.usage }) catch return 1;
            stderr.flush() catch return 1;
            return 1;
        },
    };
    var fs = core.Fs.initRoot(init.io, req.root orelse "/") catch |e| return fail(stderr, "cannot open the root: {t}", .{e});
    defer fs.deinit();
    var diag: core.Diag = .init(stderr, .notice);
    var ctx = core.Context.init(arena, init.io, &fs, &diag, init.environ_map, req.scope, std.os.linux.getuid()) catch |e| {
        return fail(stderr, "cannot initialise: {t}", .{e});
    };
    switch (req.mode) {
        .exec => return exec.executor.run(&ctx, .{ .unit = req.unit, .phase = req.phase }),
        .log => {
            var opts: exec.logger.Options = .{};
            if (req.max_size) |v| opts.max_size = v;
            if (req.keep) |v| opts.keep = v;
            return exec.logger.run(&ctx, init.gpa, req.unit, opts, 0);
        },
    }
}

const FailureFmt = struct {
    failure: cli.systemctl.Failure,

    pub fn format(f: FailureFmt, w: *Io.Writer) Io.Writer.Error!void {
        try f.failure.format(w);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    var stderr: Io.File.Writer = .init(.stderr(), init.io, &err_buf);

    const tool = std.meta.stringToEnum(Tool, std.fs.path.basename(args[0])) orelse {
        if (exec.args.isServiceCommand(args[1..])) return runService(init, args[1..], &stderr.interface);
        try stderr.interface.writeAll(usage);
        try stderr.interface.flush();
        return 0;
    };
    return switch (tool) {
        .systemctl => runSystemctl(init, args[1..], &stdout.interface, &stderr.interface),
        .journalctl => runJournalctl(init, args[1..], &stdout.interface, &stderr.interface),
    };
}

test {
    _ = @import("core/root.zig");
    _ = @import("unit/root.zig");
    _ = @import("index/root.zig");
    _ = @import("reconcile/root.zig");
    _ = @import("cli/root.zig");
    _ = @import("config/root.zig");
    _ = @import("detect/root.zig");
    _ = @import("backend/root.zig");
    _ = @import("ops/root.zig");
    _ = @import("exec/root.zig");
}
