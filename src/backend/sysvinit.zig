// SPDX-License-Identifier: GPL-3.0-or-later
//! sysvinit backend (§11.2), Debian/Devuan and Red Hat flavours: a service is an LSB init script
//! in `/etc/init.d`, links in `/etc/rc<N>.d` enable it, and the script itself controls it.
//!
//! Nothing supervises a service: it runs under the executor in the background and stays dead
//! when it dies, and `status` is the exit status of `<script> status`. Enabling runs
//! `update-rc.d` or `chkconfig` with the variables that keep them from calling `systemctl`,
//! which is this program.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const profile = @import("../detect/profile.zig");
const InitKind = @import("../detect/kind.zig").InitKind;
const model = @import("../unit/model.zig");
const name_mod = @import("../unit/name.zig");
const resolve = @import("../unit/resolve.zig");
const marker = @import("../index/marker.zig");
const rebuild = @import("../index/rebuild.zig");
const apply = @import("../reconcile/apply.zig");
const logpath = @import("../exec/logpath.zig");
const executor = @import("../exec/executor.zig");
const daemon = @import("../exec/daemon.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const runner = @import("runner.zig");
const shell = @import("shell.zig");
const render = @import("sysvinit/render.zig");
const layout = @import("sysvinit/layout.zig");
const native = @import("sysvinit/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Sysvinit = @This();

pub const backend_name = "sysvinit";
pub const generator_number = 1;

/// Capabilities of §11.2: dependencies as ordering only, no supervision and no restart policy.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .ordering = true,
};

pub const Variant = render.Variant;

const update_rc = "update-rc.d";
const insserv = "insserv";
const chkconfig = "chkconfig";
/// Keeps `update-rc.d` from calling `systemctl enable|disable`.
const skip_systemd_native = "_SKIP_SYSTEMD_NATIVE=1";
/// Keeps `chkconfig` from forwarding `on` and `off` to `systemctl` for a script that has a unit.
const skip_redirect = "SYSTEMCTL_SKIP_REDIRECT=1";

const tool_dirs = [_][]const u8{ "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin" };
/// Number of scripts a script requires that `enable` follows.
const max_dependency_depth = 8;
/// Priorities of the links `enable` writes when no tool does.
const direct_start = 80;
const direct_stop = 20;

ctx: *core.Context,
dirs: *const profile.BackendDirs,
variant: Variant,
vt: interface.VTable = vtable,
/// Replaces the check of which programs are installed; for tests.
tools_override: ?[]const []const u8 = null,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs, variant: Variant) Sysvinit {
    return .{ .ctx = ctx, .dirs = dirs, .variant = variant };
}

pub fn backend(self: *Sysvinit) Backend {
    self.vt = vtable;
    return .{ .ptr = self, .vtable = &self.vt };
}

fn toolInstalled(ctx: *const core.Context, name: []const u8) bool {
    for (tool_dirs) |dir| {
        const path = std.fs.path.join(ctx.gpa, &.{ dir, name }) catch return false;
        if (ctx.fs.exists(path)) return true;
    }
    return false;
}

/// The flavour of `kind`; a generic sysvinit is Red Hat when it has `chkconfig` and neither of the
/// Debian tools.
pub fn variantFor(ctx: *const core.Context, kind: InitKind) Variant {
    switch (kind) {
        .sysvinit_redhat => return .redhat,
        .sysvinit_debian => return .debian,
        else => {},
    }
    const debian = toolInstalled(ctx, update_rc) or toolInstalled(ctx, insserv);
    return if (toolInstalled(ctx, chkconfig) and !debian) .redhat else .debian;
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

fn me(ptr: *anyopaque) *Sysvinit {
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
        .dirs = if (self.ctx.scope == .user) &.{} else layout.lookupDirs(self.dirs),
        .extractor = native.extractCommand,
    };
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    if (scope == .user) return &.{};
    const dirs = try gpa.alloc(rebuild.ScanDir, 1);
    dirs[0] = .{ .path = layout.generationDir(self.dirs), .tier = .admin };
    return dirs;
}

// ---- generation -------------------------------------------------------------------------

fn serviceExists(self: *Sysvinit, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

/// Script name of the service a dependency refers to, or null when it cannot be a script:
/// targets (the network ones are handled apart), other unit types, and units that are neither a
/// script nor a systemd unit that can be translated.
fn mapDependency(self: *Sysvinit, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
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

fn mapList(self: *Sysvinit, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, exclude: []const []const []const u8, out: *std.ArrayList([]const u8)) !void {
    outer: for (deps) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        // A trailing backslash would continue the header line in the parsers of the init tools.
        if (std.mem.endsWith(u8, mapped, "\\")) continue;
        for (exclude) |ex| if (contains(ex, mapped)) continue :outer;
        if (!contains(out.items, mapped)) try out.append(self.ctx.gpa, mapped);
    }
}

fn mentionsTarget(lists: []const []const []const u8) bool {
    for (lists) |list| for (list) |name| if (std.mem.eql(u8, name, "network.target") or std.mem.eql(u8, name, "network-online.target")) return true;
    return false;
}

/// `$network` is the LSB facility that `insserv` and `chkconfig` resolve to whatever brings the
/// network up. Both network targets map to it, since sysvinit has no point at which the network is online.
const network_facility = "$network";
const remote_fs = "$remote_fs";

/// `Before=` becomes `X-Start-Before`; the filesystems, and the network a hard dependency asks
/// for, are required facilities. The units a unit requires, wants or follows are `Should-Start` on
/// Debian, since `insserv` fails on a `Required-Start` that is not enabled, and the hard ones are `Required-Start` on Red Hat.
fn mapDependencies(self: *Sysvinit, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) !render.Deps {
    const gpa = self.ctx.gpa;
    var hard: std.ArrayList([]const u8) = .empty;
    var required: std.ArrayList([]const u8) = .empty;
    var should: std.ArrayList([]const u8) = .empty;
    var before: std.ArrayList([]const u8) = .empty;
    try self.mapList(own, resolutions, u.requires, &.{}, &hard);
    try self.mapList(own, resolutions, u.binds_to, &.{}, &hard);
    try required.append(gpa, remote_fs);
    if (self.variant == .redhat) try required.appendSlice(gpa, hard.items);
    if (mentionsTarget(&.{ u.requires, u.binds_to })) try required.append(gpa, network_facility);
    if (self.variant == .debian) try should.appendSlice(gpa, hard.items);
    try self.mapList(own, resolutions, u.wants, &.{ required.items, should.items }, &should);
    if (mentionsTarget(&.{ u.wants, u.after }) and !contains(required.items, network_facility)) try should.append(gpa, network_facility);
    try self.mapList(own, resolutions, u.after, &.{ required.items, should.items }, &should);
    try self.mapList(own, resolutions, u.before, &.{}, &before);
    return .{ .required = required.items, .should = should.items, .before = before.items, .pulls_in = hard.items };
}

fn accountKnown(self: *Sysvinit, file: []const u8, account: []const u8) bool {
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
/// and `/etc/group`.
fn executorResolves(self: *Sysvinit, u: *const model.Unit) bool {
    const user = u.user orelse return false;
    if (!self.accountKnown("/etc/passwd", user)) return false;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
    return true;
}

fn hasTool(self: *Sysvinit, name: []const u8) bool {
    if (self.tools_override) |tools| return contains(tools, name);
    return toolInstalled(self.ctx, name);
}

fn plainGroups(u: *const model.Unit) bool {
    if (u.group) |g| if (!shell.plainAccount(g)) return false;
    for (u.supplementary_groups) |g| if (!shell.plainAccount(g)) return false;
    return true;
}

/// An account the executor cannot resolve (LDAP, sssd) is passed to it as numeric ids that the
/// script looks up with `id` and `getent`; the executor stays root and switches to them itself.
fn identityFor(self: *Sysvinit, u: *const model.Unit) !render.Identity {
    if (u.scope == .user) return .{};
    const user = u.user orelse return .{};
    if (self.executorResolves(u)) return .{};
    if (!shell.plainAccount(user) or !plainGroups(u)) {
        self.ctx.diag.err("{s}: User=, Group= and SupplementaryGroups= must be plain names to be looked up by the system libc", .{u.name.full});
        return error.Unsupported;
    }
    return .{ .numeric = .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups } };
}

fn modeFor(u: *const model.Unit) render.Mode {
    if (u.exec_start.len == 0) return .none;
    if (u.service_type == .oneshot) return .oneshot;
    // A daemon without a pid file cannot be followed: the command runs to the end and the service
    // stays active.
    if (u.service_type == .forking and u.pid_file == null) return .oneshot;
    return .daemon;
}

fn remains(u: *const model.Unit, mode: render.Mode) bool {
    return switch (mode) {
        .daemon => false,
        .oneshot => u.remain_after_exit or u.service_type == .forking,
        .none => u.remain_after_exit,
    };
}

fn notesFor(gpa: Allocator, u: *const model.Unit, mode: render.Mode) ![]const []const u8 {
    var notes: std.ArrayList([]const u8) = .empty;
    if (u.service_type == .forking and mode == .oneshot) {
        try notes.append(gpa, "Type=forking without PIDFile=: the daemon is started but not followed, and stop cannot signal it");
    }
    if (mode == .daemon and u.restart != .no) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "Restart={t} is not honored: sysvinit does not supervise services, a service that dies stays dead", .{u.restart}));
    }
    if (u.kill_mode == .none or u.kill_mode == .mixed) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "KillMode={t} is handled like control-group", .{u.kill_mode}));
    }
    return notes.toOwnedSlice(gpa);
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    if (u.scope == .user) {
        self.ctx.diag.err("{s}: sysvinit has no service manager for users", .{u.name.full});
        return error.Unsupported;
    }
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);
    // A trailing backslash would continue the header line in the parsers of the init tools.
    if (std.mem.endsWith(u8, svc, "\\")) {
        self.ctx.diag.err("{s}: '{s}' is not a script name the init tools can read", .{ u.name.full, svc });
        return error.Unsupported;
    }
    const mode = modeFor(u);
    const exit_file = try executor.execExitPath(self.ctx, u.name.full);
    const in: render.Input = .{
        .unit = u,
        .variant = self.variant,
        .service = svc,
        .mode = mode,
        .remain = remains(u, mode),
        .identity = try self.identityFor(u),
        .deps = try self.mapDependencies(svc, u, input.deps),
        .executor_path = policy.executor_path,
        .state_dir = std.fs.path.dirname(exit_file) orelse "/run/fake-systemd",
        .log_dir = logpath.logDir(self.ctx, u.name.full),
        .daemon_pid_file = try daemon.daemonPidPath(self.ctx, u.name.full),
        .main_pid_file = try executor.execPidPath(self.ctx, u.name.full),
        .exit_file = exit_file,
        .notes = try notesFor(gpa, u, mode),
    };
    const body = try render.script(gpa, in);
    const generator = try interface.generatorLine(gpa, backend_name, generator_number);
    const content = try marker.compose(gpa, u.name.full, input.source, input.src_hash, generator, body);
    const path = try std.fs.path.join(gpa, &.{ layout.generationDir(self.dirs), svc });
    try guard.requireNotOther(self.ctx, guard.claimFile(self.ctx, path, u.name.full), u.name.full, path);
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    files[0] = .{ .path = path, .content = content, .mode = 0o755 };
    return .{ .service_name = svc, .files = files };
}

// ---- enablement -------------------------------------------------------------------------

const LinkState = enum {
    /// A start link in the default runlevel.
    enabled,
    /// Links exist, none of them starts the service in the default runlevel.
    disabled,
    none,
};

fn isEnabledLevel(default_level: u8, level: u8) bool {
    return level == default_level or level == 'S';
}

fn linkState(self: *Sysvinit, service: []const u8) !LinkState {
    const links = try layout.linksOf(self.ctx, self.dirs, service);
    const default_level = layout.defaultRunlevel(self.ctx, self.dirs);
    var any = false;
    for (links) |l| {
        any = true;
        if (l.start and isEnabledLevel(default_level, l.level)) return .enabled;
    }
    return if (any) .disabled else .none;
}

/// Content of the file at `path`, null when it does not exist; any other failure is an error, so a
/// script that cannot be read is never taken for an absent or native one.
fn contentOf(self: *Sysvinit, path: []const u8) !?[]const u8 {
    return self.ctx.fs.readFileAlloc(self.ctx.gpa, path, max_script_bytes) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

const max_script_bytes = 64 << 20;

/// True when the script was generated by fake-systemd.
fn isGenerated(self: *Sysvinit, path: []const u8) !bool {
    const content = (try self.contentOf(path)) orelse return false;
    return marker.parse(content) != null;
}

/// Unit recorded in the marker of the script, null for native scripts.
fn generatedUnit(self: *Sysvinit, service: []const u8) !?[]const u8 {
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    const content = (try self.contentOf(path)) orelse return null;
    const parsed = marker.parse(content) orelse return null;
    return parsed.marker.unit;
}

fn toolArgv(gpa: Allocator, env_var: []const u8, tool: []const u8, tail: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{ "env", env_var, tool });
    try argv.appendSlice(gpa, tail);
    return argv.items;
}

fn mustRun(env: Env, argv: []const []const u8) anyerror!void {
    const res = try env.runner.run(env.ctx.gpa, argv, .quiet);
    if (res.code != 0) return error.CommandFailed;
}

/// The tools write the links without an init running, so a chroot or a container build with the
/// tools installed uses them too; a root that is not the running one has none to call.
fn useTools(self: *Sysvinit, env: Env) bool {
    return env.online or self.ctx.fs.host_root;
}

/// Runlevels in `levels` that have a start link of the service.
fn startLevels(gpa: Allocator, links: []const layout.Found, levels: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (levels) |level| {
        for (links) |l| if (l.start and l.level == level) {
            try out.append(gpa, level);
            break;
        };
    }
    return out.toOwnedSlice(gpa);
}

fn linkFile(gpa: Allocator, dir: []const u8, starts: bool, number: u8, service: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(gpa, "{c}{d:0>2}{s}", .{ @as(u8, if (starts) 'S' else 'K'), number, service });
    return std.fs.path.join(gpa, &.{ dir, name });
}

fn hasLinkAt(links: []const layout.Found, level: u8) bool {
    for (links) |l| if (l.level == level) return true;
    return false;
}

/// Writes the links of a script without a tool: start links in the runlevels of its header, stop
/// links in the others, and a disabled script's stop links turn back into start links. The
/// numbers are those of `chkconfig:`, or late start and early stop ones that the tool sorts at its next run.
fn linkDirect(self: *Sysvinit, service: []const u8, script: []const u8) !void {
    const gpa = self.ctx.gpa;
    const header = try native.parseHeader(gpa, (try self.contentOf(script)) orelse "");
    const start_levels = if (header.default_start.len > 0) header.default_start else "2345";
    const stop_levels = if (header.default_stop.len > 0) header.default_stop else "016";
    const start_number = header.start_priority orelse direct_start;
    const stop_number = header.stop_priority orelse direct_stop;
    const links = try layout.linksOf(self.ctx, self.dirs, service);
    const target = try layout.linkTarget(gpa, service);
    for (start_levels) |level| {
        const dir = try layout.runlevelDir(gpa, self.dirs, level);
        var stopped: ?layout.Found = null;
        var started = false;
        for (links) |l| if (l.level == level) {
            if (l.start) started = true else stopped = l;
        };
        if (started) continue;
        if (stopped) |l| {
            try self.ctx.fs.rename(l.path, try linkFile(gpa, dir, true, l.number, service));
            continue;
        }
        try self.ctx.fs.makePath(dir);
        try self.ctx.fs.symLink(target, try linkFile(gpa, dir, true, start_number, service));
    }
    for (stop_levels) |level| {
        if (hasLinkAt(links, level)) continue;
        const dir = try layout.runlevelDir(gpa, self.dirs, level);
        try self.ctx.fs.makePath(dir);
        try self.ctx.fs.symLink(target, try linkFile(gpa, dir, false, stop_number, service));
    }
}

fn unlinkDirect(self: *Sysvinit, service: []const u8) !void {
    const gpa = self.ctx.gpa;
    const links = try layout.linksOf(self.ctx, self.dirs, service);
    for (links) |l| {
        if (!l.start or l.level == '0' or l.level == '1' or l.level == '6') continue;
        const dir = std.fs.path.dirname(l.path) orelse continue;
        try self.ctx.fs.rename(l.path, try linkFile(gpa, dir, false, l.number, service));
    }
}

/// Start links of `links` that `before` does not have: they were created.
fn diffLinks(gpa: Allocator, before: []const layout.Found, after: []const layout.Found, service: []const u8, changes: *std.ArrayList(interface.Change)) !void {
    for (after) |a| {
        if (!a.start) continue;
        const known = for (before) |b| {
            if (b.start and std.mem.eql(u8, b.path, a.path)) break true;
        } else false;
        if (!known) try changes.append(gpa, .{ .created = .{ .link = a.path, .target = try layout.linkTarget(gpa, service) } });
    }
    for (before) |b| {
        if (!b.start) continue;
        const kept = for (after) |a| {
            if (a.start and std.mem.eql(u8, b.path, a.path)) break true;
        } else false;
        if (!kept) try changes.append(gpa, .{ .removed = b.path });
    }
}

/// Relations of the generated script `content` of `service`, derived from its unit rather than
/// read back from the script; null for a script of someone else, or when the unit cannot be
/// loaded any more.
pub fn generatedDeps(self: *Sysvinit, service: []const u8, content: []const u8) !?render.Deps {
    const parsed = marker.parse(content) orelse return null;
    var u = executor.loadUnit(self.ctx, parsed.marker.unit) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    return try self.mapDependencies(service, &u, &.{});
}

/// Scripts that fake-systemd generated and that are not enabled, which the generated script `script` requires.
fn dependenciesToEnable(self: *Sysvinit, service: []const u8, script: []const u8) ![]const []const u8 {
    const gpa = self.ctx.gpa;
    const deps = (try self.generatedDeps(service, (try self.contentOf(script)) orelse return &.{})) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (deps.pulls_in) |dep| {
        if (dep.len == 0 or std.mem.eql(u8, dep, service)) continue;
        const path = (try layout.locate(self.ctx, self.dirs, dep)) orelse continue;
        if (!(try self.isGenerated(path))) continue;
        if ((try self.linkState(dep)) == .enabled) continue;
        try out.append(gpa, dep);
    }
    return out.items;
}

fn predictedLink(self: *Sysvinit, env: Env, service: []const u8) !interface.Change {
    const level = layout.defaultRunlevel(self.ctx, self.dirs);
    const dir = try layout.runlevelDir(env.ctx.gpa, self.dirs, level);
    return .{ .created = .{ .link = try linkFile(env.ctx.gpa, dir, true, direct_start, service), .target = try layout.linkTarget(env.ctx.gpa, service) } };
}

fn enableOne(self: *Sysvinit, env: Env, service: []const u8, changes: *std.ArrayList(interface.Change), depth: usize) anyerror!void {
    const gpa = env.ctx.gpa;
    const state = try self.linkState(service);
    const script = (try layout.locate(self.ctx, self.dirs, service)) orelse {
        if (state == .enabled) return;
        // A dry run has not written the script yet.
        if (env.ctx.dry_run) {
            try changes.append(gpa, try self.predictedLink(env, service));
            return;
        }
        env.ctx.diag.err("{s}: no init script found", .{service});
        return error.Unsupported;
    };
    // An enabled script may have been generated again with a new requirement.
    if (depth < max_dependency_depth) {
        for (try self.dependenciesToEnable(service, script)) |dep| try self.enableOne(env, dep, changes, depth + 1);
    }
    if (state == .enabled) return;
    if (env.ctx.dry_run) return changes.append(gpa, try self.predictedLink(env, service));
    const before = try layout.linksOf(self.ctx, self.dirs, service);
    switch (self.variant) {
        .debian => if (self.useTools(env) and self.hasTool(update_rc)) {
            const verb: []const u8 = if (state == .none) "defaults" else "enable";
            try mustRun(env, try toolArgv(gpa, skip_systemd_native, update_rc, &.{ service, verb }));
        } else try self.linkDirect(service, script),
        .redhat => if (self.useTools(env) and self.hasTool(chkconfig)) {
            try mustRun(env, try toolArgv(gpa, skip_redirect, chkconfig, &.{ service, "on" }));
        } else try self.linkDirect(service, script),
    }
    try diffLinks(gpa, before, try layout.linksOf(self.ctx, self.dirs, service), service, changes);
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    var changes: std.ArrayList(interface.Change) = .empty;
    try self.enableOne(env, service, &changes, 0);
    return changes.items;
}

/// A script that is enabled and has `service` in its `Required-Start`, when there is one:
/// `insserv` refuses the header of a script whose requirement is not enabled in its runlevels.
fn requiredByEnabled(self: *Sysvinit, service: []const u8) !?[]const u8 {
    const dir = layout.generationDir(self.dirs);
    const entries = try guard.iterateOrEmpty(self.ctx, dir);
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, service)) continue;
        const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, e.name });
        const content = (try self.contentOf(path)) orelse continue;
        const required = if (try self.generatedDeps(e.name, content)) |deps|
            deps.required
        else
            (try native.parseHeader(self.ctx.gpa, content)).required_start;
        if (!contains(required, service)) continue;
        if ((try self.linkState(e.name)) == .enabled) return e.name;
    }
    return null;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    if ((try self.linkState(service)) != .enabled) return &.{};
    if (self.variant == .debian) {
        if (try self.requiredByEnabled(service)) |dependent| {
            env.ctx.diag.err("{s}: required by {s}, which is enabled: disable that first, `insserv` would refuse its header", .{ service, dependent });
            return error.Unsupported;
        }
    }
    const before = try layout.linksOf(self.ctx, self.dirs, service);
    var changes: std.ArrayList(interface.Change) = .empty;
    if (env.ctx.dry_run) {
        const default_level = layout.defaultRunlevel(self.ctx, self.dirs);
        for (before) |l| if (l.start and isEnabledLevel(default_level, l.level)) try changes.append(gpa, .{ .removed = l.path });
        return changes.items;
    }
    switch (self.variant) {
        .debian => if (self.useTools(env) and self.hasTool(update_rc)) {
            var tail: std.ArrayList([]const u8) = .empty;
            try tail.appendSlice(gpa, &.{ service, "disable" });
            for (try startLevels(gpa, before, "S2345")) |level| try tail.append(gpa, try gpa.dupe(u8, &.{level}));
            try mustRun(env, try toolArgv(gpa, skip_systemd_native, update_rc, tail.items));
        } else try self.unlinkDirect(service),
        .redhat => if (self.useTools(env) and self.hasTool(chkconfig)) {
            const levels = try startLevels(gpa, before, "2345");
            try mustRun(env, try toolArgv(gpa, skip_redirect, chkconfig, &.{ "--level", levels, service, "off" }));
        } else try self.unlinkDirect(service),
    }
    try diffLinks(gpa, before, try layout.linksOf(self.ctx, self.dirs, service), service, &changes);
    return changes.items;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    return if ((try me(ptr).linkState(service)) == .enabled) .enabled else .disabled;
}

// ---- runtime control --------------------------------------------------------------------

/// Path of the script of `service`; a dry run has not written it yet.
fn scriptPath(self: *Sysvinit, env: Env, service: []const u8) ![]const u8 {
    if (try layout.locate(self.ctx, self.dirs, service)) |path| return path;
    if (env.ctx.dry_run) return std.fs.path.join(env.ctx.gpa, &.{ layout.generationDir(self.dirs), service });
    env.ctx.diag.err("{s}: no init script found", .{service});
    return error.Unsupported;
}

/// Last lines of the output of a script that failed: the scripts print their reasons to
/// standard output.
fn reportFailure(env: Env, service: []const u8, action: []const u8, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    const from = if (std.mem.findScalarLast(u8, trimmed[0..trimmed.len -| 1], '\n')) |at| at + 1 else 0;
    env.ctx.diag.err("{s} {s}: {s}", .{ service, action, trimmed[from..] });
}

fn control(self: *Sysvinit, env: Env, service: []const u8, action: []const u8) anyerror!void {
    const path = try self.scriptPath(env, service);
    const res = try env.runner.run(env.ctx.gpa, &.{ path, action }, .capture);
    if (res.code != 0) {
        reportFailure(env, service, action, res.stdout);
        return error.CommandFailed;
    }
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "start");
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "stop");
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "restart");
}

fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "reload");
}

/// Main process of a generated service from the file its executor writes, else the pid file a
/// native script commonly keeps. A pid is only taken when `guard.acceptPid` allows signaling it.
fn pidOf(self: *Sysvinit, service: []const u8) !?u32 {
    const gpa = self.ctx.gpa;
    if (!guard.serviceNameOk(service)) return null;
    if (try self.generatedUnit(service)) |unit| {
        const path = executor.execPidPath(self.ctx, unit) catch return null;
        return guard.recordedPid(self.ctx, path);
    }
    for ([_][]const u8{ "/run", "/var/run" }) |dir| {
        const path = std.fmt.allocPrint(gpa, "{s}/{s}.pid", .{ dir, service }) catch return null;
        if (guard.pidFromFile(self.ctx, path)) |pid| return pid;
    }
    return null;
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    const name = std.mem.cutPrefix(u8, signal, "SIG") orelse signal;
    const pid = (try self.pidOf(service)) orelse {
        env.ctx.diag.err("{s}: no process to signal", .{service});
        return error.CommandFailed;
    };
    const pid_text = try std.fmt.allocPrint(env.ctx.gpa, "{d}", .{pid});
    const res = try env.runner.run(env.ctx.gpa, &.{ "kill", "-s", name, pid_text }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const self = me(ptr);
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return .{ .state = .inactive };
    const res = try env.runner.run(env.ctx.gpa, &.{ path, "status" }, .capture);
    const state = native.stateOfStatus(res.code, native.looksLikeUsage(res.stdout));
    return .{ .state = state, .pid = if (state == .active) try self.pidOf(service) else null, .text = res.stdout };
}

// ---- manager ----------------------------------------------------------------------------

/// Enables what an enabled generated script pulls in, for a script that was generated again with
/// a new requirement.
fn pullIn(self: *Sysvinit, env: Env) !void {
    var scratch: std.ArrayList(interface.Change) = .empty;
    const dir = layout.generationDir(self.dirs);
    const entries = try guard.iterateOrEmpty(self.ctx, dir);
    for (entries) |e| {
        const path = try std.fs.path.join(env.ctx.gpa, &.{ dir, e.name });
        if (!(try self.isGenerated(path)) or (try self.linkState(e.name)) != .enabled) continue;
        for (try self.dependenciesToEnable(e.name, path)) |dep| {
            self.enableOne(env, dep, &scratch, 1) catch |err| env.ctx.diag.warn("{s}: cannot enable {s}, which {s} requires: {t}", .{ dep, dep, e.name, err });
        }
    }
}

/// `insserv` computes the boot order again, which a changed header needs, and drops dangling
/// links; `chkconfig` has no global counterpart, so the priorities of every enabled generated
/// script are read from its header again.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    if (env.ctx.dry_run) return;
    try self.pullIn(env);
    if (!self.useTools(env)) return;
    switch (self.variant) {
        .debian => {
            if (!self.hasTool(insserv)) return;
            const res = try env.runner.run(env.ctx.gpa, &.{insserv}, .quiet);
            if (res.code != 0) env.ctx.diag.warn("insserv failed, the boot order of the services was not computed again", .{});
        },
        .redhat => {
            if (!self.hasTool(chkconfig)) return;
            const dir = layout.generationDir(self.dirs);
            const entries = try guard.iterateOrEmpty(self.ctx, dir);
            for (entries) |e| {
                const path = try std.fs.path.join(env.ctx.gpa, &.{ dir, e.name });
                if (!(try self.isGenerated(path)) or (try self.linkState(e.name)) == .none) continue;
                const res = try env.runner.run(env.ctx.gpa, try toolArgv(env.ctx.gpa, skip_redirect, chkconfig, &.{ e.name, "resetpriorities" }), .quiet);
                if (res.code != 0) env.ctx.diag.warn("{s}: chkconfig could not read the priorities again", .{e.name});
            }
        },
    }
}

/// `shutdown` is the command of sysvinit that goes through `init` and the stop links of the
/// runlevel 0 or 6; `-h` halts or powers off, as `-P` and `-H` choose.
fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const argv: []const []const u8 = switch (action) {
        .reboot => &.{ "shutdown", "-r", "now" },
        .poweroff => &.{ "shutdown", "-h", "-P", "now" },
        .halt => &.{ "shutdown", "-h", "-H", "now" },
    };
    const res = try env.runner.run(env.ctx.gpa, argv, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = render;
    _ = layout;
    _ = native;
}
