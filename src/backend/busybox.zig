// SPDX-License-Identifier: GPL-3.0-or-later
//! BusyBox init backend (§11.3). BusyBox init reads `/etc/inittab` and runs its entries; it has
//! no control interface, so a service cannot be started or stopped by editing the file and
//! nothing supervises what an entry starts. The services therefore follow what the system runs
//! next to init:
//!
//! - `runsvdir` in the inittab: the services are runit service directories that BusyBox's own
//!   `runsvdir`, `runsv` and `sv` supervise, and the runit backend serves them, with the
//!   directory `runsvdir` scans taken from the inittab, the `sv` of BusyBox, whose messages
//!   differ, behind an adapter, and the generated scripts adapted to its `runsv`.
//! - otherwise: the services are init scripts that run under the executor in the background,
//!   as on sysvinit without supervision, and the sysvinit backend serves them. Enabling lists the
//!   script in a block of the inittab (`wait` at boot, in dependency order, and `shutdown` in
//!   the reverse order), which init reads again when it gets SIGHUP.
//!
//! The mode is read from the inittab when the backend is built, so a system that starts
//! `runsvdir` later is served as the first kind from then on.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const profile = @import("../detect/profile.zig");
const marker = @import("../index/marker.zig");
const rebuild = @import("../index/rebuild.zig");
const apply = @import("../reconcile/apply.zig");
const interface = @import("interface.zig");
const shell = @import("shell.zig");
const runner = @import("runner.zig");
const Runit = @import("runit.zig");
const Sysvinit = @import("sysvinit.zig");
const runit_layout = @import("runit/layout.zig");
const sysv_native = @import("sysvinit/native.zig");
const inittab = @import("busybox/inittab.zig");
const sv = @import("busybox/sv.zig");

const Backend = interface.Backend;
const Env = interface.Env;
const Busybox = @This();

pub const backend_name = "busybox";
pub const generator_number = 1;

pub const Mode = enum { runsvdir, inittab };

pub const inittab_path = "/etc/inittab";
/// Services as runit service directories, and the directory `runsvdir` scans when the inittab
/// does not name one: the default of the `sv` applet.
const runsv_base: profile.BackendDirs = .{
    .provenance = .generic,
    .admin = &.{"/etc/sv"},
    .enable_dir = sv.default_scan_dir,
    .native_logs = &.{"/var/log/{name}/current"},
};

ctx: *core.Context,
/// Directories of the init scripts, from the profile.
dirs: *const profile.BackendDirs,
vt: interface.VTable = vtable,
mode: Mode = .inittab,
/// Directory the `runsvdir` of the inittab scans.
scan_dir: []const u8 = sv.default_scan_dir,
runsv_dirs: profile.BackendDirs = runsv_base,
runit: Runit = undefined,
sysv: Sysvinit = undefined,
inner: Backend = undefined,
adapter: sv.Adapter = undefined,

pub fn init(ctx: *core.Context, dirs: *const profile.BackendDirs) Busybox {
    return .{ .ctx = ctx, .dirs = dirs };
}

/// Reads the inittab and builds the backend that serves what it starts. Called where the
/// instance stays, since the backends it builds point into it.
pub fn backend(self: *Busybox) Backend {
    const text = self.ctx.fs.readFileAlloc(self.ctx.gpa, inittab_path, 1 << 20) catch "";
    const dir = inittab.runsvdirDir(self.ctx.gpa, text) catch null;
    self.mode = if (dir != null) .runsvdir else .inittab;
    self.scan_dir = dir orelse sv.default_scan_dir;
    self.vt = vtable;
    switch (self.mode) {
        .runsvdir => {
            self.runsv_dirs = runsv_base;
            self.runsv_dirs.enable_dir = self.scan_dir;
            self.runit = .init(self.ctx, &self.runsv_dirs);
            self.inner = self.runit.backend();
        },
        .inittab => {
            self.sysv = .init(self.ctx, self.dirs, .redhat);
            self.inner = self.sysv.backend();
        },
    }
    self.vt.caps = self.inner.caps();
    self.vt.caps.user_services = false;
    return .{ .ptr = self, .vtable = &self.vt };
}

const vtable: interface.VTable = .{
    .name = backend_name,
    .generator = generator_number,
    .caps = .{},
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
    .service_of_file = serviceOfFile,
};

fn me(ptr: *anyopaque) *Busybox {
    return @ptrCast(@alignCast(ptr));
}

/// `env` for the backend that serves the mode: the runit backend runs `sv`, which behaves a
/// little differently in BusyBox.
fn envFor(self: *Busybox, env: Env) Env {
    if (self.mode != .runsvdir) return env;
    self.adapter = .{ .inner = env.runner, .scan_dir = self.scan_dir };
    var adapted = env;
    adapted.runner = self.adapter.runner();
    return adapted;
}

// ---- scanning and generation ---------------------------------------------------------------

fn nativeScan(ptr: *anyopaque, env: Env) anyerror!interface.NativeScan {
    const self = me(ptr);
    return self.inner.nativeScan(self.envFor(env));
}

fn scanDirs(ptr: *anyopaque, gpa: Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    return me(ptr).inner.scanDirs(gpa, scope);
}

/// `finish` ends with `sv once .` to keep the service from starting again. The `runsv` of BusyBox
/// takes the byte that command sends after it has seen `finish` exit when it is quick, and `once`
/// then starts the service that just ended; `down` only sets what is wanted, whatever the state.
const finish_once = "sv once .\n";
const finish_down = "sv down .\n";

/// The text of a generated run or finish script as BusyBox needs it: a run script finds the
/// services it starts through `sv`, which looks in `/var/service` when `SVDIR` is not set, so with
/// another scan directory it says where, and `finish` uses `down` where it would use `once`.
fn adaptScript(self: *Busybox, gpa: Allocator, path: []const u8, content: []const u8) !?[]const u8 {
    const parsed = marker.parse(content) orelse return null;
    const leaf = std.fs.path.basename(path);
    const in_log = std.mem.eql(u8, std.fs.path.basename(std.fs.path.dirname(path) orelse ""), "log");
    var body: std.Io.Writer.Allocating = .init(gpa);
    try body.writer.writeAll(parsed.shebang);
    if (std.mem.eql(u8, leaf, "run") and !in_log and !std.mem.eql(u8, self.scan_dir, sv.default_scan_dir)) {
        try body.writer.writeAll("export SVDIR=");
        try shell.writeWord(&body.writer, self.scan_dir, false);
        try body.writer.writeByte('\n');
        try body.writer.writeAll(parsed.rest);
    } else if (std.mem.eql(u8, leaf, "finish") and std.mem.find(u8, parsed.rest, finish_once) != null) {
        const size = std.mem.replacementSize(u8, parsed.rest, finish_once, finish_down);
        const text = try gpa.alloc(u8, size);
        _ = std.mem.replace(u8, parsed.rest, finish_once, finish_down, text);
        try body.writer.writeAll(text);
    } else return null;
    return try marker.compose(gpa, parsed.marker.unit, parsed.marker.source, parsed.marker.source_hash, parsed.marker.generator, body.written());
}

fn adaptFiles(self: *Busybox, gpa: Allocator, generated: interface.Generated) !interface.Generated {
    const files = try gpa.alloc(apply.GeneratedFile, generated.files.len);
    for (generated.files, files) |f, *out| {
        out.* = f;
        if (try self.adaptScript(gpa, f.path, f.content)) |content| out.content = content;
    }
    return .{ .service_name = generated.service_name, .files = files };
}

fn generate(ptr: *anyopaque, gpa: Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    if (input.unit.scope == .user) {
        self.ctx.diag.err("{s}: BusyBox init has no service manager for users", .{input.unit.name.full});
        return error.Unsupported;
    }
    const generated = try self.inner.generate(gpa, input);
    return if (self.mode == .runsvdir) self.adaptFiles(gpa, generated) else generated;
}

/// A file of a runit service directory (`run`, `finish`, `log/run`, `control/t`) names its
/// service by the directory; an init script by its own name.
fn serviceOfFile(path: []const u8) []const u8 {
    const leaf = std.fs.path.basename(path);
    const dir = std.fs.path.dirname(path) orelse return leaf;
    const parent = std.fs.path.basename(dir);
    const in_service_dir = std.mem.eql(u8, parent, "log") or std.mem.eql(u8, parent, "control") or
        std.mem.eql(u8, leaf, "run") or std.mem.eql(u8, leaf, "finish") or std.mem.eql(u8, leaf, "down");
    return if (in_service_dir) runit_layout.serviceOfFile(path) else leaf;
}

// ---- enablement ----------------------------------------------------------------------------------

fn scriptDir(self: *Busybox) []const u8 {
    return if (self.dirs.admin.len > 0) self.dirs.admin[0] else "/etc/init.d";
}

fn scriptPath(self: *Busybox, service: []const u8) ![]const u8 {
    return std.fs.path.join(self.ctx.gpa, &.{ self.scriptDir(), service });
}

fn readInittab(self: *Busybox) []const u8 {
    return self.ctx.fs.readFileAlloc(self.ctx.gpa, inittab_path, 1 << 20) catch "";
}

fn enabledList(self: *Busybox) std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    const services = inittab.enabledServices(self.ctx.gpa, self.readInittab(), self.scriptDir()) catch return list;
    list.appendSlice(self.ctx.gpa, services) catch return list;
    return list;
}

fn indexOf(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |l, i| if (std.mem.eql(u8, l, name)) return i;
    return null;
}

const max_dependency_depth = 8;

fn headerOf(self: *Busybox, service: []const u8) !sysv_native.Header {
    const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, try self.scriptPath(service), 1 << 20) catch "";
    return sysv_native.parseHeader(self.ctx.gpa, content);
}

fn names(header: sysv_native.Header, service: []const u8) bool {
    return indexOf(header.required_start, service) != null or indexOf(header.should_start, service) != null;
}

/// Lists `service`, after the services it requires and follows, which are listed too when they
/// are scripts, and before the first listed service that requires or follows it. Returns false
/// when it was listed already.
fn addOrdered(self: *Busybox, list: *std.ArrayList([]const u8), service: []const u8, depth: usize) !bool {
    if (indexOf(list.items, service) != null) return false;
    const header = try self.headerOf(service);
    if (depth < max_dependency_depth) {
        for (header.required_start) |dep| {
            if (dep.len == 0 or dep[0] == '$' or std.mem.eql(u8, dep, service)) continue;
            if (!self.ctx.fs.exists(try self.scriptPath(dep))) continue;
            _ = try self.addOrdered(list, dep, depth + 1);
        }
    }
    var at = list.items.len;
    for (list.items, 0..) |other, i| {
        if (names(try self.headerOf(other), service)) {
            at = i;
            break;
        }
    }
    for ([_][]const []const u8{ header.required_start, header.should_start }) |deps| {
        for (deps) |dep| if (indexOf(list.items, dep)) |i| {
            at = @max(at, i + 1);
        };
    }
    try list.insert(self.ctx.gpa, at, try self.ctx.gpa.dupe(u8, service));
    return true;
}

/// Writes the inittab with the block listing `list`, keeping the mode of the file, and tells a
/// running init to read it again so that its shutdown entries are the new ones.
fn commit(self: *Busybox, env: Env, list: []const []const u8) !void {
    const gpa = env.ctx.gpa;
    const text = self.readInittab();
    const updated = try inittab.withServices(gpa, text, list, self.scriptDir());
    if (env.ctx.dry_run) return;
    const mode: u16 = if (self.ctx.fs.stat(inittab_path)) |st| st.mode else |_| 0o644;
    try self.ctx.fs.writeFileAtomic(inittab_path, updated, mode);
    if (env.online) {
        const res = try env.runner.run(gpa, &.{ "kill", "-HUP", "1" }, .quiet);
        if (res.code != 0) env.ctx.diag.warn("init did not take SIGHUP, it reads {s} at the next boot", .{inittab_path});
    }
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, opts: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    if (self.mode == .runsvdir) return self.inner.enable(self.envFor(env), service, opts);
    if (!env.ctx.dry_run and !self.ctx.fs.exists(try self.scriptPath(service))) {
        env.ctx.diag.err("{s}: no init script found", .{service});
        return error.Unsupported;
    }
    var list = self.enabledList();
    const before = try env.ctx.gpa.dupe([]const u8, list.items);
    if (!try self.addOrdered(&list, service, 0)) return &.{};
    for (list.items) |name| {
        if (indexOf(before, name) == null) env.ctx.diag.notice("{s}: listed in {s}", .{ name, inittab_path });
    }
    try self.commit(env, list.items);
    return &.{};
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, opts: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    if (self.mode == .runsvdir) return self.inner.disable(self.envFor(env), service, opts);
    var list = self.enabledList();
    const at = indexOf(list.items, service) orelse return &.{};
    _ = list.orderedRemove(at);
    env.ctx.diag.notice("{s}: removed from {s}", .{ service, inittab_path });
    try self.commit(env, list.items);
    return &.{};
}

fn isEnabled(ptr: *anyopaque, env: Env, service: []const u8) anyerror!output.EnabledState {
    const self = me(ptr);
    if (self.mode == .runsvdir) return self.inner.isEnabled(self.envFor(env), service);
    return if (indexOf(self.enabledList().items, service) != null) .enabled else .disabled;
}

/// Entries of services whose script is gone are dropped, as when a unit is removed.
fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const self = me(ptr);
    if (self.mode == .runsvdir) return self.inner.reloadManager(self.envFor(env));
    if (env.ctx.dry_run) return;
    var list = self.enabledList();
    var i: usize = 0;
    var changed = false;
    while (i < list.items.len) {
        if (self.ctx.fs.exists(try self.scriptPath(list.items[i]))) {
            i += 1;
        } else {
            _ = list.orderedRemove(i);
            changed = true;
        }
    }
    if (changed) try self.commit(env, list.items);
}

// ---- runtime control ------------------------------------------------------------------------------

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    return self.inner.start(self.envFor(env), service);
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    return self.inner.stop(self.envFor(env), service);
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    return self.inner.restart(self.envFor(env), service);
}

fn reload(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    const self = me(ptr);
    return self.inner.reload(self.envFor(env), service);
}

fn kill(ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const self = me(ptr);
    return self.inner.kill(self.envFor(env), service, signal);
}

fn status(ptr: *anyopaque, env: Env, service: []const u8) anyerror!interface.Status {
    const self = me(ptr);
    return self.inner.status(self.envFor(env), service);
}

/// The applets of BusyBox ask init, which runs the `shutdown` entries before it ends everything.
fn power(_: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const verb = switch (action) {
        .reboot => "reboot",
        .poweroff => "poweroff",
        .halt => "halt",
    };
    const res = try env.runner.run(env.ctx.gpa, &.{verb}, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

test {
    _ = inittab;
    _ = sv;
}
