// SPDX-License-Identifier: GPL-3.0-or-later
//! finit backend (§11.3): a service is a stanza in `/etc/finit.d/available/<name>.conf`, boot
//! enablement is a link in `/etc/finit.d/enabled`, and `initctl` controls the running init.
//!
//! The command of every stanza is the executor, which logs to the uniform location and applies
//! the unit settings; finit supervises it and restarts it by its own policy. Finit loads a
//! service only from a file it read at a reload, so a service that is started without being
//! enabled is loaded through a link in `/run/finit/system`, which `stop` removes again. Finit
//! has no soft dependencies and does not order without depending: `Requires=` becomes a start
//! condition, and enabling a service also enables the services its conditions name.
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
const executor = @import("../exec/executor.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const runner = @import("runner.zig");
const shell = @import("shell.zig");
const render = @import("finit/render.zig");
const layout = @import("finit/layout.zig");
const native = @import("finit/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Finit = @This();

pub const backend_name = "finit";
pub const generator_number = 1;

/// Capabilities of §11.3. Conditions are the only dependency finit has: a service waits for
/// the state of another and stops when it leaves it.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .supervision = true,
    .oneshot = true,
    .restart_policy = true,
};

const ctl = "initctl";
const network_online_condition = "net/route/default";
/// Milliseconds `initctl start` is followed until the service stops activating.
pub const default_start_wait_ms = 15_000;
/// Longest wait for a service to leave `running`: the kill delay finit allows, plus a margin.
pub const default_stop_wait_ms = 65_000;
pub const default_oneshot_wait_ms = 90_000;
const poll_ms = 100;
const max_pull_depth = 8;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// Milliseconds to follow a start, a stop and a oneshot; tests shorten them.
start_wait_ms: u64 = default_start_wait_ms,
stop_wait_ms: u64 = default_stop_wait_ms,
oneshot_wait_ms: u64 = default_oneshot_wait_ms,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) Finit {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *Finit) Backend {
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

fn me(ptr: *anyopaque) *Finit {
    return @ptrCast(@alignCast(ptr));
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    const dirs = try self.ctx.gpa.alloc([]const u8, 2);
    dirs[0] = try layout.availableDir(self.ctx.gpa, self.dirs);
    dirs[1] = layout.rcsd(self.dirs);
    return .{ .dirs = if (self.ctx.scope == .user) &.{} else dirs, .extractor = native.extractCommand, .strip_suffix = layout.conf_suffix };
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    if (scope == .user) return &.{};
    const dirs = try gpa.alloc(rebuild.ScanDir, 1);
    dirs[0] = .{ .path = try layout.availableDir(gpa, self.dirs), .tier = .admin };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

fn serviceExists(self: *Finit, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

/// finit name of the service a dependency refers to, or null when it cannot be a service:
/// targets, other unit types, and units that are neither a finit service nor a systemd unit
/// that can be translated.
fn mapDependency(self: *Finit, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
    const gpa = self.ctx.gpa;
    const n = name_mod.parse(gpa, dep) catch return null;
    if (n.kind != .service) return null;
    for (resolutions) |r| if (std.mem.eql(u8, r.unit, n.full)) return r.service;
    if (n.isTemplate() or std.mem.startsWith(u8, n.prefix, "systemd-")) return null;
    const svc = try layout.serviceName(gpa, n);
    if (std.mem.eql(u8, svc, own)) return null;
    if (try self.serviceExists(svc)) return svc;
    const resolved = resolve.resolve(gpa, self.ctx.fs.*, .{ .scope = self.ctx.scope, .xdg_config_home = self.ctx.xdg_config_home }, n) catch return null;
    return if (resolved.state == .found) svc else null;
}

fn readConf(self: *Finit, service: []const u8) !?[]const u8 {
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    return guard.readOrAbsent(self.ctx, path, 1 << 20);
}

/// Identity `initctl` takes for `service`: the generated name, or what a native file declares.
fn identityOf(self: *Finit, service: []const u8) ![]const u8 {
    const content = (try self.readConf(service)) orelse return service;
    if (marker.parse(content) != null) return service;
    return (try native.identityOf(self.ctx.gpa, content)) orelse service;
}

/// Start condition that waits for `service`: its end for a task, its running state otherwise.
fn conditionFor(self: *Finit, service: []const u8) ![]const u8 {
    const gpa = self.ctx.gpa;
    const ident = try self.identityOf(service);
    const kind = if (try self.readConf(service)) |c| (try native.kindOf(gpa, c)) orelse "service" else "service";
    if (std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "run")) return std.fmt.allocPrint(gpa, "{s}/{s}/success", .{ kind, ident });
    return std.fmt.allocPrint(gpa, "service/{s}/running", .{ident});
}

fn mentionsNetworkOnline(u: *const model.Unit) bool {
    for ([_][]const []const u8{ u.requires, u.binds_to, u.wants, u.after }) |list| {
        if (contains(list, "network-online.target")) return true;
    }
    return false;
}

fn conditions(self: *Finit, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) ![]const []const u8 {
    const gpa = self.ctx.gpa;
    var out: std.ArrayList([]const u8) = .empty;
    if (mentionsNetworkOnline(u)) try out.append(gpa, network_online_condition);
    for ([_][]const []const u8{ u.requires, u.binds_to }) |list| for (list) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        const cond = try self.conditionFor(mapped);
        if (!contains(out.items, cond)) try out.append(gpa, cond);
    };
    return out.items;
}

fn accountKnown(self: *Finit, file: []const u8, account: []const u8) bool {
    if (shell.allDigits(account)) return true;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, file, 1 << 20) catch return false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], account)) return true;
    }
    return false;
}

/// True when the static executor can switch to the unit's user and groups from `/etc/passwd`
/// and `/etc/group`, and applies the supplementary groups of the account as `initgroups` does.
fn executorResolves(self: *Finit, u: *const model.Unit) bool {
    const user = u.user orelse return false;
    if (!self.accountKnown("/etc/passwd", user)) return false;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
    return true;
}

/// An account the executor cannot resolve (LDAP, sssd) is passed to it as numeric ids that finit
/// looks up when it starts the service; the executor stays root and switches to them itself.
/// Null when the executor resolves the account or the unit names no user.
fn identityFor(self: *Finit, u: *const model.Unit) !?shell.Numeric {
    const user = u.user orelse return null;
    if (self.executorResolves(u)) return null;
    var plain = shell.plainAccount(user);
    if (u.group) |g| plain = plain and shell.plainAccount(g);
    for (u.supplementary_groups) |g| plain = plain and shell.plainAccount(g);
    if (!plain) {
        self.ctx.diag.err("{s}: User=, Group= and SupplementaryGroups= must be plain names to be looked up by the system libc", .{u.name.full});
        return error.Unsupported;
    }
    return .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups };
}

/// Oneshots, `Type=forking` without a pid file, which finit cannot follow, and units without a
/// command run once as a task; everything else is a supervised service.
fn kindFor(u: *const model.Unit) render.Kind {
    if (u.exec_start.len == 0 or u.service_type == .oneshot) return .task;
    if (u.service_type == .forking and u.pid_file == null) return .task;
    return .service;
}

fn hasDirectories(u: *const model.Unit) bool {
    return u.runtime_directory.len + u.state_directory.len + u.cache_directory.len +
        u.logs_directory.len + u.configuration_directory.len > 0;
}

fn notesFor(gpa: Allocator, u: *const model.Unit, kind: render.Kind) ![]const []const u8 {
    var notes: std.ArrayList([]const u8) = .empty;
    if (u.service_type == .forking and u.pid_file == null and u.exec_start.len > 0) {
        try notes.append(gpa, "Type=forking without PIDFile=: the daemon is started but not supervised");
    }
    if (kind == .service) switch (u.restart) {
        .@"on-failure", .@"on-abnormal", .@"on-abort", .@"on-watchdog", .@"on-success" => {
            try notes.append(gpa, try std.fmt.allocPrint(gpa, "Restart={t} is approximated by restarting after every exit", .{u.restart}));
        },
        else => {},
    };
    if (u.kill_mode == .none or u.kill_mode == .mixed) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "KillMode={t} is handled like control-group", .{u.kill_mode}));
    }
    if (u.wants.len > 0) try notes.append(gpa, "Wants= has no counterpart in finit and is not expressed");
    return notes.toOwnedSlice(gpa);
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    if (u.scope == .user) {
        self.ctx.diag.err("{s}: finit has no service manager for users", .{u.name.full});
        return error.Unsupported;
    }
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);
    const kind = kindFor(u);
    const post = kind == .service and (u.exec_stop_post.len > 0 or hasDirectories(u));
    const available = try layout.availableDir(gpa, self.dirs);
    const identity = try self.identityFor(u);

    const in: render.Input = .{
        .unit = u,
        .kind = kind,
        .service = svc,
        .executor_path = policy.executor_path,
        .plain_command = if (u.exec_start.len == 0) "/bin/true" else null,
        .stop_on_signal = kind == .service and policy.needsStopHook(u.*),
        .record_exit = kind == .task and u.exec_start.len > 0,
        .conditions = try self.conditions(svc, u, input.deps),
        .exec_script = if (identity != null) try layout.execScriptPath(gpa, self.dirs, svc) else null,
        .post_script = if (post) try layout.postScriptPath(gpa, self.dirs, svc) else null,
        .transient = kind == .task and !u.remain_after_exit and u.service_type != .forking,
        .notes = try notesFor(gpa, u, kind),
    };
    const body = render.renderAlloc(gpa, in) catch |e| switch (e) {
        error.LineTooLong => {
            self.ctx.diag.err("{s}: the stanza is longer than finit reads", .{u.name.full});
            return error.Unsupported;
        },
        else => |other| return other,
    };
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const conf = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);

    const conf_path = try std.fs.path.join(gpa, &.{ available, try layout.confName(gpa, svc) });
    try guard.requireNotOther(self.ctx, guard.claimFile(self.ctx, conf_path, u.name.full), u.name.full, conf_path);
    var files: std.ArrayList(apply.GeneratedFile) = .empty;
    try files.append(gpa, .{ .path = conf_path, .content = conf });
    if (post) {
        const script = try render.postScript(gpa, u.name.full, policy.executor_path, identity);
        try files.append(gpa, .{
            .path = in.post_script.?,
            .content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, script),
            .mode = 0o755,
        });
    }
    if (identity) |ids| {
        const script = try render.execScript(gpa, policy.executor_path, ids);
        try files.append(gpa, .{
            .path = in.exec_script.?,
            .content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, script),
            .mode = 0o755,
        });
    }
    return .{ .service_name = svc, .files = files.items };
}

// ---- enablement -------------------------------------------------------------------------

fn linked(self: *Finit, link: []const u8) bool {
    _ = self.ctx.fs.lstat(link) catch return false;
    return true;
}

fn isStatic(self: *Finit, service: []const u8) !bool {
    const path = try std.fs.path.join(self.ctx.gpa, &.{ layout.rcsd(self.dirs), try layout.confName(self.ctx.gpa, service) });
    const st = self.ctx.fs.stat(path) catch return false;
    return st.kind != .directory;
}

fn relativeTarget(gpa: Allocator, service: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "../available/{s}{s}", .{ service, layout.conf_suffix });
}

/// Services named by the conditions of `service` that have a file of their own, depth first.
fn pulledIn(self: *Finit, service: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    if (depth >= max_pull_depth) return;
    const content = (try self.readConf(service)) orelse return;
    for (try native.conditionsOf(self.ctx.gpa, content)) |cond| {
        var parts = std.mem.splitScalar(u8, cond, '/');
        const kind = parts.next() orelse continue;
        if (!std.mem.eql(u8, kind, "service") and !std.mem.eql(u8, kind, "task") and !std.mem.eql(u8, kind, "run")) continue;
        const ident = parts.next() orelse continue;
        const dep = self.serviceOfIdentity(ident) orelse continue;
        if (std.mem.eql(u8, dep, service) or contains(out.items, dep)) continue;
        try out.append(self.ctx.gpa, dep);
        try self.pulledIn(dep, depth + 1, out);
    }
}

/// File name of the service whose identity is `ident`: generated services are named like their
/// identity; a native one is found by its file name.
fn serviceOfIdentity(self: *Finit, ident: []const u8) ?[]const u8 {
    const plain = if (std.mem.findScalar(u8, ident, ':')) |i| ident[0..i] else ident;
    if (!guard.serviceNameOk(plain)) return null;
    return if (self.serviceExists(plain) catch false) plain else null;
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    var wanted: std.ArrayList([]const u8) = .empty;
    try wanted.append(gpa, service);
    try self.pulledIn(service, 0, &wanted);
    var changes: std.ArrayList(interface.Change) = .empty;
    for (wanted.items) |svc| {
        if (try self.isStatic(svc)) continue;
        const link = try layout.enabledPath(gpa, self.dirs, svc);
        if (self.linked(link)) continue;
        if (!env.ctx.dry_run and !try self.serviceExists(svc)) {
            env.ctx.diag.err("{s}: no finit service file found", .{svc});
            return error.Unsupported;
        }
        const target = try relativeTarget(gpa, svc);
        if (!env.ctx.dry_run) {
            try self.ctx.fs.makePath(std.fs.path.dirname(link) orelse "/");
            try self.ctx.fs.symLink(target, link);
        }
        try changes.append(gpa, .{ .created = .{ .link = link, .target = target } });
    }
    return changes.items;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const link = try layout.enabledPath(env.ctx.gpa, self.dirs, service);
    if (!self.linked(link)) {
        if (try self.isStatic(service)) {
            env.ctx.diag.err("{s}: a static service in {s} cannot be disabled; move its file to available/", .{ service, layout.rcsd(self.dirs) });
            return error.Unsupported;
        }
        return &.{};
    }
    if (!env.ctx.dry_run) try self.ctx.fs.deleteFile(link);
    const changes = try env.ctx.gpa.alloc(interface.Change, 1);
    changes[0] = .{ .removed = link };
    return changes;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    if (self.linked(try layout.enabledPath(self.ctx.gpa, self.dirs, service))) return .enabled;
    return if (try self.isStatic(service)) .enabled else .disabled;
}

// ---- runtime control --------------------------------------------------------------------

fn run(env: Env, tail: []const []const u8, stdio: runner.Stdio) !runner.Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, ctl);
    try argv.appendSlice(env.ctx.gpa, tail);
    return env.runner.run(env.ctx.gpa, argv.items, stdio);
}

/// `initctl status` prints an error when finit does not know the name, which a probe has to hide.
pub const status_script = "exec initctl -p status \"$1\" 2>/dev/null";

fn runStatus(env: Env, ident: []const u8, stdio: runner.Stdio) !runner.Result {
    return env.runner.run(env.ctx.gpa, &.{ "sh", "-c", status_script, "initctl-status", ident }, stdio);
}

/// Exit status of `initctl` when it could not read the reply of finit, which is busy for a moment
/// after a reload.
const talk_failed = 255;
const talk_attempts = 5;
const talk_retry_ms = 300;

fn mustRun(env: Env, tail: []const []const u8) anyerror!void {
    var attempt: u8 = 1;
    while (true) : (attempt += 1) {
        const res = try run(env, tail, .quiet);
        if (res.code == 0) return;
        if (res.code != talk_failed or attempt >= talk_attempts) return error.CommandFailed;
        sleepMs(env, talk_retry_ms);
    }
}

fn sleepMs(env: Env, ms: u64) void {
    env.ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return;
}

/// Unit recorded in the marker of the service file, null for native services.
fn generatedUnit(self: *Finit, service: []const u8) !?[]const u8 {
    const content = (try self.readConf(service)) orelse return null;
    return guard.unitOfMarked(content);
}

fn flagsOf(self: *Finit, service: []const u8) !native.Flags {
    const content = (try self.readConf(service)) orelse return .{};
    const parsed = marker.parse(content) orelse return .{};
    return native.parseFlags(parsed.rest);
}

/// True when finit has read a file that defines `ident`.
fn isLoaded(env: Env, ident: []const u8) !bool {
    const res = try runStatus(env, ident, .quiet);
    return res.code == 0;
}

fn probe(self: *Finit, env: Env, service: []const u8) !interface.Status {
    const ident = try self.identityOf(service);
    const res = try runStatus(env, ident, .capture);
    if (res.code != 0) return .{ .state = .inactive };
    const parsed = native.parseStatusText(res.stdout);
    return .{ .state = native.stateOf(parsed, try self.flagsOf(service)), .pid = parsed.pid, .text = res.stdout };
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    return me(ptr).probe(env, service);
}

/// True when a reload loads `service` without a link of ours: it is enabled.
fn loadsAtBoot(self: *Finit, service: []const u8) !bool {
    if (self.linked(try layout.enabledPath(self.ctx.gpa, self.dirs, service))) return true;
    return self.isStatic(service);
}

/// Links `service` and the services its conditions name into the volatile directory, so that the
/// next reload loads them; enabled services are loaded without one. Returns true when a link was made.
fn linkRuntime(self: *Finit, env: Env, service: []const u8) !bool {
    var wanted: std.ArrayList([]const u8) = .empty;
    try wanted.append(env.ctx.gpa, service);
    try self.pulledIn(service, 0, &wanted);
    var made = false;
    for (wanted.items) |svc| {
        const path = (try layout.locate(self.ctx, self.dirs, svc)) orelse if (env.ctx.dry_run) try layout.availablePath(env.ctx.gpa, self.dirs, svc) else {
            env.ctx.diag.err("{s}: no finit service file found", .{svc});
            return error.Unsupported;
        };
        if (try self.loadsAtBoot(svc)) continue;
        if (!env.ctx.dry_run and try isLoaded(env, try self.identityOf(svc))) continue;
        const link = try layout.runtimePath(env.ctx.gpa, svc);
        if (self.linked(link)) continue;
        if (!env.ctx.dry_run) {
            try self.ctx.fs.makePath(layout.runtime_dir);
            try self.ctx.fs.symLink(path, link);
        }
        made = true;
    }
    return made;
}

/// Loads `service` when finit does not know it; true when a reload did so. The reload is
/// asynchronous: the service is followed until finit lists it.
fn ensureLoaded(self: *Finit, env: Env, service: []const u8) !bool {
    const ident = try self.identityOf(service);
    if (!env.ctx.dry_run and try isLoaded(env, ident)) return false;
    _ = try self.linkRuntime(env, service);
    try mustRun(env, &.{"reload"});
    if (env.ctx.dry_run) return true;
    var waited: u64 = 0;
    while (!try isLoaded(env, ident)) : (waited += poll_ms) {
        if (waited >= self.start_wait_ms) {
            env.ctx.diag.err("{s}: finit did not load the service", .{service});
            return error.CommandFailed;
        }
        sleepMs(env, poll_ms);
    }
    return true;
}

fn isTask(self: *Finit, service: []const u8) !bool {
    const content = (try self.readConf(service)) orelse return false;
    const kind = (try native.kindOf(self.ctx.gpa, content)) orelse return false;
    return std.mem.eql(u8, kind, "task") or std.mem.eql(u8, kind, "run");
}

fn waitFor(self: *Finit, env: Env, service: []const u8, comptime pending: fn (output.ActiveState) bool, limit_ms: u64) !interface.Status {
    var waited: u64 = 0;
    while (true) {
        const s = try self.probe(env, service);
        if (!pending(s.state) or waited >= limit_ms) return s;
        sleepMs(env, poll_ms);
        waited += poll_ms;
    }
}

fn isStopping(s: output.ActiveState) bool {
    return s == .deactivating or s == .active;
}

fn exitOf(self: *Finit, service: []const u8) !?native.Exit {
    const unit = (try self.generatedUnit(service)) orelse return null;
    const path = executor.execExitPath(self.ctx, unit) catch return null;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 64) catch return null;
    return native.parseExit(text);
}

fn clearExit(self: *Finit, service: []const u8) !void {
    const unit = (try self.generatedUnit(service)) orelse return;
    const path = try executor.execExitPath(self.ctx, unit);
    self.ctx.fs.deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

/// Runs a task again and waits for the executor to record how it ended; a task that is not
/// generated has no record and is not waited for.
fn runTask(self: *Finit, env: Env, service: []const u8) anyerror!void {
    const ident = try self.identityOf(service);
    if (!env.ctx.dry_run) try self.clearExit(service);
    const loaded = try self.ensureLoaded(env, service);
    if (!loaded) try mustRun(env, &.{ "reload", ident });
    if (env.ctx.dry_run or (try self.generatedUnit(service)) == null) return;
    var waited: u64 = 0;
    while (waited < self.oneshot_wait_ms) : (waited += poll_ms) {
        if (try self.exitOf(service)) |e| {
            if (e == .ok) return;
            env.ctx.diag.err("{s}: the command failed", .{service});
            return error.CommandFailed;
        }
        sleepMs(env, poll_ms);
    }
    env.ctx.diag.err("{s}: no result after {d} s", .{ service, self.oneshot_wait_ms / 1000 });
    return error.CommandFailed;
}

/// Words of `initctl status` for a service that has not finished starting: its command runs
/// or it waits for a condition. `restart` is the pause of a service that exited.
const starting_words = [_][]const u8{ "starting", "setup", "waiting", "busy" };

/// Follows a start until finit has run the command. A service that exits at once is not a failed
/// start, as for a systemd simple service; one whose command or environment file is missing,
/// and one that keeps waiting for a condition, are.
fn waitStarted(self: *Finit, env: Env, service: []const u8) anyerror!void {
    const ident = try self.identityOf(service);
    var waited: u64 = 0;
    while (true) {
        const res = try runStatus(env, ident, .capture);
        if (res.code != 0) return;
        const parsed = native.parseStatusText(res.stdout);
        const pending = for (starting_words) |w| {
            if (std.mem.eql(u8, parsed.word, w)) break true;
        } else false;
        if (std.mem.eql(u8, parsed.word, "missing")) {
            env.ctx.diag.err("{s}: finit cannot run the command or reads no environment file for it", .{service});
            return error.CommandFailed;
        }
        if (!pending) return;
        if (waited >= self.start_wait_ms) {
            env.ctx.diag.err("{s}: still {s} after {d} s, waiting for a condition", .{ service, parsed.word, self.start_wait_ms / 1000 });
            return error.CommandFailed;
        }
        sleepMs(env, poll_ms);
        waited += poll_ms;
    }
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    if (try self.isTask(service)) return self.runTask(env, service);
    _ = try self.ensureLoaded(env, service);
    try mustRun(env, &.{ "start", try self.identityOf(service) });
    if (!env.ctx.dry_run) try self.waitStarted(env, service);
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const ident = try self.identityOf(service);
    if (env.ctx.dry_run or try isLoaded(env, ident)) {
        try mustRun(env, &.{ "stop", ident });
        if (!env.ctx.dry_run) _ = try self.waitFor(env, service, isStopping, self.stop_wait_ms);
    }
    const link = try layout.runtimePath(env.ctx.gpa, service);
    if (self.linked(link)) {
        if (!env.ctx.dry_run) try self.ctx.fs.deleteFile(link);
        try mustRun(env, &.{"reload"});
    }
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    if (try self.isTask(service)) return self.runTask(env, service);
    if (!try self.ensureLoaded(env, service)) {
        try mustRun(env, &.{ "restart", try self.identityOf(service) });
        if (!env.ctx.dry_run) try self.waitStarted(env, service);
    }
}

/// Script of the stanza that runs the executor with the numeric ids of its account, when it has
/// one: the reload runs the executor with the identity the service has.
fn execScriptOf(self: *Finit, env: Env, service: []const u8) !?[]const u8 {
    const content = (try self.readConf(service)) orelse return null;
    const words = (try native.extractCommand(env.ctx.gpa, content)) orelse return null;
    if (words.len == 0 or !std.mem.endsWith(u8, words[0], layout.exec_suffix)) return null;
    return words[0];
}

fn run2(env: Env, argv: []const []const u8) !runner.Result {
    return env.runner.run(env.ctx.gpa, argv, .capture);
}

/// A generated service reloads through the executor, which runs `ExecReload=`; a native one
/// keeps the reload of finit.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const unit_name = (try self.generatedUnit(service)) orelse return mustRun(env, &.{ "reload", try self.identityOf(service) });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, (try self.execScriptOf(env, service)) orelse policy.executor_path);
    try argv.appendSlice(env.ctx.gpa, &.{ "--exec", unit_name, "--phase", "reload" });
    const res = try env.runner.run(env.ctx.gpa, argv.items, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    try mustRun(env, &.{ "signal", try me(ptr).identityOf(service), name });
}

/// Finit reads changed files at a reload: new services start, changed ones restart and the
/// ones whose file is gone stop.
fn reloadManager(_: *anyopaque, env: Env) anyerror!void {
    if (env.ctx.dry_run) return;
    const res = try run(env, &.{"reload"}, .quiet);
    if (res.code != 0) env.ctx.diag.warn("initctl reload failed, finit reads the service files at the next reload", .{});
}

fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const verb = switch (action) {
        .reboot => "reboot",
        .poweroff => "poweroff",
        .halt => "halt",
    };
    const res = try run(env, &.{verb}, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
}
