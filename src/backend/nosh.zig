// SPDX-License-Identifier: GPL-3.0-or-later
//! nosh backend (§11.3), experimental: fake-systemd translates nothing itself. A unit becomes a
//! small record of where it comes from, and `system-control convert-systemd-units` of nosh makes the
//! service bundle from the unit file when the service is enabled or started. `system-control` then
//! enables, starts, stops and reads the service as it does any bundle.
//!
//! The converter reads the unit file and the drop-ins beside it, not the merge of all search
//! directories that the other backends translate, and it refuses settings nosh cannot run (a
//! `Type=notify` service, for one). A bundle it made carries the marker of fake-systemd as a comment
//! in its `run` script, so that it is not taken for a native service; it is removed once the record
//! of its unit is gone.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const profile = @import("../detect/profile.zig");
const marker = @import("../index/marker.zig");
const rebuild = @import("../index/rebuild.zig");
const apply = @import("../reconcile/apply.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const runner = @import("runner.zig");
const layout = @import("nosh/layout.zig");
const native = @import("nosh/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Nosh = @This();

pub const backend_name = "nosh";
pub const generator_number = 1;

/// Capabilities of §11.3: what the converter of nosh maps. Wants=, After= and the like become the
/// dependency links of the bundle, which the converter makes and not fake-systemd.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .ordering = true,
    .supervision = true,
    .oneshot = true,
    .restart_policy = true,
};

const ctl = "system-control";
/// The converter finds the drop-ins of a unit beside it, so it runs in the directory of the unit.
pub const convert_script = "cd \"$1\" && exec system-control convert-systemd-units --bundle-root \"$2\" \"$3\"";
const hash_file = "fake-systemd.hash";
const poll_ms = 100;
pub const default_settle_ms = 10_000;
pub const default_transient_ms = 3_000;
const max_dependency_depth = 8;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// Replaces the check that the tools reach the filesystem root of the context; for tests.
real_root_override: ?bool = null,
/// Milliseconds to follow a oneshot until it has run; tests shorten it.
settle_ms: u64 = default_settle_ms,
/// Milliseconds to wait for the moment between two states to pass before a start; tests shorten it.
transient_ms: u64 = default_transient_ms,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) Nosh {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *Nosh) Backend {
    self.vt = vtable;
    return .{ .ptr = self, .vtable = &self.vt };
}

const vtable: interface.VTable = .{
    .name = backend_name,
    .generator = generator_number,
    .caps = capabilities,
    .native_scan = nativeScan,
    .scan_dirs = scanDirs,
    .generate = generate,
    .enable = enable,
    .disable = disable,
    .start = start,
    .stop = stop,
    .restart = restart,
    .reload = reload,
    .kill = kill,
    .status = status,
    .is_enabled = isEnabled,
    .reload_manager = reloadManager,
    .power = power,
};

fn me(ptr: *anyopaque) *Nosh {
    return @ptrCast(@alignCast(ptr));
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = if (self.ctx.scope == .user) &.{} else self.dirs.admin,
        .extractor = native.extractCommand,
        .entry_file = "service/run",
    };
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    if (scope == .user) return &.{};
    const dirs = try gpa.alloc(rebuild.ScanDir, 1);
    dirs[0] = .{ .path = try layout.recordDir(gpa, self.dirs), .tier = .admin };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    if (u.scope == .user) {
        self.ctx.diag.err("{s}: nosh services of a user are not supported", .{u.name.full});
        return error.Unsupported;
    }
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);
    if (guard.hasControl(input.source)) {
        self.ctx.diag.err("{s}: the path of the unit holds a line break or NUL", .{u.name.full});
        return error.Unsupported;
    }
    const body = try std.fmt.allocPrint(
        gpa,
        "# nosh converts the unit itself: system-control convert-systemd-units\ndirectory {s}\nunit {s}\nhash {x:0>16}\n",
        .{ std.fs.path.dirname(input.source) orelse "/", u.name.full, input.src_hash },
    );
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);
    const record_path = try layout.recordPath(gpa, self.dirs, svc);
    try guard.requireNotOther(self.ctx, guard.claimFile(self.ctx, record_path, u.name.full), u.name.full, record_path);
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    files[0] = .{ .path = record_path, .content = content };
    return .{ .service_name = svc, .files = files };
}

// ---- conversion -------------------------------------------------------------------------

fn run(env: Env, tail: []const []const u8, stdio: runner.Stdio) !runner.Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, ctl);
    try argv.appendSlice(env.ctx.gpa, tail);
    return env.runner.run(env.ctx.gpa, argv.items, stdio);
}

fn mustRun(env: Env, tail: []const []const u8) anyerror!void {
    const res = try run(env, tail, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// True when the tools of nosh work on the filesystem the backend reads and writes.
fn inRealRoot(self: *Nosh) bool {
    if (self.real_root_override) |o| return o;
    const own = self.ctx.fs.devIno("/") catch return false;
    var real = core.Fs.initRoot(self.ctx.io, "/") catch return false;
    defer real.deinit();
    const other = real.devIno("/") catch return false;
    return own.eql(other);
}

fn readRecord(self: *Nosh, service: []const u8) !?struct { record: native.Record, hash: u64 } {
    const path = try layout.recordPath(self.ctx.gpa, self.dirs, service);
    const content = (try guard.readOrAbsent(self.ctx, path, 1 << 16)) orelse return null;
    const parsed = marker.parse(content) orelse return null;
    const record = native.parseRecord(parsed.rest) orelse return null;
    return .{ .record = record, .hash = parsed.marker.source_hash };
}

fn isCurrent(self: *Nosh, service: []const u8, record: native.Record) !bool {
    const path = try std.fs.path.join(self.ctx.gpa, &.{ try layout.bundlePath(self.ctx.gpa, self.dirs, service), hash_file });
    const text = (try guard.readOrAbsent(self.ctx, path, 64)) orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), record.hash);
}

/// Makes the bundle of a service whose unit changed since the last conversion, or that has none.
/// A service without a record is native: nothing to convert.
fn materialize(self: *Nosh, env: Env, service: []const u8) anyerror!void {
    const found = (try self.readRecord(service)) orelse return;
    if (!env.ctx.dry_run and try self.isCurrent(service, found.record)) return;
    if (!env.ctx.dry_run and !self.inRealRoot()) {
        env.ctx.diag.err("{s}: nosh converts units where its tools run; run 'systemctl daemon-reload' on the target", .{service});
        return error.Unsupported;
    }
    const root = layout.bundleRoot(self.dirs);
    const res = try env.runner.run(env.ctx.gpa, &.{ "sh", "-c", convert_script, "nosh-convert", found.record.directory, root, found.record.unit }, .inherit);
    if (res.code != 0) return error.CommandFailed;
    if (env.ctx.dry_run) return;
    try self.markBundle(service, found.record, found.hash);
}

/// The marker goes into the `run` script as a comment, and the hash of the unit next to it.
fn markBundle(self: *Nosh, service: []const u8, record: native.Record, source_hash: u64) !void {
    const gpa = self.ctx.gpa;
    const bundle = try layout.bundlePath(gpa, self.dirs, service);
    const run_path = try std.fs.path.join(gpa, &.{ bundle, "service", "run" });
    const content = self.ctx.fs.readFileAlloc(gpa, run_path, 1 << 20) catch |e| {
        self.ctx.diag.warn("{s}: the converter left no run script: {t}", .{ service, e });
        return;
    };
    if (marker.parse(content) == null) {
        const generator = try interface.generatorLine(gpa, backend_name, generator_number);
        const source = try std.fs.path.join(gpa, &.{ record.directory, record.unit });
        const composed = try marker.compose(gpa, record.unit, source, source_hash, generator, content);
        try self.ctx.fs.writeFileAtomic(run_path, composed, 0o755);
    }
    try self.ctx.fs.writeFileAtomic(try std.fs.path.join(gpa, &.{ bundle, hash_file }), try std.fmt.allocPrint(gpa, "{s}\n", .{record.hash}), 0o644);
}

// ---- enablement -------------------------------------------------------------------------

/// Names of the target bundles whose `wants/` directories hold the link that enables `service`.
fn wantedBy(self: *Nosh, service: []const u8) ![]const []const u8 {
    const gpa = self.ctx.gpa;
    const dir = try std.fs.path.join(gpa, &.{ try layout.bundlePath(gpa, self.dirs, service), "wanted-by" });
    const entries = try guard.iterateOrEmpty(self.ctx, dir);
    var out: std.ArrayList([]const u8) = .empty;
    for (entries) |e| try out.append(gpa, e.name);
    return out.items;
}

fn wantsLink(self: *Nosh, target: []const u8, service: []const u8) ![]const u8 {
    const gpa = self.ctx.gpa;
    return std.fs.path.join(gpa, &.{ try layout.targetsDir(gpa, self.dirs), target, "wants", service });
}

fn linked(self: *Nosh, path: []const u8) bool {
    _ = self.ctx.fs.lstat(path) catch return false;
    return true;
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    try self.materialize(env, service);
    var before: std.ArrayList([]const u8) = .empty;
    for (try self.wantedBy(service)) |t| if (!self.linked(try self.wantsLink(t, service))) try before.append(gpa, t);
    if (env.ctx.dry_run) {
        try mustRun(env, &.{ "enable", service });
        return &.{};
    }
    if (!self.inRealRoot()) {
        env.ctx.diag.err("{s}: nosh enables services where its tools run", .{service});
        return error.Unsupported;
    }
    try mustRun(env, &.{ "enable", service });
    // `system-control enable` exits 0 when it could not make a link, so the links are checked.
    var changes: std.ArrayList(interface.Change) = .empty;
    for (before.items) |t| {
        const link = try self.wantsLink(t, service);
        if (!self.linked(link)) {
            env.ctx.diag.err("{s}: system-control did not link the service into {s}", .{ service, t });
            return error.CommandFailed;
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = self.ctx.fs.readLink(link, &buf) catch continue;
        try changes.append(gpa, .{ .created = .{ .link = link, .target = try gpa.dupe(u8, target) } });
    }
    return changes.items;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    var existing: std.ArrayList([]const u8) = .empty;
    for (try self.wantedBy(service)) |t| {
        const link = try self.wantsLink(t, service);
        if (self.linked(link)) try existing.append(gpa, link);
    }
    if (existing.items.len == 0 and !env.ctx.dry_run) return &.{};
    try mustRun(env, &.{ "disable", service });
    var changes: std.ArrayList(interface.Change) = .empty;
    for (existing.items) |link| {
        if (env.ctx.dry_run or !self.linked(link)) try changes.append(gpa, .{ .removed = link });
    }
    return changes.items;
}

/// A bundle is enabled when a `wants/` directory of a target it is wanted by links to it.
fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    for (try self.wantedBy(service)) |t| {
        if (self.linked(try self.wantsLink(t, service))) return .enabled;
    }
    return .disabled;
}

// ---- runtime control --------------------------------------------------------------------

fn sleepMs(env: Env, ms: u64) void {
    env.ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return;
}

/// Unit recorded for the service, null for a native one.
fn generatedUnit(self: *Nosh, service: []const u8) !?[]const u8 {
    const found = (try self.readRecord(service)) orelse return null;
    return found.record.unit;
}

fn bundleExists(self: *Nosh, service: []const u8) bool {
    return (layout.locate(self.ctx, self.dirs, service) catch return false) != null;
}

const Probe = struct {
    code: u8,
    text: []const u8,
    parsed: native.Parsed,
};

fn probe(env: Env, service: []const u8) !Probe {
    const res = try run(env, &.{ "status", service }, .capture);
    return .{ .code = res.code, .text = res.stdout, .parsed = if (res.code == 0) native.parseStatus(res.stdout) else .{} };
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const self = me(ptr);
    if (!self.bundleExists(service)) return .{ .state = .inactive };
    const p = try probe(env, service);
    return .{ .state = native.stateOf(p.parsed), .pid = p.parsed.pid, .text = p.text };
}

/// Converts `service` and the generated services its bundle wants or requires, which nosh starts
/// with it and cannot find otherwise.
fn materializeAll(self: *Nosh, env: Env, service: []const u8, depth: usize) anyerror!void {
    try self.materialize(env, service);
    if (depth >= max_dependency_depth or env.ctx.dry_run) return;
    const gpa = env.ctx.gpa;
    const bundle = try layout.bundlePath(gpa, self.dirs, service);
    for ([_][]const u8{ "wants", "requires" }) |kind| {
        const entries = try guard.iterateOrEmpty(self.ctx, try std.fs.path.join(gpa, &.{ bundle, kind }));
        for (entries) |e| {
            if ((try self.readRecord(e.name)) != null) try self.materializeAll(env, e.name, depth + 1);
        }
    }
}

/// Waits out the moment between two states, in which a start is never answered.
fn settle(self: *Nosh, env: Env, service: []const u8) !void {
    if (env.ctx.dry_run or !self.bundleExists(service)) return;
    var waited: u64 = 0;
    while (waited < self.transient_ms) : (waited += poll_ms) {
        const p = try probe(env, service);
        if (!native.isTransient(p.parsed.state)) return;
        sleepMs(env, poll_ms);
    }
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.materializeAll(env, service, 0);
    try self.settle(env, service);
    try mustRun(env, &.{ "start", service });
    if (env.ctx.dry_run) return;
    // A oneshot is `done` when it ran, after a moment of `failed`; one whose run failed fails the start, as in systemd.
    var waited: u64 = 0;
    while (true) {
        const p = try probe(env, service);
        const state = native.stateOf(p.parsed);
        if (state != .activating and !native.isTransient(p.parsed.state)) {
            if (state == .failed and std.mem.eql(u8, p.parsed.state, "done")) {
                env.ctx.diag.err("{s}: the command failed", .{service});
                return error.CommandFailed;
            }
            return;
        }
        if (waited >= self.settle_ms) return;
        sleepMs(env, poll_ms);
        waited += poll_ms;
    }
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    if (!self.bundleExists(service) and !env.ctx.dry_run) return;
    try mustRun(env, &.{ "stop", service });
}

/// `system-control` has no restart: the service is stopped and started.
fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try stop(ptr, env, service);
    try start(ptr, env, service);
}

/// A generated service reloads through the executor, which runs `ExecReload=`; a native one gets
/// the hangup of its main process.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const unit_name = (try self.generatedUnit(service)) orelse return mustRun(env, &.{ "hangup", service });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.ctx.gpa, guard.executorPrefix(env.ctx, unit_name));
    try argv.appendSlice(env.ctx.gpa, &.{ policy.executor_path, "--exec", unit_name, "--phase", "reload" });
    const res = try env.runner.run(env.ctx.gpa, argv.items, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// `system-control` sends no signal but the hangup: the main process is signalled directly.
fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const p = try probe(env, service);
    const pid = guard.accepted(self.ctx, p.parsed.pid, null) orelse {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const pid_text = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{pid});
    const res = try env.runner.run(env.ctx.gpa, &.{ "kill", "-s", name, pid_text }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// Converts the bundles whose unit changed, and removes the bundles whose record is gone. A
/// bundle is removed only when it carries both things that `markBundle` leaves in what it
/// converted: the marker in its `run` and the hash file.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    if (env.ctx.dry_run) return;
    const root = layout.bundleRoot(self.dirs);
    const entries = try guard.iterateOrEmpty(self.ctx, root);
    for (entries) |e| {
        const service = e.name;
        if ((try self.readRecord(service)) != null) continue;
        if (!self.ctx.fs.exists(try std.fs.path.join(gpa, &.{ root, service, hash_file }))) continue;
        const run_path = try std.fs.path.join(gpa, &.{ root, service, "service", "run" });
        const content = (try guard.readOrAbsent(self.ctx, run_path, 1 << 20)) orelse continue;
        if (marker.parse(content) == null) continue;
        self.ctx.fs.deleteTree(try std.fs.path.join(gpa, &.{ root, service })) catch |err| {
            env.ctx.diag.warn("{s}: cannot remove the bundle: {t}", .{ service, err });
        };
    }
    const records = try guard.iterateOrEmpty(self.ctx, try layout.recordDir(gpa, self.dirs));
    for (records) |r| {
        const found = (try self.readRecord(r.name)) orelse continue;
        if (!self.bundleExists(r.name) or try self.isCurrent(r.name, found.record)) continue;
        self.materialize(env, r.name) catch |err| env.ctx.diag.warn("{s}: cannot convert the unit: {t}", .{ r.name, err });
    }
}

fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const verb = switch (action) {
        .reboot => "reboot",
        .poweroff => "poweroff",
        .halt => "halt",
    };
    try mustRun(env, &.{verb});
}

test {
    _ = layout;
    _ = native;
}
