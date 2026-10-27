// SPDX-License-Identifier: GPL-3.0-or-later
//! Everything an operation needs: allocator, I/O, filesystem, diagnostics, scope and user paths.
const std = @import("std");
const Io = std.Io;
const Fs = @import("Fs.zig");
const Diag = @import("Diag.zig");
const types = @import("types.zig");
const Config = @import("../config/Config.zig");

const Context = @This();

gpa: std.mem.Allocator,
io: Io,
fs: *Fs,
diag: *Diag,
environ: *const std.process.Environ.Map,
scope: types.Scope,
dry_run: bool = false,
offline: bool = false,
config: Config = .{},
uid: u32,
home: []const u8,
xdg_config_home: []const u8,
xdg_state_home: []const u8,
xdg_cache_home: []const u8,
xdg_runtime_dir: []const u8,

/// `gpa` is expected to be an arena: derived paths are never freed individually.
pub fn init(
    gpa: std.mem.Allocator,
    io: Io,
    fs: *Fs,
    diag: *Diag,
    environ: *const std.process.Environ.Map,
    scope: types.Scope,
    uid: u32,
) !Context {
    const home = absoluteOnly(environ.get("HOME")) orelse if (uid == 0) "/root" else "/";
    return .{
        .gpa = gpa,
        .io = io,
        .fs = fs,
        .diag = diag,
        .environ = environ,
        .scope = scope,
        .uid = uid,
        .home = home,
        .xdg_config_home = try dirFromEnv(gpa, environ, "XDG_CONFIG_HOME", home, ".config"),
        .xdg_state_home = try dirFromEnv(gpa, environ, "XDG_STATE_HOME", home, ".local/state"),
        .xdg_cache_home = try dirFromEnv(gpa, environ, "XDG_CACHE_HOME", home, ".cache"),
        .xdg_runtime_dir = absoluteOnly(environ.get("XDG_RUNTIME_DIR")) orelse
            try std.fmt.allocPrint(gpa, "/run/user/{d}", .{uid}),
    };
}

pub fn getEnv(ctx: Context, name: []const u8) ?[]const u8 {
    return ctx.environ.get(name);
}

/// An XDG base directory must be absolute; a relative value is ignored.
fn absoluteOnly(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len > 0 and v[0] == '/') v else null;
}

fn dirFromEnv(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    name: []const u8,
    home: []const u8,
    default_rel: []const u8,
) ![]const u8 {
    if (absoluteOnly(environ.get(name))) |v| return v;
    return std.fs.path.join(gpa, &.{ home, default_rel });
}

test "defaults follow systemd conventions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/u");
    var out_buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out_buf);
    var diag: Diag = .init(&w, .notice);
    var fs: Fs = undefined;
    const ctx: Context = try .init(arena.allocator(), std.testing.io, &fs, &diag, &env, .user, 1000);
    try std.testing.expectEqualStrings("/home/u/.config", ctx.xdg_config_home);
    try std.testing.expectEqualStrings("/home/u/.local/state", ctx.xdg_state_home);
    try std.testing.expectEqualStrings("/home/u/.cache", ctx.xdg_cache_home);
    try std.testing.expectEqualStrings("/run/user/1000", ctx.xdg_runtime_dir);
    try std.testing.expectEqualStrings("/home/u", ctx.getEnv("HOME").?);
}

test "environment overrides win" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", "/s");
    try env.put("XDG_RUNTIME_DIR", "/r");
    var out_buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out_buf);
    var diag: Diag = .init(&w, .notice);
    var fs: Fs = undefined;
    const ctx: Context = try .init(arena.allocator(), std.testing.io, &fs, &diag, &env, .system, 0);
    try std.testing.expectEqualStrings("/s", ctx.xdg_state_home);
    try std.testing.expectEqualStrings("/r", ctx.xdg_runtime_dir);
    try std.testing.expectEqualStrings("/root/.config", ctx.xdg_config_home);
}

test "relative XDG values are ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/u");
    try env.put("XDG_CONFIG_HOME", "rel/config");
    try env.put("XDG_STATE_HOME", "../state");
    try env.put("XDG_CACHE_HOME", ".");
    try env.put("XDG_RUNTIME_DIR", "run");
    var out_buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out_buf);
    var diag: Diag = .init(&w, .notice);
    var fs: Fs = undefined;
    const ctx: Context = try .init(arena.allocator(), std.testing.io, &fs, &diag, &env, .user, 1000);
    try std.testing.expectEqualStrings("/home/u/.config", ctx.xdg_config_home);
    try std.testing.expectEqualStrings("/home/u/.local/state", ctx.xdg_state_home);
    try std.testing.expectEqualStrings("/home/u/.cache", ctx.xdg_cache_home);
    try std.testing.expectEqualStrings("/run/user/1000", ctx.xdg_runtime_dir);
}
