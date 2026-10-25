// SPDX-License-Identifier: GPL-3.0-or-later
//! dinit backend (§11.2): service description files in dinit's own format, boot enablement
//! through `waits-for.d` links of the boot service, and runtime control through `dinitctl`.
//!
//! Templates are generated per instance as `name-instance`, because dinit reads
//! `name@argument` from one shared file and the index records one file per unit.
//! `dinitctl enable` starts the service at once, which `systemctl enable` never does, so
//! boot enablement writes the same link `dinitctl enable` writes and leaves the daemon alone.
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
const render = @import("dinit/render.zig");
const layout = @import("dinit/layout.zig");
const native = @import("dinit/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Dinit = @This();

pub const backend_name = "dinit";
pub const generator_number = 1;

/// Capabilities declared in §11.2.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .ordering = true,
    .supervision = true,
    .oneshot = true,
    .restart_policy = true,
    .user_services = true,
    .runtime_dir = true,
    .vendor_admin_split = true,
    .parametric_services = true,
};

const native_support: policy.Native = .{
    .forking_pidfile = true,
    .forking_plain = true,
    .environment = true,
    .limits = &render.nativeLimitNames(),
};

const ctl = "dinitctl";
const power_tool = "shutdown";

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// Replaces the check of which services are enabled when the network targets are mapped; for
/// tests.
enabled_override: ?[]const []const u8 = null,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) Dinit {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *Dinit) Backend {
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

fn me(ptr: *anyopaque) *Dinit {
    return @ptrCast(@alignCast(ptr));
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    const gpa = self.ctx.gpa;
    var seen: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    for (try layout.lookupDirs(self.ctx, self.dirs, self.ctx.scope)) |dir| {
        const real = self.ctx.fs.realpath(gpa, dir) catch continue;
        const dup = for (seen.items) |s| {
            if (std.mem.eql(u8, s, real)) break true;
        } else false;
        if (dup) continue;
        try seen.append(gpa, real);
        try out.append(gpa, dir);
    }
    return .{ .dirs = try out.toOwnedSlice(gpa), .extractor = native.extractCommand };
}

fn addScanDir(gpa: Allocator, list: *std.ArrayList(rebuild.ScanDir), path: []const u8, tier: core.Tier) !void {
    for (list.items) |e| if (std.mem.eql(u8, e.path, path)) return;
    try list.append(gpa, .{ .path = path, .tier = tier });
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const d = self.dirs;
    var out: std.ArrayList(rebuild.ScanDir) = .empty;
    switch (scope) {
        .system => {
            for (d.vendor) |v| if (std.mem.startsWith(u8, v, "/usr/local/")) try addScanDir(gpa, &out, v, .vendor);
            if (d.vendor_write) |v| try addScanDir(gpa, &out, v, .vendor);
            for (d.admin) |a| try addScanDir(gpa, &out, a, .admin);
            for (d.runtime) |r| try addScanDir(gpa, &out, r, .runtime);
        },
        .user => {
            for (d.user_vendor) |v| try addScanDir(gpa, &out, v, .vendor);
            for (d.user_admin) |a| try addScanDir(gpa, &out, a, .admin);
            for (d.user) |p| try addScanDir(gpa, &out, try layout.expandHome(self.ctx, p), .personal);
        },
    }
    return out.toOwnedSlice(gpa);
}

// ---- generation -------------------------------------------------------------------------

fn serviceExists(self: *Dinit, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

fn networkService(self: *Dinit, target: []const u8) !?[]const u8 {
    const candidates = if (std.mem.eql(u8, target, "network-online.target"))
        self.dirs.network_online
    else if (std.mem.eql(u8, target, "network.target"))
        self.dirs.network
    else
        return null;
    for (candidates) |c| if (try self.serviceExists(c)) return c;
    return null;
}

/// dinit name of the service a dependency refers to, or null when dinit would reject the
/// dependency: targets other than the network ones, other unit types, and units that are neither
/// a dinit service nor a systemd unit that can be translated. A unit the pipeline already resolved (`resolutions`) takes
/// its answer from there.
fn mapDependency(self: *Dinit, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
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

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

fn mapList(self: *Dinit, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, exclude: []const []const []const u8, out: *std.ArrayList([]const u8)) !void {
    outer: for (deps) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        for (exclude) |ex| if (contains(ex, mapped)) continue :outer;
        if (!contains(out.items, mapped)) try out.append(self.ctx.gpa, mapped);
    }
}

fn mapDependencies(self: *Dinit, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) !render.Deps {
    var needs: std.ArrayList([]const u8) = .empty;
    var wants: std.ArrayList([]const u8) = .empty;
    var after: std.ArrayList([]const u8) = .empty;
    var before: std.ArrayList([]const u8) = .empty;
    try self.mapList(own, resolutions, u.requires, &.{}, &needs);
    try self.mapList(own, resolutions, u.binds_to, &.{}, &needs);
    try self.mapList(own, resolutions, u.wants, &.{needs.items}, &wants);
    if (network.mentions(u)) {
        for (try network.enabledProviders(self.ctx.gpa, self.dirs.network_providers, own, self.enabledLookup())) |p| {
            if (!contains(needs.items, p) and !contains(wants.items, p)) try wants.append(self.ctx.gpa, p);
        }
    }
    try self.mapList(own, resolutions, u.after, &.{ needs.items, wants.items }, &after);
    try self.mapList(own, resolutions, u.before, &.{}, &before);
    return .{ .depends_on = needs.items, .waits_for = wants.items, .after = after.items, .before = before.items };
}

fn accountKnown(self: *Dinit, file: []const u8, account: []const u8) bool {
    if (account.len > 0 and std.ascii.isDigit(account[0])) return true;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, file, 1 << 20) catch return false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], account)) return true;
    }
    return false;
}

/// User dinit switches to. With the executor, an account the static binary can resolve from
/// `/etc/passwd` and `/etc/group` is left to it; anything else is switched by dinit through the
/// system libc, and the executor then runs with the final identity.
fn runAs(self: *Dinit, u: *const model.Unit, use_executor: bool) ?[]const u8 {
    if (u.scope == .user) return null;
    const user = u.user orelse return null;
    if (!use_executor) return user;
    if (!self.accountKnown("/etc/passwd", user)) return user;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return user;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return user;
    return null;
}

const command_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };

/// Words of `cmd` with a bare program name resolved against the standard directories.
fn commandWords(self: *Dinit, cmd: model.Command) ![]const []const u8 {
    const gpa = self.ctx.gpa;
    const words = try gpa.dupe([]const u8, cmd.words);
    const prog = words[0];
    if (std.mem.findScalar(u8, prog, '/') == null) {
        for (command_dirs) |dir| {
            const path = try std.fs.path.join(gpa, &.{ dir, prog });
            if (self.ctx.fs.exists(path)) {
                words[0] = path;
                break;
            }
        }
    }
    return words;
}

fn serviceKind(u: *const model.Unit, use_executor: bool) render.Kind {
    return switch (u.service_type) {
        .oneshot => .scripted,
        .forking => if (use_executor) .process else if (u.pid_file != null) .bgprocess else .scripted,
        else => .process,
    };
}

fn notesFor(gpa: Allocator, u: *const model.Unit) ![]const []const u8 {
    var notes: std.ArrayList([]const u8) = .empty;
    if (u.service_type == .forking and u.pid_file == null and policy.executorReason(u.*, capabilities, native_support) == null) {
        try notes.append(gpa, "Type=forking without PIDFile=: the daemon is started but not supervised");
    }
    if (u.restart == .@"on-success") try notes.append(gpa, "Restart=on-success is approximated by restart = true");
    if (u.kill_mode == .none or u.kill_mode == .mixed) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "KillMode={t} is handled like control-group", .{u.kill_mode}));
    }
    return notes.toOwnedSlice(gpa);
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    const svc = try layout.serviceName(gpa, u.name);

    const reason = policy.executorReason(u.*, capabilities, native_support);
    const use_executor = reason != null and reason.? != .no_command;
    const kind = serviceKind(u, use_executor);

    var command: render.Command = .executor;
    if (!use_executor) {
        command = .{ .native = if (u.exec_start.len == 0) &.{"/bin/true"} else try self.commandWords(u.exec_start[0]) };
    }
    var stop_cmd: render.Stop = .none;
    if (policy.plainStopCommand(u.*)) {
        stop_cmd = .{ .native = try self.commandWords(u.exec_stop[0]) };
    } else if (policy.needsStopHook(u.*)) {
        stop_cmd = .executor;
    }

    const body_input: render.Input = .{
        .unit = u,
        .kind = kind,
        .command = command,
        .stop = stop_cmd,
        .executor_path = policy.executor_path,
        .run_as = self.runAs(u, use_executor),
        .deps = try self.mapDependencies(svc, u, input.deps),
        .log_file = try std.fs.path.join(gpa, &.{ logpath.logDir(self.ctx, u.name.full), "current" }),
        .notes = try notesFor(gpa, u),
    };
    const body = try render.renderAlloc(gpa, body_input);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);

    const dir = try layout.generationDir(self.ctx, self.dirs, u.scope, input.tier, input.source);
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    files[0] = .{ .path = try std.fs.path.join(gpa, &.{ dir, svc }), .content = content };
    return .{ .service_name = svc, .files = files };
}

// ---- enablement -------------------------------------------------------------------------

fn linkPath(self: *Dinit, service: []const u8) ![]const u8 {
    return std.fs.path.join(self.ctx.gpa, &.{ try layout.bootDir(self.ctx, self.dirs), service });
}

/// What `dinitctl enable` writes: a relative link when the service sits next to the boot
/// directory, otherwise the path of the service file.
fn linkTarget(self: *Dinit, service: []const u8) ![]const u8 {
    const gpa = self.ctx.gpa;
    const boot = try layout.bootDir(self.ctx, self.dirs);
    const parent = std.fs.path.dirname(boot) orelse "/";
    const found = try layout.locate(self.ctx, self.dirs, service);
    if (found == null or std.mem.eql(u8, std.fs.path.dirname(found.?) orelse "", parent)) {
        return std.fmt.allocPrint(gpa, "../{s}", .{service});
    }
    return found.?;
}

fn linked(self: *Dinit, link: []const u8) bool {
    _ = self.ctx.fs.lstat(link) catch return false;
    return true;
}

/// The log directories of a service and of the services it pulls in have to exist before dinit
/// opens their log files.
fn ensureLogDir(self: *Dinit, env: Env, service: []const u8) void {
    if (env.ctx.dry_run) return;
    self.ensureLogDirDepth(service, 0);
}

const max_dependency_depth = 16;

fn ensureLogDirDepth(self: *Dinit, service: []const u8, depth: usize) void {
    if (depth > max_dependency_depth) return;
    const path = (layout.locate(self.ctx, self.dirs, service) catch return) orelse return;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 20) catch return;
    const parsed = marker.parse(content) orelse return;
    const dir = logpath.logDir(self.ctx, parsed.marker.unit);
    self.ctx.fs.makePath(dir) catch |e| self.ctx.diag.warn("cannot create log directory {s}: {t}", .{ dir, e });
    for ([_][]const u8{ "depends-on", "waits-for" }) |key| {
        var lines = std.mem.splitScalar(u8, parsed.rest, '\n');
        while (lines.next()) |line| {
            const value = native.settingValue(line, key) orelse continue;
            self.ensureLogDirDepth(value, depth + 1);
        }
    }
}

fn ctlArgv(env: Env, tail: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, ctl);
    if (env.ctx.scope == .user) try argv.append(env.ctx.gpa, "--user");
    try argv.appendSlice(env.ctx.gpa, tail);
    return argv.items;
}

fn runCtl(env: Env, tail: []const []const u8, stdio: @import("runner.zig").Stdio) !@import("runner.zig").Result {
    return env.runner.run(env.ctx.gpa, try ctlArgv(env, tail), stdio);
}

fn mustRun(env: Env, tail: []const []const u8) anyerror!void {
    const res = try runCtl(env, tail, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, opts: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    const boot = self.dirs.boot_target orelse "boot";
    if (opts.runtime) {
        if (env.online) {
            try mustRun(env, &.{ "--quiet", "add-dep", "waits-for", boot, service });
            return &.{};
        }
        env.ctx.diag.warn("{s}: init is not running, enabling persistently instead of --runtime", .{service});
    }
    const link = try self.linkPath(service);
    if (self.linked(link)) return &.{};
    const change: interface.Change = .{ .created = .{ .link = link, .target = try self.linkTarget(service) } };
    if (!env.ctx.dry_run) {
        try self.ctx.fs.makePath(std.fs.path.dirname(link) orelse "/");
        try self.ctx.fs.symLink(change.created.target, link);
        self.ensureLogDir(env, service);
    }
    const changes = try gpa.alloc(interface.Change, 1);
    changes[0] = change;
    return changes;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, opts: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    const boot = self.dirs.boot_target orelse "boot";
    if (opts.runtime and env.online) {
        try mustRun(env, &.{ "--quiet", "rm-dep", "waits-for", boot, service });
        return &.{};
    }
    const link = try self.linkPath(service);
    if (!self.linked(link)) return &.{};
    if (!env.ctx.dry_run) try self.ctx.fs.deleteFile(link);
    const changes = try gpa.alloc(interface.Change, 1);
    changes[0] = .{ .removed = link };
    return changes;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    return if (self.linked(try self.linkPath(service))) .enabled else .disabled;
}

fn serviceEnabled(ptr: *anyopaque, service: []const u8) bool {
    const self = me(ptr);
    const link = self.linkPath(service) catch return false;
    return self.linked(link);
}

fn enabledLookup(self: *Dinit) network.Enabled {
    return .{ .ptr = self, .is_enabled = serviceEnabled, .injected = self.enabled_override };
}

// ---- runtime control --------------------------------------------------------------------

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    me(ptr).ensureLogDir(env, service);
    try mustRun(env, &.{ "--quiet", "start", service });
}

fn stop(_: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try mustRun(env, &.{ "--quiet", "stop", "--force", service });
}

/// `dinitctl restart` refuses a service that is not started, which `systemctl restart` starts.
fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    me(ptr).ensureLogDir(env, service);
    if (!env.ctx.dry_run) {
        const probe = try runCtl(env, &.{ "--quiet", "is-started", service }, .capture);
        if (probe.code != 0) return mustRun(env, &.{ "--quiet", "start", service });
    }
    try mustRun(env, &.{ "--quiet", "restart", service });
}

/// dinit has no reload action: the commands of `ExecReload=` run through the executor.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    const unit_name = self.generatedUnit(service) orelse {
        env.ctx.diag.err("{s}: not generated by fake-systemd and dinit has no reload action; use 'kill --signal=' instead", .{service});
        return error.Unsupported;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ policy.executor_path, "--exec", unit_name });
    if (env.ctx.scope == .user) try argv.append(gpa, "--user");
    try argv.appendSlice(gpa, &.{ "--phase", "reload" });
    const res = try env.runner.run(gpa, argv.items, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// Unit recorded in the marker of the service file, null for native services.
fn generatedUnit(self: *Dinit, service: []const u8) ?[]const u8 {
    const path = (layout.locate(self.ctx, self.dirs, service) catch return null) orelse return null;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 20) catch return null;
    const parsed = marker.parse(content) orelse return null;
    return parsed.marker.unit;
}

fn kill(_: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    try mustRun(env, &.{ "signal", name, service });
}

fn status(_: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const res = try runCtl(env, &.{ "status", service }, .capture);
    if (res.code != 0) return .{ .state = .inactive };
    return native.parseStatus(res.stdout);
}

/// Reloads the description of every loaded service that fake-systemd generated.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    const listing = try runCtl(env, &.{"list"}, .capture);
    if (listing.code != 0) return error.CommandFailed;
    for (try native.parseList(env.ctx.gpa, listing.stdout)) |service| {
        if (self.generatedUnit(service) == null) continue;
        const res = try runCtl(env, &.{ "--quiet", "reload", service }, .inherit);
        if (res.code != 0) env.ctx.diag.warn("{s}: dinit could not reload the service description", .{service});
    }
}

fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const flag = switch (action) {
        .reboot => "-r",
        .poweroff => "-p",
        .halt => "-h",
    };
    const res = try env.runner.run(env.ctx.gpa, &.{ power_tool, flag }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = policy;
    _ = render;
    _ = layout;
    _ = native;
}
