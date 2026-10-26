// SPDX-License-Identifier: GPL-3.0-or-later
//! OpenRC backend (§11.2): a service is an `openrc-run` script in `/etc/init.d`, a symlink to it
//! in `/etc/runlevels/<runlevel>` enables it, and `rc-service` controls it.
//!
//! `Restart=` units run under `supervise-daemon`, which respawns on any exit; the others run their
//! executor under `start-stop-daemon` with a pid file, and the executor logs and records how the
//! main process ended. OpenRC starts the services a script `need`s or `want`s itself, so
//! dependencies need no links, and a service that is started stays recorded as started until it
//! is stopped, which is why a oneshot is `started` once its commands ran and why a service whose
//! process is gone reads `crashed` and takes its end from the file of the executor.
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
const executor = @import("../exec/executor.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const network = @import("network.zig");
const runner = @import("runner.zig");
const render = @import("openrc/render.zig");
const layout = @import("openrc/layout.zig");
const native = @import("openrc/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const OpenRc = @This();

pub const backend_name = "openrc";
pub const generator_number = 1;

/// Capabilities of §11.2. `user_services` is set per instance, where OpenRC has user sessions.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .ordering = true,
    .supervision = true,
    .restart_policy = true,
};

/// What a script expresses without the executor: `Environment=` as exported variables,
/// `Limit*=` through `rc_ulimit`, `User=` with `Group=` through `command_user`, `UMask=` and
/// both kinds of `Type=forking` through `start-stop-daemon`.
const native_support: policy.Native = .{
    .forking_pidfile = true,
    .forking_plain = true,
    .environment = true,
    .limits = &render.nativeLimitNames(),
    .group = true,
    .umask = true,
};

const rc_service = "rc-service";
const rc_update = "rc-update";
const openrc_init = "openrc-init";
const openrc_shutdown = "openrc-shutdown";
/// First OpenRC whose `supervise-daemon` can pipe a daemon's output to a logger.
const logger_pipe_version: native.Version = .{ .major = 0, .minor = 51 };
const user_session_script = "/etc/init.d/user";

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// OpenRC runs user sessions (0.60 and later): the `user` service is installed.
user_manager: bool = false,
/// Version of the installed OpenRC, replaced by tests.
version_override: ?native.Version = null,
/// Replaces the check of which programs are installed; for tests.
tools_override: ?[]const []const u8 = null,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) OpenRc {
    return .{ .ctx = ctx, .dirs = dirs, .user_manager = ctx.fs.exists(user_session_script) };
}

pub fn backend(self: *OpenRc) Backend {
    self.vt = vtable;
    self.vt.caps.user_services = self.user_manager;
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

fn me(ptr: *anyopaque) *OpenRc {
    return @ptrCast(@alignCast(ptr));
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = try layout.lookupDirs(self.ctx, self.dirs, self.ctx.scope),
        .extractor = native.extractCommand,
    };
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const dirs = try gpa.alloc(rebuild.ScanDir, 1);
    dirs[0] = .{
        .path = try layout.generationDir(self.ctx, self.dirs, scope),
        .tier = if (scope == .user) .personal else .admin,
    };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn serviceExists(self: *OpenRc, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

/// OpenRC name of the service a dependency refers to, or null when it cannot be a service:
/// targets (the network ones are handled apart), other unit types, and units that are neither
/// an OpenRC service nor a systemd unit that can be translated.
fn mapDependency(self: *OpenRc, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
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

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

fn mapList(self: *OpenRc, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, exclude: []const []const []const u8, out: *std.ArrayList([]const u8)) !void {
    outer: for (deps) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        for (exclude) |ex| if (contains(ex, mapped)) continue :outer;
        if (!contains(out.items, mapped)) try out.append(self.ctx.gpa, mapped);
    }
}

fn mentionsTarget(u: *const model.Unit, target: []const u8) bool {
    for ([_][]const []const u8{ u.requires, u.binds_to, u.wants, u.after }) |list| {
        if (contains(list, target)) return true;
    }
    return false;
}

/// Virtual services the network targets stand for, as soft dependencies: the profile names the
/// virtual `net`, which every network provider declares with `provide`, and `network-online`,
/// which the `net-online` service provides.
fn networkUse(self: *OpenRc, own: []const u8, u: *const model.Unit, out: *std.ArrayList([]const u8)) !void {
    const targets = [_]struct { name: []const u8, services: []const []const u8 }{
        .{ .name = "network.target", .services = self.dirs.network },
        .{ .name = "network-online.target", .services = self.dirs.network_online },
    };
    for (targets) |t| {
        if (!mentionsTarget(u, t.name)) continue;
        for (t.services) |s| {
            if (!std.mem.eql(u8, s, own) and !contains(out.items, s)) try out.append(self.ctx.gpa, s);
        }
    }
}

fn mapDependencies(self: *OpenRc, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) !render.Deps {
    var need: std.ArrayList([]const u8) = .empty;
    var want: std.ArrayList([]const u8) = .empty;
    var use: std.ArrayList([]const u8) = .empty;
    var after: std.ArrayList([]const u8) = .empty;
    var before: std.ArrayList([]const u8) = .empty;
    try self.mapList(own, resolutions, u.requires, &.{}, &need);
    try self.mapList(own, resolutions, u.binds_to, &.{}, &need);
    try self.mapList(own, resolutions, u.wants, &.{need.items}, &want);
    try self.networkUse(own, u, &use);
    try self.mapList(own, resolutions, u.after, &.{ need.items, want.items, use.items }, &after);
    try self.mapList(own, resolutions, u.before, &.{}, &before);
    return .{ .need = need.items, .want = want.items, .use = use.items, .after = after.items, .before = before.items };
}

fn accountKnown(self: *OpenRc, file: []const u8, account: []const u8) bool {
    if (account.len > 0 and std.ascii.isDigit(account[0])) return true;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, file, 1 << 20) catch return false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, line[0..colon], account)) return true;
    }
    return false;
}

fn numeric(name: []const u8) bool {
    return name.len > 0 and std.ascii.isDigit(name[0]);
}

/// True when the static executor can switch to the unit's user and groups from `/etc/passwd`
/// and `/etc/group`; it then applies the user's supplementary groups as `initgroups` does.
fn executorResolves(self: *OpenRc, u: *const model.Unit) bool {
    if (u.scope == .user) return false;
    const user = u.user orelse return false;
    if (!self.accountKnown("/etc/passwd", user)) return false;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
    return true;
}

/// True when the script cannot carry the unit's settings itself and the executor has to.
/// `command_user` takes one account and one group; the words of `command`, `directory` and
/// `command_user` reach `supervise-daemon` through an unquoted `eval`; exported variables
/// share the namespace of the script; and `ExecStop=` has to run whenever the service goes
/// down, which the resident executor does.
fn nativeBlocked(u: *const model.Unit) bool {
    if (u.scope == .system) {
        if (u.user) |user| if (numeric(user) or !render.plainAccount(user)) return true;
        if (u.group) |g| if (numeric(g) or !render.plainAccount(g)) return true;
        if (u.supplementary_groups.len > 0) return true;
        if (u.group != null and u.user == null) return true;
    }
    for (u.environment) |e| if (!render.validEnvName(e.name)) return true;
    if (u.working_directory) |dir| if (!render.bare(dir)) return true;
    if (u.exec_start.len > 0 and !render.bare(u.exec_start[0].words[0])) return true;
    if (render.stopsOnSignal(u)) return true;
    if (u.service_type == .forking and u.restart != .no and u.pid_file != null) return true;
    return false;
}

const command_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };
const tool_dirs = [_][]const u8{ "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin" };

/// `name` found in the standard directories, or null when none holds it.
fn findProgram(self: *OpenRc, name: []const u8) !?[]const u8 {
    if (self.tools_override) |tools| return if (contains(tools, name)) name else null;
    for (command_dirs) |dir| {
        const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, name });
        if (self.ctx.fs.exists(path)) return path;
    }
    return null;
}

fn hasTool(self: *OpenRc, name: []const u8) bool {
    if (self.tools_override) |tools| return contains(tools, name);
    for (tool_dirs) |dir| {
        const path = std.fs.path.join(self.ctx.gpa, &.{ dir, name }) catch return false;
        if (self.ctx.fs.exists(path)) return true;
    }
    return false;
}

fn commandWords(self: *OpenRc, cmd: model.Command) ![]const []const u8 {
    const words = try self.ctx.gpa.dupe([]const u8, cmd.words);
    if (std.mem.findScalar(u8, words[0], '/') == null) words[0] = (try self.findProgram(words[0])) orelse words[0];
    return words;
}

/// `user[:group]` for `command_user`.
fn accountSpec(gpa: Allocator, u: *const model.Unit) Allocator.Error![]const u8 {
    const user = u.user.?;
    return if (u.group) |g| std.fmt.allocPrint(gpa, "{s}:{s}", .{ user, g }) else gpa.dupe(u8, user);
}

const Identities = struct {
    /// How the daemon switches account.
    daemon: ?render.Identity = null,
    /// How executor calls from script functions do.
    call: ?render.Wrapper = null,
};

/// An account the executor cannot resolve (LDAP, sssd) is switched by OpenRC through the system
/// libc: `command_user` applies the groups of the account. Supplementary groups and executor
/// calls from script functions need `setpriv`, or `su`, which knows no group arguments. A
/// native command always takes `command_user`, since no executor switches for it.
fn identitiesFor(self: *OpenRc, u: *const model.Unit, mode: render.Mode, use_executor: bool, have_setpriv: bool) !Identities {
    if (u.scope == .user) return .{};
    const user = u.user orelse return .{};
    const resolves = self.executorResolves(u);
    if (resolves and use_executor) return .{};
    var out: Identities = .{};
    const wrapper: render.Wrapper = if (have_setpriv)
        .{ .setpriv = .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups } }
    else
        .{ .su = user };
    if (!resolves) {
        if (!have_setpriv and (u.group != null or u.supplementary_groups.len > 0)) {
            self.ctx.diag.warn("{s}: setpriv is not installed, the groups of {s} come from the group database only", .{ u.name.full, user });
        }
        out.call = wrapper;
    }
    // The daemon of `background` mode is started by start-stop-daemon, whose `--user` is not
    // OpenRC's on Debian, so the switch is made by `setpriv` there as well.
    out.daemon = if (have_setpriv and use_executor and (u.supplementary_groups.len > 0 or mode == .background))
        .{ .wrapper = wrapper }
    else
        .{ .command_user = try accountSpec(self.ctx.gpa, u) };
    return out;
}

fn readVersion(self: *OpenRc) ?native.Version {
    if (self.version_override) |v| return v;
    for (layout.version_files) |path| {
        const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 64) catch continue;
        if (native.parseVersion(text)) |v| return v;
    }
    return null;
}

/// The restart behavior `supervise-daemon` gives the unit; it respawns on every exit.
fn effectiveRestart(u: *const model.Unit) model.Restart {
    return switch (u.restart) {
        .@"on-watchdog" => .no,
        else => u.restart,
    };
}

fn modeFor(u: *const model.Unit) render.Mode {
    if (u.exec_start.len == 0) return .none;
    if (u.service_type == .oneshot) return .oneshot;
    const restarts = effectiveRestart(u) != .no;
    // A daemon without a pid file cannot be followed, so start-stop-daemon starts it as it is.
    if (u.service_type == .forking and u.pid_file == null) return .forking;
    return if (restarts) .supervised else .background;
}

fn notesFor(gpa: Allocator, u: *const model.Unit, mode: render.Mode) ![]const []const u8 {
    var notes: std.ArrayList([]const u8) = .empty;
    if (u.service_type == .forking and mode == .forking and u.restart != .no and u.pid_file == null) {
        try notes.append(gpa, "Type=forking without PIDFile=: the daemon is started but not supervised");
    }
    switch (u.restart) {
        .@"on-failure", .@"on-abnormal", .@"on-abort" => try notes.append(gpa, try std.fmt.allocPrint(gpa, "Restart={s} is approximated by respawning on every exit", .{@tagName(u.restart)})),
        .@"on-success" => try notes.append(gpa, "Restart=on-success is approximated by respawning on every exit"),
        else => {},
    }
    if (mode == .oneshot and !u.remain_after_exit) {
        try notes.append(gpa, "A oneshot stays started in OpenRC; status reads it as inactive");
    }
    if (u.kill_mode == .none or u.kill_mode == .mixed) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "KillMode={t} is handled like control-group", .{u.kill_mode}));
    }
    return notes.toOwnedSlice(gpa);
}

fn pidFile(gpa: Allocator, ctx: *const core.Context, u: *const model.Unit, svc: []const u8, mode: render.Mode) !?[]const u8 {
    switch (mode) {
        .background => {
            const dir = if (u.scope == .user) ctx.xdg_runtime_dir else "/run";
            return try std.fmt.allocPrint(gpa, "{s}/{s}.fake-systemd.pid", .{ dir, svc });
        },
        .forking => {
            const raw = u.pid_file orelse return null;
            if (std.fs.path.isAbsolute(raw)) return raw;
            return try std.fs.path.join(gpa, &.{ "/run", raw });
        },
        else => return null,
    }
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    const svc = try layout.serviceName(gpa, u.name);

    const reason = policy.executorReason(u.*, capabilities, native_support);
    const mode = modeFor(u);
    // Without a supervisor of its own a service runs under the executor, which logs and records the exit.
    const use_executor = (reason != null and reason.? != .no_command) or nativeBlocked(u) or mode == .background;
    const have_setpriv = (try self.findProgram("setpriv")) != null;
    const ids = try self.identitiesFor(u, mode, use_executor, have_setpriv);
    const version = self.readVersion();
    const pipes = version == null or version.?.atLeast(logger_pipe_version.major, logger_pipe_version.minor);

    const command: render.Command = if (use_executor)
        .executor
    else
        .{ .native = if (u.exec_start.len == 0) &.{"/bin/true"} else try self.commandWords(u.exec_start[0]) };
    const in: render.Input = .{
        .unit = u,
        .mode = mode,
        .command = command,
        .identity = ids.daemon,
        .call_wrapper = ids.call,
        .deps = try self.mapDependencies(svc, u, input.deps),
        .executor_path = policy.executor_path,
        .setpriv_path = (try self.findProgram("setpriv")) orelse "/usr/bin/setpriv",
        .logging = if (pipes) .pipe else .file,
        .log_dir = logpath.logDir(self.ctx, u.name.full),
        .pidfile = try pidFile(gpa, self.ctx, u, svc, mode),
        .exec_pid_file = try executor.execPidPath(self.ctx, u.name.full),
        .exit_file = try executor.execExitPath(self.ctx, u.name.full),
        .notes = try notesFor(gpa, u, mode),
    };
    const body = try render.script(gpa, in);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);

    const dir = try layout.generationDir(self.ctx, self.dirs, u.scope);
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    files[0] = .{ .path = try std.fs.path.join(gpa, &.{ dir, svc }), .content = content, .mode = 0o755 };
    return .{ .service_name = svc, .files = files };
}

// ---- enablement -------------------------------------------------------------------------

fn linkPath(self: *OpenRc, service: []const u8) ![]const u8 {
    const dir = try layout.runlevelDir(self.ctx, self.dirs, layout.runlevel(self.dirs));
    return std.fs.path.join(self.ctx.gpa, &.{ dir, service });
}

fn linked(self: *OpenRc, link: []const u8) bool {
    _ = self.ctx.fs.lstat(link) catch return false;
    return true;
}

fn rcArgv(env: Env, tool: []const u8, tail: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, tool);
    if (env.ctx.scope == .user) try argv.append(env.ctx.gpa, "--user");
    try argv.appendSlice(env.ctx.gpa, tail);
    return argv.items;
}

fn runRc(env: Env, tool: []const u8, tail: []const []const u8, stdio: runner.Stdio) !runner.Result {
    return env.runner.run(env.ctx.gpa, try rcArgv(env, tool, tail), stdio);
}

fn mustRun(env: Env, tail: []const []const u8) anyerror!void {
    const res = try runRc(env, rc_update, tail, .quiet);
    if (res.code != 0) return error.CommandFailed;
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    const link = try self.linkPath(service);
    if (self.linked(link)) return &.{};
    const script = (try layout.locate(self.ctx, self.dirs, service)) orelse blk: {
        // A dry run has not written the script yet.
        if (env.ctx.dry_run) break :blk try std.fs.path.join(gpa, &.{ try layout.generationDir(self.ctx, self.dirs, self.ctx.scope), service });
        env.ctx.diag.err("{s}: no init script found", .{service});
        return error.Unsupported;
    };
    const changes = try gpa.alloc(interface.Change, 1);
    changes[0] = .{ .created = .{ .link = link, .target = script } };
    if (env.ctx.dry_run) return changes;
    if (env.online) {
        try mustRun(env, &.{ "add", service, layout.runlevel(self.dirs) });
    } else {
        try self.ctx.fs.makePath(std.fs.path.dirname(link) orelse "/");
        try self.ctx.fs.symLink(script, link);
    }
    return changes;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const link = try self.linkPath(service);
    if (!self.linked(link)) return &.{};
    const changes = try env.ctx.gpa.alloc(interface.Change, 1);
    changes[0] = .{ .removed = link };
    if (env.ctx.dry_run) return changes;
    if (env.online) {
        try mustRun(env, &.{ "del", service, layout.runlevel(self.dirs) });
    } else try self.ctx.fs.deleteFile(link);
    return changes;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    return if (self.linked(try self.linkPath(service))) .enabled else .disabled;
}

// ---- runtime control --------------------------------------------------------------------

/// What `rc-service` reports for `service`.
const Probe = struct {
    code: u8,
    stdout: []const u8,
    state: output.ActiveState,
    pid: ?u32,
};

fn readState(self: *OpenRc, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const path = std.fmt.allocPrint(self.ctx.gpa, fmt, args) catch return null;
    return self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 4096) catch null;
}

/// Main process of the service: the one its executor recorded, else the child `supervise-daemon`
/// supervises, else the process in
/// the pid file `start-stop-daemon` recorded.
fn pidOf(self: *OpenRc, service: []const u8) ?u32 {
    if (self.generatedUnit(service)) |unit| {
        if (executor.execPidPath(self.ctx, unit) catch null) |path| {
            if (self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 64) catch null) |text| {
                if (native.parsePid(text)) |pid| return pid;
            }
        }
    }
    const state = layout.stateDir(self.ctx) catch return null;
    if (self.readState("{s}/options/{s}/child_pid", .{ state, service })) |text| {
        if (native.parsePid(text)) |pid| return pid;
    }
    const path = if (self.readState("{s}/options/{s}/pidfile", .{ state, service })) |text|
        std.mem.trim(u8, text, " \t\r\n")
    else if (self.readState("{s}/daemons/{s}/001", .{ state, service })) |text|
        native.pidfileOfDaemon(text) orelse return null
    else
        return null;
    if (path.len == 0) return null;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 64) catch return null;
    return native.parsePid(text);
}

/// True when a supervisor gave up on the service: it is `stopped` with a `failed` marker.
fn markedFailed(self: *OpenRc, service: []const u8) bool {
    const state = layout.stateDir(self.ctx) catch return false;
    const path = std.fs.path.join(self.ctx.gpa, &.{ state, "failed", service }) catch return false;
    _ = self.ctx.fs.lstat(path) catch return false;
    return true;
}

/// Flags recorded in a generated script; none for native services.
fn flagsOf(self: *OpenRc, service: []const u8) native.Flags {
    const path = (layout.locate(self.ctx, self.dirs, service) catch return .{}) orelse return .{};
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 20) catch return .{};
    const parsed = marker.parse(content) orelse return .{};
    return native.parseFlags(parsed.rest);
}

/// Unit recorded in the marker of the script, null for native services.
fn generatedUnit(self: *OpenRc, service: []const u8) ?[]const u8 {
    const path = (layout.locate(self.ctx, self.dirs, service) catch return null) orelse return null;
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 20) catch return null;
    const parsed = marker.parse(content) orelse return null;
    return parsed.marker.unit;
}

/// How the executor recorded the end of the service, when it ran with `--record-exit`.
fn recordedExit(self: *OpenRc, service: []const u8) ?native.Exit {
    const unit = self.generatedUnit(service) orelse return null;
    const path = executor.execExitPath(self.ctx, unit) catch return null;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 64) catch return null;
    return native.parseExit(text);
}

/// Path of the pid file start-stop-daemon keeps for a service that runs its executor in the
/// background.
fn ssdPidFile(self: *OpenRc, service: []const u8) ![]const u8 {
    const dir = if (self.ctx.scope == .user) self.ctx.xdg_runtime_dir else "/run";
    return std.fmt.allocPrint(self.ctx.gpa, "{s}/{s}.fake-systemd.pid", .{ dir, service });
}

/// True when the executor of a recording service has ended: it wrote its exit file, or the
/// process of its pid file is gone. A start-stop-daemon that registers no daemon with OpenRC, as
/// the one of dpkg does not, leaves the service `started` after its death.
fn executorGone(self: *OpenRc, service: []const u8) bool {
    if (self.recordedExit(service) != null) return true;
    const path = self.ssdPidFile(service) catch return false;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 64) catch return false;
    const pid = native.parsePid(text) orelse return false;
    const proc = std.fmt.allocPrint(self.ctx.gpa, "/proc/{d}", .{pid}) catch return false;
    return !self.ctx.fs.exists(proc);
}

fn probe(self: *OpenRc, env: Env, service: []const u8) !Probe {
    const res = try runRc(env, rc_service, &.{ service, "status" }, .capture);
    const flags = self.flagsOf(service);
    var code = res.code;
    if (code == 0 and flags.record_exit and self.executorGone(service)) code = native.status_crashed;
    const failed = code == 3 and self.markedFailed(service);
    const exit = if (native.isCrashed(code)) self.recordedExit(service) else null;
    const state = native.stateOfStatus(code, failed, flags.transient, exit);
    const live = state == .active or state == .deactivating or state == .activating;
    return .{ .code = code, .stdout = res.stdout, .state = state, .pid = if (live) self.pidOf(service) else null };
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const p = try me(ptr).probe(env, service);
    return .{ .state = p.state, .pid = p.pid, .text = p.stdout };
}

fn rcService(env: Env, service: []const u8, action: []const u8) anyerror!void {
    const res = try runRc(env, rc_service, &.{ service, action }, .quiet);
    if (res.code != 0) return error.CommandFailed;
}

/// OpenRC reads the dependencies of services from a cache that `rc-update -u` and `openrc` write,
/// and does not notice a script that appeared since: a generated service and the services it
/// needs would start without each other. The cache is rebuilt when the script directory changed
/// after it was written.
fn refreshDependencies(self: *OpenRc, env: Env) !void {
    if (env.ctx.dry_run) return;
    const cache = try std.fs.path.join(env.ctx.gpa, &.{ try layout.stateDir(self.ctx), "deptree" });
    const dir = try layout.generationDir(self.ctx, self.dirs, self.ctx.scope);
    if (self.ctx.fs.stat(cache)) |c| {
        const d = self.ctx.fs.stat(dir) catch return;
        if (d.mtime_ns < c.mtime_ns) return;
    } else |_| {}
    const res = try runRc(env, rc_update, &.{"-u"}, .quiet);
    if (res.code != 0) env.ctx.diag.warn("rc-update -u failed, OpenRC may not know the services that were generated", .{});
}

/// `rc-service start` does nothing for a service recorded as started: a service whose process
/// is gone, and a oneshot that finished, are restarted instead.
fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    if (env.ctx.dry_run) return rcService(env, service, "start");
    try self.refreshDependencies(env);
    const p = try self.probe(env, service);
    const finished = self.flagsOf(service).transient and p.code == 0;
    if (native.isCrashed(p.code) and self.flagsOf(service).record_exit) {
        try rcService(env, service, "zap");
        return rcService(env, service, "start");
    }
    if (native.isCrashed(p.code) or finished) return rcService(env, service, "restart");
    return rcService(env, service, "start");
}

/// A service a supervisor gave up on is already stopped; `zap` resets its failed marker, which
/// `stop` leaves alone.
fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    if (self.markedFailed(service)) return rcService(env, service, "zap");
    if (self.flagsOf(service).record_exit and self.executorGone(service)) return rcService(env, service, "zap");
    return rcService(env, service, "stop");
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).refreshDependencies(env);
    return rcService(env, service, "restart");
}

/// The `reload` of a generated script runs `ExecReload=` through the executor; a native
/// service keeps its own.
fn reload(_: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return rcService(env, service, "reload");
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const pid = self.pidOf(service) orelse {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const pid_text = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{pid});
    const res = try env.runner.run(env.ctx.gpa, &.{ "kill", "-s", name, pid_text }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

/// OpenRC rebuilds its dependency cache when a script changes; `rc-update -u` does it at once.
fn reloadManager(_: *anyopaque, env: Env) anyerror!void {
    if (env.ctx.dry_run) return;
    const res = try runRc(env, rc_update, &.{"-u"}, .quiet);
    if (res.code != 0) env.ctx.diag.warn("rc-update -u failed, OpenRC rebuilds its dependency cache at the next start", .{});
}

/// With `openrc-init` as PID 1 the shutdown goes through `openrc-shutdown`; under another PID 1
/// (sysvinit, BusyBox init) the `reboot`, `poweroff` and `halt` commands ask it.
fn power(ptr: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const self = me(ptr);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const pid1 = self.ctx.fs.readLink("/proc/1/exe", &buf) catch "";
    const openrc_pid1 = std.mem.eql(u8, std.fs.path.basename(pid1), openrc_init) and self.hasTool(openrc_shutdown);
    const argv: []const []const u8 = if (openrc_pid1) switch (action) {
        .reboot => &.{ openrc_shutdown, "-r", "now" },
        .poweroff => &.{ openrc_shutdown, "-p", "now" },
        .halt => &.{ openrc_shutdown, "-H", "now" },
    } else switch (action) {
        .reboot => &.{"reboot"},
        .poweroff => &.{"poweroff"},
        .halt => &.{"halt"},
    };
    const res = try env.runner.run(env.ctx.gpa, argv, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
}
