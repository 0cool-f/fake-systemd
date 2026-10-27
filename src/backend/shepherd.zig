// SPDX-License-Identifier: GPL-3.0-or-later
//! GNU Shepherd backend (§11.3): a service is a Scheme file in `available/`, a link in `init.d/`
//! enables it, and `herd` controls the running daemon.
//!
//! The configuration of `shepherd` loads every file of `init.d/` at startup and starts what it
//! registered. A service that is started without being enabled is loaded at run time with
//! `herd load root`. On Guix System the services come from the operating-system declaration, which
//! fake-systemd cannot change: enabling and disabling only say so, while starting, stopping and
//! reading the state work as everywhere. The command of every service is the executor, which
//! logs to the uniform location and applies the unit settings; Shepherd supervises it.
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
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const runner = @import("runner.zig");
const shell = @import("shell.zig");
const render = @import("shepherd/render.zig");
const layout = @import("shepherd/layout.zig");
const native = @import("shepherd/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Shepherd = @This();

pub const backend_name = "shepherd";
pub const generator_number = 1;

/// Capabilities of §11.3. Requirements are the only dependency Shepherd has: starting a service
/// starts what it requires, and stopping that stops the service.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .supervision = true,
    .oneshot = true,
    .restart_policy = true,
    .user_services = true,
};

const herd = "herd";
const kill_tool = "kill";
const poll_ms = 100;
pub const default_wait_ms = 10_000;
const max_pull_depth = 8;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// Milliseconds to follow a stop; tests shorten it.
wait_ms: u64 = default_wait_ms,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) Shepherd {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *Shepherd) Backend {
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

fn me(ptr: *anyopaque) *Shepherd {
    return @ptrCast(@alignCast(ptr));
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = try layout.lookupDirs(self.ctx, self.dirs, self.ctx.scope),
        .extractor = native.extractCommand,
        .strip_suffix = layout.scm_suffix,
    };
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const dirs = try gpa.alloc(rebuild.ScanDir, 1);
    dirs[0] = .{
        .path = try layout.availableDir(self.ctx, self.dirs, scope),
        .tier = if (scope == .user) .personal else .admin,
    };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

fn serviceExists(self: *Shepherd, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

/// Name of the service a dependency refers to, or null when it cannot be a service: targets
/// (the network ones are handled apart), other unit types, and units that are neither a service
/// of Shepherd nor a systemd unit that can be translated.
fn mapDependency(self: *Shepherd, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
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

/// The network service of the profile that exists as a file, for a unit that waits for the
/// network.
fn networkService(self: *Shepherd, own: []const u8, u: *const model.Unit) !?[]const u8 {
    const online = contains(u.requires, "network-online.target") or contains(u.wants, "network-online.target") or contains(u.after, "network-online.target");
    const plain = contains(u.requires, "network.target") or contains(u.wants, "network.target") or contains(u.after, "network.target");
    const candidates = if (online) self.dirs.network_online else if (plain) self.dirs.network else return null;
    for (candidates) |c| {
        if (!std.mem.eql(u8, c, own) and try self.serviceExists(c)) return c;
    }
    return null;
}

fn requirements(self: *Shepherd, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ u.requires, u.binds_to }) |list| for (list) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        if (!contains(out.items, mapped)) try out.append(self.ctx.gpa, mapped);
    };
    if (try self.networkService(own, u)) |net| if (!contains(out.items, net)) try out.append(self.ctx.gpa, net);
    return out.items;
}

fn accountKnown(self: *Shepherd, file: []const u8, account: []const u8) bool {
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
/// and `/etc/group`, and applies the supplementary groups of the account as `initgroups` does.
fn executorResolves(self: *Shepherd, u: *const model.Unit) bool {
    const user = u.user orelse return false;
    if (!self.accountKnown("/etc/passwd", user)) return false;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
    return true;
}

/// An account the executor cannot resolve (LDAP, sssd) is passed to it as numeric ids that a shell
/// looks up when Shepherd starts the service; the executor stays root and switches to them itself.
fn identityFor(self: *Shepherd, u: *const model.Unit) !?shell.Numeric {
    if (u.scope == .user) return null;
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

fn hasDirectories(u: *const model.Unit) bool {
    return u.runtime_directory.len + u.state_directory.len + u.cache_directory.len +
        u.logs_directory.len + u.configuration_directory.len > 0;
}

fn kindFor(u: *const model.Unit) render.Kind {
    if (u.exec_start.len == 0) return if (u.remain_after_exit) .remain else .oneshot;
    return switch (u.service_type) {
        .oneshot => if (u.remain_after_exit) .remain else .oneshot,
        // A daemon without a pid file cannot be followed: it is started and left alone.
        .forking => if (u.pid_file == null) .remain else .daemon,
        else => .daemon,
    };
}

fn notesFor(gpa: Allocator, u: *const model.Unit, kind: render.Kind) ![]const []const u8 {
    var notes: std.ArrayList([]const u8) = .empty;
    if (u.service_type == .forking and u.pid_file == null and u.exec_start.len > 0) {
        try notes.append(gpa, "Type=forking without PIDFile=: the daemon is started but not supervised");
    }
    if (kind == .daemon) switch (u.restart) {
        .@"on-failure", .@"on-abnormal", .@"on-abort", .@"on-watchdog", .@"on-success" => {
            try notes.append(gpa, try std.fmt.allocPrint(gpa, "Restart={t} is approximated by respawning after every exit", .{u.restart}));
        },
        else => {},
    };
    if (kind == .daemon and (u.exec_stop_post.len > 0 or hasDirectories(u))) {
        try notes.append(gpa, "ExecStopPost= runs when the service is stopped, not when its process ends by itself");
    }
    if (u.kill_mode == .none or u.kill_mode == .mixed) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "KillMode={t} is handled like control-group", .{u.kill_mode}));
    }
    if (u.wants.len > 0) try notes.append(gpa, "Wants= has no counterpart in Shepherd and is not expressed");
    return notes.toOwnedSlice(gpa);
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);
    // A backslash would close the `#{...}#` form of the symbol that names the service.
    if (std.mem.findScalar(u8, svc, '\\') != null) {
        self.ctx.diag.err("{s}: '{s}' is not a name Shepherd can register", .{ u.name.full, svc });
        return error.Unsupported;
    }
    const kind = kindFor(u);
    const stops = u.exec_stop.len > 0 or u.exec_stop_post.len > 0 or hasDirectories(u);
    const in: render.Input = .{
        .unit = u,
        .kind = kind,
        .service = svc,
        .executor_path = policy.executor_path,
        .no_command = u.exec_start.len == 0,
        .stop_on_signal = kind == .daemon and u.exec_stop.len > 0,
        .stop_post = kind == .daemon and (u.exec_stop_post.len > 0 or hasDirectories(u)),
        .remain_stop = kind == .remain and stops,
        .requirements = try self.requirements(svc, u, input.deps),
        .identity = try self.identityFor(u),
        .user_scope = u.scope == .user,
        .notes = try notesFor(gpa, u, kind),
    };
    const body = try render.renderAlloc(gpa, in);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);

    const path = try layout.availablePath(self.ctx, self.dirs, svc);
    try guard.requireNotOther(self.ctx, guard.claimFile(self.ctx, path, u.name.full), u.name.full, path);
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    files[0] = .{ .path = path, .content = content };
    return .{ .service_name = svc, .files = files };
}

// ---- enablement -------------------------------------------------------------------------

fn linked(self: *Shepherd, link: []const u8) bool {
    _ = self.ctx.fs.lstat(link) catch return false;
    return true;
}

fn relativeTarget(gpa: Allocator, service: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "../available/{s}{s}", .{ service, layout.scm_suffix });
}

/// What the configuration needs to load `init.d/` at startup and start what it registered.
fn loaderText(self: *Shepherd, gpa: Allocator) ![]const u8 {
    const dir = try layout.enabledDir(self.ctx, self.dirs, self.ctx.scope);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(
        \\;; Loads the services that fake-systemd enabled and starts them.
        \\(use-modules (ice-9 ftw) (shepherd service))
        \\(let* ((dir
    );
    try w.writeByte(' ');
    try render.writeString(w, dir);
    try w.writeAll(
        \\)
        \\       (files (or (false-if-exception (scandir dir)) '()))
        \\       (files (filter (lambda (f) (string-suffix? ".scm" f)) files)))
        \\  (for-each (lambda (f)
        \\              (catch #t
        \\                (lambda () (load (string-append dir "/" f)))
        \\                (lambda args (format (current-error-port) "cannot load ~a~%" f))))
        \\            files)
        \\  (for-each (lambda (f)
        \\              (catch #t
        \\                (lambda ()
        \\                  (start-in-the-background
        \\                   (list (string->symbol (string-drop-right f 4)))))
        \\                (lambda args #f)))
        \\            files))
        \\
    );
    return aw.toOwnedSlice();
}

/// Makes sure the configuration loads `init.d/`: a missing configuration file is written; one that
/// does not mention the directory is left alone and the user is told what to add.
fn ensureLoader(self: *Shepherd, env: Env) !void {
    const config = try layout.configFile(self.ctx, self.ctx.scope);
    const dir = try layout.enabledDir(self.ctx, self.dirs, self.ctx.scope);
    if (self.ctx.fs.readFileAlloc(self.ctx.gpa, config, 1 << 20)) |text| {
        if (std.mem.find(u8, text, dir) != null) return;
        env.ctx.diag.warn("{s} does not load {s}: add the lines of the loader, which fake-systemd writes to {s}.loader", .{ config, dir, config });
        if (!env.ctx.dry_run) try self.ctx.fs.writeFileAtomic(try std.fmt.allocPrint(self.ctx.gpa, "{s}.loader", .{config}), try self.loaderText(self.ctx.gpa), 0o644);
        return;
    } else |_| {}
    if (env.ctx.dry_run) return;
    try self.ctx.fs.makePath(std.fs.path.dirname(config) orelse "/");
    try self.ctx.fs.writeFileAtomic(config, try self.loaderText(self.ctx.gpa), 0o644);
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    if (layout.isGuixSystem(env.ctx)) {
        env.ctx.diag.warn("{s}: enabling needs a change of the operating-system declaration; add the service to it and reconfigure", .{service});
        return &.{};
    }
    const link = try layout.enabledPath(self.ctx, self.dirs, service);
    if (self.linked(link)) return &.{};
    const target = try relativeTarget(gpa, service);
    if (!env.ctx.dry_run) {
        if (!try self.serviceExists(service)) {
            env.ctx.diag.err("{s}: no Shepherd service file found", .{service});
            return error.Unsupported;
        }
        try self.ctx.fs.makePath(std.fs.path.dirname(link) orelse "/");
        try self.ctx.fs.symLink(target, link);
        try self.ensureLoader(env);
    }
    const changes = try gpa.alloc(interface.Change, 1);
    changes[0] = .{ .created = .{ .link = link, .target = target } };
    return changes;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    if (layout.isGuixSystem(env.ctx)) {
        env.ctx.diag.warn("{s}: disabling needs a change of the operating-system declaration; remove the service from it and reconfigure", .{service});
        return &.{};
    }
    const link = try layout.enabledPath(self.ctx, self.dirs, service);
    if (!self.linked(link)) return &.{};
    if (!env.ctx.dry_run) try self.ctx.fs.deleteFile(link);
    const changes = try env.ctx.gpa.alloc(interface.Change, 1);
    changes[0] = .{ .removed = link };
    return changes;
}

/// Enabled is a link in `init.d/`, or a service the running Shepherd registered from its own
/// configuration.
fn isEnabled(ptr: *anyopaque, env: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    if (self.linked(try layout.enabledPath(self.ctx, self.dirs, service))) return .enabled;
    if (env.online and !(try self.serviceExists(service))) {
        const res = try runStatus(env, service, .capture);
        if (res.code == 0) return .enabled;
    }
    return .disabled;
}

// ---- runtime control --------------------------------------------------------------------

fn run(env: Env, tail: []const []const u8, stdio: runner.Stdio) !runner.Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, herd);
    try argv.appendSlice(env.ctx.gpa, tail);
    return env.runner.run(env.ctx.gpa, argv.items, stdio);
}

/// `herd status` prints an error when Shepherd does not know the name, which a probe has to hide.
pub const status_script = "exec herd status \"$1\" 2>/dev/null";

fn runStatus(env: Env, ident: []const u8, stdio: runner.Stdio) !runner.Result {
    return env.runner.run(env.ctx.gpa, &.{ "sh", "-c", status_script, "herd-status", ident }, stdio);
}

fn mustRun(env: Env, tail: []const []const u8) anyerror!void {
    const res = try run(env, tail, .quiet);
    if (res.code != 0) return error.CommandFailed;
}

fn sleepMs(env: Env, ms: u64) void {
    env.ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return;
}

fn readConf(self: *Shepherd, service: []const u8) !?[]const u8 {
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    return guard.readOrAbsent(self.ctx, path, 1 << 20);
}

/// Name `herd` takes for `service`: the generated name, or what a native file declares.
fn identityOf(self: *Shepherd, service: []const u8) ![]const u8 {
    const content = (try self.readConf(service)) orelse return service;
    if (marker.parse(content) != null) return service;
    return (try native.identityOf(self.ctx.gpa, content)) orelse service;
}

/// Unit recorded in the marker of the service file, null for native services.
fn generatedUnit(self: *Shepherd, service: []const u8) !?[]const u8 {
    const content = (try self.readConf(service)) orelse return null;
    return guard.unitOfMarked(content);
}

const Probe = struct {
    loaded: bool,
    text: []const u8,
    parsed: native.Parsed,
};

fn probe(self: *Shepherd, env: Env, service: []const u8) !Probe {
    const res = try runStatus(env, try self.identityOf(service), .capture);
    if (res.code != 0) return .{ .loaded = false, .text = "", .parsed = .{} };
    return .{ .loaded = true, .text = res.stdout, .parsed = native.parseStatus(res.stdout) };
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const p = try me(ptr).probe(env, service);
    return .{ .state = native.stateOf(p.parsed), .pid = p.parsed.pid, .text = p.text };
}

/// Services named in `#:requirement` of `service`, depth first.
fn requiredBy(self: *Shepherd, service: []const u8, depth: usize, out: *std.ArrayList([]const u8)) !void {
    if (depth >= max_pull_depth) return;
    const content = (try self.readConf(service)) orelse return;
    for (try native.requirementsOf(self.ctx.gpa, content)) |dep| {
        if (std.mem.eql(u8, dep, service) or contains(out.items, dep)) continue;
        if (!guard.serviceNameOk(dep) or !try self.serviceExists(dep)) continue;
        try out.append(self.ctx.gpa, dep);
        try self.requiredBy(dep, depth + 1, out);
    }
}

fn loadFile(self: *Shepherd, env: Env, service: []const u8) !void {
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse if (env.ctx.dry_run) try layout.availablePath(self.ctx, self.dirs, service) else {
        env.ctx.diag.err("{s}: no Shepherd service file found", .{service});
        return error.Unsupported;
    };
    try mustRun(env, &.{ "load", "root", path });
}

/// Loads `service` and the services it requires into the running Shepherd when it does not know
/// them yet.
fn ensureLoaded(self: *Shepherd, env: Env, service: []const u8) !Probe {
    var wanted: std.ArrayList([]const u8) = .empty;
    try self.requiredBy(service, 0, &wanted);
    for (wanted.items) |dep| {
        if (env.ctx.dry_run or !(try self.probe(env, dep)).loaded) try self.loadFile(env, dep);
    }
    var p = try self.probe(env, service);
    if (!p.loaded) {
        try self.loadFile(env, service);
        p = try self.probe(env, service);
    }
    return p;
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const ident = try self.identityOf(service);
    const p = try self.ensureLoaded(env, service);
    // A service whose process ended by itself is disabled by Shepherd until it is enabled again.
    if (p.parsed.disabled) try mustRun(env, &.{ "enable", ident });
    try mustRun(env, &.{ "start", ident });
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const p = try self.probe(env, service);
    if (!p.loaded and !env.ctx.dry_run) return;
    try mustRun(env, &.{ "stop", try self.identityOf(service) });
    if (env.ctx.dry_run) return;
    var waited: u64 = 0;
    while (waited < self.wait_ms) : (waited += poll_ms) {
        const now = try self.probe(env, service);
        if (now.parsed.run != .running and now.parsed.run != .stopping) return;
        sleepMs(env, poll_ms);
    }
}

/// A generated service is loaded again first, so that a changed file applies; `herd restart` starts
/// a service that is stopped.
fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const ident = try self.identityOf(service);
    const p = try self.ensureLoaded(env, service);
    if ((try self.generatedUnit(service)) != null and p.loaded) try self.loadFile(env, service);
    if (p.parsed.disabled) try mustRun(env, &.{ "enable", ident });
    try mustRun(env, &.{ "restart", ident });
}

/// A generated service reloads through the executor, which runs `ExecReload=`; a native one has the
/// action of its own definition.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const unit_name = (try self.generatedUnit(service)) orelse return mustRun(env, &.{ "reload", try self.identityOf(service) });
    var argv: std.ArrayList([]const u8) = .empty;
    // An account the executor cannot resolve: the shell of the service looks its ids up.
    if (try self.readConf(service)) |content| {
        if (try native.identityScriptOf(env.ctx.gpa, content)) |script| try argv.appendSlice(env.ctx.gpa, &.{ "/bin/sh", "-c", script });
    }
    try argv.appendSlice(env.ctx.gpa, &.{ policy.executor_path, "--exec", unit_name });
    if (env.ctx.scope == .user) try argv.append(env.ctx.gpa, "--user");
    try argv.appendSlice(env.ctx.gpa, &.{ "--phase", "reload" });
    const res = try env.runner.run(env.ctx.gpa, argv.items, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// Shepherd has no signal action: the process of the service is signalled directly.
fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const p = try self.probe(env, service);
    const pid = guard.accepted(self.ctx, p.parsed.pid, null) orelse {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const pid_text = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{pid});
    const res = try env.runner.run(env.ctx.gpa, &.{ kill_tool, "-s", name, pid_text }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// Shepherd keeps the definition it read; loading a file again replaces it without touching a
/// running process.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    if (env.ctx.dry_run) return;
    const dir = try layout.availableDir(self.ctx, self.dirs, self.ctx.scope);
    const entries = try guard.iterateOrEmpty(self.ctx, dir);
    for (entries) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, layout.scm_suffix)) continue;
        const service = layout.serviceOfFile(e.name);
        if ((try self.generatedUnit(service)) == null) continue;
        if (!(try self.probe(env, service)).loaded) continue;
        const res = try run(env, &.{ "load", "root", try std.fs.path.join(self.ctx.gpa, &.{ dir, e.name }) }, .quiet);
        if (res.code != 0) env.ctx.diag.warn("{s}: Shepherd could not load the service file again", .{service});
    }
}

fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const argv: []const []const u8 = switch (action) {
        .reboot => &.{"reboot"},
        .poweroff => &.{ herd, "power-off" },
        .halt => &.{ herd, "halt" },
    };
    const res = try env.runner.run(env.ctx.gpa, argv, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
}
