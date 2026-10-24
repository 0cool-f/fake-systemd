//! Init detection (spec §4.1) and running check (§4.2). Every probe goes through the context's
//! `Fs` and environment, so tests fake `/proc`, control paths and tools inside a tmp root.
const std = @import("std");
const Context = @import("../core/Context.zig");
const Fs = @import("../core/Fs.zig");
const kind_mod = @import("kind.zig");

pub const InitKind = kind_mod.InitKind;

pub const override_env = "FAKE_SYSTEMD_INIT";

/// What decided the detected kind.
pub const Signal = enum {
    override_env,
    override_config,
    proc_exe,
    control_path,
    tool,
    none,
};

pub const Detection = struct {
    kind: InitKind = .unknown,
    /// An init of this kind runs as PID 1 in the current root.
    running: bool = false,
    signal: Signal = .none,
    /// PID 1 is the real systemd.
    systemd_pid1: bool = false,
};

pub const Options = struct {
    /// `Init=` from the configuration; `FAKE_SYSTEMD_INIT` takes precedence. `auto` or empty means none.
    config_init: ?[]const u8 = null,
    /// `--root` given: offline mode, control paths of a running init are not consulted.
    offline_root: bool = false,
};

const proc_exe_path = "/proc/1/exe";
const proc_root_path = "/proc/1/root";

const ExeName = struct { name: []const u8, kind: InitKind };

/// PID 1 executables with an unambiguous backend. A plain `init` is ambiguous and resolved by
/// control paths.
const exe_names = [_]ExeName{
    .{ .name = "dinit", .kind = .dinit },
    .{ .name = "runit", .kind = .runit },
    .{ .name = "runit-init", .kind = .runit },
    .{ .name = "s6-svscan", .kind = .s6 },
    .{ .name = "openrc-init", .kind = .openrc },
    .{ .name = "finit", .kind = .finit },
    .{ .name = "shepherd", .kind = .shepherd },
    .{ .name = "66-boot", .kind = .s66 },
    .{ .name = "procd", .kind = .procd },
    .{ .name = "system-manager", .kind = .nosh },
};

const ControlPath = struct { path: []const u8, kind: InitKind };

/// Control directories and sockets of a running init. Order resolves overlap: OpenRC and s6-rc
/// are listed before the sysvinit and s6 paths that they can coexist with.
const control_paths = [_]ControlPath{
    .{ .path = "/run/dinitctl", .kind = .dinit },
    .{ .path = "/run/s6-rc", .kind = .s6_rc },
    .{ .path = "/run/openrc/softlevel", .kind = .openrc },
    .{ .path = "/run/runit", .kind = .runit },
    .{ .path = "/run/service", .kind = .s6 },
    .{ .path = "/run/s6", .kind = .s6 },
    .{ .path = "/run/66", .kind = .s66 },
    .{ .path = "/run/finit", .kind = .finit },
    .{ .path = "/run/shepherd/socket", .kind = .shepherd },
    .{ .path = "/run/system-manager", .kind = .nosh },
    .{ .path = "/run/initctl", .kind = .sysvinit },
    .{ .path = "/dev/initctl", .kind = .sysvinit },
};

const ToolProbe = struct { tool: []const u8, kind: InitKind };

const tool_probes = [_]ToolProbe{
    .{ .tool = "dinitctl", .kind = .dinit },
    .{ .tool = "s6-rc", .kind = .s6_rc },
    .{ .tool = "openrc-run", .kind = .openrc },
    .{ .tool = "sv", .kind = .runit },
    .{ .tool = "update-rc.d", .kind = .sysvinit_debian },
    .{ .tool = "chkconfig", .kind = .sysvinit_redhat },
};

const tool_dirs = [_][]const u8{ "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin" };

pub fn detect(ctx: *const Context, opts: Options) !Detection {
    var result: Detection = .{};
    const proc = probeProcExe(ctx);
    result.systemd_pid1 = proc.systemd;

    var kind: ?InitKind = null;
    if (try overrideKind(ctx, opts)) |o| {
        kind = o.kind;
        result.signal = o.signal;
    }

    var control: ?InitKind = null;
    if (!opts.offline_root) control = probeControl(ctx);

    if (kind == null) {
        if (proc.kind) |pk| {
            kind = pk;
            result.signal = .proc_exe;
            if (pk == .s6 and control != null and control.? == .s6_rc) kind = .s6_rc;
        } else if (control) |ck| {
            kind = ck;
            result.signal = .control_path;
        }
    }

    const running = !opts.offline_root and kind != null and sameRoot(ctx) and
        (confirms(proc.kind, kind.?) or confirms(control, kind.?));

    if (kind == null) {
        if (probeTools(ctx)) |tk| {
            kind = tk;
            result.signal = .tool;
        }
    }

    result.kind = kind orelse .unknown;
    result.running = running and result.kind != .unknown;
    if (result.kind == .sysvinit) result.kind = refineSysvinit(ctx);
    return result;
}

fn confirms(seen: ?InitKind, kind: InitKind) bool {
    return seen != null and seen.?.sameBackend(kind);
}

const Override = struct { kind: InitKind, signal: Signal };

fn overrideKind(ctx: *const Context, opts: Options) !?Override {
    if (ctx.getEnv(override_env)) |value| {
        if (try parseOverride(ctx, override_env, value)) |k| return .{ .kind = k, .signal = .override_env };
    }
    if (opts.config_init) |value| {
        if (try parseOverride(ctx, "Init=", value)) |k| return .{ .kind = k, .signal = .override_config };
    }
    return null;
}

fn parseOverride(ctx: *const Context, source: []const u8, value: []const u8) !?InitKind {
    if (value.len == 0 or std.mem.eql(u8, value, "auto")) return null;
    if (InitKind.fromName(value)) |k| return k;
    ctx.diag.warn("{s}: unknown init '{s}', using detection", .{ source, value });
    return null;
}

const ProcProbe = struct {
    kind: ?InitKind = null,
    systemd: bool = false,
};

fn probeProcExe(ctx: *const Context) ProcProbe {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = ctx.fs.readLink(proc_exe_path, &buf) catch return .{};
    const trimmed = std.mem.trimEnd(u8, std.mem.cutSuffix(u8, target, " (deleted)") orelse target, "/");
    const base = std.fs.path.basename(trimmed);
    if (std.mem.eql(u8, base, "systemd")) return .{ .systemd = true };
    for (exe_names) |e| {
        if (std.mem.eql(u8, e.name, base)) return .{ .kind = e.kind };
    }
    if (std.mem.eql(u8, base, "busybox")) return .{ .kind = .busybox };
    return .{};
}

fn probeControl(ctx: *const Context) ?InitKind {
    for (control_paths) |c| {
        if (ctx.fs.exists(c.path)) return c.kind;
    }
    return null;
}

fn probeTools(ctx: *const Context) ?InitKind {
    for (tool_probes) |t| {
        if (hasTool(ctx, t.tool)) return t.kind;
    }
    return null;
}

fn hasTool(ctx: *const Context, tool: []const u8) bool {
    var buf: [256]u8 = undefined;
    for (tool_dirs) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, tool }) catch continue;
        const st = ctx.fs.stat(path) catch continue;
        if (st.kind == .file) return true;
    }
    return false;
}

/// Debian or Red Hat flavour from installed tools and release files; stays `sysvinit` otherwise.
fn refineSysvinit(ctx: *const Context) InitKind {
    if (hasTool(ctx, "update-rc.d") or hasTool(ctx, "insserv")) return .sysvinit_debian;
    if (hasTool(ctx, "chkconfig")) return .sysvinit_redhat;
    if (ctx.fs.exists("/etc/debian_version")) return .sysvinit_debian;
    if (ctx.fs.exists("/etc/redhat-release")) return .sysvinit_redhat;
    return .sysvinit;
}

/// True when `/` and PID 1's root are the same filesystem object. A missing `/proc/1/root`
/// means different roots; an unreadable one cannot disprove it and counts as the same.
fn sameRoot(ctx: *const Context) bool {
    const own = ctx.fs.devIno("/") catch return false;
    const init_root = ctx.fs.devIno(proc_root_path) catch |e| return e == error.AccessDenied;
    return own.eql(init_root);
}

const testing = std.testing;
const Diag = @import("../core/Diag.zig");

const Harness = struct {
    tmp: testing.TmpDir,
    fs: Fs,
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    diag_buf: [512]u8 = undefined,
    diag_writer: std.Io.Writer = undefined,
    diag: Diag = undefined,
    ctx: Context = undefined,

    fn init(h: *Harness) !void {
        h.tmp = testing.tmpDir(.{ .iterate = true });
        h.fs = .initDir(testing.io, h.tmp.dir);
        h.arena = .init(testing.allocator);
        h.env = .init(testing.allocator);
        h.diag_writer = .fixed(&h.diag_buf);
        h.diag = .init(&h.diag_writer, .info);
        h.ctx = try .init(h.arena.allocator(), testing.io, &h.fs, &h.diag, &h.env, .system, 0);
    }

    fn deinit(h: *Harness) void {
        h.env.deinit();
        h.arena.deinit();
        h.tmp.cleanup();
    }

    fn file(h: *Harness, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try h.fs.makePath(d);
        try h.fs.writeFileAtomic(path, "", 0o755);
    }

    fn dir(h: *Harness, path: []const u8) !void {
        try h.fs.makePath(path);
    }

    /// PID 1 runs `exe` in the same root.
    fn pid1(h: *Harness, exe: []const u8) !void {
        try h.dir("/proc/1");
        try h.fs.symLink(exe, "/proc/1/exe");
        try h.fs.symLink("/", "/proc/1/root");
    }

    fn pid1InOtherRoot(h: *Harness, exe: []const u8) !void {
        try h.dir("/proc/1");
        try h.dir("/elsewhere");
        try h.fs.symLink(exe, "/proc/1/exe");
        try h.fs.symLink("/elsewhere", "/proc/1/root");
    }

    fn warnings(h: *Harness) []const u8 {
        return h.diag_writer.buffered();
    }
};

fn expectDetection(h: *Harness, opts: Options, kind: InitKind, running: bool, signal: Signal) !void {
    const d = try detect(&h.ctx, opts);
    try testing.expectEqual(kind, d.kind);
    try testing.expectEqual(running, d.running);
    try testing.expectEqual(signal, d.signal);
}

test "empty root detects nothing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectDetection(&h, .{}, .unknown, false, .none);
}

test "PID 1 executable names map to backends and confirm running" {
    const cases = [_]struct { []const u8, InitKind }{
        .{ "/usr/bin/dinit", .dinit },
        .{ "/usr/bin/runit", .runit },
        .{ "/usr/bin/runit-init", .runit },
        .{ "/usr/bin/s6-svscan", .s6 },
        .{ "/usr/sbin/openrc-init", .openrc },
        .{ "/sbin/finit", .finit },
        .{ "/usr/bin/shepherd", .shepherd },
        .{ "/usr/bin/66-boot", .s66 },
        .{ "/sbin/procd", .procd },
        .{ "/bin/busybox", .busybox },
        .{ "/usr/bin/system-manager", .nosh },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.pid1(c[0]);
        try expectDetection(&h, .{}, c[1], true, .proc_exe);
    }
}

test "a deleted executable suffix is ignored" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/dinit (deleted)");
    try expectDetection(&h, .{}, .dinit, true, .proc_exe);
}

test "PID 1 in a different root is not running" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1InOtherRoot("/usr/bin/dinit");
    try expectDetection(&h, .{}, .dinit, false, .proc_exe);
}

test "missing /proc/1/root means a different root even with a control path" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.dir("/proc/1");
    try h.fs.symLink("/usr/bin/dinit", "/proc/1/exe");
    try h.dir("/run");
    try h.file("/run/dinitctl");
    try expectDetection(&h, .{}, .dinit, false, .proc_exe);
}

test "real systemd as PID 1 is flagged and not driven" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/lib/systemd/systemd");
    const d = try detect(&h.ctx, .{});
    try testing.expect(d.systemd_pid1);
    try testing.expectEqual(InitKind.unknown, d.kind);
    try testing.expect(!d.running);
}

test "ambiguous init is resolved by control paths" {
    const cases = [_]struct { []const u8, InitKind }{
        .{ "/run/dinitctl", .dinit },
        .{ "/run/openrc/softlevel", .openrc },
        .{ "/run/initctl", .sysvinit },
        .{ "/run/runit/x", .runit },
        .{ "/run/s6-rc/x", .s6_rc },
        .{ "/run/service/x", .s6 },
        .{ "/run/66/x", .s66 },
        .{ "/run/finit/x", .finit },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.pid1("/sbin/init");
        try h.file(c[0]);
        const d = try detect(&h.ctx, .{});
        try testing.expect(d.kind.sameBackend(c[1]));
        try testing.expect(d.running);
        try testing.expectEqual(Signal.control_path, d.signal);
    }
}

test "init without any signal is unknown" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/sbin/init");
    try expectDetection(&h, .{}, .unknown, false, .none);
}

test "OpenRC wins over the sysvinit control socket" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/sbin/init");
    try h.file("/run/initctl");
    try h.file("/run/openrc/softlevel");
    try expectDetection(&h, .{}, .openrc, true, .control_path);
}

test "s6-svscan with an s6-rc directory is s6-rc" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/s6-svscan");
    try h.dir("/run/s6-rc");
    try expectDetection(&h, .{}, .s6_rc, true, .proc_exe);
}

test "control path without /proc is offline" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.file("/run/dinitctl");
    try expectDetection(&h, .{}, .dinit, false, .control_path);
}

test "sysvinit flavour comes from tools and release files" {
    {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.pid1("/sbin/init");
        try h.file("/run/initctl");
        try h.file("/usr/sbin/update-rc.d");
        try expectDetection(&h, .{}, .sysvinit_debian, true, .control_path);
    }
    {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.pid1("/sbin/init");
        try h.file("/run/initctl");
        try h.file("/sbin/chkconfig");
        try expectDetection(&h, .{}, .sysvinit_redhat, true, .control_path);
    }
    {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.pid1("/sbin/init");
        try h.file("/run/initctl");
        try h.file("/etc/debian_version");
        try expectDetection(&h, .{}, .sysvinit_debian, true, .control_path);
    }
    {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.pid1("/sbin/init");
        try h.file("/run/initctl");
        try h.file("/etc/redhat-release");
        try expectDetection(&h, .{}, .sysvinit_redhat, true, .control_path);
    }
    {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.pid1("/sbin/init");
        try h.file("/run/initctl");
        try expectDetection(&h, .{}, .sysvinit, true, .control_path);
    }
}

test "tools are used when nothing else matches, always offline" {
    const cases = [_]struct { []const u8, InitKind }{
        .{ "/usr/bin/dinitctl", .dinit },
        .{ "/usr/bin/sv", .runit },
        .{ "/usr/bin/s6-rc", .s6_rc },
        .{ "/sbin/openrc-run", .openrc },
        .{ "/usr/sbin/update-rc.d", .sysvinit_debian },
        .{ "/usr/sbin/chkconfig", .sysvinit_redhat },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        try h.file(c[0]);
        try expectDetection(&h, .{}, c[1], false, .tool);
    }
}

test "tool probe priority and non-executable directories" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.file("/usr/bin/sv");
    try h.file("/usr/bin/dinitctl");
    try expectDetection(&h, .{}, .dinit, false, .tool);

    var h2: Harness = undefined;
    try h2.init();
    defer h2.deinit();
    try h2.dir("/usr/bin/dinitctl");
    try expectDetection(&h2, .{}, .unknown, false, .none);
}

test "tools do not override a detected running init" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/runit");
    try h.file("/usr/bin/dinitctl");
    try expectDetection(&h, .{}, .runit, true, .proc_exe);
}

test "environment override wins over detection and config" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/dinit");
    try h.env.put(override_env, "openrc");
    const d = try detect(&h.ctx, .{ .config_init = "runit" });
    try testing.expectEqual(InitKind.openrc, d.kind);
    try testing.expectEqual(Signal.override_env, d.signal);
    try testing.expect(!d.running);
}

test "an override that matches the running init keeps running true" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/dinit");
    try h.env.put(override_env, "dinit");
    try expectDetection(&h, .{}, .dinit, true, .override_env);
}

test "config override applies when the environment has none" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/dinit");
    try expectDetection(&h, .{ .config_init = "runit" }, .runit, false, .override_config);
    try expectDetection(&h, .{ .config_init = "auto" }, .dinit, true, .proc_exe);
    try expectDetection(&h, .{ .config_init = "" }, .dinit, true, .proc_exe);
}

test "override accepts none and s6-rc" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectDetection(&h, .{ .config_init = "none" }, .unknown, false, .override_config);
    try expectDetection(&h, .{ .config_init = "s6-rc" }, .s6_rc, false, .override_config);
}

test "an unknown override value warns and falls back" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/dinit");
    try h.env.put(override_env, "systemd");
    try expectDetection(&h, .{}, .dinit, true, .proc_exe);
    try testing.expect(std.mem.indexOf(u8, h.warnings(), "FAKE_SYSTEMD_INIT: unknown init 'systemd'") != null);
}

test "an invalid environment value falls through to the config value" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.env.put(override_env, "bogus");
    try expectDetection(&h, .{ .config_init = "finit" }, .finit, false, .override_config);
}

test "offline root ignores control paths and never runs" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.pid1("/usr/bin/dinit");
    try h.file("/run/openrc/softlevel");
    try expectDetection(&h, .{ .offline_root = true }, .dinit, false, .proc_exe);

    var h2: Harness = undefined;
    try h2.init();
    defer h2.deinit();
    try h2.file("/run/openrc/softlevel");
    try h2.file("/usr/bin/dinitctl");
    try expectDetection(&h2, .{ .offline_root = true }, .dinit, false, .tool);
}

test "offline root still honours overrides" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectDetection(&h, .{ .offline_root = true, .config_init = "runit" }, .runit, false, .override_config);
}

test "a dangling absolute /proc/1/exe link never escapes the root" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try h.dir("/proc/1");
    try h.fs.symLink("/proc/self/exe", "/proc/1/exe");
    try expectDetection(&h, .{}, .unknown, false, .none);
}
