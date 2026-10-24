//! Backend for an unknown or unsupported init: queries answer inactive/disabled and every
//! mutation fails with a message explaining how to select a backend.
const std = @import("std");
const core = @import("../core/root.zig");
const output = @import("../cli/output.zig");
const rebuild = @import("../index/rebuild.zig");
const interface = @import("interface.zig");

const Backend = interface.Backend;
const Env = interface.Env;

const NullBackend = @This();

/// Name of the detected init, `unknown` when none; used in messages only.
detected: []const u8 = "unknown",

pub const backend_name = "null";

pub fn backend(self: *NullBackend) Backend {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: interface.VTable = .{
    .name = backend_name,
    .generator = 1,
    .caps = .{ .translates = false },
    .native_scan = nativeScan,
    .scan_dirs = scanDirs,
    .generate = generate,
    .enable = changeUnsupported,
    .disable = changeUnsupported,
    .start = unsupported,
    .stop = unsupported,
    .restart = unsupported,
    .reload = unsupported,
    .kill = killUnsupported,
    .status = status,
    .is_enabled = isEnabled,
    .reload_manager = reloadManager,
    .power = powerUnsupported,
};

fn self_(ptr: *anyopaque) *NullBackend {
    return @ptrCast(@alignCast(ptr));
}

pub const no_backend_fmt = "no supported init system was detected (found: {s}); set FAKE_SYSTEMD_INIT=<name> or Init=<name> in /etc/fake-systemd/fake-systemd.conf";

fn report(ptr: *anyopaque, env: Env) interface.Error {
    env.ctx.diag.err(no_backend_fmt, .{self_(ptr).detected});
    return error.Unsupported;
}

fn noExtractor(_: std.mem.Allocator, _: []const u8) std.mem.Allocator.Error!?[]const []const u8 {
    return null;
}

fn nativeScan(_: *anyopaque, _: Env) anyerror!interface.NativeScan {
    return .{ .dirs = &.{}, .extractor = noExtractor };
}

fn scanDirs(_: *anyopaque, _: std.mem.Allocator, _: core.Scope) anyerror![]const rebuild.ScanDir {
    return &.{};
}

fn generate(_: *anyopaque, _: std.mem.Allocator, _: interface.GenerateInput) anyerror!interface.Generated {
    return error.Unsupported;
}

fn changeUnsupported(ptr: *anyopaque, env: Env, _: []const u8, _: interface.EnableOptions) anyerror![]const interface.Change {
    return report(ptr, env);
}

fn unsupported(ptr: *anyopaque, env: Env, _: []const u8) anyerror!void {
    return report(ptr, env);
}

fn killUnsupported(ptr: *anyopaque, env: Env, _: []const u8, _: []const u8) anyerror!void {
    return report(ptr, env);
}

fn powerUnsupported(ptr: *anyopaque, env: Env, _: interface.Power) anyerror!void {
    return report(ptr, env);
}

fn status(_: *anyopaque, _: Env, _: []const u8) anyerror!interface.Status {
    return .{ .state = .inactive };
}

fn isEnabled(_: *anyopaque, _: Env, _: []const u8) anyerror!output.EnabledState {
    return .disabled;
}

fn reloadManager(_: *anyopaque, _: Env) anyerror!void {}
