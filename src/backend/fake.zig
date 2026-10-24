//! Test backend: deterministic generation of one marker file per unit, an in-memory service
//! table and runtime operations that go through the `Runner`.
const std = @import("std");
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const rebuild = @import("../index/rebuild.zig");
const marker = @import("../index/marker.zig");
const interface = @import("interface.zig");

const Backend = interface.Backend;
const Env = interface.Env;

const Fake = @This();

pub const backend_name = "fake";

/// Service directories per scope and tier.
pub const Dirs = struct {
    vendor: []const u8 = "/usr/lib/fake.d",
    admin: []const u8 = "/etc/fake.d",
    runtime: []const u8 = "/run/fake.d",
    user_vendor: []const u8 = "/usr/lib/fake.d/user",
    user_admin: []const u8 = "/etc/fake.d/user",
    user_personal: []const u8 = "/home/fake/.config/fake.d",
    /// Directory of boot-enable links.
    enabled: []const u8 = "/etc/fake.d/enabled",
};

pub const Service = struct {
    enabled: bool = false,
    state: output.ActiveState = .inactive,
    pid: ?u32 = null,
};

gpa: std.mem.Allocator,
dirs: Dirs = .{},
caps: interface.Capabilities = .{ .supervision = true, .soft_deps = true, .hard_deps = true, .vendor_admin_split = true },
native_dirs: []const []const u8 = &.{"/etc/fake-native"},
/// Calls of `generate`, for tests that assert unchanged units are not translated again.
generate_count: usize = 0,
services: std.StringHashMapUnmanaged(Service) = .empty,
vt: interface.VTable = vtable,
reload_count: usize = 0,
power_calls: std.ArrayList(interface.Power) = .empty,

pub fn init(gpa: std.mem.Allocator) Fake {
    return .{ .gpa = gpa };
}

pub fn backend(self: *Fake) Backend {
    self.vt = vtable;
    self.vt.caps = self.caps;
    return .{ .ptr = self, .vtable = &self.vt };
}

pub fn serviceState(self: *Fake, name: []const u8) Service {
    return self.services.get(name) orelse .{};
}

pub fn setService(self: *Fake, name: []const u8, svc: Service) !void {
    try self.services.put(self.gpa, name, svc);
}

const vtable: interface.VTable = .{
    .name = backend_name,
    .generator = 1,
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
};

fn me(ptr: *anyopaque) *Fake {
    return @ptrCast(@alignCast(ptr));
}

fn dirFor(self: *const Fake, scope: core.Scope, tier: core.Tier) []const u8 {
    return switch (scope) {
        .system => switch (tier) {
            .vendor => self.dirs.vendor,
            .admin, .personal => self.dirs.admin,
            .runtime => self.dirs.runtime,
        },
        .user => switch (tier) {
            .vendor => self.dirs.user_vendor,
            .admin, .runtime => self.dirs.user_admin,
            .personal => self.dirs.user_personal,
        },
    };
}

fn serviceName(unit_name: []const u8) []const u8 {
    return std.mem.cutSuffix(u8, unit_name, ".service") orelse unit_name;
}

fn nativeScan(ptr: *anyopaque, _: Env) anyerror!interface.NativeScan {
    return .{ .dirs = me(ptr).native_dirs, .extractor = extractExec };
}

fn scanDirs(ptr: *anyopaque, gpa: std.mem.Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
    const self = me(ptr);
    const tiers = [_]core.Tier{ .vendor, .admin, .runtime, .personal };
    var out: std.ArrayList(rebuild.ScanDir) = .empty;
    for (tiers) |t| {
        const dir = self.dirFor(scope, t);
        var dup = false;
        for (out.items) |o| if (std.mem.eql(u8, o.path, dir)) {
            dup = true;
        };
        if (!dup) try out.append(gpa, .{ .path = dir, .tier = t });
    }
    return out.toOwnedSlice(gpa);
}

fn generate(ptr: *anyopaque, gpa: std.mem.Allocator, input: interface.GenerateInput) anyerror!interface.Generated {
    const self = me(ptr);
    self.generate_count += 1;
    const unit = input.unit;
    const svc = serviceName(unit.name.full);
    const exec = if (unit.exec_start.len > 0) unit.exec_start[0].executable() else "";
    const body = try std.fmt.allocPrint(gpa, "name = {s}\nexec = {s}\n", .{ svc, exec });
    const generator = try interface.generatorLine(gpa, backend_name, 1);
    const content = try marker.compose(gpa, unit.name.full, input.source, input.src_hash, generator, body);
    const files = try gpa.alloc(@import("../reconcile/apply.zig").GeneratedFile, 1);
    files[0] = .{
        .path = try std.fs.path.join(gpa, &.{ self.dirFor(unit.scope, input.tier), svc }),
        .content = content,
    };
    return .{ .service_name = svc, .files = files };
}

fn runCommand(env: Env, verb: []const u8, service: []const u8) anyerror!void {
    const res = try env.runner.run(env.ctx.gpa, &.{ "fakectl", verb, service }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

fn enable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const link = try std.fs.path.join(env.ctx.gpa, &.{ self.dirs.enabled, service });
    const target = try std.fs.path.join(env.ctx.gpa, &.{ self.dirs.admin, service });
    var svc = self.serviceState(service);
    const changes = try env.ctx.gpa.alloc(interface.Change, if (svc.enabled) 0 else 1);
    if (!svc.enabled) changes[0] = .{ .created = .{ .link = link, .target = target } };
    if (!env.ctx.dry_run) {
        svc.enabled = true;
        try self.setService(service, svc);
    }
    return changes;
}

fn disable(ptr: *anyopaque, env: Env, service: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    const self = me(ptr);
    const link = try std.fs.path.join(env.ctx.gpa, &.{ self.dirs.enabled, service });
    var svc = self.serviceState(service);
    const changes = try env.ctx.gpa.alloc(interface.Change, if (svc.enabled) 1 else 0);
    if (svc.enabled) changes[0] = .{ .removed = link };
    if (!env.ctx.dry_run) {
        svc.enabled = false;
        try self.setService(service, svc);
    }
    return changes;
}

fn transition(self: *Fake, env: Env, service: []const u8, verb: []const u8, state: output.ActiveState) anyerror!void {
    try runCommand(env, verb, service);
    if (env.ctx.dry_run) return;
    var svc = self.serviceState(service);
    svc.state = state;
    svc.pid = if (state == .active) 4242 else null;
    try self.setService(service, svc);
}

fn start(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return transition(me(ptr), env, service, "start", .active);
}

fn stop(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return transition(me(ptr), env, service, "stop", .inactive);
}

fn restart(ptr: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return transition(me(ptr), env, service, "restart", .active);
}

fn reload(_: *anyopaque, env: Env, service: []const u8) anyerror!void {
    return runCommand(env, "reload", service);
}

fn kill(_: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void {
    const res = try env.runner.run(env.ctx.gpa, &.{ "fakectl", "kill", signal, service }, .inherit);
    if (res.code != 0) return error.CommandFailed;
}

fn status(ptr: *anyopaque, _: Env, service: []const u8) anyerror!interface.Status {
    const svc = me(ptr).serviceState(service);
    return .{ .state = svc.state, .pid = svc.pid };
}

fn isEnabled(ptr: *anyopaque, _: Env, service: []const u8) anyerror!output.EnabledState {
    return if (me(ptr).serviceState(service).enabled) .enabled else .disabled;
}

fn reloadManager(ptr: *anyopaque, env: Env) anyerror!void {
    const res = try env.runner.run(env.ctx.gpa, &.{ "fakectl", "reload-manager" }, .inherit);
    if (res.code != 0) return error.CommandFailed;
    if (!env.ctx.dry_run) me(ptr).reload_count += 1;
}

fn power(ptr: *anyopaque, env: Env, action: interface.Power) anyerror!void {
    const res = try env.runner.run(env.ctx.gpa, &.{ "fakectl", "power", @tagName(action) }, .inherit);
    if (res.code != 0) return error.CommandFailed;
    if (!env.ctx.dry_run) try me(ptr).power_calls.append(me(ptr).gpa, action);
}

/// Number of `extractExec` calls, for tests that assert native files are not read again.
pub var extract_calls: usize = 0;

fn extractExec(gpa: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!?[]const []const u8 {
    extract_calls += 1;
    const prefix = "exec = ";
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const words = try gpa.alloc([]const u8, 1);
        words[0] = line[prefix.len..];
        return words;
    }
    return null;
}
