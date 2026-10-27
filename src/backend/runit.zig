// SPDX-License-Identifier: GPL-3.0-or-later
//! runit backend (§11.2): a service is a directory with `run`, `finish`, `log/run` and
//! `control/t`; a symlink to it in the runlevel directory makes `runsvdir` supervise it, and
//! `sv` controls it.
//!
//! `runsvdir` starts everything it finds, so "enabled at boot" is a link without a `down` file.
//! A service that is run without being enabled is linked together with a `down` file, which
//! keeps it from starting at boot, and stays linked once stopped. Disabling a running service
//! writes `down` and leaves the link, because removing the link makes `runsvdir` stop the
//! service; disabling any other service removes the link and waits until the `runsv` that
//! supervised it is gone, since a link restored before `runsvdir` noticed would be undone by
//! its next scan. Dependencies are `sv start` lines at the top of `run`, so each service a
//! generated `run` starts is linked with `down` too.
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
const shell = @import("shell.zig");
const network = @import("network.zig");
const runner = @import("runner.zig");
const render = @import("runit/render.zig");
const layout = @import("runit/layout.zig");
const files = @import("s6/files.zig");
const native = @import("runit/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Runit = @This();

pub const backend_name = "runit";
pub const generator_number = 2;

/// Capabilities of §11.2. `user_services` is set per instance, where a user service manager
/// is installed.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .supervision = true,
    .per_service_logger = true,
    .restart_policy = true,
};

/// What `run` expresses without the executor: `Environment=`, `UMask=`, and `User=` with
/// groups through `chpst -u`.
const native_support: policy.Native = .{
    .environment = true,
    .group = true,
    .umask = true,
};

const sv = "sv";
const power_tool = "runit-init";
const turnstile_backend = "/usr/libexec/turnstile/runit";
const turnstile_conf = "/etc/turnstile/turnstiled.conf";
const turnstile_runit_conf = "/etc/turnstile/backend/runit.conf";

/// Seconds `sv stop` waits before it kills a service without `TimeoutStopSec=`; systemd's
/// default.
const default_stop_wait: u64 = 90;
/// How long to wait for `runsvdir` (which scans every 5 s) to start supervising a new link.
const supervise_wait_ms = 8000;
const supervise_poll_ms = 250;
const max_dependency_depth = 16;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
/// A turnstile runit instance runs `runsvdir` for each user.
user_manager: bool = false,
/// Directory turnstile's `runsvdir` scans, when its configuration names one.
user_service_dir: ?[]const u8 = null,
/// Replaces the check of which services are enabled when the network targets are mapped; for
/// tests.
enabled_override: ?[]const []const u8 = null,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) Runit {
    var self: Runit = .{ .ctx = ctx, .dirs = dirs };
    self.detectUserManager();
    return self;
}

pub fn backend(self: *Runit) Backend {
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
    .service_of_file = layout.serviceOfFile,
};

fn me(ptr: *anyopaque) *Runit {
    return @ptrCast(@alignCast(ptr));
}

// ---- user service manager ---------------------------------------------------------------

fn readSmall(self: *Runit, path: []const u8) ?[]const u8 {
    return self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 16) catch null;
}

/// Value of `key = value` (turnstiled.conf) or `key="value"` (shell) on a line of `text`.
fn assignment(text: []const u8, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const rest = std.mem.cutPrefix(u8, line, key) orelse continue;
        const eq = std.mem.trimStart(u8, rest, " \t");
        if (eq.len == 0 or eq[0] != '=') continue;
        found = std.mem.trim(u8, eq[1..], " \t\"'");
    }
    return found;
}

/// Turns a `services_dir` value such as `${HOME}/.config/service` into a path.
fn expandServiceDir(self: *Runit, value: []const u8) ?[]const u8 {
    for ([_][]const u8{ "${HOME}/", "$HOME/", "~/" }) |prefix| {
        if (std.mem.cutPrefix(u8, value, prefix)) |rest| return std.fs.path.join(self.ctx.gpa, &.{ self.ctx.home, rest }) catch null;
    }
    return if (value.len > 0 and value[0] == '/' and std.mem.findScalar(u8, value, '$') == null) value else null;
}

/// User services need turnstile with its runit backend: it runs a `runsvdir` per user on
/// `services_dir`, which defaults to `~/.config/service`.
fn detectUserManager(self: *Runit) void {
    if (!self.ctx.fs.exists(turnstile_backend)) return;
    const conf = self.readSmall(turnstile_conf) orelse return;
    const selected = assignment(conf, "backend") orelse return;
    if (!std.mem.eql(u8, selected, "runit")) return;
    self.user_manager = true;
    const runit_conf = self.readSmall(turnstile_runit_conf) orelse return;
    if (assignment(runit_conf, "services_dir")) |dir| self.user_service_dir = self.expandServiceDir(dir);
}

// ---- scanning ---------------------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return .{
        .dirs = try layout.lookupDirs(self.ctx, self.dirs, self.ctx.scope),
        .extractor = native.extractCommand,
        .entry_file = "run",
    };
}

/// The generation directory is read twice: for the scripts that carry their own marker, and for
/// the service directories that list their started services in a meta file.
fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const dirs = try gpa.alloc(rebuild.ScanDir, 2);
    const path = try layout.generationDir(self.ctx, self.dirs, scope);
    const tier: core.Tier = if (scope == .user) .personal else .admin;
    dirs[0] = .{ .path = path, .tier = tier, .nested = true };
    dirs[1] = .{ .path = path, .tier = tier };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn serviceExists(self: *Runit, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

/// runit name of the service a dependency refers to, or null when it cannot be a service:
/// targets (runit has no equivalent of the network targets), other unit types, and units that
/// are neither a runit service nor a systemd unit that can be translated.
fn mapDependency(self: *Runit, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
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

fn networkService(self: *Runit, target: []const u8) !?[]const u8 {
    const candidates = if (std.mem.eql(u8, target, "network-online.target"))
        self.dirs.network_online
    else if (std.mem.eql(u8, target, "network.target"))
        self.dirs.network
    else
        return null;
    for (candidates) |c| if (try self.serviceExists(c)) return c;
    return null;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

fn mapList(self: *Runit, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, exclude: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    for (deps) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        if (contains(exclude, mapped) or contains(out.items, mapped)) continue;
        try out.append(self.ctx.gpa, mapped);
    }
}

fn accountKnown(self: *Runit, file: []const u8, account: []const u8) bool {
    if (shell.allDigits(account)) return true;
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

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// True when `run` cannot carry the unit's settings itself and the executor has to. Without
/// `setpriv`, `chpst` takes account names, never numbers, and `-u` needs a group to take
/// supplementary groups; either way groups need a user.
fn nativeBlocked(u: *const model.Unit, have_setpriv: bool) bool {
    if (!have_setpriv) {
        if (u.user) |user| if (numeric(user)) return true;
        if (u.group) |g| if (numeric(g)) return true;
        for (u.supplementary_groups) |g| if (numeric(g)) return true;
        if (u.supplementary_groups.len > 0 and u.group == null) return true;
    }
    const has_groups = u.group != null or u.supplementary_groups.len > 0;
    if (has_groups and u.user == null) return true;
    for (u.environment) |e| if (!validEnvName(e.name)) return true;
    return false;
}

/// True when the static executor can switch to the unit's user and groups from `/etc/passwd`
/// and `/etc/group`; it then applies the user's supplementary groups as `initgroups` does.
fn executorResolves(self: *Runit, u: *const model.Unit) bool {
    if (u.scope == .user) return false;
    const user = u.user orelse return false;
    if (!self.accountKnown("/etc/passwd", user)) return false;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
    return true;
}

fn plainAccounts(u: *const model.Unit) bool {
    var plain = render.plainAccount(u.user.?);
    if (u.group) |g| plain = plain and render.plainAccount(g);
    for (u.supplementary_groups) |g| plain = plain and render.plainAccount(g);
    return plain;
}

/// An account the executor cannot resolve (LDAP, sssd) is passed to it as numeric ids that the
/// scripts look up, wherever they run it; the executor stays root and switches itself.
fn numericFor(self: *Runit, u: *const model.Unit, use_executor: bool) !?shell.Numeric {
    if (u.scope == .user) return null;
    const user = u.user orelse return null;
    if (self.executorResolves(u)) return null;
    if (!plainAccounts(u)) {
        if (!use_executor) return null;
        self.ctx.diag.err("{s}: User=, Group= and SupplementaryGroups= must be plain names to be looked up by the system libc", .{u.name.full});
        return error.Unsupported;
    }
    return .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups };
}

/// How `run` switches to the account of a native command that the executor cannot resolve (LDAP,
/// sssd): `setpriv`, which is dynamically linked, so the system libc finds the user and
/// `--init-groups` applies its groups; without `setpriv`, `chpst -u` switches without the
/// supplementary groups of the user.
fn identityFor(self: *Runit, u: *const model.Unit, have_setpriv: bool, use_executor: bool) !?render.Identity {
    if (u.scope == .user or use_executor) return null;
    const user = u.user orelse return null;
    if (self.executorResolves(u)) return null;
    const plain = plainAccounts(u);
    if (have_setpriv and plain) return .{ .setpriv = .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups } };
    if (!have_setpriv) {
        self.ctx.diag.warn("{s}: setpriv is not installed, chpst switches to {s} without its supplementary groups", .{ u.name.full, user });
    }
    return .{ .chpst = try identitySpec(self.ctx.gpa, u) };
}

/// `chpst -u` argument: the user, then the group and the supplementary groups.
fn identitySpec(gpa: Allocator, u: *const model.Unit) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, u.user.?);
    if (u.group) |g| {
        try out.append(gpa, ':');
        try out.appendSlice(gpa, g);
        for (u.supplementary_groups) |s| {
            try out.append(gpa, ':');
            try out.appendSlice(gpa, s);
        }
    }
    return out.toOwnedSlice(gpa);
}

const command_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };

/// `name` found in the standard directories, or null when none holds it.
fn findProgram(self: *Runit, name: []const u8) !?[]const u8 {
    for (command_dirs) |dir| {
        const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, name });
        if (self.ctx.fs.exists(path)) return path;
    }
    return null;
}

/// `name` resolved against the standard directories, or `fallback` when none holds it.
fn resolveProgram(self: *Runit, name: []const u8, fallback: []const u8) ![]const u8 {
    return (try self.findProgram(name)) orelse fallback;
}

fn commandWords(self: *Runit, cmd: model.Command) ![]const []const u8 {
    const words = try self.ctx.gpa.dupe([]const u8, cmd.words);
    if (std.mem.findScalar(u8, words[0], '/') == null) words[0] = try self.resolveProgram(words[0], words[0]);
    return words;
}

fn svdirFor(self: *Runit, u: *const model.Unit) !?[]const u8 {
    if (u.scope != .user) return null;
    return try layout.enableDir(self.ctx, self.dirs, self.user_service_dir);
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);

    const have_setpriv = (try self.findProgram("setpriv")) != null;
    const reason = policy.executorReason(u.*, capabilities, native_support);
    const use_executor = (reason != null and reason.? != .no_command) or nativeBlocked(u, have_setpriv) or self.executorResolves(u);

    var needs: std.ArrayList([]const u8) = .empty;
    var wants: std.ArrayList([]const u8) = .empty;
    try self.mapList(svc, input.deps, u.requires, &.{}, &needs);
    try self.mapList(svc, input.deps, u.binds_to, &.{}, &needs);
    try self.mapList(svc, input.deps, u.wants, needs.items, &wants);
    if (network.mentions(u)) {
        for (try network.enabledProviders(gpa, self.dirs.network_providers, svc, self.enabledLookup())) |p| {
            if (!contains(needs.items, p) and !contains(wants.items, p)) try wants.append(gpa, p);
        }
    }

    const command: render.Command = if (use_executor)
        .executor
    else
        .{ .native = if (u.exec_start.len == 0) &.{"/bin/true"} else try self.commandWords(u.exec_start[0]) };
    const in: render.Input = .{
        .unit = u,
        .command = command,
        .identity = try self.identityFor(u, have_setpriv, use_executor),
        .numeric = try self.numericFor(u, use_executor),
        .hard = needs.items,
        .soft = wants.items,
        .svdir = try self.svdirFor(u),
        .executor_path = policy.executor_path,
        .sleep_path = try self.resolveProgram("sleep", "/usr/bin/sleep"),
        .setpriv_path = try self.resolveProgram("setpriv", "/usr/bin/setpriv"),
    };

    const dir = try std.fs.path.join(gpa, &.{ try layout.generationDir(self.ctx, self.dirs, u.scope), svc });
    try guard.requireNotOther(self.ctx, guard.claimDir(self.ctx, dir, u.name.full, &.{"run"}), u.name.full, dir);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    var set: files.Set = .init(gpa, input, generator, dir);
    set.starts = try std.mem.concat(gpa, []const u8, &.{ needs.items, wants.items });
    try set.script("run", try render.run(gpa, in), 0o755);
    if (render.needsFinish(u)) try set.script("finish", try render.finish(gpa, in), 0o755);
    try set.script("log/run", try render.log(gpa, u.name.full, u.scope, policy.executor_path), 0o755);
    if (render.needsStopControl(u)) try set.script("control/t", try render.stopControl(gpa, in), 0o755);
    return .{ .service_name = svc, .files = try set.done() };
}

// ---- enablement -------------------------------------------------------------------------

fn enableDirPath(self: *Runit) ![]const u8 {
    return layout.enableDir(self.ctx, self.dirs, self.user_service_dir);
}

fn linkPath(self: *Runit, service: []const u8) ![]const u8 {
    return std.fs.path.join(self.ctx.gpa, &.{ try self.enableDirPath(), service });
}

fn downPath(self: *Runit, service: []const u8) !?[]const u8 {
    const dir = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    return try std.fs.path.join(self.ctx.gpa, &.{ dir, "down" });
}

fn linked(self: *Runit, link: []const u8) bool {
    _ = self.ctx.fs.lstat(link) catch return false;
    return true;
}

fn hasDown(self: *Runit, service: []const u8) bool {
    const path = (self.downPath(service) catch return false) orelse return false;
    return self.ctx.fs.exists(path);
}

/// Creates the link of `service` and returns whether it was new.
fn makeLink(self: *Runit, service: []const u8, dir: []const u8) !bool {
    const link = try self.linkPath(service);
    if (self.linked(link)) return false;
    try self.ctx.fs.makePath(std.fs.path.dirname(link) orelse "/");
    try self.ctx.fs.symLink(dir, link);
    return true;
}

fn writeDown(self: *Runit, path: []const u8) !void {
    try self.ctx.fs.writeFileAtomic(path, "", 0o644);
}

/// Links `service` with a `down` file unless it is linked already, so that `runsvdir`
/// supervises it without starting it. Returns true when the link is new.
fn linkIdle(self: *Runit, service: []const u8) !bool {
    const dir = (try layout.locate(self.ctx, self.dirs, service)) orelse return false;
    if (self.linked(try self.linkPath(service))) return false;
    const down = try std.fs.path.join(self.ctx.gpa, &.{ dir, "down" });
    if (!self.ctx.fs.exists(down)) try self.writeDown(down);
    return try self.makeLink(service, dir);
}

/// Services the generated service of `service` starts, in order.
fn dependencies(self: *Runit, service: []const u8) ![]const []const u8 {
    const dir = (try layout.locate(self.ctx, self.dirs, service)) orelse return &.{};
    return guard.startedServices(self.ctx, dir);
}

/// Links the services `service` starts, and those they start in turn, idle. Services that
/// were linked now are appended to `created`.
fn linkDependencies(self: *Runit, service: []const u8, created: *std.ArrayList([]const u8), depth: usize) !void {
    if (depth > max_dependency_depth) return;
    for (try self.dependencies(service)) |dep| {
        if (try self.linkIdle(dep)) try created.append(self.ctx.gpa, dep);
        try self.linkDependencies(dep, created, depth + 1);
    }
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const dir = (try layout.locate(self.ctx, self.dirs, service)) orelse blk: {
        // A dry run has not written the service directory yet.
        if (env.ctx.dry_run) break :blk try std.fs.path.join(env.ctx.gpa, &.{ try layout.generationDir(self.ctx, self.dirs, self.ctx.scope), service });
        env.ctx.diag.err("{s}: no service directory found", .{service});
        return error.Unsupported;
    };
    var changes: std.ArrayList(interface.Change) = .empty;
    const link = try self.linkPath(service);
    if (!self.linked(link)) {
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
    }
    return changes.items;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const link = try self.linkPath(service);
    if (!self.linked(link)) return &.{};
    const changes = try env.ctx.gpa.alloc(interface.Change, 1);
    var supervised = false;
    if (env.online) {
        const st = try self.statusOf(env, service);
        if (st.state == .active or st.state == .activating or st.state == .deactivating) {
            const down = (try self.downPath(service)) orelse return &.{};
            if (self.ctx.fs.exists(down)) return &.{};
            if (!env.ctx.dry_run) try self.writeDown(down);
            changes[0] = .{ .created_file = down };
            return changes;
        }
        supervised = native.hasStatusLine(st.text);
    }
    changes[0] = .{ .removed = link };
    if (env.ctx.dry_run) return changes;
    try self.ctx.fs.deleteFile(link);
    if (supervised) self.waitGone(env, service);
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

fn enabledLookup(self: *Runit) network.Enabled {
    return .{ .ptr = self, .is_enabled = serviceEnabled, .injected = self.enabled_override };
}

// ---- runtime control --------------------------------------------------------------------

/// What `sv` is given for `service`: the name, which `sv` resolves in its own service
/// directory, or for a user service the path of the link, since `sv` has no way to know the
/// directory of a user's `runsvdir`.
fn svTarget(self: *Runit, service: []const u8) ![]const u8 {
    if (self.ctx.scope == .system) return service;
    return self.linkPath(service);
}

fn runSv(self: *Runit, env: Env, pre: []const []const u8, action: []const u8, service: []const u8, stdio: runner.Stdio) !runner.Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(env.ctx.gpa, sv);
    try argv.appendSlice(env.ctx.gpa, pre);
    try argv.append(env.ctx.gpa, action);
    try argv.append(env.ctx.gpa, try self.svTarget(service));
    return env.runner.run(env.ctx.gpa, argv.items, stdio);
}

fn statusOf(self: *Runit, env: Env, service: []const u8) !interface.Status {
    const res = try self.runSv(env, &.{}, "status", service, .capture);
    return native.parseStatus(res.stdout, self.verdictOf(service));
}

fn exitStatusPath(self: *Runit, service: []const u8) !?[]const u8 {
    const dir = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    return try std.fs.path.join(self.ctx.gpa, &.{ dir, "supervise", render.exit_status_file });
}

fn verdictOf(self: *Runit, service: []const u8) ?native.Verdict {
    const path = (self.exitStatusPath(service) catch return null) orelse return null;
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 256) catch return null;
    return native.parseVerdict(text);
}

fn forgetExit(self: *Runit, env: Env, service: []const u8) void {
    if (env.ctx.dry_run) return;
    const path = (self.exitStatusPath(service) catch return) orelse return;
    self.ctx.fs.deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => env.ctx.diag.warn("{s}: cannot remove {s}: {t}", .{ service, path, e }),
    };
}

fn sleepMs(env: Env, ms: u64) void {
    env.ctx.io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch return;
}

/// Waits until a `runsv` supervises `service`; a new link is only noticed at the next scan.
fn waitSupervised(self: *Runit, env: Env, service: []const u8) void {
    if (env.ctx.dry_run) return;
    var waited: u64 = 0;
    while (waited <= supervise_wait_ms) : (waited += supervise_poll_ms) {
        const res = self.runSv(env, &.{}, "status", service, .capture) catch return;
        if (!native.notSupervised(res.stdout)) return;
        sleepMs(env, supervise_poll_ms);
    }
    env.ctx.diag.warn("{s}: runsvdir did not start supervising the service in time", .{service});
}

/// Waits until the `runsv` of an unlinked service has exited, which `runsvdir` does at its
/// next scan; `sv` is given the service directory because the name no longer resolves.
fn waitGone(self: *Runit, env: Env, service: []const u8) void {
    const dir = (layout.locate(self.ctx, self.dirs, service) catch return) orelse return;
    var waited: u64 = 0;
    while (waited <= supervise_wait_ms) : (waited += supervise_poll_ms) {
        const res = env.runner.run(env.ctx.gpa, &.{ sv, "status", dir }, .capture) catch return;
        if (!native.hasStatusLine(res.stdout)) return;
        sleepMs(env, supervise_poll_ms);
    }
    env.ctx.diag.warn("{s}: runsvdir did not stop supervising the removed link in time", .{service});
}

fn reportFailure(env: Env, service: []const u8, res: runner.Result) void {
    const text = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (text.len > 0) env.ctx.diag.err("{s}: sv: {s}", .{ service, text });
}

/// Sends `action` (`start` or `restart`) after the service and its dependencies are linked
/// and supervised. `sv` waits for the `run` state, so a service that ends at once reads as a
/// failure; one whose `finish` recorded an end is a start that happened.
fn begin(self: *Runit, env: Env, service: []const u8, action: []const u8) !void {
    var created: std.ArrayList([]const u8) = .empty;
    if (!env.ctx.dry_run) {
        try self.linkDependencies(service, &created, 0);
        if (try self.linkIdle(service)) try created.append(env.ctx.gpa, service);
    }
    for (created.items) |name| self.waitSupervised(env, name);
    self.forgetExit(env, service);
    const pre: []const []const u8 = if (self.waitsOf(service).start) |s| try waitArgs(env.ctx.gpa, s) else &.{};
    var res = try self.runSv(env, pre, action, service, .quiet);
    if (res.code != 0 and native.notSupervised(res.stdout)) {
        self.waitSupervised(env, service);
        res = try self.runSv(env, pre, action, service, .quiet);
    }
    if (res.code == 0) return;
    if (self.verdictOf(service) != null) {
        const st = try self.statusOf(env, service);
        if (st.state == .inactive or st.state == .failed) return;
    }
    reportFailure(env, service, res);
    return error.CommandFailed;
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).begin(env, service, "start");
}

/// A stop followed by a start: `sv restart` would start the service again whatever its
/// `finish` decided for the exit, but `finish` keeps a `Restart=no` service down after the
/// restart's own SIGTERM.
fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.stopService(env, service);
    try self.begin(env, service, "start");
}

/// Stops the service, killing it after the timeout, and forgets how it ended.
fn stopService(self: *Runit, env: Env, service: []const u8) !void {
    const wait = try waitArgs(env.ctx.gpa, self.waitsOf(service).stop orelse default_stop_wait);
    const res = try self.runSv(env, wait, "force-stop", service, .quiet);
    if (res.code != 0) {
        const st = try self.statusOf(env, service);
        if (st.state != .inactive and st.state != .failed) {
            reportFailure(env, service, res);
            return error.CommandFailed;
        }
    }
    self.forgetExit(env, service);
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    try me(ptr).stopService(env, service);
}

fn waitArgs(gpa: Allocator, seconds: u64) Allocator.Error![]const []const u8 {
    const args = try gpa.alloc([]const u8, 2);
    args[0] = "-w";
    args[1] = try std.fmt.allocPrint(gpa, "{d}", .{seconds});
    return args;
}

/// `sv` waits recorded in a generated `run`; none for native services.
fn waitsOf(self: *Runit, service: []const u8) render.Waits {
    const dir = (layout.locate(self.ctx, self.dirs, service) catch return .{}) orelse return .{};
    const path = std.fs.path.join(self.ctx.gpa, &.{ dir, "run" }) catch return .{};
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, path, 1 << 20) catch return .{};
    const parsed = marker.parse(content) orelse return .{};
    return native.parseWaits(parsed.rest);
}

/// Unit recorded in the marker of the `run` script, null for native services.
fn generatedUnit(self: *Runit, service: []const u8) !?[]const u8 {
    const dir = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, "run" });
    const content = (try guard.readOrAbsent(self.ctx, path, 1 << 20)) orelse return null;
    return guard.unitOfMarked(content);
}

/// `ExecReload=` runs through the executor, which gets the pid `runsv` supervises as
/// `$MAINPID`; a service fake-systemd did not generate gets `sv reload`, which runs its own
/// `control/h` or sends SIGHUP.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    if (try self.generatedUnit(service)) |unit_name| {
        var argv: std.ArrayList([]const u8) = .empty;
        if ((try self.statusOf(env, service)).pid) |pid| {
            try argv.appendSlice(gpa, &.{ "env", try std.fmt.allocPrint(gpa, "MAINPID={d}", .{pid}) });
        }
        try argv.appendSlice(gpa, guard.executorPrefix(env.ctx, unit_name));
        try argv.appendSlice(gpa, &.{ policy.executor_path, "--exec", unit_name });
        if (env.ctx.scope == .user) try argv.append(gpa, "--user");
        try argv.appendSlice(gpa, &.{ "--phase", "reload" });
        const res = try env.runner.run(gpa, argv.items, .inherit);
        if (res.code != 0) return error.CommandFailed;
        return;
    }
    const res = try self.runSv(env, &.{}, "reload", service, .quiet);
    if (res.code != 0) {
        reportFailure(env, service, res);
        return error.CommandFailed;
    }
}

/// `sv` command letter for the signals it can send; others go through `kill`.
fn svSignal(name: []const u8) ?[]const u8 {
    const map = [_]struct { name: []const u8, action: []const u8 }{
        .{ .name = "HUP", .action = "hup" },
        .{ .name = "INT", .action = "interrupt" },
        .{ .name = "QUIT", .action = "quit" },
        .{ .name = "USR1", .action = "1" },
        .{ .name = "USR2", .action = "2" },
        .{ .name = "ALRM", .action = "alarm" },
        .{ .name = "TERM", .action = "term" },
        .{ .name = "KILL", .action = "kill" },
        .{ .name = "STOP", .action = "pause" },
        .{ .name = "CONT", .action = "cont" },
    };
    for (map) |m| if (std.mem.eql(u8, m.name, name)) return m.action;
    return null;
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    if (svSignal(name)) |action| {
        const res = try self.runSv(env, &.{}, action, service, .quiet);
        if (res.code != 0) {
            reportFailure(env, service, res);
            return error.CommandFailed;
        }
        return;
    }
    const st = try self.statusOf(env, service);
    const pid = guard.accepted(self.ctx, st.pid, null) orelse {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const pid_text = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{pid});
    const res = try env.runner.run(env.ctx.gpa, &.{ "kill", "-s", name, pid_text }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    return me(ptr).statusOf(env, service);
}

/// True when `target` is a service directory of the generation directory that has nothing left
/// but what runit and the generation leave behind, which is what a removed unit looks like.
fn generatedLeftover(self: *Runit, target: []const u8) bool {
    const gen = layout.generationDir(self.ctx, self.dirs, self.ctx.scope) catch return false;
    const parent = std.fs.path.dirname(target) orelse return false;
    if (!std.mem.eql(u8, parent, gen)) return false;
    return guard.abandonedServiceDir(self.ctx, target);
}

/// `runsvdir` rescans its directory every five seconds and `runsv` reads `run` at each start,
/// so there is nothing to reload; links to a service directory of the generation directory
/// that holds nothing but leftovers of a removed unit are removed, as generated dependencies
/// are collected without a call to `disable`.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    if (env.ctx.dry_run) return;
    const dir = try self.enableDirPath();
    const entries = try guard.iterateOrEmpty(self.ctx, dir);
    for (entries) |entry| {
        if (entry.kind != .sym_link) continue;
        const link = try std.fs.path.join(env.ctx.gpa, &.{ dir, entry.name });
        if (self.ctx.fs.exists(try std.fs.path.join(env.ctx.gpa, &.{ link, "run" }))) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = self.ctx.fs.readLink(link, &buf) catch continue;
        if (!self.generatedLeftover(target)) continue;
        self.ctx.fs.deleteFile(link) catch |e| env.ctx.diag.warn("cannot remove {s}: {t}", .{ link, e });
    }
}

/// runit-init 0 and 6 ask the init to run stage 3 and power off or reboot; runit has no
/// separate halt.
fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const arg = switch (action) {
        .reboot => "6",
        .poweroff, .halt => "0",
    };
    const res = try env.runner.run(env.ctx.gpa, &.{ power_tool, arg }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
}
