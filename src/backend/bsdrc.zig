// SPDX-License-Identifier: GPL-3.0-or-later
//! BSD-style rc backend (§11.3, Slackware): a service is a script `/etc/rc.d/rc.<name>` with the
//! verbs `start`, `stop` and `restart`, and the execute permission of the script enables it.
//!
//! `rc.M` starts a fixed list of scripts and then `rc.local`, and `rc.6` stops a fixed list
//! after `rc.local_shutdown stop`; a new service has no other place in the boot. Generated
//! scripts are therefore started by a managed block in `rc.local` and stopped by one in
//! `rc.local_shutdown`, both rewritten from the scripts that exist. A script that is not
//! executable is disabled and is run through `sh`.
//!
//! Nothing supervises a service: it runs under the executor in the background and stays dead
//! when it dies, and `status` is the exit status of `<script> status`.
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
const daemon = @import("../exec/daemon.zig");
const interface = @import("interface.zig");
const policy = @import("policy.zig");
const guard = @import("guard.zig");
const network = @import("network.zig");
const shell = @import("shell.zig");
const sysv_native = @import("sysvinit/native.zig");
const render = @import("bsdrc/render.zig");
const layout = @import("bsdrc/layout.zig");
const native = @import("bsdrc/native.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const BsdRc = @This();

pub const backend_name = "bsd-rc";
pub const generator_number = 2;

/// Capabilities of §11.3: the scripts of the dependencies are started first, the boot order is
/// that of the managed block, nothing supervises, and `rc.local_shutdown` runs at shutdown.
pub const capabilities: interface.Capabilities = .{
    .hard_deps = true,
    .soft_deps = true,
    .ordering = true,
    .shutdown_hooks = true,
};

/// Files whose mention of a script means the boot already starts it, for a native script that is
/// enabled.
const boot_files = [_][]const u8{ "rc.M", "rc.inet2", "rc.S", "rc.local" };
const pid_dirs = [_][]const u8{ "/run", "/var/run" };

ctx: *core.Context,
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) BsdRc {
    return .{ .ctx = ctx, .dirs = dirs };
}

pub fn backend(self: *BsdRc) Backend {
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

fn me(ptr: *anyopaque) *BsdRc {
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
        .strip_prefix = layout.prefix,
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

fn serviceExists(self: *BsdRc, service: []const u8) !bool {
    return (try layout.locate(self.ctx, self.dirs, service)) != null;
}

/// Service a dependency refers to, or null when it cannot be one: targets, other unit types,
/// and units that are neither a script nor a systemd unit that can be translated.
fn mapDependency(self: *BsdRc, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
    const gpa = self.ctx.gpa;
    const n = name_mod.parse(gpa, dep) catch return null;
    if (n.kind != .service) return null;
    for (resolutions) |r| if (std.mem.eql(u8, r.unit, n.full)) return r.service;
    if (n.isTemplate() or std.mem.startsWith(u8, n.prefix, "systemd-")) return null;
    const svc = try layout.serviceName(gpa, n);
    if (std.mem.eql(u8, svc, own) or layout.isReserved(svc)) return null;
    if (try self.serviceExists(svc)) return svc;
    const resolved = resolve.resolve(gpa, self.ctx.fs.*, .{ .scope = self.ctx.scope, .xdg_config_home = self.ctx.xdg_config_home }, n) catch return null;
    return if (resolved.state == .found) svc else null;
}

fn mapList(self: *BsdRc, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, exclude: []const []const []const u8, out: *std.ArrayList([]const u8)) !void {
    outer: for (deps) |dep| {
        const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
        for (exclude) |ex| if (contains(ex, mapped)) continue :outer;
        if (!contains(out.items, mapped)) try out.append(self.ctx.gpa, mapped);
    }
}

/// `Requires=` and `BindsTo=` are the scripts `start` runs first and whose failure fails it,
/// `Wants=` the ones it runs and ignores; `After=` and `Before=` only order the managed block.
/// The network targets map to nothing: `rc.local` runs after `rc.inet1` and `rc.inet2`.
fn mapDependencies(self: *BsdRc, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep) !render.Deps {
    var requires: std.ArrayList([]const u8) = .empty;
    var wants: std.ArrayList([]const u8) = .empty;
    var after: std.ArrayList([]const u8) = .empty;
    var before: std.ArrayList([]const u8) = .empty;
    try self.mapList(own, resolutions, u.requires, &.{}, &requires);
    try self.mapList(own, resolutions, u.binds_to, &.{}, &requires);
    try self.mapList(own, resolutions, u.wants, &.{requires.items}, &wants);
    try self.mapList(own, resolutions, u.after, &.{ requires.items, wants.items }, &after);
    try self.mapList(own, resolutions, u.before, &.{}, &before);
    return .{ .requires = requires.items, .wants = wants.items, .after = after.items, .before = before.items };
}

fn accountKnown(self: *BsdRc, file: []const u8, account: []const u8) bool {
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
fn executorResolves(self: *BsdRc, u: *const model.Unit) bool {
    const user = u.user orelse return false;
    if (!self.accountKnown("/etc/passwd", user)) return false;
    if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
    for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
    return true;
}

fn plainGroups(u: *const model.Unit) bool {
    if (u.group) |g| if (!shell.plainAccount(g)) return false;
    for (u.supplementary_groups) |g| if (!shell.plainAccount(g)) return false;
    return true;
}

/// An account the executor cannot resolve (LDAP, sssd) is passed to it as numeric ids that the
/// script looks up with `id` and `getent`; the executor stays root and switches to them itself.
fn identityFor(self: *BsdRc, u: *const model.Unit) !render.Identity {
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
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "Restart={t} is not honored: BSD-style rc does not supervise services, a service that dies stays dead", .{u.restart}));
    }
    if (u.kill_mode == .none or u.kill_mode == .mixed) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa, "KillMode={t} is handled like control-group", .{u.kill_mode}));
    }
    if (network.mentions(u)) {
        try notes.append(gpa, "network.target: rc.local runs after rc.inet1 and rc.inet2, which bring the network up");
    }
    return notes.toOwnedSlice(gpa);
}

fn isExecutablePath(self: *const BsdRc, path: []const u8) bool {
    const st = self.ctx.fs.stat(path) catch return false;
    return st.mode & 0o111 != 0;
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    const u = input.unit;
    if (u.scope == .user) {
        self.ctx.diag.err("{s}: BSD-style rc has no service manager for users", .{u.name.full});
        return error.Unsupported;
    }
    const svc = try layout.serviceName(gpa, u.name);
    try guard.checkUnit(self.ctx, u, svc);
    if (layout.isReserved(svc)) {
        self.ctx.diag.err("{s}: rc.{s} is a boot script of the system, not a service", .{ u.name.full, svc });
        return error.Unsupported;
    }
    const mode = modeFor(u);
    if (network.mentions(u)) self.ctx.diag.info("{s}: the network targets map to nothing, rc.local runs after the network scripts", .{u.name.full});
    const exit_file = try executor.execExitPath(self.ctx, u.name.full);
    const path = try layout.scriptPath(gpa, self.dirs, svc);
    try guard.requireNotOther(self.ctx, guard.claimFile(self.ctx, path, u.name.full), u.name.full, path);
    const in: render.Input = .{
        .unit = u,
        .service = svc,
        .script_dir = layout.generationDir(self.dirs),
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
    const files = try gpa.alloc(apply.GeneratedFile, 1);
    // A new script is disabled; an enabled one stays so when it is generated again.
    files[0] = .{ .path = path, .content = content, .mode = if (self.isExecutablePath(path)) 0o755 else 0o644 };
    return .{ .service_name = svc, .files = files };
}

// ---- enablement -------------------------------------------------------------------------

/// Upper bound for a script read whole; a larger one is an error, not an absent file.
const max_script_bytes = 64 << 20;

/// Content of the file at `path`, null when it does not exist. Any other failure is an error, so
/// a file that cannot be read in full is never taken for an absent one and rewritten.
fn contentOf(self: *const BsdRc, path: []const u8) !?[]const u8 {
    return self.ctx.fs.readFileAlloc(self.ctx.gpa, path, max_script_bytes) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

/// A script fake-systemd generated, with what it says about its order.
const Generated = struct {
    service: []const u8,
    path: []const u8,
    executable: bool,
    rel: render.Deps,
};

/// What the unit of a generated script says about its order, derived from the unit itself rather
/// than read back from the script; none when the unit cannot be loaded any more.
fn relationsOf(self: *BsdRc, service: []const u8, unit_name: []const u8) !render.Deps {
    var u = executor.loadUnit(self.ctx, unit_name) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{},
    };
    return self.mapDependencies(service, &u, &.{});
}

fn generatedScripts(self: *BsdRc) ![]const Generated {
    const gpa = self.ctx.gpa;
    var out: std.ArrayList(Generated) = .empty;
    const dir = layout.generationDir(self.dirs);
    const entries = try guard.iterateOrEmpty(self.ctx, dir);
    for (entries) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, layout.prefix)) continue;
        const path = try std.fs.path.join(gpa, &.{ dir, e.name });
        const content = (try self.contentOf(path)) orelse continue;
        const parsed = marker.parse(content) orelse continue;
        const service = layout.serviceOfFile(path);
        try out.append(gpa, .{
            .service = service,
            .path = path,
            .executable = self.isExecutablePath(path),
            .rel = try self.relationsOf(service, parsed.marker.unit),
        });
    }
    std.mem.sort(Generated, out.items, {}, struct {
        fn less(_: void, a: Generated, b: Generated) bool {
            return std.mem.lessThan(u8, a.service, b.service);
        }
    }.less);
    return out.items;
}

fn indexOf(list: []const Generated, service: []const u8) ?usize {
    for (list, 0..) |g, i| if (std.mem.eql(u8, g.service, service)) return i;
    return null;
}

/// The indices of `list` in an order that starts a script after the ones it requires, wants or
/// follows and before the ones it precedes; ties and cycles fall back to the name.
fn bootOrder(gpa: Allocator, list: []const Generated) Allocator.Error![]const usize {
    const n = list.len;
    const before = try gpa.alloc(std.ArrayList(usize), n);
    for (before) |*b| b.* = .empty;
    const waiting = try gpa.alloc(usize, n);
    @memset(waiting, 0);
    for (list, 0..) |g, i| {
        for ([_][]const []const u8{ g.rel.requires, g.rel.wants, g.rel.after }) |names| {
            for (names) |dep| {
                const d = indexOf(list, dep) orelse continue;
                if (d == i) continue;
                try before[d].append(gpa, i);
                waiting[i] += 1;
            }
        }
        for (g.rel.before) |succ| {
            const s = indexOf(list, succ) orelse continue;
            if (s == i) continue;
            try before[i].append(gpa, s);
            waiting[s] += 1;
        }
    }
    var order: std.ArrayList(usize) = .empty;
    const done = try gpa.alloc(bool, n);
    @memset(done, false);
    while (order.items.len < n) {
        var pick: ?usize = null;
        for (0..n) |i| if (!done[i] and waiting[i] == 0) {
            pick = i;
            break;
        };
        // A cycle: the first script left goes next.
        if (pick == null) for (0..n) |i| if (!done[i]) {
            pick = i;
            break;
        };
        const p = pick.?;
        done[p] = true;
        try order.append(gpa, p);
        for (before[p].items) |s| if (waiting[s] > 0) {
            waiting[s] -= 1;
        };
    }
    return order.toOwnedSlice(gpa);
}

fn hookLine(gpa: Allocator, path: []const u8, verb: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    try aw.writer.writeAll("[ -x ");
    try shell.writeWord(&aw.writer, path, false);
    try aw.writer.writeAll(" ] && ");
    try shell.writeWord(&aw.writer, path, false);
    try aw.writer.print(" {s}", .{verb});
    return aw.toOwnedSlice();
}

/// Rewrites `rc.local` and `rc.local_shutdown`: the first starts the enabled generated scripts
/// in boot order, the second stops every generated script in the reverse order, so that a
/// service started by hand or as a dependency runs its `ExecStop=` too.
fn syncHooks(self: *BsdRc, env: Env) !void {
    if (env.ctx.dry_run) return;
    const gpa = env.ctx.gpa;
    const list = try self.generatedScripts();
    const order = try bootOrder(gpa, list);
    var starts: std.ArrayList([]const u8) = .empty;
    var stops: std.ArrayList([]const u8) = .empty;
    for (order) |i| if (list[i].executable) try starts.append(gpa, try hookLine(gpa, list[i].path, "start"));
    var k = order.len;
    while (k > 0) {
        k -= 1;
        try stops.append(gpa, try hookLine(gpa, list[order[k]].path, "stop"));
    }
    try self.writeHook(layout.start_hook, starts.items, 0o755);
    try self.writeHook(layout.stop_hook, stops.items, 0o755);
}

fn writeHook(self: *BsdRc, hook: []const u8, commands: []const []const u8, mode: u16) !void {
    const gpa = self.ctx.gpa;
    const path = try layout.hookPath(gpa, self.dirs, hook);
    const current = try self.contentOf(path);
    const old_mode = if (self.ctx.fs.stat(path)) |st| st.mode else |_| mode;
    const rewritten = native.withBlock(gpa, current, commands) catch |e| switch (e) {
        error.MalformedBlock => {
            if (native.blockFault(current orelse "")) |fault| {
                self.ctx.diag.err("{s}:{d}: {s}; the script is left as it is", .{ path, fault.line, fault.reason.text() });
            }
            return error.Unsupported;
        },
        else => |other| return other,
    };
    // A script that holds nothing but the block is never deleted: it may be the system's own.
    const text = rewritten orelse blk: {
        const had_block = current != null and std.mem.find(u8, current.?, native.block_begin) != null;
        if (!had_block) return;
        break :blk native.hook_shebang;
    };
    if (current != null and std.mem.eql(u8, current.?, text)) return;
    try self.ctx.fs.makePath(layout.generationDir(self.dirs));
    try self.ctx.fs.writeFileAtomic(path, text, if (current == null) mode else old_mode);
}

/// Sets or clears the execute permission of a script, as `chmod +x` and `chmod -x` do.
fn setExecutable(self: *BsdRc, path: []const u8, on: bool) !void {
    const st = try self.ctx.fs.stat(path);
    const bits: u16 = if (on) st.mode | ((st.mode & 0o444) >> 2) else st.mode & ~@as(u16, 0o111);
    try guard.chmodInPlace(self.ctx, path, bits);
}

fn isGenerated(self: *BsdRc, path: []const u8) !bool {
    const content = (try self.contentOf(path)) orelse return false;
    return marker.parse(content) != null;
}

/// True when the boot scripts of the system mention the script, so that it starts without a
/// block of ours.
fn bootStarts(self: *BsdRc, service: []const u8) !bool {
    const needle = try std.fmt.allocPrint(self.ctx.gpa, "{s}{s}", .{ layout.prefix, service });
    for (boot_files) |file| {
        const path = try layout.hookPath(self.ctx.gpa, self.dirs, file);
        const text = (try self.contentOf(path)) orelse continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trimStart(u8, line, " \t");
            if (t.len > 0 and t[0] == '#') continue;
            if (std.mem.find(u8, t, needle) != null) return true;
        }
    }
    return false;
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    var changes: std.ArrayList(interface.Change) = .empty;
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse {
        // A dry run has not written the script yet.
        if (env.ctx.dry_run) {
            try changes.append(gpa, .{ .mode_set = .{ .path = try layout.scriptPath(gpa, self.dirs, service), .executable = true } });
            return changes.items;
        }
        env.ctx.diag.err("{s}: no rc script found", .{service});
        return error.Unsupported;
    };
    if (!self.isExecutablePath(path)) {
        try changes.append(gpa, .{ .mode_set = .{ .path = path, .executable = true } });
        if (env.ctx.dry_run) return changes.items;
        try self.setExecutable(path, true);
    }
    if (env.ctx.dry_run) return changes.items;
    if (try self.isGenerated(path)) {
        try self.syncHooks(env);
    } else if (!try self.bootStarts(service)) {
        env.ctx.diag.warn("{s}: no boot script starts rc.{s}; start it from rc.local", .{ service, service });
    }
    return changes.items;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const gpa = env.ctx.gpa;
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return &.{};
    if (!self.isExecutablePath(path)) return &.{};
    const changes = try gpa.alloc(interface.Change, 1);
    changes[0] = .{ .mode_set = .{ .path = path, .executable = false } };
    if (env.ctx.dry_run) return changes;
    try self.setExecutable(path, false);
    if (try self.isGenerated(path)) try self.syncHooks(env);
    return changes;
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return .disabled;
    return if (self.isExecutablePath(path)) .enabled else .disabled;
}

// ---- runtime control --------------------------------------------------------------------

/// Path of the script of `service`; a dry run has not written it yet.
fn scriptPath(self: *BsdRc, env: Env, service: []const u8) ![]const u8 {
    if (try layout.locate(self.ctx, self.dirs, service)) |path| return path;
    if (env.ctx.dry_run) return layout.scriptPath(env.ctx.gpa, self.dirs, service);
    env.ctx.diag.err("{s}: no rc script found", .{service});
    return error.Unsupported;
}

/// The command that runs `action` of the script: the script itself when it is enabled, which
/// the system runs the same way, else through the shell.
fn scriptArgv(self: *BsdRc, gpa: Allocator, path: []const u8, action: []const u8) ![]const []const u8 {
    if (self.isExecutablePath(path) or !self.ctx.fs.exists(path)) return gpa.dupe([]const u8, &.{ path, action });
    return gpa.dupe([]const u8, &.{ "sh", path, action });
}

/// Last lines of the output of a script that failed: the scripts print their reasons to
/// standard output.
fn reportFailure(env: Env, service: []const u8, action: []const u8, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;
    const from = if (std.mem.findScalarLast(u8, trimmed[0..trimmed.len -| 1], '\n')) |at| at + 1 else 0;
    env.ctx.diag.err("{s} {s}: {s}", .{ service, action, trimmed[from..] });
}

fn control(self: *BsdRc, env: Env, service: []const u8, action: []const u8) anyerror!void {
    const path = try self.scriptPath(env, service);
    const res = try env.runner.run(env.ctx.gpa, try self.scriptArgv(env.ctx.gpa, path, action), .capture);
    if (res.code != 0) {
        reportFailure(env, service, action, res.stdout);
        return error.CommandFailed;
    }
}

/// A started service has to be stopped at shutdown, so the hooks are written before it starts.
fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.syncHooks(env);
    return self.control(env, service, "start");
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "stop");
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    try self.syncHooks(env);
    return self.control(env, service, "restart");
}

/// A native script may not know `reload`; its own answer decides.
fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return me(ptr).control(env, service, "reload");
}

/// Unit recorded in the marker of the script, null for native scripts.
fn generatedUnit(self: *BsdRc, service: []const u8) !?[]const u8 {
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return null;
    const content = (try self.contentOf(path)) orelse return null;
    const parsed = marker.parse(content) orelse return null;
    return parsed.marker.unit;
}

/// The process of a native script from the pid files such scripts commonly keep, when
/// `guard.acceptPid` allows signaling it.
fn pidFileOf(self: *BsdRc, service: []const u8) ?u32 {
    const gpa = self.ctx.gpa;
    if (!guard.serviceNameOk(service)) return null;
    for (pid_dirs) |dir| {
        const flat = std.fmt.allocPrint(gpa, "{s}/{s}.pid", .{ dir, service }) catch return null;
        const nested = std.fmt.allocPrint(gpa, "{s}/{s}/{s}.pid", .{ dir, service, service }) catch return null;
        for ([_][]const u8{ flat, nested }) |path| {
            if (guard.pidFromFile(self.ctx, path)) |pid| return pid;
        }
    }
    return null;
}

/// Main process of a generated service from the file its executor writes, else the pid file a
/// native script commonly keeps.
fn pidOf(self: *BsdRc, service: []const u8) !?u32 {
    if (try self.generatedUnit(service)) |unit| {
        const path = executor.execPidPath(self.ctx, unit) catch return null;
        return guard.recordedPid(self.ctx, path);
    }
    return self.pidFileOf(service);
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

/// The program a native script starts, as the name of its process.
fn processOf(self: *BsdRc, path: []const u8) !?[]const u8 {
    const content = (try self.contentOf(path)) orelse return null;
    const words = native.extractCommand(self.ctx.gpa, content) catch return null;
    const exe = (words orelse return null)[0];
    return native.processName(exe);
}

/// A generated script answers `status` with the LSB exit codes. A native script has no `status`
/// verb in general, so its state is the process of its pid file, else a process named like the
/// program it starts.
fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const self = me(ptr);
    const path = (try layout.locate(self.ctx, self.dirs, service)) orelse return .{ .state = .inactive };
    if (try self.isGenerated(path)) {
        const res = try env.runner.run(env.ctx.gpa, try self.scriptArgv(env.ctx.gpa, path, "status"), .capture);
        const state = sysv_native.stateOfStatus(res.code, sysv_native.looksLikeUsage(res.stdout));
        return .{ .state = state, .pid = if (state == .active) try self.pidOf(service) else null, .text = res.stdout };
    }
    if (self.pidFileOf(service)) |pid| return .{ .state = .active, .pid = pid };
    const name = (try self.processOf(path)) orelse return .{ .state = .inactive };
    const res = try env.runner.run(env.ctx.gpa, &.{ "pgrep", "-x", name }, .capture);
    if (res.code != 0) return .{ .state = .inactive };
    return .{ .state = .active, .pid = native.parsePid(res.stdout) };
}

// ---- manager ----------------------------------------------------------------------------

/// The hooks list the scripts that exist, so a script that was removed leaves them.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    return me(ptr).syncHooks(env);
}

/// `shutdown` is the command of sysvinit that goes through `init` and runlevel 0 or 6, where
/// `rc.0` and `rc.6` run `rc.local_shutdown`.
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
    _ = @import("bsdrc/script.zig");
}
