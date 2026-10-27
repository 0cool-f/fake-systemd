// SPDX-License-Identifier: GPL-3.0-or-later
//! s6 backend without s6-rc (§11.2): a service is a directory with `run`, `finish`, `log/run`
//! and data files; a symlink to it in the scan directory makes `s6-svscan` supervise it, and
//! `s6-svc`, `s6-svstat` and `s6-svwait` control it. `s6-svscan` runs the `log` service of a
//! service as its logger.
//!
//! `s6-svscan` starts everything it finds, so "enabled at boot" is a link without a `down`
//! file. A service that is run without being enabled is linked together with a `down` file,
//! which keeps it from starting at boot, and stays linked once stopped. Disabling a running
//! service writes `down` and leaves the link; disabling any other service removes the link and
//! lets the next scan stop its supervisor. Dependencies are `s6-svc -u` and `s6-svwait -u` lines
//! at the top of `run`, so each service a generated `run` starts is linked with `down` too.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const profile = @import("../detect/profile.zig");
const marker = @import("../index/marker.zig");
const rebuild = @import("../index/rebuild.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const network = @import("network.zig");
const runner = @import("runner.zig");
const render = @import("s6/render.zig");
const layout = @import("s6/layout.zig");
const native = @import("s6/native.zig");
const common = @import("s6/common.zig");
const files = @import("s6/files.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const S6 = @This();

pub const backend_name = "s6";
pub const generator_number = 2;

/// Capabilities of §11.2. s6 has no user service manager, and no oneshot service type: a
/// oneshot is a service that stops itself after its command.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .supervision = true,
    .per_service_logger = true,
    .restart_policy = true,
};

const power_tool = "s6-linux-init-hpr";
const default_scan_dir = "/service";
/// How long to wait for `s6-svscan` (which scans every 5 s) to start supervising a new link.
const supervise_wait_ms = 8000;
const supervise_poll_ms = 250;
const max_dependency_depth = 16;
/// Milliseconds `s6-svc -wu` waits for a service to come up.
const up_wait_ms = 10_000;
/// Milliseconds `s6-svc -wd` waits beyond the `timeout-kill` of a service.
const down_slack_ms = 5000;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// Replaces the check of which services are enabled when the network targets are mapped; for
/// tests.
enabled_override: ?[]const []const u8 = null,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) S6 {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *S6) Backend {
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
    .service_of_file = layout.serviceOfPlainFile,
};

fn me(ptr: *anyopaque) *S6 {
    return @ptrCast(@alignCast(ptr));
}

fn base(self: *S6) common.Base {
    return .{ .ctx = self.ctx, .dirs = self.dirs, .flavor = .plain, .enabled_override = self.enabled_override };
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = try layout.lookupDirs(self.ctx, self.dirs, .plain),
        .extractor = native.extractCommand,
        .entry_file = "run",
    };
}

/// The generation directory is read twice: for the scripts that carry their own marker, and for
/// the service directories that list their data files in a meta file.
fn scanDirs(ptr: *anyopaque, gpa: Allocator, _: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const dirs = try gpa.alloc(rebuild.ScanDir, 2);
    const path = layout.generationDir(self.dirs, .plain);
    dirs[0] = .{ .path = path, .tier = .admin, .nested = true };
    dirs[1] = .{ .path = path, .tier = .admin };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn scanDir(self: *S6) []const u8 {
    return self.dirs.enable_dir orelse default_scan_dir;
}

fn enabledLookup(self: *S6) network.Enabled {
    return .{ .ptr = self, .is_enabled = serviceEnabled, .injected = self.enabled_override };
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const b = self.base();
    const u = input.unit;
    if (u.scope == .user) {
        self.ctx.diag.err("{s}: the s6 backend has no user services", .{u.name.full});
        return error.Unsupported;
    }
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);

    const have_setpriv = (try b.findProgram("setpriv")) != null;
    const reason = policy.executorReason(u.*, capabilities, common.nativeSupport());
    const use_executor = (reason != null and reason.? != .no_command) or common.Base.nativeBlocked(u, have_setpriv) or b.executorResolves(u) or render.stopsOnSignal(u);

    const deps = try b.dependencies(svc, u, input.deps, self.enabledLookup());
    const command: render.Command = if (use_executor)
        .executor
    else
        .{ .native = if (u.exec_start.len == 0) &.{"/bin/true"} else try b.commandWords(u.exec_start[0]) };
    const in: render.Input = .{
        .unit = u,
        .command = command,
        .identity = try b.identityFor(u, have_setpriv, use_executor),
        .numeric = try b.numericFor(u, use_executor),
        .hard = try scanPaths(gpa, self.scanDir(), deps.hard),
        .soft = try scanPaths(gpa, self.scanDir(), deps.soft),
        .executor_path = policy.executor_path,
        .sleep_path = try b.resolveProgram("sleep", "/usr/bin/sleep"),
        .setpriv_path = try b.resolveProgram("setpriv", "/usr/bin/setpriv"),
        .nice_path = try b.resolveProgram("nice", "/usr/bin/nice"),
    };

    const dir = try std.fs.path.join(gpa, &.{ layout.generationDir(self.dirs, .plain), svc });
    try guard.requireNotOther(self.ctx, guard.claimDir(self.ctx, dir, u.name.full, &.{"run"}), u.name.full, dir);
    var set: files.Set = .init(gpa, input, try interface.generatorLine(gpa, backend_name, generator_number), dir);
    set.starts = try std.mem.concat(gpa, []const u8, &.{ deps.hard, deps.soft });
    try set.script("run", try render.run(gpa, in), 0o755);
    if (render.needsFinish(u)) try set.script("finish", try render.finish(gpa, in), 0o755);
    try set.script("log/run", try render.log(gpa, u.name.full, u.scope, policy.executor_path), 0o755);
    try set.data("timeout-kill", try render.numberFile(gpa, render.killTimeoutMs(u)));
    if (render.downSignal(u)) |sig| try set.data("down-signal", try render.lineFile(gpa, try render.signalFileName(gpa, sig)));
    if (render.finishTimeoutMs(u)) |ms| try set.data("timeout-finish", try render.numberFile(gpa, ms));
    return .{ .service_name = svc, .files = try set.done() };
}

fn scanPaths(gpa: Allocator, scan: []const u8, names: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, names.len);
    for (names, out) |n, *p| p.* = try std.fs.path.join(gpa, &.{ scan, n });
    return out;
}

// ---- enablement -------------------------------------------------------------------------

fn linkPath(self: *S6, service: []const u8) ![]const u8 {
    return std.fs.path.join(self.ctx.gpa, &.{ self.scanDir(), service });
}

fn serviceDir(self: *S6, service: []const u8) !?[]const u8 {
    return layout.locatePlain(self.ctx, self.dirs, service);
}

fn downPath(self: *S6, service: []const u8) !?[]const u8 {
    const dir = (try self.serviceDir(service)) orelse return null;
    return try std.fs.path.join(self.ctx.gpa, &.{ dir, "down" });
}

fn linked(self: *S6, link: []const u8) bool {
    _ = self.ctx.fs.lstat(link) catch return false;
    return true;
}

fn hasDown(self: *S6, service: []const u8) bool {
    const path = (self.downPath(service) catch return false) orelse return false;
    return self.ctx.fs.exists(path);
}

/// Creates the link of `service` and returns whether it was new.
fn makeLink(self: *S6, service: []const u8, dir: []const u8) !bool {
    const link = try self.linkPath(service);
    if (self.linked(link)) return false;
    try self.ctx.fs.makePath(std.fs.path.dirname(link) orelse "/");
    try self.ctx.fs.symLink(dir, link);
    return true;
}

fn writeDown(self: *S6, path: []const u8) !void {
    try self.ctx.fs.writeFileAtomic(path, "", 0o644);
}

/// Links `service` with a `down` file unless it is linked already, so that `s6-svscan`
/// supervises it without starting it. Returns true when the link is new.
fn linkIdle(self: *S6, service: []const u8) !bool {
    const dir = (try self.serviceDir(service)) orelse return false;
    if (self.linked(try self.linkPath(service))) return false;
    const down = try std.fs.path.join(self.ctx.gpa, &.{ dir, "down" });
    if (!self.ctx.fs.exists(down)) try self.writeDown(down);
    return try self.makeLink(service, dir);
}

/// Services the generated service of `service` starts, in order.
fn dependencyNames(self: *S6, service: []const u8) ![]const []const u8 {
    const dir = (try self.serviceDir(service)) orelse return &.{};
    return guard.startedServices(self.ctx, dir);
}

/// Links the services `service` starts, and those they start in turn, idle. Services that
/// were linked now are appended to `created`.
fn linkDependencies(self: *S6, service: []const u8, created: *std.ArrayList([]const u8), depth: usize) !void {
    if (depth > max_dependency_depth) return;
    for (try self.dependencyNames(service)) |dep| {
        if (try self.linkIdle(dep)) try created.append(self.ctx.gpa, dep);
        try self.linkDependencies(dep, created, depth + 1);
    }
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const dir = (try self.serviceDir(service)) orelse blk: {
        // A dry run has not written the service directory yet.
        if (env.ctx.dry_run) break :blk try std.fs.path.join(env.ctx.gpa, &.{ layout.generationDir(self.dirs, .plain), service });
        env.ctx.diag.err("{s}: no service directory found", .{service});
        return error.Unsupported;
    };
    var changes: std.ArrayList(interface.Change) = .empty;
    const link = try self.linkPath(service);
    const was_linked = self.linked(link);
    if (!was_linked) {
        try changes.append(env.ctx.gpa, .{ .created = .{ .link = link, .target = dir } });
        if (!env.ctx.dry_run) _ = try self.makeLink(service, dir);
    }
    const down = try std.fs.path.join(env.ctx.gpa, &.{ dir, "down" });
    if (self.ctx.fs.exists(down)) {
        try changes.append(env.ctx.gpa, .{ .removed = down });
        if (!env.ctx.dry_run) try self.ctx.fs.deleteFile(down);
    }
    if (!env.ctx.dry_run) {
        var created: std.ArrayList([]const u8) = .empty;
        try self.linkDependencies(service, &created, 0);
        if (env.online and (!was_linked or created.items.len > 0)) self.rescan(env, false);
    }
    return changes.items;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const link = try self.linkPath(service);
    if (!self.linked(link)) return &.{};
    const changes = try env.ctx.gpa.alloc(interface.Change, 1);
    var was_supervised = false;
    if (env.online) {
        const st = try self.statusOf(env, service);
        if (st.state == .active or st.state == .activating or st.state == .deactivating) {
            const down = (try self.downPath(service)) orelse return &.{};
            if (self.ctx.fs.exists(down)) return &.{};
            if (!env.ctx.dry_run) try self.writeDown(down);
            changes[0] = .{ .created_file = down };
            return changes;
        }
        was_supervised = self.supervised(env, link);
    }
    changes[0] = .{ .removed = link };
    if (env.ctx.dry_run) return changes;
    try self.ctx.fs.deleteFile(link);
    if (was_supervised) {
        self.rescan(env, true);
        self.waitGone(env, service);
    }
    return changes;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    if (!self.linked(try self.linkPath(service))) return .disabled;
    return if (self.hasDown(service)) .disabled else .enabled;
}

fn serviceEnabled(ptr: *anyopaque, service: []const u8) anyerror!bool {
    const self = me(ptr);
    const link = self.linkPath(service) catch return false;
    return self.linked(link) and !self.hasDown(service);
}

// ---- runtime control --------------------------------------------------------------------

fn runTool(env: Env, argv: []const []const u8, stdio: runner.Stdio) !runner.Result {
    return env.runner.run(env.ctx.gpa, argv, stdio);
}

fn sleepMs(env: Env, ms: u64) void {
    env.ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return;
}

/// True when an `s6-supervise` runs for the service directory `path`.
fn supervised(self: *S6, env: Env, path: []const u8) bool {
    _ = self;
    const res = runTool(env, &.{ "s6-svok", path }, .capture) catch return false;
    return res.code == 0;
}

/// Asks `s6-svscan` to scan now, and with `nuke` to stop the supervisors of removed links.
fn rescan(self: *S6, env: Env, nuke: bool) void {
    if (env.ctx.dry_run) return;
    const res = runTool(env, &.{ "s6-svscanctl", if (nuke) "-an" else "-a", self.scanDir() }, .quiet) catch return;
    if (res.code != 0) env.ctx.diag.warn("s6-svscan did not accept a request to scan {s}", .{self.scanDir()});
}

fn statusOf(self: *S6, env: Env, service: []const u8) !interface.Status {
    const res = try runTool(env, &.{ "s6-svstat", try self.linkPath(service) }, .capture);
    return native.parseStatus(res.stdout, self.verdictOf(service));
}

fn exitStatusPath(self: *S6, service: []const u8) !?[]const u8 {
    const dir = (try self.serviceDir(service)) orelse return null;
    return try std.fs.path.join(self.ctx.gpa, &.{ dir, "supervise", render.exit_status_file });
}

fn verdictOf(self: *S6, service: []const u8) ?native.Verdict {
    const path = (self.exitStatusPath(service) catch return null) orelse return null;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 256) catch return null;
    return native.parseVerdict(text);
}

fn forgetExit(self: *S6, env: Env, service: []const u8) void {
    if (env.ctx.dry_run) return;
    const path = (self.exitStatusPath(service) catch return) orelse return;
    self.ctx.fs.deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => env.ctx.diag.warn("{s}: cannot remove {s}: {t}", .{ service, path, e }),
    };
}

/// Records a stop that fake-systemd asked for as a clean end, so a service that had to be
/// killed does not read as failed.
fn markStopped(self: *S6, env: Env, service: []const u8) !void {
    if (env.ctx.dry_run or (try self.generatedUnit(service)) == null) return;
    const path = (try self.exitStatusPath(service)) orelse return;
    self.ctx.fs.writeFileAtomic(path, "ok 0 0\n", 0o644) catch |e| env.ctx.diag.warn("{s}: cannot write {s}: {t}", .{ service, path, e });
}

/// Waits until an `s6-supervise` supervises `service`; a new link is only noticed at the next scan.
fn waitSupervised(self: *S6, env: Env, service: []const u8) void {
    if (env.ctx.dry_run) return;
    const link = self.linkPath(service) catch return;
    var waited: u64 = 0;
    while (waited <= supervise_wait_ms) : (waited += supervise_poll_ms) {
        if (self.supervised(env, link)) return;
        sleepMs(env, supervise_poll_ms);
    }
    env.ctx.diag.warn("{s}: s6-svscan did not start supervising the service in time", .{service});
}

/// Waits until the supervisor of an unlinked service has exited, which the next nuking scan of
/// `s6-svscan` makes it do; `s6-svstat` is given the service directory because the link is gone.
fn waitGone(self: *S6, env: Env, service: []const u8) void {
    const dir = (self.serviceDir(service) catch return) orelse return;
    var waited: u64 = 0;
    while (waited <= supervise_wait_ms) : (waited += supervise_poll_ms) {
        const res = runTool(env, &.{ "s6-svstat", dir }, .capture) catch return;
        if (!native.hasStatusLine(res.stdout)) return;
        sleepMs(env, supervise_poll_ms);
    }
    env.ctx.diag.warn("{s}: s6-svscan did not stop supervising the removed link in time", .{service});
}

fn reportFailure(env: Env, service: []const u8, res: runner.Result) void {
    const text = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (text.len > 0) env.ctx.diag.err("{s}: {s}", .{ service, text });
}

/// Brings the service and its dependencies up. `s6-svc -wu` returns once the service is up, so a
/// service that ends at once reads as a failure unless its `finish` recorded an end.
fn begin(self: *S6, env: Env, service: []const u8) !void {
    var created: std.ArrayList([]const u8) = .empty;
    if (!env.ctx.dry_run) {
        try self.linkDependencies(service, &created, 0);
        if (try self.linkIdle(service)) try created.append(env.ctx.gpa, service);
    }
    if (created.items.len > 0) {
        self.rescan(env, false);
        for (created.items) |name| self.waitSupervised(env, name);
    }
    self.forgetExit(env, service);
    const wait = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{up_wait_ms});
    const res = try runTool(env, &.{ "s6-svc", "-wu", "-T", wait, "-u", try self.linkPath(service) }, .quiet);
    if (res.code == 0) return self.awaitOneshot(env, service);
    if (self.verdictOf(service) != null) {
        const st = try self.statusOf(env, service);
        if (st.state == .inactive or st.state == .failed) return self.awaitOneshot(env, service);
    }
    reportFailure(env, service, res);
    return error.CommandFailed;
}

/// Waits until a oneshot that ends by itself has run its command and its `finish`, as `s6-svc -wu`
/// returns as soon as the process is up.
fn awaitOneshot(self: *S6, env: Env, service: []const u8) !void {
    const flags = try self.runFlags(service);
    if (!flags.oneshot) return;
    const limit = flags.start_timeout_ms orelse render.default_timeout_ms;
    const wait = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{limit});
    const argv: []const []const u8 = if (limit == 0)
        &.{ "s6-svwait", "-D", try self.linkPath(service) }
    else
        &.{ "s6-svwait", "-D", "-t", wait, try self.linkPath(service) };
    const res = try runTool(env, argv, .quiet);
    if (res.code != 0) {
        reportFailure(env, service, res);
        return error.CommandFailed;
    }
    if (self.verdictOf(service) == .failed) {
        env.ctx.diag.err("Job for {s} failed: the command of the oneshot did not succeed", .{service});
        return error.CommandFailed;
    }
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).begin(env, service);
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.stopService(env, service);
    try self.begin(env, service);
}

fn readNumber(self: *S6, dir: []const u8, name: []const u8) ?u64 {
    const path = std.fs.path.join(self.ctx.gpa, &.{ dir, name }) catch return null;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 64) catch return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

/// Milliseconds `s6-svc -wd` waits: the `timeout-kill` of the service plus a margin, which
/// is also what native services get when they have none; none when the service is never killed.
fn downWaitMs(self: *S6, service: []const u8) ?u64 {
    const dir = (self.serviceDir(service) catch return render.default_timeout_ms) orelse return render.default_timeout_ms;
    const kill_ms = self.readNumber(dir, "timeout-kill") orelse render.default_timeout_ms;
    if (kill_ms == 0) return null;
    return kill_ms + down_slack_ms;
}

/// Stops the service: `s6-svc -d` sends the stop signal and `s6-supervise` kills the process after
/// its `timeout-kill`. A service with `ExecStop=` runs them in its supervising executor on that
/// signal; a oneshot that holds after its command has them run first through the executor, with
/// the service marked as not to be restarted while its process is terminated.
fn stopService(self: *S6, env: Env, service: []const u8) !void {
    const link = try self.linkPath(service);
    if (!self.supervised(env, link)) return;
    if ((try self.runFlags(service)).exec_stop) try self.runStopHook(env, service, link);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(env.ctx.gpa, &.{ "s6-svc", "-wd" });
    if (self.downWaitMs(service)) |ms| try argv.appendSlice(env.ctx.gpa, &.{ "-T", try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{ms}) });
    try argv.appendSlice(env.ctx.gpa, &.{ "-d", link });
    const res = try runTool(env, argv.items, .quiet);
    if (res.code != 0) {
        const st = try self.statusOf(env, service);
        if (st.state != .inactive and st.state != .failed) {
            reportFailure(env, service, res);
            return error.CommandFailed;
        }
    }
    try self.markStopped(env, service);
}

fn runStopHook(self: *S6, env: Env, service: []const u8, link: []const u8) !void {
    const gpa = env.ctx.gpa;
    const unit_name = (try self.generatedUnit(service)) orelse return;
    _ = try runTool(env, &.{ "s6-svc", "-O", link }, .quiet);
    var argv: std.ArrayList([]const u8) = .empty;
    if ((try self.statusOf(env, service)).pid) |pid| {
        try argv.appendSlice(gpa, &.{ "env", try std.fmt.allocPrint(gpa, "MAINPID={d}", .{pid}) });
    }
    try argv.appendSlice(gpa, guard.executorPrefix(env.ctx, unit_name));
    try argv.appendSlice(gpa, &.{ policy.executor_path, "--exec", unit_name, "--phase", "stop-main" });
    const res = try runTool(env, argv.items, .inherit);
    if (res.code != 0) env.ctx.diag.warn("{s}: ExecStop= failed", .{service});
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).stopService(env, service);
}

fn runScript(self: *S6, service: []const u8) !?[]const u8 {
    const dir = (try self.serviceDir(service)) orelse return null;
    const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, "run" });
    return guard.readOrAbsent(self.ctx, path, 1 << 20);
}

/// Settings recorded in a generated `run`; none for native services.
fn runFlags(self: *S6, service: []const u8) !native.Flags {
    const content = (try self.runScript(service)) orelse return .{};
    const parsed = marker.parse(content) orelse return .{};
    return native.parseFlags(parsed.rest);
}

/// Unit recorded in the marker of the `run` script, null for native services.
fn generatedUnit(self: *S6, service: []const u8) !?[]const u8 {
    return common.unitOf((try self.runScript(service)) orelse return null);
}

/// `ExecReload=` runs through the executor, which gets the pid `s6-supervise` supervises as
/// `$MAINPID`; a service fake-systemd did not generate gets SIGHUP.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    if (try self.generatedUnit(service)) |unit_name| {
        var argv: std.ArrayList([]const u8) = .empty;
        if ((try self.statusOf(env, service)).pid) |pid| {
            try argv.appendSlice(gpa, &.{ "env", try std.fmt.allocPrint(gpa, "MAINPID={d}", .{pid}) });
        }
        try argv.appendSlice(gpa, guard.executorPrefix(env.ctx, unit_name));
        try argv.appendSlice(gpa, &.{ policy.executor_path, "--exec", unit_name, "--phase", "reload" });
        const res = try runTool(env, argv.items, .inherit);
        if (res.code != 0) return error.CommandFailed;
        return;
    }
    const res = try runTool(env, &.{ "s6-svc", "-h", try self.linkPath(service) }, .quiet);
    if (res.code != 0) {
        reportFailure(env, service, res);
        return error.CommandFailed;
    }
}

/// `s6-svc -s` takes any signal by name or number.
fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const res = try runTool(env, &.{ "s6-svc", "-s", name, try self.linkPath(service) }, .quiet);
    if (res.code != 0) {
        reportFailure(env, service, res);
        return error.CommandFailed;
    }
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    return me(ptr).statusOf(env, service);
}

/// True when `target` is a service directory of the generation directory that has nothing left
/// but what s6 and the generation leave behind, which is what a removed unit looks like.
fn generatedLeftover(self: *S6, target: []const u8) bool {
    const gen = layout.generationDir(self.dirs, .plain);
    const parent = std.fs.path.dirname(target) orelse return false;
    if (!std.mem.eql(u8, parent, gen)) return false;
    return guard.abandonedServiceDir(self.ctx, target);
}

/// `s6-svscan` scans its directory by itself and `s6-supervise` reads `run` at each start, so
/// there is nothing to reload; links to a service directory of the generation directory that
/// holds nothing but leftovers of a removed unit are removed, as generated dependencies are
/// collected without a call to `disable`, and the scan that follows stops the supervisors of
/// removed links.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    if (env.ctx.dry_run) return;
    const dir = self.scanDir();
    const entries = try guard.iterateOrEmpty(self.ctx, dir);
    var removed = false;
    for (entries) |entry| {
        if (entry.kind != .sym_link) continue;
        const link = try std.fs.path.join(env.ctx.gpa, &.{ dir, entry.name });
        if (self.ctx.fs.exists(try std.fs.path.join(env.ctx.gpa, &.{ link, "run" }))) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = self.ctx.fs.readLink(link, &buf) catch continue;
        if (!self.generatedLeftover(target)) continue;
        self.ctx.fs.deleteFile(link) catch |e| {
            env.ctx.diag.warn("cannot remove {s}: {t}", .{ link, e });
            continue;
        };
        removed = true;
    }
    if (removed) self.rescan(env, true);
}

/// `s6-linux-init-hpr` asks the shutdown daemon of s6-linux-init to halt, power off or reboot.
fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const flag = switch (action) {
        .reboot => "-r",
        .poweroff => "-p",
        .halt => "-h",
    };
    const res = try runTool(env, &.{ power_tool, flag }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
    _ = common;
    _ = files;
}
