// SPDX-License-Identifier: GPL-3.0-or-later
//! 66 backend (§11.3), the service manager of Obarun: a service is a frontend file in 66's own
//! INI format, `66 enable` parses it into a tree, and `66 start`, `66 stop` and `66 status`
//! control it under a supervision tree (the scandir).
//!
//! 66 keeps what it parsed in constant databases under its working directory, so enabling and
//! disabling run `66` itself, on a running system or offline in the real root; inside a
//! `--root` tree nothing can run it and the operations are refused. The enabled state is read
//! from the resolve file instead of asking `66`. Every service runs through the executor, which
//! applies the settings of the unit and feeds the uniform logger: 66's own logger is turned
//! off, since the pipe it writes to cannot be read by another program. Dependencies are
//! `Depends`, which 66 starts first and stops last, so `Wants=` is expressed like `Requires=`.
//!
//! `enable -P` and `disable -P` act on the named service only: without it 66 enables the
//! dependencies together with the service and disables the services that depend on it. A
//! dependency that is not enabled is still started with the service that needs it.
//!
//! A frontend file that was regenerated is parsed again before the service starts, because 66
//! runs what it parsed. Parsing again resets the enabled state, so it is set again afterwards.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const profile = @import("../detect/profile.zig");
const model = @import("../unit/model.zig");
const name_mod = @import("../unit/name.zig");
const resolve = @import("../unit/resolve.zig");
const marker = @import("../index/marker.zig");
const rebuild = @import("../index/rebuild.zig");
const apply = @import("../reconcile/apply.zig");
const logpath = @import("../exec/logpath.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const network = @import("network.zig");
const runner = @import("runner.zig");
const shell = @import("shell.zig");
const render = @import("s66/render.zig");
const layout = @import("s66/layout.zig");
const native = @import("s66/native.zig");
const cdb = @import("s66/cdb.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const S66 = @This();

pub const backend_name = "66";
pub const generator_number = 1;

/// Capabilities of §11.3. `soft_deps` is off: 66 has one kind of dependency. A user has a
/// supervision tree of their own, which a session starts.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .supervision = true,
    .oneshot = true,
    .restart_policy = true,
    .user_services = true,
    .vendor_admin_split = true,
};

const ctl = "66";
const command_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };
/// Services a service depends on that are followed when frontend files are parsed again.
const max_dependency_depth = 16;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// Replaces the check that the root is the real one, where `66` can reach its files; for tests.
run_here: ?bool = null,
/// Replaces the check of which services are enabled when the network targets are mapped; for
/// tests.
enabled_override: ?[]const []const u8 = null,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) S66 {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *S66) Backend {
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
    .service_of_file = layout.serviceOfFile,
};

fn me(ptr: *anyopaque) *S66 {
    return @ptrCast(@alignCast(ptr));
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = try layout.lookupDirs(self.ctx, self.dirs, self.ctx.scope),
        .extractor = native.extractCommand,
    };
}

fn addScanDir(gpa: Allocator, out: *std.ArrayList(rebuild.ScanDir), path: []const u8, tier: core.Tier) Allocator.Error!void {
    for (out.items) |d| if (std.mem.eql(u8, d.path, path)) return;
    try out.append(gpa, .{ .path = path, .tier = tier });
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const d = self.dirs;
    var out: std.ArrayList(rebuild.ScanDir) = .empty;
    switch (scope) {
        .system => {
            for (d.vendor) |v| try addScanDir(gpa, &out, v, .vendor);
            for (d.admin) |a| try addScanDir(gpa, &out, a, .admin);
        },
        .user => {
            for (d.user_vendor) |v| try addScanDir(gpa, &out, v, .vendor);
            for (d.user_admin) |a| try addScanDir(gpa, &out, a, .admin);
            for (d.user) |p| try addScanDir(gpa, &out, try layout.expandHome(self.ctx, p), .personal);
        },
    }
    return out.toOwnedSlice(gpa);
}

// ---- state kept by 66 ---------------------------------------------------------------------

/// True when the tools can reach the files they work on: the root is the real one.
fn canRun(self: *S66) bool {
    return self.run_here orelse self.ctx.fs.host_root;
}

fn parsed(self: *S66, service: []const u8) bool {
    const link = layout.parsedLink(self.ctx, service) catch return false;
    _ = self.ctx.fs.lstat(link) catch return false;
    return true;
}

fn readResolve(self: *S66, service: []const u8) ?[]const u8 {
    const path = layout.resolvePath(self.ctx, service) catch return null;
    return self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 20) catch null;
}

fn enabledNow(self: *S66, service: []const u8) bool {
    const data = self.readResolve(service) orelse return false;
    return (cdb.number(data, "enabled") orelse 0) != 0;
}

fn serviceEnabled(ptr: *anyopaque, service: []const u8) bool {
    return me(ptr).enabledNow(service);
}

fn enabledLookup(self: *S66) network.Enabled {
    return .{ .ptr = self, .is_enabled = serviceEnabled, .injected = self.enabled_override };
}

fn frontendText(self: *S66, service: []const u8) ?[]const u8 {
    const path = (layout.locate(self.ctx, self.dirs, service) catch return null) orelse return null;
    return self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 20) catch null;
}

/// True when the frontend file is newer than what 66 parsed from it.
fn isStale(self: *S66, service: []const u8) bool {
    const path = (layout.locate(self.ctx, self.dirs, service) catch return false) orelse return false;
    const front = self.ctx.fs.stat(path) catch return false;
    const resolve_path = layout.resolvePath(self.ctx, service) catch return false;
    const parsed_at = self.ctx.fs.stat(resolve_path) catch return false;
    return front.mtime_ns > parsed_at.mtime_ns;
}

/// Settings recorded in the frontend file of `service`; a service fake-systemd did not generate
/// holds its state when it is done, as 66 says.
fn flagsOf(self: *S66, service: []const u8) render.Flags {
    const text = self.frontendText(service) orelse return .{ .remain = true };
    const parsed_file = marker.parse(text) orelse return .{ .remain = true };
    return native.parseFlags(parsed_file.rest);
}

/// Unit recorded in the marker of the frontend file, null for services fake-systemd did not generate.
fn generatedUnit(self: *S66, service: []const u8) ?[]const u8 {
    const text = self.frontendText(service) orelse return null;
    const parsed_file = marker.parse(text) orelse return null;
    return parsed_file.marker.unit;
}

// ---- generation -------------------------------------------------------------------------

fn serviceExists(self: *S66, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

fn networkService(self: *S66, target: []const u8) !?[]const u8 {
    const candidates = if (std.mem.eql(u8, target, "network-online.target"))
        self.dirs.network_online
    else if (std.mem.eql(u8, target, "network.target"))
        self.dirs.network
    else
        return null;
    for (candidates) |c| if (try self.serviceExists(c)) return c;
    return null;
}

/// 66 name of the service a dependency refers to, or null when it cannot be a service: targets
/// (except the network ones), other unit types, and units that are neither a 66 service nor a
/// systemd unit that can be translated.
fn mapDependency(self: *S66, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
    const gpa = self.ctx.gpa;
    const n = name_mod.parse(gpa, dep) catch return null;
    switch (n.kind) {
        .target => return self.networkService(n.full),
        .service => {},
        else => return null,
    }
    for (resolutions) |r| if (std.mem.eql(u8, r.unit, n.full)) return r.service;
    if (n.isTemplate() or std.mem.startsWith(u8, n.prefix, "systemd-")) return null;
    const svc = try layout.serviceName(gpa, n);
    if (std.mem.eql(u8, svc, own)) return null;
    if (try self.serviceExists(svc)) return svc;
    const resolved = resolve.resolve(gpa, self.ctx.fs.*, .{ .scope = self.ctx.scope, .xdg_config_home = self.ctx.xdg_config_home }, n) catch return null;
    return if (resolved.state == .found) svc else null;
}

fn mapList(self: *S66, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    for (deps) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        if (!contains(out.items, mapped)) try out.append(self.ctx.gpa, mapped);
    }
}

/// Services the unit depends on: those it requires or wants, and the enabled network providers
/// when it mentions a network target.
fn dependencies(self: *S66, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try self.mapList(own, resolutions, u.requires, &out);
    try self.mapList(own, resolutions, u.binds_to, &out);
    try self.mapList(own, resolutions, u.wants, &out);
    if (u.scope == .system and network.mentions(u)) {
        for (try network.enabledProviders(self.ctx.gpa, self.dirs.network_providers, own, self.enabledLookup())) |p| {
            if (!contains(out.items, p)) try out.append(self.ctx.gpa, p);
        }
    }
    return out.toOwnedSlice(self.ctx.gpa);
}

fn accountKnown(self: *S66, file: []const u8, account: []const u8) bool {
    if (account.len > 0 and std.ascii.isDigit(account[0])) return true;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, file, 1 << 20) catch return false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], account)) return true;
    }
    return false;
}

/// True when the static executor can switch to the unit's user and groups from `/etc/passwd`
/// and `/etc/group`; it then applies the user's supplementary groups as `initgroups` does.
fn executorResolves(self: *S66, u: *const model.Unit) bool {
    if (u.scope == .user) return false;
    const user = u.user orelse return false;
    if (!self.accountKnown("/etc/passwd", user)) return false;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
    return true;
}

fn findProgram(self: *S66, name: []const u8) !?[]const u8 {
    for (command_dirs) |dir| {
        const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, name });
        if (self.ctx.fs.exists(path)) return path;
    }
    return null;
}

fn resolveProgram(self: *S66, name: []const u8, fallback: []const u8) ![]const u8 {
    return (try self.findProgram(name)) orelse fallback;
}

/// How the start script switches to an account the executor cannot resolve (LDAP, sssd).
/// `setpriv` resolves the user through the system libc and `--init-groups` applies its groups;
/// without it `execl-runas`, which 66 ships, applies the groups of the account but not a
/// `Group=` or `SupplementaryGroups=` the unit adds. 66's own `RunAs` keeps the groups of root.
fn identityFor(self: *S66, u: *const model.Unit) !?render.Identity {
    if (u.scope == .user) return null;
    const user = u.user orelse return null;
    if (self.executorResolves(u)) return null;
    var plain = shell.plainAccount(user);
    if (u.group) |g| plain = plain and shell.plainAccount(g);
    for (u.supplementary_groups) |g| plain = plain and shell.plainAccount(g);
    if (!plain) {
        self.ctx.diag.err("{s}: User=, Group= and SupplementaryGroups= must be plain names to be switched by the system libc", .{u.name.full});
        return error.Unsupported;
    }
    if ((try self.findProgram("setpriv")) != null) {
        return .{ .setpriv = .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups } };
    }
    if (u.group != null or u.supplementary_groups.len > 0) {
        self.ctx.diag.warn("{s}: setpriv is not installed, execl-runas switches to {s} with its own groups only", .{ u.name.full, user });
    }
    return .{ .runas = user };
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    const svc = try layout.serviceName(gpa, u.name);
    const in: render.Input = .{
        .unit = u,
        .service = svc,
        .depends = try self.dependencies(svc, u, input.deps),
        .identity = try self.identityFor(u),
        .executor_path = policy.executor_path,
        .setpriv_path = try self.resolveProgram("setpriv", "/usr/bin/setpriv"),
        .runas_path = try self.resolveProgram("execl-runas", "/usr/bin/execl-runas"),
        .ctl_path = try self.resolveProgram(ctl, "/usr/bin/66"),
        .log_dir = logpath.logDir(self.ctx, u.name.full),
    };
    const body = try render.frontend(gpa, in);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);
    const dir = try layout.generationDir(self.ctx, self.dirs, u.scope, input.tier);
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    files[0] = .{ .path = try std.fs.path.join(gpa, &.{ dir, svc }), .content = content, .mode = 0o644 };
    return .{ .service_name = svc, .files = files };
}

// ---- running 66 ---------------------------------------------------------------------------

fn run66(env: Env, tree: ?[]const u8, args: []const []const u8, stdio: runner.Stdio) !runner.Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, ctl);
    if (tree) |t| try argv.appendSlice(env.ctx.gpa, &.{ "-t", t });
    try argv.appendSlice(env.ctx.gpa, args);
    return env.runner.run(env.ctx.gpa, argv.items, stdio);
}

fn failed(env: Env, service: []const u8, what: []const u8, res: runner.Result) error{CommandFailed} {
    const text = std.mem.trim(u8, res.stdout, " \t\r\n");
    env.ctx.diag.err("{s}: {s} exited {d}{s}{s}", .{ service, what, res.code, if (text.len > 0) ": " else "", text });
    return error.CommandFailed;
}

fn refuseInRoot(self: *S66, env: Env, service: []const u8, what: []const u8) error{Unsupported} {
    _ = self;
    env.ctx.diag.err("{s}: {s} needs 66, which keeps its state under /var/lib/66 and cannot run inside a --root tree; run it on the target", .{ service, what });
    return error.Unsupported;
}

/// Parses `service` again when its frontend file is newer than what 66 parsed, and enables it
/// again if it was enabled and `keep_enabled` says so. Does nothing for a service that was never
/// parsed, or whose frontend fake-systemd did not generate.
fn refresh(self: *S66, env: Env, service: []const u8, keep_enabled: bool) !void {
    if (env.ctx.dry_run or !self.parsed(service)) return;
    if (self.generatedUnit(service) == null or !self.isStale(service)) return;
    const was_enabled = self.enabledNow(service);
    var res = try run66(env, null, &.{ "parse", "-f", service }, .quiet);
    if (res.code != 0) return failed(env, service, "66 parse", res);
    if (!was_enabled or !keep_enabled) return;
    res = try run66(env, self.dirs.boot_target, &.{ "enable", "-P", service }, .quiet);
    if (res.code != 0) return failed(env, service, "66 enable", res);
}

fn refreshWithDependencies(self: *S66, env: Env, service: []const u8, depth: usize) !void {
    if (depth > max_dependency_depth) return;
    if (self.frontendText(service)) |text| {
        for (try native.dependsOf(env.ctx.gpa, text)) |dep| try self.refreshWithDependencies(env, dep, depth + 1);
    }
    try self.refresh(env, service, true);
}

// ---- enablement -------------------------------------------------------------------------

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    if (!self.canRun() and !env.ctx.dry_run) return self.refuseInRoot(env, service, "enable");
    // A dry run has not written the frontend file yet.
    if (!env.ctx.dry_run and !(try self.serviceExists(service))) {
        env.ctx.diag.err("{s}: no frontend file found", .{service});
        return error.Unsupported;
    }
    if (self.enabledNow(service) and !self.isStale(service)) return &.{};
    try self.refresh(env, service, false);
    const res = try run66(env, self.dirs.boot_target, &.{ "enable", "-P", service }, .quiet);
    if (res.code != 0) return failed(env, service, "66 enable", res);
    const changes = try env.ctx.gpa.alloc(interface.Change, 1);
    changes[0] = .{ .created_file = try layout.resolvePath(self.ctx, service) };
    return changes;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    if (!self.canRun() and !env.ctx.dry_run) return self.refuseInRoot(env, service, "disable");
    if (!env.ctx.dry_run and !self.enabledNow(service)) return &.{};
    const res = try run66(env, null, &.{ "disable", "-P", service }, .quiet);
    if (res.code != 0) return failed(env, service, "66 disable", res);
    return &.{};
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    return if (self.parsed(service) and self.enabledNow(service)) .enabled else .disabled;
}

// ---- runtime control --------------------------------------------------------------------

fn runstateOf(self: *S66, env: Env, service: []const u8) !?native.Runstate {
    if (!self.parsed(service)) return null;
    const res = try run66(env, null, &.{ "runstate", "-nf", native.runstate_fields, service }, .quiet);
    if (res.code != 0) return null;
    return native.parseRunstate(res.stdout);
}

fn statusOf(self: *S66, env: Env, service: []const u8) !interface.Status {
    const rs = (try self.runstateOf(env, service)) orelse return .{ .state = .inactive };
    return native.normalize(rs, self.flagsOf(service));
}

fn begin(self: *S66, env: Env, service: []const u8) !void {
    try self.refreshWithDependencies(env, service, 0);
    const res = try run66(env, self.dirs.boot_target, &.{ "start", service }, .quiet);
    if (res.code != 0) return failed(env, service, "66 start", res);
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).begin(env, service);
}

fn stillRunning(rs: native.Runstate, flags: render.Flags) bool {
    return switch (rs.state) {
        .up, .starting, .restarting => true,
        .down => rs.who == .self and flags.restarts,
        else => false,
    };
}

/// Directories `66-svctl`, which 66 keeps out of the search path, is installed in.
const svctl_candidates = [_][]const u8{ "/usr/libexec/66-svctl", "/usr/local/libexec/66-svctl", "/usr/lib/66/66-svctl", "/usr/lib/66-svctl" };

fn svctlPath(self: *S66) []const u8 {
    for (svctl_candidates) |path| if (self.ctx.fs.exists(path)) return path;
    return "66-svctl";
}

/// Brings a service that 66 starts again down for good. `66 stop` does nothing while the service
/// is between two runs and `66 signal` does nothing to a service that is up, so the supervisor
/// is asked through its control fifo, in the live directory `66 resolve` names.
fn holdDown(self: *S66, env: Env, service: []const u8) !void {
    const found = try run66(env, null, &.{ "resolve", "-nf", "live_servicedir", service }, .quiet);
    const dir = std.mem.trim(u8, found.stdout, " \t\r\n");
    if (found.code != 0 or dir.len == 0) return failed(env, service, "66 resolve", found);
    const res = try env.runner.run(env.ctx.gpa, &.{ self.svctlPath(), "-D", "-w", "d", "-T", "30000", "--", dir }, .quiet);
    if (res.code != 0) return failed(env, service, "66-svctl", res);
}

/// `66 stop`, then a service that is still wanted up is brought down for good; a failed service
/// is forgotten, as `stop` of a failed unit leaves it inactive.
fn stopService(self: *S66, env: Env, service: []const u8) !void {
    if (!self.parsed(service) and !env.ctx.dry_run) return;
    var res = try run66(env, null, &.{ "stop", service }, .quiet);
    if (res.code != 0) return failed(env, service, "66 stop", res);
    if (env.ctx.dry_run) return;
    const flags = self.flagsOf(service);
    var rs = (try self.runstateOf(env, service)) orelse return;
    if (stillRunning(rs, flags)) {
        try self.holdDown(env, service);
        rs = (try self.runstateOf(env, service)) orelse return;
    }
    if (native.normalize(rs, flags).state == .failed) {
        res = try run66(env, null, &.{ "free", "-P", service }, .quiet);
        if (res.code != 0) return failed(env, service, "66 free", res);
    }
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).stopService(env, service);
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.stopService(env, service);
    try self.begin(env, service);
}

/// Sends `signal` to the process 66 supervises: `66 signal` and `66 reload` do not reach a
/// service that is up.
fn signalMain(self: *S66, env: Env, service: []const u8, signal: []const u8) !void {
    const pid = (try self.statusOf(env, service)).pid orelse {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const pid_text = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{pid});
    const res = try env.runner.run(env.ctx.gpa, &.{ "kill", "-s", name, pid_text }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// `ExecReload=` runs through the executor, which gets the pid 66 supervises as `$MAINPID`; a
/// service fake-systemd did not generate gets SIGHUP.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    const unit_name = self.generatedUnit(service) orelse return self.signalMain(env, service, "HUP");
    var argv: std.ArrayList([]const u8) = .empty;
    if ((try self.statusOf(env, service)).pid) |pid| {
        try argv.appendSlice(gpa, &.{ "env", try std.fmt.allocPrint(gpa, "MAINPID={d}", .{pid}) });
    }
    try argv.appendSlice(gpa, &.{ policy.executor_path, "--exec", unit_name });
    if (env.ctx.scope == .user) try argv.append(gpa, "--user");
    try argv.appendSlice(gpa, &.{ "--phase", "reload" });
    const res = try env.runner.run(gpa, argv.items, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    try me(ptr).signalMain(env, service, signal);
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    return me(ptr).statusOf(env, service);
}

/// Parses again the generated services whose frontend file changed, so that the next boot runs
/// the new definition, and removes what 66 parsed from a frontend file that is gone. A service
/// that runs keeps running.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    if (env.ctx.dry_run or !self.canRun()) return;
    const gpa = env.ctx.gpa;
    const links = try std.fs.path.join(gpa, &.{ try layout.stateRoot(self.ctx), ".resolve", "service" });
    const entries = self.ctx.fs.iterateDir(gpa, links) catch return;
    const lookup = try layout.lookupDirs(self.ctx, self.dirs, self.ctx.scope);
    for (entries) |entry| {
        const service = entry.name;
        if (self.generatedUnit(service) != null) {
            self.refresh(env, service, true) catch |e| env.ctx.diag.warn("{s}: cannot parse it again: {t}", .{ service, e });
            continue;
        }
        const data = self.readResolve(service) orelse continue;
        const frontend = cdb.string(data, "frontend") orelse continue;
        const ours = for (lookup) |d| {
            if (std.mem.startsWith(u8, frontend, d) and frontend.len > d.len and frontend[d.len] == '/') break true;
        } else false;
        if (!ours or self.ctx.fs.exists(frontend)) continue;
        const res = try run66(env, null, &.{ "remove", "-P", service }, .quiet);
        if (res.code != 0) env.ctx.diag.warn("{s}: 66 remove exited {d}", .{ service, res.code });
    }
}

fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const verb = switch (action) {
        .reboot => "reboot",
        .poweroff => "poweroff",
        .halt => "halt",
    };
    const res = try run66(env, null, &.{verb}, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
    _ = cdb;
}
